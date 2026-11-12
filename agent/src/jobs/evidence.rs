//! Local protected output headroom, acquired before requesting a lease.
//!
//! Fixed-size, fsynced slots cannot be consumed by ordinary queue eviction.
//! Unbound slots survive a lost lease response for its authority horizon; bound
//! evidence survives restart through the job retry horizon. A process-wide job
//! pass claim serializes writers sharing a state directory, not ordinary intake.

use crate::payload::LeasedJob;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

const SLOTS: usize = 128;
// Exact JSON evidence may be escaped again in the envelope; include room for
// bounded terminal output and metadata, not only the observation's raw bytes.
const SLOT_BYTES: usize = 768 * 1024;
const HEADER_BYTES: usize = 44;
const RETENTION: chrono::TimeDelta = chrono::TimeDelta::days(8);

pub struct OutputStore {
    directory: PathBuf,
    _claim: fs::File,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Evidence {
    pub attempt: u32,
    pub lease_token: String,
    pub observation_id: Uuid,
    pub sha256: String,
    pub body: String,
    pub accepted: bool,
}

#[derive(Serialize, Deserialize)]
struct Slot {
    job: Option<Uuid>,
    expires_at: DateTime<Utc>,
    evidence: Option<Evidence>,
    #[serde(default)]
    outcome: Option<super::record::Outcome>,
}

fn private_file(path: &Path) -> io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.create_new(true).write(true).read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

#[cfg(target_os = "linux")]
fn allocate_banks(file: &fs::File) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let mut status = std::mem::MaybeUninit::<libc::statfs>::uninit();
    if unsafe { libc::fstatfs(file.as_raw_fd(), status.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let kind = unsafe { status.assume_init() }.f_type;
    // Preallocation on COW filesystems reserves only unwritten extents, not
    // repeated journal overwrites. Keep the supported boundary explicit;
    // snapshots/reflinks must not silently turn reserved output into new allocation.
    if !matches!(kind, libc::EXT4_SUPER_MAGIC | libc::TMPFS_MAGIC) {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "protected jobs require an ext4 or tmpfs state directory; COW and other filesystems are unsupported",
        ));
    }
    let result =
        unsafe { libc::fallocate(file.as_raw_fd(), 0, 0, (SLOT_BYTES * 2) as libc::off_t) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn allocate_banks(_file: &fs::File) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "protected jobs require a supported Linux state filesystem",
    ))
}

