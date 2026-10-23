//! `query.disk_usage@1`: capacity and use of each mounted filesystem, from
//! PID 1's mount table and `statvfs`. Inventory sensitivity. Matches
//! `Renga.Jobs.Queries.DiskUsage`. With osquery, its `mounts` table answers
//! instead.
//!
//! `statvfs` on a network or FUSE mount whose server is gone can block for
//! good, and a thread blocked in a system call cannot be stopped. Each call
//! therefore runs on its own thread, and the query waits for it only so
//! long: a mount that does not answer is left out and the result says it
//! was cut short. The stuck thread is left behind, and that mount is not
//! asked again until it returns, so a dead mount holds at most one thread
//! and never holds the job worker.

use super::{
    clip, osquery_rows, osquery_text, osquery_u64, parameters, Bounded, Query, Sensitivity,
};
use crate::{cancellation::Cancellation, jobs::JobFailure, osquery};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeSet,
    sync::{mpsc, Mutex},
    thread,
    time::{Duration, Instant},
};

const MAX_FILESYSTEMS: usize = 512;
const STATVFS_WAIT: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(50);

/// Mount points whose last probe has not returned.
static STALLED: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());
const OSQUERY_SQL: &str = "SELECT path, device, type, blocks_size, blocks, blocks_free, \
     blocks_available, inodes, inodes_free FROM mounts";

/// Kernel and virtual filesystems that hold no disk data, left out so the
/// answer is about storage.
const VIRTUAL_TYPES: &[&str] = &[
    "autofs",
    "binfmt_misc",
    "bpf",
    "cgroup",
    "cgroup2",
    "configfs",
    "debugfs",
    "devpts",
    "devtmpfs",
    "efivarfs",
    "fusectl",
    "hugetlbfs",
    "mqueue",
    "nsfs",
    "proc",
    "pstore",
    "ramfs",
    "rpc_pipefs",
    "securityfs",
    "selinuxfs",
    "squashfs",
    "sysfs",
    "tracefs",
    "tmpfs",
];

pub struct DiskUsage;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {}

/// One mounted filesystem's numbers.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Filesystem {
    pub mount_point: String,
    pub device: String,
    pub fs_type: String,
    pub size_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
    pub inodes_total: Option<u64>,
    pub inodes_used: Option<u64>,
}

impl Query for DiskUsage {
    fn name(&self) -> &'static str {
        "query.disk_usage"
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Inventory
    }

    fn answer(&self, raw: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        let Parameters {} = parameters(raw)?;
        let (filesystems, stalled) = read_filesystems(cancellation)?;
        Ok(answer(filesystems, stalled))
    }

    fn uses_osquery(&self) -> bool {
        true
    }

    fn answer_with_osquery(
        &self,
        osquery: &mut osquery::Client,
        raw: &Value,
    ) -> Result<Option<Value>, JobFailure> {
        let Parameters {} = parameters(raw)?;
        let Some(rows) = osquery_rows(osquery, OSQUERY_SQL) else {
            return Ok(None);
        };
        let filesystems = rows
            .iter()
            .filter_map(|row| {
                let number = |column| osquery_u64(row, column).unwrap_or(0);
                let usage = Usage {
                    fragment_size: number("blocks_size"),
                    blocks: number("blocks"),
                    free: number("blocks_free"),
                    available: number("blocks_available"),
                    files: number("inodes"),
                    files_free: number("inodes_free"),
                };
                Some(filesystem(
                    osquery_text(row, "path")?,
                    osquery_text(row, "device").unwrap_or(""),
                    osquery_text(row, "type")?,
                    usage,
                ))
            })
            .collect();
        // osquery's table answers from its own daemon; no statvfs here stalls.
        Ok(Some(answer(filesystems, false)))
    }
}

/// What one bounded probe came to.
#[derive(Debug, PartialEq)]
enum Probe<T> {
    Done(T),
    /// It did not answer in time, or an earlier probe of it still hasn't.
    Stalled,
}

