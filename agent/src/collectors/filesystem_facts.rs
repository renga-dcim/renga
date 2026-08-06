//! Owned filesystem facts backed by PID 1's procfs mount namespace.

use procfs::process::{MountInfos, Process};
#[cfg(test)]
use procfs::FromBufRead;
use std::{io, path::PathBuf};

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
    process_root: Option<PathBuf>,
}

impl ProcfsSource {
    pub fn host_pid_one() -> Self {
        Self { process_root: None }
    }

    #[cfg(test)]
    pub fn from_process_root(process_root: PathBuf) -> Self {
        Self {
            process_root: Some(process_root),
        }
    }

    fn process(&self) -> procfs::ProcResult<Process> {
        match &self.process_root {
            Some(root) => Process::new_with_root(root.clone()),
            None => Process::new(1),
        }
    }
}

impl FilesystemFactsSource for ProcfsSource {
    fn collect(&self) -> io::Result<Vec<FilesystemFacts>> {
        let mountinfo = self
            .process()
            .and_then(|process| process.mountinfo())
            .map_err(io::Error::other)?;
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