impl OutputStore {
    pub fn open(state: &Path) -> io::Result<Self> {
        let directory = state.join("job-output");
        fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        }
        let claim = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(directory.join(".worker"))?;
        claim.try_lock().map_err(io::Error::other)?;
        let store = Self {
            directory,
            _claim: claim,
        };
        // Only a slot allocated before a lease request can be incomplete here.
        for item in fs::read_dir(&store.directory)? {
            let item = item?;
            if item.file_name().to_string_lossy().starts_with(".tmp-") {
                fs::remove_file(item.path())?;
            } else if item.path().extension().is_some_and(|ext| ext == "journal") {
                let (_, _, slot) = Self::read_slot(&item.path())?;
                if slot.expires_at <= Utc::now() {
                    tracing::warn!(path = %item.path().display(), "protected job output expired at retry horizon");
                    fs::remove_file(item.path())?;
                }
            }
        }
        store.sync()?;
        Ok(store)
    }

    /// Reserve future-write extents, not a sparse or compressible zero-fill promise.
    /// Failure prevents the lease request; a lost response leaves this slot reclaimable.
    pub fn reserve(&self) -> io::Result<PathBuf> {
        let count = fs::read_dir(&self.directory)?
            .collect::<io::Result<Vec<_>>>()?
            .iter()
            .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "journal"))
            .count();
        if count >= SLOTS {
            return Err(io::Error::other(
                "protected job output is full; refusing new leases",
            ));
        }
        let temporary = self.directory.join(format!(".tmp-{}", Uuid::new_v4()));
        let path = self
            .directory
            .join(format!("slot-{}.journal", Uuid::new_v4()));
        let result = (|| {
            let mut file = private_file(&temporary)?;
            // Both journal banks and the directory entry exist durably before
            // asking for a lease. Updates never create/rename/extend a file.
            allocate_banks(&file)?;
            file.sync_all()?;
            Self::commit_bank(
                &mut file,
                0,
                1,
                &Slot {
                    job: None,
                    // A lease request is bounded to 30s, and server authority lasts 60s.
                    expires_at: Utc::now() + chrono::TimeDelta::seconds(120),
                    evidence: None,
                    outcome: None,
                },
            )?;
            fs::rename(&temporary, &path)?;
            self.sync()
        })();
        if let Err(error) = result {
            let _ = fs::remove_file(temporary);
            return Err(error);
        }
        Ok(path)
    }

    pub fn bind(&self, pending: &Path, job: &LeasedJob) -> io::Result<()> {
        if Self::find(&self.directory, job.id)?.is_some() {
            return self.release(pending);
        }
        Self::write_slot(
            pending,
            &Slot {
                job: Some(job.id),
                expires_at: Utc::now() + RETENTION,
                evidence: None,
                outcome: None,
            },
        )
    }

    pub fn release(&self, path: &Path) -> io::Result<()> {
        match fs::remove_file(path) {
            Ok(()) => self.sync(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }

    pub fn confirm(&self, job: Uuid) -> io::Result<()> {
        if let Some((path, _)) = Self::find(&self.directory, job)? {
            self.release(&path)?;
        }
        Ok(())
    }

    fn find(directory: &Path, job: Uuid) -> io::Result<Option<(PathBuf, Slot)>> {
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            if path.extension().is_some_and(|ext| ext == "journal") {
                let (_, _, slot) = Self::read_slot(&path)?;
                if slot.job == Some(job) {
                    return Ok(Some((path, slot)));
                }
            }
        }
        Ok(None)
    }

    fn required(state: &Path, job: Uuid) -> io::Result<(PathBuf, Slot)> {
        Self::find(&state.join("job-output"), job)?.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "protected output reservation missing",
            )
        })
    }

    pub fn load(state: &Path, job: Uuid) -> io::Result<Option<Evidence>> {
        // A missing reservation is an error, not permission to execute unreserved.
        let (_, slot) = Self::required(state, job)?;
        Ok(slot.evidence)
    }

    pub fn save(state: &Path, job: Uuid, evidence: Evidence) -> io::Result<()> {
        let (path, mut slot) = Self::required(state, job)?;
        slot.evidence = Some(evidence);
        Self::write_slot(&path, &slot)
    }

    pub fn outcome(state: &Path, job: Uuid) -> io::Result<Option<super::record::Outcome>> {
        let (_, slot) = Self::required(state, job)?;
        Ok(slot.outcome)
    }

    pub fn save_outcome(
        state: &Path,
        job: Uuid,
        outcome: &super::record::Outcome,
    ) -> io::Result<()> {
        let (path, mut slot) = Self::required(state, job)?;
        slot.outcome = Some(outcome.clone());
        Self::write_slot(&path, &slot)
    }

    fn read_slot(path: &Path) -> io::Result<(usize, u64, Slot)> {
        let mut file = fs::File::open(path)?;
        let mut latest = None;
        for bank in 0..2 {
            file.seek(SeekFrom::Start((bank * SLOT_BYTES) as u64))?;
            let mut header = [0; HEADER_BYTES];
            if file.read_exact(&mut header).is_err() {
                continue;
            }
            let generation = u64::from_le_bytes(header[..8].try_into().unwrap());
            let size = u32::from_le_bytes(header[8..12].try_into().unwrap()) as usize;
            if generation == 0 || size > SLOT_BYTES - HEADER_BYTES {
                continue;
            }
            let mut body = vec![0; size];
            if file.read_exact(&mut body).is_err() {
                continue;
            }
            let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
            digest.update(&header[..12]);
            digest.update(&body);
            if digest.finish().as_ref() != &header[12..] {
                continue;
            }
            let slot: Slot = serde_json::from_slice(&body)?;
            if latest
                .as_ref()
                .is_none_or(|(_, previous, _)| generation > *previous)
            {
                latest = Some((bank, generation, slot));
            }
        }
        latest.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "no committed protected output bank",
            )
        })
    }

    fn write_slot(path: &Path, slot: &Slot) -> io::Result<()> {
        let (bank, generation, _) = Self::read_slot(path)?;
        let mut file = fs::OpenOptions::new().read(true).write(true).open(path)?;
        Self::commit_bank(&mut file, 1 - bank, generation + 1, slot)
    }

    fn commit_bank(
        file: &mut fs::File,
        bank: usize,
        generation: u64,
        slot: &Slot,
    ) -> io::Result<()> {
        let body = serde_json::to_vec(slot)?;
        if body.len() > SLOT_BYTES - HEADER_BYTES {
            return Err(io::Error::other("protected output exceeded reserved bytes"));
        }
        let offset = (bank * SLOT_BYTES) as u64;
        file.seek(SeekFrom::Start(offset + HEADER_BYTES as u64))?;
        file.write_all(&body)?;
        file.sync_data()?;
        // A torn body/header leaves the other bank intact. The digest covers
        // generation and length as well as data, so torn metadata cannot win.
        let mut header = [0; HEADER_BYTES];
        header[..8].copy_from_slice(&generation.to_le_bytes());
        header[8..12].copy_from_slice(&(body.len() as u32).to_le_bytes());
        let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
        digest.update(&header[..12]);
        digest.update(&body);
        header[12..].copy_from_slice(digest.finish().as_ref());
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(&header)?;
        file.sync_data()
    }

    fn sync(&self) -> io::Result<()> {
        fs::File::open(&self.directory)?.sync_all()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reservations_survive_restart_and_apply_backpressure_without_eviction() {
        let state = std::env::temp_dir().join(format!("renga-output-{}", Uuid::new_v4()));
        let store = OutputStore::open(&state).unwrap();
        assert!(
            OutputStore::open(&state).is_err(),
            "a second process cannot run jobs in this state"
        );
        let job: LeasedJob = serde_json::from_value(json!({
            "id": Uuid::new_v4(), "capability": "inventory.collect@1", "attempt": 1,
            "lease_token": "secret", "lease_expires_at": Utc::now(),
            "timeout_ms": 300000, "output_limit_bytes": 65536
        }))
        .unwrap();
        let pending = store.reserve().unwrap();
        assert_eq!(
            fs::metadata(&pending).unwrap().len(),
            (SLOT_BYTES * 2) as u64
        );
        store.bind(&pending, &job).unwrap();
        let evidence = Evidence {
            attempt: 1,
            lease_token: "secret".into(),
            observation_id: Uuid::new_v4(),
            sha256: "digest".into(),
            body: "exact bytes".into(),
            accepted: false,
        };
        OutputStore::save(&state, job.id, evidence.clone()).unwrap();
        for _ in 1..SLOTS {
            store.reserve().unwrap();
        }
        assert!(store.reserve().is_err());
        drop(store);
        let store = OutputStore::open(&state).unwrap();
        assert!(store.reserve().is_err());
        assert_eq!(
            OutputStore::load(&state, job.id).unwrap().unwrap().body,
            evidence.body
        );
        store.confirm(job.id).unwrap();
        store.reserve().unwrap();
        drop(store);
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    #[cfg(target_os = "linux")]
    #[ignore = "requires RENGA_OUTPUT_UNSUPPORTED_FS to name an isolated overlayfs"]
    fn unsupported_storage_cannot_reserve_protected_output() {
        let state = PathBuf::from(std::env::var_os("RENGA_OUTPUT_UNSUPPORTED_FS").unwrap());
        let store = OutputStore::open(&state).unwrap();
        assert_eq!(
            store.reserve().unwrap_err().kind(),
            io::ErrorKind::Unsupported
        );
        assert_eq!(fs::read_dir(state.join("job-output")).unwrap().count(), 1);
    }

    #[test]
    #[cfg(target_os = "linux")]
    #[ignore = "requires RENGA_OUTPUT_FULL_FS to name an isolated small tmpfs"]
    fn reserved_output_commits_after_the_filesystem_is_exhausted() {
        let state = PathBuf::from(std::env::var_os("RENGA_OUTPUT_FULL_FS").unwrap());
        let store = OutputStore::open(&state).unwrap();
        let job: LeasedJob = serde_json::from_value(json!({
            "id": Uuid::new_v4(), "capability": "inventory.collect@1", "attempt": 1,
            "lease_token": "secret", "lease_expires_at": Utc::now(),
            "timeout_ms": 300000, "output_limit_bytes": 65536
        }))
        .unwrap();
        let pending = store.reserve().unwrap();
        store.bind(&pending, &job).unwrap();
        let next_pending = store.reserve().unwrap();
        let mut filler = private_file(&state.join("filler")).unwrap();
        let block = [0x5a; 4096];
        let exhausted = loop {
            if let Err(error) = filler.write_all(&block) {
                break error;
            }
        };
        assert_eq!(exhausted.raw_os_error(), Some(28));
        assert_eq!(store.reserve().unwrap_err().raw_os_error(), Some(28));
        let evidence = Evidence {
            attempt: 1,
            lease_token: "secret".into(),
            observation_id: Uuid::new_v4(),
            sha256: "immutable digest".into(),
            body: "\\".repeat(256_000),
            accepted: true,
        };
        OutputStore::save(&state, job.id, evidence.clone()).unwrap();
        let outcome = super::super::record::Outcome {
            kind: crate::payload::ReportType::Succeeded,
            payload: json!({"result": "x".repeat(60_000)}),
        };
        OutputStore::save_outcome(&state, job.id, &outcome).unwrap();
        let mut next_job = job.clone();
        next_job.id = Uuid::new_v4();
        store.bind(&next_pending, &next_job).unwrap();
        drop(store);
        let _reopened = OutputStore::open(&state).unwrap();
        let recovered = OutputStore::load(&state, job.id).unwrap().unwrap();
        assert_eq!(recovered.body, evidence.body);
        assert_eq!(recovered.sha256, evidence.sha256);
        assert!(recovered.accepted);
        assert_eq!(
            OutputStore::outcome(&state, job.id).unwrap().unwrap(),
            outcome
        );
        assert!(OutputStore::load(&state, next_job.id).unwrap().is_none());
        fs::remove_file(state.join("filler")).unwrap();
    }
}
