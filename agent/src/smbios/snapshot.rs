//! Boot-scoped copies of the root-only SMBIOS tables.
//!
//! A privileged pre-start helper copies the two fixed table files into a new
//! generation directory and publishes it by atomically replacing the `current`
//! link. The tables never change until the next boot, so one copy per service
//! start is enough. The helper runs outside the service sandbox, which makes its
//! fixed source paths, no-follow opens, and root-controlled destination the
//! security boundary: it never reads or writes a path an unprivileged account can
//! redirect. The agent only reads a generation that is complete and from this boot.

use serde::{Deserialize, Serialize};
use std::{
    ffi::{CString, OsStr},
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{fchown, DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

/// Where the kernel exposes the raw tables.
pub const SOURCE_DIRECTORY: &str = "/sys/firmware/dmi/tables";
/// Root-owned and not writable by the agent; `/run` is cleared at every boot.
pub const SNAPSHOT_DIRECTORY: &str = "/run/renga/smbios";
pub const BOOT_ID_PATH: &str = "/proc/sys/kernel/random/boot_id";
/// The service group that may read published generations.
pub const AGENT_GROUP: &str = "renga-agent";

const TABLE: &str = "DMI";
const ENTRY_POINT: &str = "smbios_entry_point";
const MANIFEST: &str = "manifest.json";
const CURRENT: &str = "current";
const STAGING_PREFIX: &str = ".staging-";
const MANIFEST_FORMAT: u32 = 1;
/// SMBIOS 3 permits larger tables, but real ones are a few KiB. The cap bounds a
/// root process's reads and the agent's memory.
const MAX_TABLE_BYTES: u64 = 1024 * 1024;
const MAX_ENTRY_POINT_BYTES: u64 = 64;
const MAX_MANIFEST_BYTES: u64 = 4096;

/// The two raw files the parser needs.
#[derive(Debug, Eq, PartialEq)]
pub struct Snapshot {
    pub entry_point: Vec<u8>,
    pub table: Vec<u8>,
}

#[derive(Debug, Deserialize, Serialize)]
struct Manifest {
    format: u32,
    boot_id: String,
    generation: String,
    table_bytes: u64,
    entry_point_bytes: u64,
}

/// Paths and ownership for one publication; production uses [`Publisher::system`].
pub struct Publisher {
    pub source: PathBuf,
    pub destination: PathBuf,
    pub boot_id: PathBuf,
    pub group: u32,
}

impl Publisher {
    /// The production helper: fixed kernel source, fixed destination, and the agent group.
    pub fn system() -> io::Result<Self> {
        Ok(Self {
            source: SOURCE_DIRECTORY.into(),
            destination: SNAPSHOT_DIRECTORY.into(),
            boot_id: BOOT_ID_PATH.into(),
            group: group_id(AGENT_GROUP)?,
        })
    }

    /// Copies the tables into a new generation and publishes it, returning its ID.
    /// Nothing becomes visible to the agent until the final rename, so a failure or
    /// a kill at any earlier point leaves the previous state in place.
    pub fn publish(&self) -> io::Result<String> {
        let boot_id = read_boot_id(&self.boot_id)?;
        // Read both sources before creating anything, so a host without SMBIOS tables
        // fails without touching the destination.
        let table = read_bounded(&self.source.join(TABLE), MAX_TABLE_BYTES)?;
        let entry_point = read_bounded(&self.source.join(ENTRY_POINT), MAX_ENTRY_POINT_BYTES)?;
        if table.is_empty() || entry_point.is_empty() {
            return Err(invalid("SMBIOS source files are empty"));
        }

        prepare_destination(&self.destination)?;
        let generation = uuid::Uuid::new_v4().to_string();
        let staging = self
            .destination
            .join(format!("{STAGING_PREFIX}{generation}"));
        let result = self.write_generation(&staging, &generation, &boot_id, &table, &entry_point);
        if let Err(error) = result {
            let _ = fs::remove_dir_all(&staging);
            return Err(error);
        }
        let published = self.destination.join(&generation);
        fs::rename(&staging, &published)?;

        // Replacing the link is the one atomic publication step.
        let link = self
            .destination
            .join(format!("{STAGING_PREFIX}{generation}.link"));
        std::os::unix::fs::symlink(&generation, &link)?;
        if let Err(error) = fs::rename(&link, self.destination.join(CURRENT)) {
            let _ = fs::remove_file(&link);
            let _ = fs::remove_dir_all(&published);
            return Err(error);
        }
        sync_directory(&self.destination)?;
        prune(&self.destination, &generation);
        Ok(generation)
    }

    fn write_generation(
        &self,
        staging: &Path,
        generation: &str,
        boot_id: &str,
        table: &[u8],
        entry_point: &[u8],
    ) -> io::Result<()> {
        fs::DirBuilder::new().mode(0o700).create(staging)?;
        write_new(&staging.join(TABLE), table, self.group)?;
        write_new(&staging.join(ENTRY_POINT), entry_point, self.group)?;
        // The manifest is written last, so a generation with one is complete.
        let manifest = serde_json::to_vec(&Manifest {
            format: MANIFEST_FORMAT,
            boot_id: boot_id.into(),
            generation: generation.into(),
            table_bytes: table.len() as u64,
            entry_point_bytes: entry_point.len() as u64,
        })
        .map_err(io::Error::other)?;
        write_new(&staging.join(MANIFEST), &manifest, self.group)?;
        let directory = File::open(staging)?;
        fchown(&directory, None, Some(self.group))?;
        directory.set_permissions(fs::Permissions::from_mode(0o750))?;
        directory.sync_all()
    }
}

/// Reads the current generation, rejecting one that is incomplete, inconsistent, or
/// from an earlier boot.
pub fn load(destination: &Path, boot_id_path: &Path) -> io::Result<Snapshot> {
    let generation = fs::read_link(destination.join(CURRENT))?;
    let generation = plain_name(&generation)
        .ok_or_else(|| invalid("current SMBIOS snapshot link is not a generation name"))?;
    let directory = destination.join(generation);
    let manifest: Manifest = serde_json::from_slice(&read_bounded(
        &directory.join(MANIFEST),
        MAX_MANIFEST_BYTES,
    )?)
    .map_err(|_| invalid("SMBIOS snapshot manifest is malformed"))?;
    if manifest.format != MANIFEST_FORMAT || manifest.generation != generation {
        return Err(invalid(
            "SMBIOS snapshot manifest does not match its generation",
        ));
    }
    if manifest.boot_id != read_boot_id(boot_id_path)? {
        return Err(invalid("SMBIOS snapshot is from an earlier boot"));
    }
    let table = read_bounded(&directory.join(TABLE), MAX_TABLE_BYTES)?;
    let entry_point = read_bounded(&directory.join(ENTRY_POINT), MAX_ENTRY_POINT_BYTES)?;
    if table.len() as u64 != manifest.table_bytes
        || entry_point.len() as u64 != manifest.entry_point_bytes
    {
        return Err(invalid("SMBIOS snapshot is incomplete"));
    }
    Ok(Snapshot { entry_point, table })
}

fn plain_name(path: &Path) -> Option<&str> {
    let name = path.to_str()?;
    let valid = !name.is_empty()
        && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_hexdigit() || c == '-');
    valid.then_some(name)
}

/// Opens without following a final symbolic link and reads at most `limit` bytes,
/// failing rather than truncating a larger file.
fn read_bounded(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| io::Error::new(error.kind(), format!("{}: {error}", path.display())))?;
    if !file.metadata()?.is_file() {
        return Err(invalid(format!("{} is not a regular file", path.display())));
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(invalid(format!("{} exceeds {limit} bytes", path.display())));
    }
    Ok(bytes)
}