/// Runs `probe` on its own thread and waits up to `wait` for it, keyed by
/// `key` so a key whose earlier probe is still blocked is not tried again.
fn bounded<T: Send + 'static>(
    key: &str,
    wait: Duration,
    cancellation: &Cancellation,
    probe: impl FnOnce() -> T + Send + 'static,
) -> Result<Probe<T>, JobFailure> {
    if !STALLED.lock().unwrap().insert(key.to_owned()) {
        return Ok(Probe::Stalled);
    }
    let (sender, receiver) = mpsc::channel();
    let owned = key.to_owned();
    thread::spawn(move || {
        let _ = sender.send(probe());
        STALLED.lock().unwrap().remove(&owned);
    });
    let deadline = Instant::now() + wait;
    loop {
        if cancellation.cancelled() {
            return Err(JobFailure::Cancelled);
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok(Probe::Stalled);
        }
        match receiver.recv_timeout(POLL.min(left)) {
            Ok(value) => return Ok(Probe::Done(value)),
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(Probe::Stalled),
        }
    }
}

fn answer(filesystems: Vec<Filesystem>, stalled: bool) -> Value {
    let mut list = Bounded::new(MAX_FILESYSTEMS);
    let mut seen = std::collections::HashSet::new();
    for filesystem in filesystems {
        // Bind mounts repeat a filesystem under another path; count it once.
        if VIRTUAL_TYPES.contains(&filesystem.fs_type.as_str())
            || filesystem.size_bytes == 0
            || !seen.insert(filesystem.mount_point.clone())
        {
            continue;
        }
        if !list.push(filesystem) {
            break;
        }
    }
    let (filesystems, truncated) = list.into_parts();
    serde_json::json!({ "filesystems": filesystems, "truncated": truncated || stalled })
}

/// What `statvfs` reports for one filesystem, in fragments and inodes.
#[derive(Debug, Clone, Copy, Default)]
pub struct Usage {
    pub fragment_size: u64,
    pub blocks: u64,
    pub free: u64,
    pub available: u64,
    pub files: u64,
    pub files_free: u64,
}

/// Turns `statvfs` numbers into the answer's. `used` is what `df` shows:
/// total less free blocks, so space reserved for root counts as neither used
/// nor available.
pub fn filesystem(mount_point: &str, device: &str, fs_type: &str, usage: Usage) -> Filesystem {
    let bytes = |count: u64| count.saturating_mul(usage.fragment_size);
    // Filesystems without inodes, such as btrfs and vfat, report zero.
    let (inodes_total, inodes_used) = if usage.files == 0 {
        (None, None)
    } else {
        (
            Some(usage.files),
            Some(usage.files.saturating_sub(usage.files_free)),
        )
    };
    Filesystem {
        mount_point: clip(mount_point, 512),
        device: clip(device, 256),
        fs_type: clip(fs_type, 32),
        size_bytes: bytes(usage.blocks),
        used_bytes: bytes(usage.blocks.saturating_sub(usage.free)),
        available_bytes: bytes(usage.available),
        inodes_total,
        inodes_used,
    }
}

#[cfg(target_os = "linux")]
fn read_filesystems(cancellation: &Cancellation) -> Result<(Vec<Filesystem>, bool), JobFailure> {
    use crate::collectors::filesystem_facts::{FilesystemFactsSource, ProcfsSource};
    use std::{ffi::CString, mem::MaybeUninit};

    let mounts = ProcfsSource::host_pid_one()
        .collect()
        .map_err(|_| super::failed("could not read the mount table"))?;
    let mut filesystems = Vec::new();
    let mut stalled = false;
    for mount in mounts {
        if cancellation.cancelled() {
            return Err(JobFailure::Cancelled);
        }
        if VIRTUAL_TYPES.contains(&mount.filesystem_type.as_str()) {
            continue;
        }
        let Ok(path) = CString::new(mount.mountpoint.as_str()) else {
            continue;
        };
        let probe = bounded(&mount.mountpoint, STATVFS_WAIT, cancellation, move || {
            let mut stat = MaybeUninit::<libc::statvfs>::uninit();
            // SAFETY: `path` is NUL-terminated and `stat` is written by
            // statvfs before it is read, which happens only when the call
            // succeeds.
            (unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } == 0)
                .then(|| unsafe { stat.assume_init() })
        })?;
        // A mount the agent cannot reach, such as one inside another
        // namespace, is skipped rather than failing the query.
        let stat = match probe {
            Probe::Done(Some(stat)) => stat,
            Probe::Done(None) => continue,
            Probe::Stalled => {
                stalled = true;
                continue;
            }
        };
        // The fields are 32 bits wide on 32-bit targets.
        #[allow(clippy::unnecessary_cast)]
        let usage = Usage {
            fragment_size: stat.f_frsize as u64,
            blocks: stat.f_blocks as u64,
            free: stat.f_bfree as u64,
            available: stat.f_bavail as u64,
            files: stat.f_files as u64,
            files_free: stat.f_ffree as u64,
        };
        filesystems.push(filesystem(
            &mount.mountpoint,
            mount.device.as_deref().unwrap_or(""),
            &mount.filesystem_type,
            usage,
        ));
    }
    Ok((filesystems, stalled))
}

