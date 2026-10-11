//! Bounded on-disk queue of encoded observations.
//!
//! An observation is written here before its first delivery attempt and removed only when the
//! server accepts it or rejects the payload itself, so a network outage or an agent restart does
//! not lose inventory (RFD 1, "Collection model"). Each entry is one file holding the exact
//! request body, which lets the server recognize a replay by its observation ID; file names sort
//! in queue order.
//!
//! Limits on entries, bytes, and age keep the directory bounded. When a new observation would
//! exceed them the oldest entries go first, because a host agent's observation is a full snapshot
//! and the newest one carries the most current state.

use crate::{
    cancellation::Cancellation,
    transport::{FailureKind, TransportError},
};
use std::{
    fmt, fs,
    io::{self, Write},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tracing::warn;
use uuid::Uuid;

const QUEUE_DIRECTORY: &str = "observations";
const ENTRY_SUFFIX: &str = ".json";
const TEMPORARY_PREFIX: &str = ".tmp-";
/// A temporary file this old was left by an interrupted write rather than one in progress.
const ABANDONED_TEMPORARY_AGE: Duration = Duration::from_secs(600);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueueLimits {
    pub max_entries: usize,
    pub max_bytes: u64,
    pub max_age: Duration,
}

impl Default for QueueLimits {
    /// A week of hourly inventory fits within the entry count, and the byte limit still holds
    /// over 250 observations at the API's 256 kB maximum.
    fn default() -> Self {
        Self {
            max_entries: 512,
            max_bytes: 64 * 1024 * 1024,
            max_age: Duration::from_secs(7 * 24 * 60 * 60),
        }
    }
}

/// Entries this process removed without delivering them, by reason.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct QueueCounters {
    /// Oldest entries dropped to make room under the entry or byte limit.
    pub dropped_for_space: u64,
    /// Entries older than the age limit.
    pub expired: u64,
    /// Entries the server refused as payloads it will never accept.
    pub rejected: u64,
    /// Entries that could not be read back.
    pub unreadable: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueHealth {
    pub entries: usize,
    pub bytes: u64,
    pub oldest_age: Option<Duration>,
    pub counters: QueueCounters,
}

/// The result of one pass over the queue.
#[derive(Debug, Default)]
pub struct Drained {
    pub delivered: usize,
    pub rejected: usize,
    /// The failure that stopped the pass, leaving that entry and every later one queued.
    pub blocked: Option<TransportError>,
}

#[derive(Debug)]
pub struct QueueError(String);

impl fmt::Display for QueueError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for QueueError {}

fn io_error(action: &str, path: &Path, error: io::Error) -> QueueError {
    QueueError(format!("cannot {action} {}: {error}", path.display()))
}

#[derive(Debug)]
struct Entry {
    path: PathBuf,
    sequence: u64,
    queued_at: SystemTime,
    bytes: u64,
}

impl Entry {
    fn age(&self, now: SystemTime) -> Duration {
        // A clock stepped backwards makes an entry look new rather than expiring it early.
        now.duration_since(self.queued_at).unwrap_or_default()
    }
}

pub struct ObservationQueue {
    directory: PathBuf,
    limits: QueueLimits,
    next_sequence: u64,
    counters: QueueCounters,
}

impl ObservationQueue {
    /// Opens the queue under the agent's state directory, creating it on first use.
    pub fn open(state_directory: &Path, limits: QueueLimits) -> Result<Self, QueueError> {
        let directory = state_directory.join(QUEUE_DIRECTORY);
        fs::create_dir_all(&directory)
            .map_err(|error| io_error("create observation queue", &directory, error))?;
        let metadata = fs::symlink_metadata(&directory)
            .map_err(|error| io_error("inspect observation queue", &directory, error))?;
        if !metadata.is_dir() {
            return Err(QueueError(format!(
                "observation queue {} is not a directory",
                directory.display()
            )));
        }
        set_mode(&directory, 0o700)?;
        // The child's sync cannot persist its name in the parent after first-use creation.
        sync_directory(state_directory)?;

        let mut queue = Self {
            directory,
            limits,
            next_sequence: 0,
            counters: QueueCounters::default(),
        };
        queue.remove_abandoned_temporaries(SystemTime::now())?;
        queue.next_sequence = queue
            .entries()?
            .last()
            .map_or(0, |entry| entry.sequence + 1);
        Ok(queue)
    }

    /// Persists an encoded observation, durably, behind every entry already queued.
    pub fn enqueue(
        &mut self,
        observation_id: Uuid,
        body: &[u8],
        now: SystemTime,
    ) -> Result<(), QueueError> {
        let size = body.len() as u64;
        if size > self.limits.max_bytes {
            return Err(QueueError(format!(
                "observation of {size} bytes exceeds the {}-byte queue limit",
                self.limits.max_bytes
            )));
        }
        let entries = self.expire(self.entries()?, now)?;
        let sequence = self
            .next_sequence
            .max(entries.last().map_or(0, |entry| entry.sequence + 1));

        let mut remaining = entries.len();
        let mut bytes: u64 = entries.iter().map(|entry| entry.bytes).sum();
        for oldest in &entries {
            if remaining < self.limits.max_entries && bytes + size <= self.limits.max_bytes {
                break;
            }
            warn!(
                entry = %oldest.path.display(),
                "observation queue full; dropping its oldest observation"
            );
            if remove(&oldest.path)? {
                self.counters.dropped_for_space += 1;
            }
            remaining -= 1;
            bytes -= oldest.bytes;
        }

        let path = self
            .directory
            .join(entry_name(sequence, now, observation_id));
        self.write_atomically(&path, body)?;
        self.next_sequence = sequence + 1;
        Ok(())
    }

    /// Delivers queued observations oldest first. An accepted or rejected entry is removed and
    /// the pass continues; any other failure stops it so the entry keeps its place in line.
    pub fn drain(
        &mut self,
        now: SystemTime,
        cancellation: &Cancellation,
        mut deliver: impl FnMut(&[u8]) -> Result<(), TransportError>,
    ) -> Result<Drained, QueueError> {
        let mut drained = Drained::default();
        for entry in self.expire(self.entries()?, now)? {
            if cancellation.cancelled() {
                break;
            }
            let body = match fs::read(&entry.path) {
                Ok(body) => body,
                // Another agent process sharing this state directory delivered it first.
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(error) => {
                    warn!(entry = %entry.path.display(), %error, "dropping unreadable queued observation");
                    if remove(&entry.path)? {
                        self.counters.unreadable += 1;
                    }
                    continue;
                }
            };
            match deliver(&body) {
                Ok(()) => {
                    remove(&entry.path)?;
                    drained.delivered += 1;
                }
                Err(error) if error.kind() == FailureKind::PayloadRejected => {
                    warn!(entry = %entry.path.display(), %error, "server rejected queued observation; dropping it");
                    if remove(&entry.path)? {
                        self.counters.rejected += 1;
                        drained.rejected += 1;
                    }
                }
                Err(error) => {
                    drained.blocked = Some(error);
                    break;
                }
            }
        }
        Ok(drained)
    }

    pub fn health(&self, now: SystemTime) -> Result<QueueHealth, QueueError> {
        let entries = self.entries()?;
        Ok(QueueHealth {
            entries: entries.len(),
            bytes: entries.iter().map(|entry| entry.bytes).sum(),
            oldest_age: entries.first().map(|entry| entry.age(now)),
            counters: self.counters,
        })
    }

    /// Queued entries in delivery order. Files the queue did not name are left alone.
    fn entries(&self) -> Result<Vec<Entry>, QueueError> {
        let listing = fs::read_dir(&self.directory)
            .map_err(|error| io_error("list observation queue", &self.directory, error))?;
        let mut entries = Vec::new();
        for item in listing {
            let item =
                item.map_err(|error| io_error("list observation queue", &self.directory, error))?;
            let Some((sequence, queued_at)) = item.file_name().to_str().and_then(parse_entry_name)
            else {
                continue;
            };
            let metadata = match fs::symlink_metadata(item.path()) {
                Ok(metadata) if metadata.is_file() => metadata,
                _ => continue,
            };
            entries.push(Entry {
                path: item.path(),
                sequence,
                queued_at,
                bytes: metadata.len(),
            });
        }
        entries
            .sort_by(|left, right| (left.sequence, &left.path).cmp(&(right.sequence, &right.path)));
        Ok(entries)
    }

    fn expire(&mut self, entries: Vec<Entry>, now: SystemTime) -> Result<Vec<Entry>, QueueError> {
        let (expired, current): (Vec<_>, Vec<_>) = entries
            .into_iter()
            .partition(|entry| entry.age(now) > self.limits.max_age);
        for entry in expired {
            warn!(entry = %entry.path.display(), "dropping queued observation older than the queue's age limit");
            if remove(&entry.path)? {
                self.counters.expired += 1;
            }
        }
        Ok(current)
    }

    fn write_atomically(&self, path: &Path, body: &[u8]) -> Result<(), QueueError> {
        let temporary = self
            .directory
            .join(format!("{TEMPORARY_PREFIX}{}", Uuid::new_v4()));
        let result = (|| {
            let mut file = create_private_file(&temporary)?;
            file.write_all(body)
                .and_then(|()| file.sync_all())
                .map_err(|error| io_error("write queued observation", &temporary, error))?;
            fs::rename(&temporary, path)
                .map_err(|error| io_error("persist queued observation", path, error))?;
            sync_directory(&self.directory)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    fn remove_abandoned_temporaries(&self, now: SystemTime) -> Result<(), QueueError> {
        let listing = fs::read_dir(&self.directory)
            .map_err(|error| io_error("list observation queue", &self.directory, error))?;
        for item in listing.flatten() {
            let abandoned = item
                .file_name()
                .to_str()
                .is_some_and(|name| name.starts_with(TEMPORARY_PREFIX))
                && item
                    .metadata()
                    .and_then(|metadata| metadata.modified())
                    .is_ok_and(|modified| {
                        now.duration_since(modified).unwrap_or_default() > ABANDONED_TEMPORARY_AGE
                    });
            if abandoned {
                remove(&item.path())?;
            }
        }
        Ok(())
    }
}

/// `<sequence>-<queued unix seconds>-<observation id>.json`, zero-padded so names sort in queue
/// order. The observation ID keeps names unique even if two processes pick the same sequence.
fn entry_name(sequence: u64, queued_at: SystemTime, observation_id: Uuid) -> String {
    let seconds = queued_at
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{sequence:020}-{seconds:012}-{observation_id}{ENTRY_SUFFIX}")
}

fn parse_entry_name(name: &str) -> Option<(u64, SystemTime)> {
    let mut parts = name.strip_suffix(ENTRY_SUFFIX)?.splitn(3, '-');
    let sequence = parts.next()?;
    let seconds = parts.next()?;
    let observation_id = parts.next()?;
    if sequence.len() != 20 || seconds.len() != 12 || Uuid::parse_str(observation_id).is_err() {
        return None;
    }
    let queued_at = UNIX_EPOCH + Duration::from_secs(seconds.parse().ok()?);
    Some((sequence.parse().ok()?, queued_at))
}

/// Only a successful unlink frees capacity and counts as this process dropping an entry.
fn remove(path: &Path) -> Result<bool, QueueError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(io_error("remove queued observation", path, error)),
    }
}

fn create_private_file(path: &Path) -> Result<fs::File, QueueError> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map_err(|error| io_error("create queued observation", path, error))
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), QueueError> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| io_error("sync observation queue", path, error))
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<(), QueueError> {
    Ok(())
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<(), QueueError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .map_err(|error| io_error("protect observation queue", path, error))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<(), QueueError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct Fixture {
        state: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            Self {
                state: std::env::temp_dir().join(format!("renga-queue-{}", Uuid::new_v4())),
            }
        }

        fn open(&self, limits: QueueLimits) -> ObservationQueue {
            ObservationQueue::open(&self.state, limits).unwrap()
        }

        fn directory(&self) -> PathBuf {
            self.state.join(QUEUE_DIRECTORY)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.state);
        }
    }

    fn limits(max_entries: usize, max_bytes: u64, max_age_seconds: u64) -> QueueLimits {
        QueueLimits {
            max_entries,
            max_bytes,
            max_age: Duration::from_secs(max_age_seconds),
        }
    }

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(1_800_000_000 + seconds)
    }

    fn enqueue(queue: &mut ObservationQueue, body: &str, now: SystemTime) {
        queue.enqueue(Uuid::new_v4(), body.as_bytes(), now).unwrap();
    }

    /// Drains, recording each body offered, and answers with `outcome` per body.
    fn drain_with(
        queue: &mut ObservationQueue,
        now: SystemTime,
        outcome: impl Fn(&str) -> Result<(), TransportError>,
    ) -> (Drained, Vec<String>) {
        let offered = RefCell::new(Vec::new());
        let drained = queue
            .drain(now, &Cancellation::default(), |body| {
                let body = String::from_utf8(body.to_vec()).unwrap();
                offered.borrow_mut().push(body.clone());
                outcome(&body)
            })
            .unwrap();
        (drained, offered.into_inner())
    }

    fn accept(_body: &str) -> Result<(), TransportError> {
        Ok(())
    }

    fn failure(kind: FailureKind) -> TransportError {
        TransportError::new("failure".into(), kind)
    }

    #[test]
    fn entries_survive_a_restart_and_deliver_oldest_first() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(QueueLimits::default());
        enqueue(&mut queue, "first", at(0));
        enqueue(&mut queue, "second", at(1));
        drop(queue);

        // Entries queued after the restart still go behind the ones before it.
        let mut queue = fixture.open(QueueLimits::default());
        enqueue(&mut queue, "third", at(2));
        let (drained, offered) = drain_with(&mut queue, at(3), accept);

        assert_eq!(offered, ["first", "second", "third"]);
        assert_eq!((drained.delivered, drained.rejected), (3, 0));
        assert!(drained.blocked.is_none());
        assert_eq!(queue.health(at(3)).unwrap().entries, 0);
    }

    #[test]
    fn a_failure_the_payload_may_get_past_keeps_it_in_line() {
        for kind in [FailureKind::Transient, FailureKind::Permanent] {
            let fixture = Fixture::new();
            let mut queue = fixture.open(QueueLimits::default());
            for body in ["first", "second", "third"] {
                enqueue(&mut queue, body, at(0));
            }

            let (drained, offered) = drain_with(&mut queue, at(1), |body| {
                if body == "second" {
                    Err(failure(kind))
                } else {
                    Ok(())
                }
            });

            assert_eq!(offered, ["first", "second"], "{kind:?}");
            assert_eq!(drained.delivered, 1);
            assert_eq!(drained.blocked.unwrap().kind(), kind);

            let (_drained, offered) = drain_with(&mut queue, at(2), accept);
            assert_eq!(offered, ["second", "third"], "{kind:?}");
        }
    }

    #[test]
    fn a_rejected_payload_is_dropped_and_the_pass_continues() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(QueueLimits::default());
        for body in ["first", "malformed", "third"] {
            enqueue(&mut queue, body, at(0));
        }

        let (drained, offered) = drain_with(&mut queue, at(1), |body| {
            if body == "malformed" {
                Err(failure(FailureKind::PayloadRejected))
            } else {
                Ok(())
            }
        });

        assert_eq!(offered, ["first", "malformed", "third"]);
        assert_eq!((drained.delivered, drained.rejected), (2, 1));
        let health = queue.health(at(1)).unwrap();
        assert_eq!(health.entries, 0);
        assert_eq!(health.counters.rejected, 1);
    }

    #[test]
    fn the_entry_limit_drops_the_oldest_observations() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(limits(2, 1_000, 3_600));
        for body in ["first", "second", "third"] {
            enqueue(&mut queue, body, at(0));
        }

        assert_eq!(queue.health(at(0)).unwrap().counters.dropped_for_space, 1);
        let (_drained, offered) = drain_with(&mut queue, at(0), accept);
        assert_eq!(offered, ["second", "third"]);
    }

    #[test]
    fn the_byte_limit_drops_the_oldest_observations_before_writing() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(limits(100, 10, 3_600));
        for body in ["aaaa", "bbbb", "cccc"] {
            enqueue(&mut queue, body, at(0));
        }

        let health = queue.health(at(0)).unwrap();
        assert_eq!((health.entries, health.bytes), (2, 8));
        assert_eq!(health.counters.dropped_for_space, 1);

        // An observation that could never fit is refused without disturbing the queue.
        assert!(queue
            .enqueue(Uuid::new_v4(), b"far too large", at(0))
            .is_err());
        let (_drained, offered) = drain_with(&mut queue, at(0), accept);
        assert_eq!(offered, ["bbbb", "cccc"]);
    }

    #[test]
    fn observations_older_than_the_age_limit_expire_undelivered() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(limits(100, 1_000, 60));
        enqueue(&mut queue, "stale", at(0));
        enqueue(&mut queue, "fresh", at(30));

        let (_drained, offered) = drain_with(&mut queue, at(61), accept);

        assert_eq!(offered, ["fresh"]);
        assert_eq!(queue.health(at(61)).unwrap().counters.expired, 1);
    }

    #[test]
    fn a_clock_stepped_backwards_does_not_expire_entries() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(limits(100, 1_000, 60));
        enqueue(&mut queue, "queued", at(1_000));

        let health = queue.health(at(0)).unwrap();
        assert_eq!(health.oldest_age, Some(Duration::ZERO));
        let (_drained, offered) = drain_with(&mut queue, at(0), accept);
        assert_eq!(offered, ["queued"]);
    }

    #[cfg(unix)]
    #[test]
    fn failed_unlinks_do_not_claim_capacity_or_count_drops() {
        // Root bypasses directory permissions; this fault requires an unprivileged process.
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        for now in [at(0), at(61)] {
            let fixture = Fixture::new();
            let mut queue = fixture.open(limits(1, 10, 60));
            enqueue(&mut queue, "old", at(0));
            set_mode(&fixture.directory(), 0o500).unwrap();

            let result = queue.enqueue(Uuid::new_v4(), b"new", now);
            let drained = queue.drain(now, &Cancellation::default(), |_| Ok(()));
            let health = queue.health(now).unwrap();
            set_mode(&fixture.directory(), 0o700).unwrap();

            assert!(result.is_err());
            assert!(drained.is_err());
            assert_eq!((health.entries, health.bytes), (1, 3));
            assert_eq!(health.counters, QueueCounters::default());
            assert_eq!(drain_with(&mut queue, at(0), accept).1, ["old"]);
        }
    }

    #[test]
    fn health_reports_size_and_the_oldest_entry_age() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(QueueLimits::default());
        assert_eq!(
            queue.health(at(0)).unwrap(),
            QueueHealth {
                entries: 0,
                bytes: 0,
                oldest_age: None,
                counters: QueueCounters::default(),
            }
        );

        enqueue(&mut queue, "abc", at(10));
        enqueue(&mut queue, "defgh", at(40));

        let health = queue.health(at(100)).unwrap();
        assert_eq!((health.entries, health.bytes), (2, 8));
        assert_eq!(health.oldest_age, Some(Duration::from_secs(90)));
    }

    #[test]
    fn cancellation_stops_before_the_next_entry() {
        let fixture = Fixture::new();
        let mut queue = fixture.open(QueueLimits::default());
        enqueue(&mut queue, "first", at(0));
        enqueue(&mut queue, "second", at(0));
        let cancellation = Cancellation::default();

        let drained = queue
            .drain(at(0), &cancellation, |_body| {
                cancellation.cancel();
                Ok(())
            })
            .unwrap();

        assert_eq!(drained.delivered, 1);
        assert_eq!(queue.health(at(0)).unwrap().entries, 1);
    }

    #[test]
    fn foreign_files_are_ignored_and_abandoned_writes_cleaned_up() {
        let fixture = Fixture::new();
        drop(fixture.open(QueueLimits::default()));
        let directory = fixture.directory();
        fs::write(directory.join("notes.txt"), "operator file").unwrap();
        let abandoned = directory.join(format!("{TEMPORARY_PREFIX}abandoned"));
        let in_progress = directory.join(format!("{TEMPORARY_PREFIX}in-progress"));
        fs::write(&abandoned, "partial").unwrap();
        fs::write(&in_progress, "partial").unwrap();
        fs::File::options()
            .write(true)
            .open(&abandoned)
            .unwrap()
            .set_modified(SystemTime::now() - ABANDONED_TEMPORARY_AGE * 2)
            .unwrap();

        let mut queue = fixture.open(QueueLimits::default());

        assert!(!abandoned.exists());
        assert!(in_progress.exists());
        assert_eq!(queue.health(at(0)).unwrap().entries, 0);
        let (_drained, offered) = drain_with(&mut queue, at(0), accept);
        assert!(offered.is_empty());
        assert!(directory.join("notes.txt").exists());
    }

    #[cfg(unix)]
    #[test]
    fn the_queue_and_its_entries_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = Fixture::new();
        let mut queue = fixture.open(QueueLimits::default());
        enqueue(&mut queue, "secret inventory", at(0));

        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&fixture.directory()), 0o700);
        for item in fs::read_dir(fixture.directory()).unwrap() {
            assert_eq!(mode(&item.unwrap().path()), 0o600);
        }
    }

    #[test]
    fn entry_names_round_trip_and_reject_lookalikes() {
        let id = Uuid::new_v4();
        let name = entry_name(42, at(5), id);
        assert_eq!(parse_entry_name(&name), Some((42, at(5))));

        for name in [
            "notes.txt",
            "42-1800000005-not-a-uuid.json",
            &format!("{:020}-{:012}-{id}.tmp", 1, 1),
            &format!("{:020}-{:012}-oops.json", 1, 1),
        ] {
            assert_eq!(parse_entry_name(name), None, "{name}");
        }
    }
}