/// Creates the file exclusively and without following links, readable only by root
/// and the agent group.
fn write_new(path: &Path, bytes: &[u8], group: u32) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o400)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    file.write_all(bytes)?;
    fchown(&file, None, Some(group))?;
    file.set_permissions(fs::Permissions::from_mode(0o440))?;
    file.sync_all()
}

/// Creates the destination and its parent when missing, and refuses to write into
/// either unless it is a real directory owned by this user and writable by no one else.
fn prepare_destination(destination: &Path) -> io::Result<()> {
    let parent = destination
        .parent()
        .ok_or_else(|| invalid("SMBIOS snapshot destination has no parent"))?;
    for directory in [parent, destination] {
        match fs::DirBuilder::new().mode(0o700).create(directory) {
            // The service umask would hide a new directory from the agent.
            Ok(()) => fs::set_permissions(directory, fs::Permissions::from_mode(0o755))?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        let metadata = fs::symlink_metadata(directory)?;
        // SAFETY: geteuid has no preconditions and cannot fail.
        let owner = unsafe { libc::geteuid() };
        if !metadata.is_dir() || metadata.uid() != owner || metadata.mode() & 0o022 != 0 {
            return Err(invalid(format!(
                "{} must be a directory owned by uid {owner} and writable only by it",
                directory.display()
            )));
        }
    }
    Ok(())
}

/// Removes earlier generations and leftovers from interrupted runs. Failures only
/// leave stale files that the next run removes.
fn prune(destination: &Path, keep: &str) {
    let Ok(entries) = fs::read_dir(destination) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name == OsStr::new(keep) || name == OsStr::new(CURRENT) {
            continue;
        }
        let path = entry.path();
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => {
                let _ = fs::remove_dir_all(path);
            }
            Ok(_) => {
                let _ = fs::remove_file(path);
            }
            Err(_) => {}
        }
    }
}

fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

fn read_boot_id(path: &Path) -> io::Result<String> {
    let bytes = read_bounded(path, 64)?;
    let boot_id = String::from_utf8_lossy(&bytes).trim().to_string();
    if boot_id.is_empty() {
        return Err(invalid("boot ID is empty"));
    }
    Ok(boot_id)
}

fn group_id(name: &str) -> io::Result<u32> {
    let name = CString::new(name).map_err(|_| invalid("group name contains NUL"))?;
    let mut group = std::mem::MaybeUninit::<libc::group>::uninit();
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    let mut result = std::ptr::null_mut();
    // SAFETY: every pointer refers to live, correctly sized storage for the call.
    let status = unsafe {
        libc::getgrnam_r(
            name.as_ptr(),
            group.as_mut_ptr(),
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status));
    }
    if result.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("group {} does not exist", name.to_string_lossy()),
        ));
    }
    // SAFETY: getgrnam_r reported success, so `group` is initialized.
    Ok(unsafe { group.assume_init() }.gr_gid)
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    pub(crate) fn scratch(label: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "renga-smbios-{label}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }

    pub(crate) struct Host {
        pub root: PathBuf,
        pub publisher: Publisher,
    }

    /// A fake host with source tables, a boot ID, and an unpublished destination.
    pub(crate) fn host(label: &str, entry_point: &[u8], table: &[u8]) -> Host {
        let root = scratch(label);
        let source = root.join("sys/firmware/dmi/tables");
        fs::create_dir_all(&source).unwrap();
        fs::write(source.join(TABLE), table).unwrap();
        fs::write(source.join(ENTRY_POINT), entry_point).unwrap();
        let boot_id = root.join("proc/sys/kernel/random/boot_id");
        fs::create_dir_all(boot_id.parent().unwrap()).unwrap();
        fs::write(&boot_id, "11111111-2222-3333-4444-555555555555\n").unwrap();
        fs::create_dir(root.join("run")).unwrap();
        let publisher = Publisher {
            source,
            destination: root.join("run/renga/smbios"),
            boot_id,
            group: unsafe { libc::getegid() },
        };
        Host { root, publisher }
    }

    fn load_from(host: &Host) -> io::Result<Snapshot> {
        load(&host.publisher.destination, &host.publisher.boot_id)
    }

    fn mode(path: &Path) -> u32 {
        fs::symlink_metadata(path).unwrap().mode() & 0o7777
    }

    #[test]
    fn publishes_a_complete_generation_the_agent_can_load() {
        let host = host("publish", b"_SM3_entry", b"table bytes");
        let generation = host.publisher.publish().unwrap();
        let snapshot = load_from(&host).unwrap();
        assert_eq!(snapshot.entry_point, b"_SM3_entry");
        assert_eq!(snapshot.table, b"table bytes");

        let destination = &host.publisher.destination;
        let published = destination.join(&generation);
        assert_eq!(mode(destination), 0o755);
        assert_eq!(mode(&published), 0o750);
        for file in [TABLE, ENTRY_POINT, MANIFEST] {
            assert_eq!(mode(&published.join(file)), 0o440);
        }
        let names: Vec<_> = fs::read_dir(destination)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names.len(), 2, "{names:?}");
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn replaces_and_prunes_earlier_generations_and_leftovers() {
        let host = host("republish", b"_SM3_", b"first");
        let first = host.publisher.publish().unwrap();
        let destination = &host.publisher.destination;
        fs::create_dir(destination.join(".staging-interrupted")).unwrap();
        fs::write(host.publisher.source.join(TABLE), b"second").unwrap();
        let second = host.publisher.publish().unwrap();
        assert_ne!(first, second);
        assert_eq!(load_from(&host).unwrap().table, b"second");
        assert!(!destination.join(&first).exists());
        assert!(!destination.join(".staging-interrupted").exists());
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn missing_or_empty_sources_publish_nothing() {
        let host = host("missing", b"_SM3_", b"table");
        fs::remove_file(host.publisher.source.join(ENTRY_POINT)).unwrap();
        let error = host.publisher.publish().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert!(!host.publisher.destination.exists());

        fs::write(host.publisher.source.join(ENTRY_POINT), b"").unwrap();
        let error = host.publisher.publish().unwrap_err();
        assert!(error.to_string().contains("empty"), "{error}");
        assert!(!host.publisher.destination.exists());
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn failed_refresh_keeps_the_last_complete_same_boot_generation() {
        let host = host("failed-refresh", b"_SM3_", b"complete table");
        let generation = host.publisher.publish().unwrap();
        fs::remove_file(host.publisher.source.join(ENTRY_POINT)).unwrap();

        assert_eq!(
            host.publisher.publish().unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(
            fs::read_link(host.publisher.destination.join(CURRENT)).unwrap(),
            Path::new(&generation)
        );
        assert_eq!(load_from(&host).unwrap().table, b"complete table");
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn interruption_after_atomic_publish_exposes_only_the_complete_generation() {
        let host = host("publish-boundary", b"_SM3_", b"first table");
        let first = host.publisher.publish().unwrap();
        let generation = "11111111-2222-3333-4444-555555555555";
        let staging = host
            .publisher
            .destination
            .join(format!("{STAGING_PREFIX}{generation}"));
        let boot_id = read_boot_id(&host.publisher.boot_id).unwrap();
        host.publisher
            .write_generation(&staging, generation, &boot_id, b"second table", b"_SM3_")
            .unwrap();
        fs::rename(&staging, host.publisher.destination.join(generation)).unwrap();
        let link = host.publisher.destination.join("interrupted.link");
        std::os::unix::fs::symlink(generation, &link).unwrap();
        fs::rename(&link, host.publisher.destination.join(CURRENT)).unwrap();
        // Simulate termination before the destination sync and pruning steps.

        assert_eq!(load_from(&host).unwrap().table, b"second table");
        assert!(host.publisher.destination.join(first).is_dir());
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn never_follows_links_at_the_source() {
        let host = host("source-link", b"_SM3_", b"table");
        let secret = host.root.join("secret");
        fs::write(&secret, b"not a table").unwrap();
        fs::remove_file(host.publisher.source.join(TABLE)).unwrap();
        std::os::unix::fs::symlink(&secret, host.publisher.source.join(TABLE)).unwrap();
        let error = host.publisher.publish().unwrap_err();
        assert!(error.to_string().contains("symbolic links"), "{error}");
        assert!(!host.publisher.destination.exists());
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn refuses_a_linked_or_shared_destination() {
        let host = host("destination", b"_SM3_", b"table");
        let elsewhere = host.root.join("elsewhere");
        fs::create_dir_all(&elsewhere).unwrap();
        fs::create_dir_all(host.publisher.destination.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &host.publisher.destination).unwrap();
        let error = host.publisher.publish().unwrap_err();
        assert!(error.to_string().contains("must be a directory"), "{error}");
        assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0);

        fs::remove_file(&host.publisher.destination).unwrap();
        fs::create_dir(&host.publisher.destination).unwrap();
        fs::set_permissions(
            &host.publisher.destination,
            fs::Permissions::from_mode(0o777),
        )
        .unwrap();
        let error = host.publisher.publish().unwrap_err();
        assert!(error.to_string().contains("writable only by it"), "{error}");
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn rejects_snapshots_from_an_earlier_boot() {
        let host = host("reboot", b"_SM3_", b"table");
        host.publisher.publish().unwrap();
        fs::write(
            &host.publisher.boot_id,
            "66666666-7777-8888-9999-000000000000\n",
        )
        .unwrap();
        let error = load_from(&host).unwrap_err();
        assert!(error.to_string().contains("earlier boot"), "{error}");
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn rejects_partial_or_mismatched_generations() {
        let host = host("partial", b"_SM3_", b"table");
        let generation = host.publisher.publish().unwrap();
        let published = host.publisher.destination.join(&generation);
        fs::set_permissions(&published, fs::Permissions::from_mode(0o700)).unwrap();

        let table = published.join(TABLE);
        fs::set_permissions(&table, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(&table, b"tab").unwrap();
        let error = load_from(&host).unwrap_err();
        assert!(error.to_string().contains("incomplete"), "{error}");
        fs::write(&table, b"table").unwrap();
        assert!(load_from(&host).is_ok());

        let manifest = published.join(MANIFEST);
        let original = fs::read(&manifest).unwrap();
        fs::set_permissions(&manifest, fs::Permissions::from_mode(0o600)).unwrap();
        fs::remove_file(&manifest).unwrap();
        assert_eq!(
            load_from(&host).unwrap_err().kind(),
            io::ErrorKind::NotFound
        );

        let renamed = String::from_utf8(original)
            .unwrap()
            .replace(&generation, "00000000-0000-0000-0000-000000000000");
        fs::write(&manifest, renamed).unwrap();
        let error = load_from(&host).unwrap_err();
        assert!(error.to_string().contains("does not match"), "{error}");
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn rejects_a_current_link_outside_the_destination() {
        let host = host("escape", b"_SM3_", b"table");
        host.publisher.publish().unwrap();
        let current = host.publisher.destination.join(CURRENT);
        fs::remove_file(&current).unwrap();
        std::os::unix::fs::symlink("../../..", &current).unwrap();
        let error = load_from(&host).unwrap_err();
        assert!(
            error.to_string().contains("not a generation name"),
            "{error}"
        );
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn unpublished_hosts_have_no_snapshot() {
        let host = host("unpublished", b"_SM3_", b"table");
        let error = load_from(&host).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        fs::remove_dir_all(&host.root).unwrap();
    }

    #[test]
    fn caps_source_reads() {
        let host = host(
            "oversized",
            b"_SM3_",
            &vec![0; MAX_TABLE_BYTES as usize + 1],
        );
        let error = host.publisher.publish().unwrap_err();
        assert!(error.to_string().contains("exceeds"), "{error}");
        assert!(!host.publisher.destination.exists());
        fs::remove_dir_all(&host.root).unwrap();
    }
}
