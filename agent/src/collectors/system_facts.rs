//! Portable host facts and the private sysinfo adapter used to obtain them.

use sysinfo::{DiskKind, DiskRefreshKind, Disks, MemoryRefreshKind, RefreshKind, System};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct OsFacts {
    pub name: Option<String>,
    pub version: Option<String>,
    pub kernel: Option<String>,
    pub architecture: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct CpuFacts {
    pub logical_count: Option<usize>,
    pub physical_count: Option<usize>,
    pub brand: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum DiskMedium {
    Hdd,
    Ssd,
    Unknown,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct DiskFacts {
    pub name: String,
    pub medium: DiskMedium,
    pub total_bytes: Option<u64>,
    pub mount_point: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct SystemFacts {
    pub os: OsFacts,
    pub hostname: Option<String>,
    pub cpu: CpuFacts,
    pub total_memory_bytes: Option<u64>,
    /// `None` is indeterminate. Injected sources may use `Some([])` when emptiness is known.
    pub disks: Option<Vec<DiskFacts>>,
}

pub(super) trait SystemFactsSource {
    fn collect(&self) -> SystemFacts;
}

pub(super) struct SysinfoSource;

impl SystemFactsSource for SysinfoSource {
    fn collect(&self) -> SystemFacts {
        let refresh = RefreshKind::nothing()
            // CPU identity and topology are populated while usage and frequency remain disabled.
            .with_cpu(sysinfo::CpuRefreshKind::nothing())
            .with_memory(MemoryRefreshKind::nothing().with_ram());
        let system = System::new_with_specifics(refresh);
        let disks = Disks::new_with_refreshed_list_specifics(
            DiskRefreshKind::nothing().with_kind().with_storage(),
        );
        let cpus = system.cpus();

        let disks = disks
            .list()
            .iter()
            .map(|disk| DiskFacts {
                name: disk.name().to_string_lossy().into_owned(),
                medium: match disk.kind() {
                    DiskKind::HDD => DiskMedium::Hdd,
                    DiskKind::SSD => DiskMedium::Ssd,
                    _ => DiskMedium::Unknown,
                },
                total_bytes: (disk.total_space() > 0).then_some(disk.total_space()),
                mount_point: Some(disk.mount_point().to_string_lossy().into_owned()),
            })
            .collect::<Vec<_>>();

        SystemFacts {
            os: OsFacts {
                name: System::name(),
                version: System::os_version(),
                kernel: System::kernel_version(),
                architecture: Some(System::cpu_arch()).filter(|value| !value.is_empty()),
            },
            hostname: System::host_name(),
            cpu: CpuFacts {
                logical_count: (!cpus.is_empty()).then_some(cpus.len()),
                physical_count: System::physical_core_count(),
                brand: cpus
                    .first()
                    .map(|cpu| cpu.brand().to_owned())
                    .filter(|v| !v.is_empty()),
            },
            total_memory_bytes: (system.total_memory() > 0).then_some(system.total_memory()),
            // sysinfo cannot distinguish no disks from unavailable enumeration.
            disks: (!disks.is_empty()).then_some(disks),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn real_adapter_smoke_test_only_checks_portable_invariants() {
        let facts = SysinfoSource.collect();
        assert!(facts.cpu.logical_count.is_none_or(|count| count > 0));
        assert!(facts.cpu.physical_count.is_none_or(|count| count > 0));
        assert!(facts.total_memory_bytes.is_none_or(|bytes| bytes > 0));
        assert!(facts.disks.as_ref().is_none_or(|disks| {
            !disks.is_empty()
                && disks
                    .iter()
                    .all(|disk| disk.total_bytes.is_none_or(|bytes| bytes > 0))
        }));
    }
}
