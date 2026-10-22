//! `query.disk_usage@1`: capacity and use of each mounted filesystem, from
//! PID 1's mount table and `statvfs`. Inventory sensitivity. Matches
//! `Renga.Jobs.Queries.DiskUsage`.

use super::{clip, parameters, Bounded, Query, Sensitivity};
use crate::{cancellation::Cancellation, jobs::JobFailure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const MAX_FILESYSTEMS: usize = 512;

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
        Ok(answer(read_filesystems(cancellation)?))
    }
}

fn answer(filesystems: Vec<Filesystem>) -> Value {
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
    serde_json::json!({ "filesystems": filesystems, "truncated": truncated })
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
fn read_filesystems(cancellation: &Cancellation) -> Result<Vec<Filesystem>, JobFailure> {
    use crate::collectors::filesystem_facts::{FilesystemFactsSource, ProcfsSource};
    use std::{ffi::CString, mem::MaybeUninit};

    let mounts = ProcfsSource::host_pid_one()
        .collect()
        .map_err(|_| super::failed("could not read the mount table"))?;
    let mut filesystems = Vec::new();
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
        let mut stat = MaybeUninit::<libc::statvfs>::uninit();
        // SAFETY: `path` is NUL-terminated and `stat` is written by statvfs
        // before it is read, which happens only when the call succeeds.
        // A mount the agent cannot reach, such as one inside another
        // namespace, is skipped rather than failing the query.
        if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
            continue;
        }
        let stat = unsafe { stat.assume_init() };
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
    Ok(filesystems)
}

#[cfg(not(target_os = "linux"))]
fn read_filesystems(_: &Cancellation) -> Result<Vec<Filesystem>, JobFailure> {
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
        let value = answer(vec![root.clone(), root, boot, run]);

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
