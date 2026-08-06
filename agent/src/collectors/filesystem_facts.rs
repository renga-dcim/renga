//! Owned filesystem facts backed by PID 1's procfs mount namespace.

use procfs::{process::MountInfos, FromBufRead};
use std::{fs::File, io, io::Read, path::PathBuf};

pub(super) const MAX_MOUNTINFO_BYTES: u64 = 1024 * 1024;
const MAX_MOUNT_RECORDS: usize = 4096;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FilesystemFacts {
    pub device: Option<String>,
    pub mountpoint: String,
    pub filesystem_type: String,
}

pub trait FilesystemFactsSource {
    /// `Err` means the complete PID 1 mount snapshot is unavailable.
    fn collect(&self) -> io::Result<Vec<FilesystemFacts>>;
}

pub struct ProcfsSource {
    mountinfo_path: PathBuf,
}

impl ProcfsSource {
    pub fn host_pid_one() -> Self {
        Self {
            mountinfo_path: PathBuf::from("/proc/1/mountinfo"),
        }
    }

    #[cfg(test)]
    pub fn from_process_root(process_root: PathBuf) -> Self {
        Self {
            mountinfo_path: process_root.join("mountinfo"),
        }
    }
}

impl FilesystemFactsSource for ProcfsSource {
    fn collect(&self) -> io::Result<Vec<FilesystemFacts>> {
        let mut bytes = Vec::new();
        File::open(&self.mountinfo_path)?
            .take(MAX_MOUNTINFO_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_MOUNTINFO_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "PID 1 mountinfo exceeds collection byte limit",
            ));
        }
        let mountinfo = MountInfos::from_buf_read(bytes.as_slice()).map_err(io::Error::other)?;
        if mountinfo.0.len() > MAX_MOUNT_RECORDS {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "PID 1 mountinfo exceeds collection record limit",
            ));
        }
        Ok(project_mountinfo(mountinfo))
    }
}

fn project_mountinfo(mountinfo: MountInfos) -> Vec<FilesystemFacts> {
    mountinfo
        .into_iter()
        .map(|mount| FilesystemFacts {
            device: mount.mount_source.map(|source| decode_mount_field(&source)),
            mountpoint: decode_mount_field(&mount.mount_point.to_string_lossy()),
            filesystem_type: mount.fs_type,
        })
        .collect()
}

fn decode_mount_field(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

#[cfg(test)]
pub fn parse_mountinfo(value: &str) -> io::Result<Vec<FilesystemFacts>> {
    MountInfos::from_buf_read(value.as_bytes())
        .map(project_mountinfo)
        .map_err(io::Error::other)
}