#[cfg(not(target_os = "linux"))]
fn read_filesystems(_: &Cancellation) -> Result<(Vec<Filesystem>, bool), JobFailure> {
    Err(super::failed("disk usage is only read on Linux"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reports_storage_once_per_mount_point() {
        let usage = |fragment_size, blocks, free, available, files, files_free| Usage {
            fragment_size,
            blocks,
            free,
            available,
            files,
            files_free,
        };
        let root = filesystem("/", "/dev/sda1", "ext4", usage(4096, 100, 40, 30, 10, 8));
        assert_eq!(root.size_bytes, 409_600);
        assert_eq!(root.used_bytes, 245_760);
        assert_eq!(root.available_bytes, 122_880);
        assert_eq!((root.inodes_total, root.inodes_used), (Some(10), Some(2)));

        let boot = filesystem("/boot/efi", "/dev/sda2", "vfat", usage(512, 10, 5, 5, 0, 0));
        let run = filesystem("/run", "tmpfs", "tmpfs", usage(4096, 10, 10, 10, 10, 10));
        let value = answer(vec![root.clone(), root.clone(), boot, run], false);

        assert_eq!(value["truncated"], json!(false));
        let mounts: Vec<&str> = value["filesystems"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["mount_point"].as_str().unwrap())
            .collect();
        assert_eq!(mounts, ["/", "/boot/efi"]);
        assert_eq!(value["filesystems"][1]["inodes_total"], Value::Null);
        super::super::contract::assert_conforms("query.disk_usage@1", "result", &value);

        // A mount left out because it stalled cuts the answer short.
        assert_eq!(answer(vec![root], true)["truncated"], json!(true));
    }

    #[test]
    fn a_stalled_probe_frees_the_query_and_is_not_repeated() {
        let (release, hold) = mpsc::channel::<()>();
        let started = Instant::now();
        let first = bounded(
            "/stuck",
            Duration::from_millis(100),
            &Cancellation::default(),
            move || hold.recv().ok(),
        );
        assert_eq!(first.unwrap(), Probe::Stalled);
        assert!(started.elapsed() < Duration::from_secs(1));

        // While the first is blocked, the same mount is not probed again.
        let ran = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = ran.clone();
        let again = bounded(
            "/stuck",
            Duration::from_millis(100),
            &Cancellation::default(),
            move || flag.store(true, std::sync::atomic::Ordering::SeqCst),
        );
        assert_eq!(again.unwrap(), Probe::Stalled);
        assert!(!ran.load(std::sync::atomic::Ordering::SeqCst));

        // Once it returns, the mount is probed as usual.
        release.send(()).unwrap();
        let wait = Instant::now() + Duration::from_secs(5);
        while STALLED.lock().unwrap().contains("/stuck") && Instant::now() < wait {
            thread::sleep(Duration::from_millis(10));
        }
        let ok = bounded(
            "/stuck",
            Duration::from_secs(1),
            &Cancellation::default(),
            || 7,
        );
        assert_eq!(ok.unwrap(), Probe::Done(7));
    }

    #[test]
    fn cancellation_stops_waiting_for_a_probe() {
        let stopped = Cancellation::default();
        let trigger = stopped.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            trigger.cancel();
        });
        let result = bounded("/cancel", Duration::from_secs(5), &stopped, || {
            thread::sleep(Duration::from_millis(500))
        });
        assert!(matches!(result, Err(JobFailure::Cancelled)));
    }

    #[test]
    fn takes_no_parameters() {
        assert!(DiskUsage
            .answer(&json!({"path": "/"}), &Cancellation::default())
            .is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn reads_this_host() {
        let value = DiskUsage
            .answer(&json!({}), &Cancellation::default())
            .unwrap();
        super::super::contract::assert_conforms("query.disk_usage@1", "result", &value);
    }
}
