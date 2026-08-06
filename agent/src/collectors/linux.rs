//! Linux inventory from procfs/sysfs. Missing individual kernel files are tolerated.

use super::{
    filesystem_facts::{FilesystemFactsSource, ProcfsSource},
    network_facts::{AddressFamily, GetifsSource, NetworkFactsSource, NetworkInterface},
    system_facts::{DiskFacts, DiskMedium, SysinfoSource, SystemFactsSource},
    CollectError,
};
use crate::{
    cancellation::Cancellation,
    command,
    payload::{
        Address, Component, HostAttributes, Identifiers, Interface, ResourceKind, ServerResource,
    },
};
use serde_json::{json, Value};
use std::{fs, os::unix::fs::FileTypeExt, path::Path, process::Command};

/// Non-authoritative component limits reserve payload space for identity and network facts.
const MAX_DISK_COMPONENTS: usize = 128;
const MAX_FILESYSTEM_COMPONENTS: usize = 512;

#[derive(Clone, Debug, Eq, PartialEq)]
enum VirtDetection {
    None,
    Detected(String),
    Unknown,
}

trait VirtDetector {
    fn container(&self) -> VirtDetection;
    fn vm(&self) -> VirtDetection;
}

struct SystemdVirtDetector<'a>(&'a Cancellation);

impl SystemdVirtDetector<'_> {
    fn detect(&self, category: &str) -> VirtDetection {
        let Ok(output) = command::run(Command::new("systemd-detect-virt").arg(category), self.0)
        else {
            return VirtDetection::Unknown;
        };
        let Ok(value) = String::from_utf8(output.stdout) else {
            return VirtDetection::Unknown;
        };
        let value = value.trim();
        // systemd-detect-virt uses exit 1 for a successful negative detection.
        if value == "none" && matches!(output.status.code(), Some(0 | 1)) {
            VirtDetection::None
        } else if output.status.success() && !value.is_empty() {
            VirtDetection::Detected(value.to_owned())
        } else {
            VirtDetection::Unknown
        }
    }
}

impl VirtDetector for SystemdVirtDetector<'_> {
    fn container(&self) -> VirtDetection {
        self.detect("--container")
    }

    fn vm(&self) -> VirtDetection {
        self.detect("--vm")
    }
}

fn read(root: &Path, path: &str) -> Option<String> {
    fs::read_to_string(root.join(path.trim_start_matches('/')))
        .ok()
        .and_then(|v| normalize_value(&v))
}

/// Removes firmware placeholders which are common on generic/cloud DMI tables.
pub fn normalize_value(value: &str) -> Option<String> {
    let value = value.trim();
    let lower = value.to_ascii_lowercase();
    if value.is_empty()
        || matches!(
            lower.as_str(),
            "none"
                | "unknown"
                | "not specified"
                | "not applicable"
                | "to be filled by o.e.m."
                | "default string"
        )
    {
        None
    } else {
        Some(value.into())
    }
}

fn collect_from_with_cancellation(
    root: &Path,
    cancellation: &Cancellation,
) -> Result<ServerResource, CollectError> {
    let filesystem_source = ProcfsSource::host_pid_one();
    collect_from_with_sources(
        root,
        &GetifsSource,
        &SystemdVirtDetector(cancellation),
        &SysinfoSource,
        &filesystem_source,
        cancellation,
    )
}

fn collect_from_with_sources(
    root: &Path,
    network_source: &dyn NetworkFactsSource,
    detector: &dyn VirtDetector,
    facts_source: &dyn SystemFactsSource,
    filesystem_source: &dyn FilesystemFactsSource,
    cancellation: &Cancellation,
) -> Result<ServerResource, CollectError> {
    let facts = facts_source.collect();
    let hostname = read(root, "etc/hostname")
        .or_else(|| facts.hostname.as_deref().and_then(normalize_value))
        .ok_or_else(|| {
            CollectError(
                "Linux host has no usable /etc/hostname; observation cannot be matched".into(),
            )
        })?;
    let fqdn = command::run(Command::new("hostname").arg("-f"), cancellation)
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| normalize_value(&s))
        .filter(|s| s.contains('.'));
    let mut interfaces = network_source.collect().ok().map(project_interfaces);
    if let Some(interfaces) = &mut interfaces {
        enrich_interfaces(root, interfaces);
    }
    let macs = interfaces
        .as_deref()
        .unwrap_or_default()
        .iter()
        .filter(|i| i.status != "not_present")
        .filter_map(|i| i.mac_address.clone())
        .collect();
    let mut components = vec![
        component(
            "os",
            [
                ("name", json!(facts.os.name)),
                ("version", json!(facts.os.version)),
                ("kernel", json!(facts.os.kernel)),
                ("architecture", json!(facts.os.architecture)),
            ],
        ),
        component(
            "cpu",
            [
                ("logical_count", json!(facts.cpu.logical_count)),
                ("physical_count", json!(facts.cpu.physical_count)),
                ("model", json!(facts.cpu.brand)),
            ],
        ),
    ];
    if let Some(bytes) = facts.total_memory_bytes {
        components.push(component("memory", [("total_bytes", json!(bytes))]));
    }
    components.extend(collect_disks(facts.disks));
    components.extend(collect_filesystems(filesystem_source));
    components.push(virtualization_component(root, detector));
    let vendor = read(root, "sys/class/dmi/id/sys_vendor");
    let model = read(root, "sys/class/dmi/id/product_name");
    Ok(ServerResource {
        kind: ResourceKind::Server,
        identifiers: Identifiers {
            hostname: hostname.clone(),
            fqdn: fqdn.clone(),
            machine_id: read(root, "etc/machine-id"),
            dmi_uuid: read(root, "sys/class/dmi/id/product_uuid"),
            serial_number: read(root, "sys/class/dmi/id/product_serial"),
            mac_address: macs,
        },
        attributes: Some(HostAttributes {
            hostname: Some(hostname),
            fqdn,
            vendor,
            model,
            asset_tag: read(root, "sys/class/dmi/id/chassis_asset_tag"),
        }),
        interfaces,
        components,
    })
}

/// Collects from the running Linux host.
pub fn collect(cancellation: &Cancellation) -> Result<ServerResource, CollectError> {
    collect_from_with_cancellation(Path::new("/"), cancellation)
}

fn component<const N: usize>(kind: &str, values: [(&str, Value); N]) -> Component {
    Component {
        kind: kind.into(),
        attributes: values
            .into_iter()
            .filter(|(_, v)| !v.is_null())
            .map(|(k, v)| (k.into(), v))
            .collect(),
    }
}
fn enrich_interfaces(root: &Path, interfaces: &mut [Interface]) {
    for i in interfaces {
        let base = format!("sys/class/net/{}", i.name);
        i.mac_address = i.mac_address.take().filter(|mac| {
            read(root, &format!("{base}/address"))
                .and_then(|value| parse_ethernet_mac(&value))
                .as_ref()
                == Some(mac)
        });
        i.speed_mbps = read(root, &format!("{base}/speed"))
            .and_then(|v| v.parse().ok())
            .filter(|v| *v > 0);
        if i.kind != "loopback" {
            i.kind = if root.join(format!("{base}/device")).exists() {
                "ethernet"
            } else {
                "virtual"
            }
            .into();
        }
    }
}

fn parse_ethernet_mac(value: &str) -> Option<String> {
    let octets = value.trim().split(':').collect::<Vec<_>>();
    if octets.len() != 6
        || octets
            .iter()
            .any(|octet| octet.len() != 2 || !octet.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return None;
    }
    let normalized = octets.join(":").to_ascii_lowercase();
    (normalized != "00:00:00:00:00:00").then_some(normalized)
}

fn project_interfaces(facts: Vec<NetworkInterface>) -> Vec<Interface> {
    facts
        .into_iter()
        .map(|fact| Interface {
            name: fact.name,
            kind: if fact.loopback { "loopback" } else { "unknown" }.into(),
            status: if fact.up { "up" } else { "down" }.into(),
            mac_address: fact.mac,
            mtu: fact.mtu,
            speed_mbps: None,
            addresses: Some(
                fact.addresses
                    .into_iter()
                    .map(|address| Address {
                        address: format!("{}/{}", address.ip, address.prefix),
                        kind: Some(
                            match address.family {
                                AddressFamily::Ipv4 => "ipv4",
                                AddressFamily::Ipv6 => "ipv6",
                            }
                            .into(),
                        ),
                        scope: None,
                    })
                    .collect(),
            ),
        })
        .collect()
}
fn collect_disks(disks: Option<Vec<DiskFacts>>) -> Vec<Component> {
    let Some(disks) = disks else {
        return vec![];
    };
    let discovered_count = disks.len();
    bounded_components(
        "disk",
        MAX_DISK_COMPONENTS,
        discovered_count,
        disks.into_iter().map(|disk| {
            let name = normalize_value(&disk.name)
                .or_else(|| disk.mount_point.as_deref().and_then(normalize_value));
            component(
                "disk",
                [
                    ("name", json!(name)),
                    (
                        "medium",
                        json!(match disk.medium {
                            DiskMedium::Hdd => "hdd",
                            DiskMedium::Ssd => "ssd",
                            DiskMedium::Unknown => "unknown",
                        }),
                    ),
                    ("size_bytes", json!(disk.total_bytes)),
                    ("mountpoint", json!(disk.mount_point)),
                ],
            )
        }),
    )
}
fn collect_filesystems(source: &dyn FilesystemFactsSource) -> Vec<Component> {
    // PID 1 exposes the host mount namespace for the normal system service. An unavailable or
    // malformed snapshot must not fall back to the agent's potentially sandboxed mount namespace.
    let Ok(filesystems) = source.collect() else {
        return vec![];
    };
    let discovered_count = filesystems.len();
    bounded_components(
        "filesystem",
        MAX_FILESYSTEM_COMPONENTS,
        discovered_count,
        filesystems.into_iter().map(|filesystem| {
            component(
                "filesystem",
                [
                    ("device", json!(filesystem.device)),
                    ("mountpoint", json!(filesystem.mountpoint)),
                    ("filesystem_type", json!(filesystem.filesystem_type)),
                ],
            )
        }),
    )
}

fn bounded_components(
    collector: &str,
    limit: usize,
    discovered_count: usize,
    components: impl Iterator<Item = Component>,
) -> Vec<Component> {
    let mut emitted = components.take(limit).collect::<Vec<_>>();
    if discovered_count > limit {
        // This fixed, compact status record is emitted in addition to (not instead of) the cap.
        emitted.push(component(
            "collection_status",
            [
                ("collector", json!(collector)),
                ("discovered_count", json!(discovered_count)),
                ("emitted_count", json!(limit)),
                ("truncated", json!(true)),
            ],
        ));
    }
    emitted
}
/// Container execution takes environment precedence over a VM guest, while the VM provider is
/// retained because it describes the underlying host. Runtime sockets indicate hosting only.
fn virtualization_component(root: &Path, detector: &dyn VirtDetector) -> Component {
    let dmi = format!(
        "{} {}",
        read(root, "sys/class/dmi/id/sys_vendor").unwrap_or_default(),
        read(root, "sys/class/dmi/id/product_name").unwrap_or_default()
    )
    .to_ascii_lowercase();
    let fallback_provider = [
        (["qemu", "libvirt", "kvm"].as_slice(), "kvm"),
        (["vmware"].as_slice(), "vmware"),
        (["virtualbox", "innotek"].as_slice(), "virtualbox"),
        (["hyper-v"].as_slice(), "hyper-v"),
        (["xen"].as_slice(), "xen"),
        (["amazon ec2", "amazon.com"].as_slice(), "aws"),
        (["google compute engine", "google"].as_slice(), "gcp"),
        (
            ["microsoft corporation virtual machine"].as_slice(),
            "azure",
        ),
        (["digitalocean"].as_slice(), "digitalocean"),
        (["openstack"].as_slice(), "openstack"),
        (["parallels"].as_slice(), "parallels"),
        (["bhyve"].as_slice(), "bhyve"),
    ]
    .into_iter()
    .find_map(|(markers, provider)| {
        markers
            .iter()
            .any(|v| dmi.contains(v))
            .then(|| provider.to_owned())
    });
    let container_fallback = root.join(".dockerenv").exists()
        || root.join("run/.containerenv").exists()
        || read(root, "proc/1/cgroup").is_some_and(|cgroup| {
            ["/docker/", "/containerd/", "/kubepods/", "/libpod/"]
                .iter()
                .any(|marker| cgroup.contains(marker))
        });
    let container_host = [
        "run/docker.sock",
        "var/run/docker.sock",
        "run/containerd/containerd.sock",
        "run/podman/podman.sock",
    ]
    .iter()
    .any(|path| {
        root.join(path)
            .metadata()
            .is_ok_and(|metadata| metadata.file_type().is_socket())
    });
    let container_detection = detector.container();
    let vm_detection = detector.vm();
    let container_type = match &container_detection {
        VirtDetection::Detected(value) => Some(value.clone()),
        _ => None,
    };
    let provider = match &vm_detection {
        VirtDetection::Detected(value) => Some(value.clone()),
        _ => fallback_provider,
    };
    let container_guest = container_type.is_some() || container_fallback;
    let environment = if container_guest {
        "container_guest"
    } else if provider.is_some() {
        "vm_guest"
    } else if container_detection == VirtDetection::None && vm_detection == VirtDetection::None {
        "bare_metal"
    } else {
        "unknown"
    };

    component(
        "virtualization",
        [
            ("environment", json!(environment)),
            ("provider", json!(provider)),
            ("container_type", json!(container_type)),
            ("container_host", json!(container_host.then_some(true))),
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collectors::filesystem_facts::{self, FilesystemFacts};
    use crate::collectors::network_facts::NetworkAddress;
    use crate::collectors::system_facts::{CpuFacts, OsFacts, SystemFacts};
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct FakeDetector {
        container: VirtDetection,
        vm: VirtDetection,
    }

    struct FakeFacts(SystemFacts);

    impl SystemFactsSource for FakeFacts {
        fn collect(&self) -> SystemFacts {
            self.0.clone()
        }
    }

    fn partial_facts() -> FakeFacts {
        FakeFacts(SystemFacts {
            hostname: Some("portable-host".into()),
            ..SystemFacts::default()
        })
    }

    impl VirtDetector for FakeDetector {
        fn container(&self) -> VirtDetection {
            self.container.clone()
        }

        fn vm(&self) -> VirtDetection {
            self.vm.clone()
        }
    }

    struct FakeNetwork(Option<Vec<NetworkInterface>>);
    impl NetworkFactsSource for FakeNetwork {
        fn collect(&self) -> std::io::Result<Vec<NetworkInterface>> {
            self.0
                .clone()
                .ok_or_else(|| std::io::Error::other("unavailable"))
        }
    }

    struct FakeFilesystems(Option<Vec<FilesystemFacts>>);
    impl FilesystemFactsSource for FakeFilesystems {
        fn collect(&self) -> std::io::Result<Vec<FilesystemFacts>> {
            self.0
                .clone()
                .ok_or_else(|| std::io::Error::other("unavailable"))
        }
    }

    fn collect_from_with_ip(
        root: &Path,
        ip_output: Result<&str, ()>,
    ) -> Result<ServerResource, CollectError> {
        collect_with_detection(
            root,
            ip_output,
            VirtDetection::Unknown,
            VirtDetection::Unknown,
        )
    }

    fn collect_with_detection(
        root: &Path,
        ip_output: Result<&str, ()>,
        container: VirtDetection,
        vm: VirtDetection,
    ) -> Result<ServerResource, CollectError> {
        let network = FakeNetwork(ip_output.ok().map(|_| vec![]));
        collect_from_with_sources(
            root,
            &network,
            &FakeDetector { container, vm },
            &partial_facts(),
            &ProcfsSource::from_process_root(root.join("proc/1")),
            &Cancellation::default(),
        )
    }

    fn fixture() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "renga-linux-collector-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("etc")).unwrap();
        fs::write(root.join("etc/hostname"), "test-host\n").unwrap();
        root
    }
    #[test]
    fn normalizes_firmware_placeholders() {
        assert_eq!(normalize_value(" To Be Filled By O.E.M. "), None);
        assert_eq!(normalize_value("Dell"), Some("Dell".into()));
    }

    #[test]
    fn maps_complete_portable_facts_to_exact_payload_components() {
        let root = fixture();
        let facts = FakeFacts(SystemFacts {
            os: OsFacts {
                name: Some("Example OS".into()),
                version: Some("42".into()),
                kernel: Some("6.1".into()),
                architecture: Some("test-arch".into()),
            },
            hostname: Some("fallback-host".into()),
            cpu: CpuFacts {
                logical_count: Some(8),
                physical_count: Some(4),
                brand: Some("Example CPU".into()),
            },
            total_memory_bytes: Some(16_384),
            disks: Some(vec![DiskFacts {
                name: "disk0".into(),
                medium: DiskMedium::Ssd,
                total_bytes: Some(1_000_000),
                mount_point: Some("/data".into()),
            }]),
        });
        let resource = collect_from_with_sources(
            &root,
            &FakeNetwork(Some(vec![])),
            &FakeDetector {
                container: VirtDetection::Unknown,
                vm: VirtDetection::Unknown,
            },
            &facts,
            &ProcfsSource::from_process_root(root.join("proc/1")),
            &Cancellation::default(),
        )
        .unwrap();
        let components = serde_json::to_value(resource.components).unwrap();

        assert_eq!(
            components[0],
            json!({"kind":"os","name":"Example OS","version":"42","kernel":"6.1","architecture":"test-arch"})
        );
        assert_eq!(
            components[1],
            json!({"kind":"cpu","logical_count":8,"physical_count":4,"model":"Example CPU"})
        );
        assert_eq!(components[2], json!({"kind":"memory","total_bytes":16_384}));
        assert_eq!(
            components[3],
            json!({"kind":"disk","name":"disk0","medium":"ssd","size_bytes":1_000_000,"mountpoint":"/data"})
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn disk_payload_omits_unknown_capacity_and_falls_back_to_mountpoint_for_blank_name() {
        let disks = collect_disks(Some(vec![DiskFacts {
            name: "  ".into(),
            medium: DiskMedium::Unknown,
            total_bytes: None,
            mount_point: Some("/data".into()),
        }]));

        assert_eq!(
            serde_json::to_value(&disks[0]).unwrap(),
            json!({"kind":"disk","name":"/data","medium":"unknown","mountpoint":"/data"})
        );
    }

    #[test]
    fn indeterminate_and_injected_authoritative_empty_disks_emit_no_components() {
        assert!(collect_disks(None).is_empty());
        assert!(collect_disks(Some(vec![])).is_empty());
    }

    #[test]
    fn hostname_fallback_is_normalized_when_file_is_missing_or_rejected() {
        for (file_value, fallback, expected) in [
            (None, "", None),
            (None, "  \n", None),
            (None, "unknown", None),
            (None, "none", None),
            (Some("unknown\n"), "fallback-host ", Some("fallback-host")),
            (Some("none\n"), " valid-host\n", Some("valid-host")),
        ] {
            let root = fixture();
            if let Some(file_value) = file_value {
                fs::write(root.join("etc/hostname"), file_value).unwrap();
            } else {
                fs::remove_file(root.join("etc/hostname")).unwrap();
            }
            let facts = FakeFacts(SystemFacts {
                hostname: Some(fallback.into()),
                ..SystemFacts::default()
            });
            let result = collect_from_with_sources(
                &root,
                &FakeNetwork(Some(vec![])),
                &FakeDetector {
                    container: VirtDetection::Unknown,
                    vm: VirtDetection::Unknown,
                },
                &facts,
                &ProcfsSource::from_process_root(root.join("proc/1")),
                &Cancellation::default(),
            );

            assert_eq!(
                result.ok().map(|resource| resource.identifiers.hostname),
                expected.map(str::to_owned),
                "file={file_value:?}, fallback={fallback:?}"
            );
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn partial_facts_omit_unavailable_values_and_use_hostname_fallback() {
        let root = fixture();
        fs::remove_file(root.join("etc/hostname")).unwrap();
        let resource = collect_from_with_sources(
            &root,
            &FakeNetwork(Some(vec![])),
            &FakeDetector {
                container: VirtDetection::Unknown,
                vm: VirtDetection::Unknown,
            },
            &partial_facts(),
            &ProcfsSource::from_process_root(root.join("proc/1")),
            &Cancellation::default(),
        )
        .unwrap();
        let value = serde_json::to_value(resource).unwrap();

        assert_eq!(value["identifiers"]["hostname"], "portable-host");
        assert_eq!(value["attributes"]["hostname"], "portable-host");
        assert_eq!(value["components"][0], json!({"kind":"os"}));
        assert_eq!(value["components"][1], json!({"kind":"cpu"}));
        assert!(value["components"]
            .as_array()
            .unwrap()
            .iter()
            .all(|item| item["kind"] != "memory" && item["kind"] != "disk"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn collects_filesystems_from_host_pid_one_mountinfo() {
        let root = fixture();
        fs::create_dir_all(root.join("proc/1")).unwrap();
        fs::write(
            root.join("proc/mountinfo"),
            "20 1 0:20 / /sandbox rw - sandboxfs sandboxfs rw\n",
        )
        .unwrap();
        fs::write(
            root.join("proc/1/mountinfo"),
            "21 1 0:21 / /host rw - hostfs hostfs rw\n",
        )
        .unwrap();

        let filesystems =
            collect_filesystems(&ProcfsSource::from_process_root(root.join("proc/1")));

        assert_eq!(filesystems.len(), 1);
        assert_eq!(filesystems[0].attributes["device"], "hostfs");
        assert_eq!(filesystems[0].attributes["mountpoint"], "/host");
        assert_eq!(filesystems[0].attributes["filesystem_type"], "hostfs");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn parses_mountinfo_and_unescapes_fields() {
        let facts = filesystem_facts::parse_mountinfo(
            "36 25 0:32 / /mnt/data\\040archive rw,nosuid - ext4 /dev/mapper/data\\040disk rw\n",
        )
        .unwrap();
        let filesystems = collect_filesystems(&FakeFilesystems(Some(facts)));

        assert_eq!(filesystems.len(), 1);
        assert_eq!(filesystems[0].attributes["device"], "/dev/mapper/data disk");
        assert_eq!(filesystems[0].attributes["mountpoint"], "/mnt/data archive");
        assert_eq!(filesystems[0].attributes["filesystem_type"], "ext4");
    }

    #[test]
    fn bounds_filesystems_and_reports_explicit_truncation_status() {
        let mounts = (0..=MAX_FILESYSTEM_COMPONENTS)
            .map(|index| {
                format!(
                    "{} 1 0:{} / /mnt/{index} rw - ext4 /dev/vda{index} rw\n",
                    index + 2,
                    index + 2
                )
            })
            .collect::<String>();

        let facts = filesystem_facts::parse_mountinfo(&mounts).unwrap();
        let filesystems = collect_filesystems(&FakeFilesystems(Some(facts)));

        assert_eq!(filesystems.len(), MAX_FILESYSTEM_COMPONENTS + 1);
        let status = filesystems.last().unwrap();
        assert_eq!(status.kind, "collection_status");
        assert_eq!(status.attributes["collector"], "filesystem");
        assert_eq!(
            status.attributes["discovered_count"],
            MAX_FILESYSTEM_COMPONENTS + 1
        );
        assert_eq!(
            status.attributes["emitted_count"],
            MAX_FILESYSTEM_COMPONENTS
        );
        assert_eq!(status.attributes["truncated"], true);
    }

    #[test]
    fn bounds_disks_and_reports_explicit_truncation_status() {
        let disks = (0..=MAX_DISK_COMPONENTS)
            .map(|index| DiskFacts {
                name: format!("disk{index}"),
                medium: DiskMedium::Unknown,
                total_bytes: Some(4096),
                mount_point: None,
            })
            .collect();

        let disks = collect_disks(Some(disks));

        assert_eq!(disks.len(), MAX_DISK_COMPONENTS + 1);
        let status = disks.last().unwrap();
        assert_eq!(status.kind, "collection_status");
        assert_eq!(status.attributes["collector"], "disk");
        assert_eq!(
            status.attributes["discovered_count"],
            MAX_DISK_COMPONENTS + 1
        );
        assert_eq!(status.attributes["emitted_count"], MAX_DISK_COMPONENTS);
        assert_eq!(status.attributes["truncated"], true);
    }

    #[test]
    fn inaccessible_pid_one_mountinfo_does_not_fall_back_to_self_mountinfo() {
        let root = fixture();
        fs::create_dir_all(root.join("proc")).unwrap();
        fs::write(
            root.join("proc/mountinfo"),
            "20 1 0:20 / /sandbox rw - sandboxfs sandboxfs rw\n",
        )
        .unwrap();

        assert!(
            collect_filesystems(&ProcfsSource::from_process_root(root.join("proc/1"))).is_empty()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn malformed_pid_one_mountinfo_omits_all_filesystems() {
        let root = fixture();
        fs::create_dir_all(root.join("proc/1")).unwrap();
        fs::write(
            root.join("proc/mountinfo"),
            "20 1 0:20 / /sandbox rw - sandboxfs sandboxfs rw\n",
        )
        .unwrap();
        fs::write(root.join("proc/1/mountinfo"), "malformed\n").unwrap();

        assert!(
            collect_filesystems(&ProcfsSource::from_process_root(root.join("proc/1"))).is_empty()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn oversized_pid_one_mountinfo_omits_all_filesystems() {
        let root = fixture();
        fs::create_dir_all(root.join("proc/1")).unwrap();
        fs::write(
            root.join("proc/1/mountinfo"),
            vec![b'x'; filesystem_facts::MAX_MOUNTINFO_BYTES as usize + 1],
        )
        .unwrap();

        assert!(
            collect_filesystems(&ProcfsSource::from_process_root(root.join("proc/1"))).is_empty()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unavailable_network_snapshot_omits_interfaces_and_macs() {
        let root = fixture();
        let resource = collect_from_with_ip(&root, Err(())).unwrap();
        let value = serde_json::to_value(resource).unwrap();

        assert!(value.get("interfaces").is_none());
        assert!(value["identifiers"].get("mac_address").is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn authoritative_empty_network_snapshot_serializes_empty_interfaces() {
        let root = fixture();
        let resource = collect_from_with_ip(&root, Ok("[]")).unwrap();
        let value = serde_json::to_value(resource).unwrap();

        assert_eq!(value["interfaces"], json!([]));
        assert!(value["identifiers"].get("mac_address").is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn populated_snapshot_maps_addresses_flags_macs_and_linux_enrichment() {
        let root = fixture();
        let base = root.join("sys/class/net/eth0");
        fs::create_dir_all(base.join("device")).unwrap();
        fs::write(base.join("speed"), "1000\n").unwrap();
        fs::write(base.join("address"), "aa:bb:cc:dd:ee:ff\n").unwrap();
        let network = FakeNetwork(Some(vec![NetworkInterface {
            name: "eth0".into(),
            index: 2,
            mac: Some("aa:bb:cc:dd:ee:ff".into()),
            mtu: Some(1500),
            up: true,
            running: false,
            loopback: false,
            addresses: vec![NetworkAddress {
                ip: "10.0.0.2".parse().unwrap(),
                prefix: 24,
                family: AddressFamily::Ipv4,
            }],
        }]));
        let resource = collect_from_with_sources(
            &root,
            &network,
            &FakeDetector {
                container: VirtDetection::Unknown,
                vm: VirtDetection::Unknown,
            },
            &partial_facts(),
            &ProcfsSource::from_process_root(root.join("proc/1")),
            &Cancellation::default(),
        )
        .unwrap();
        let value = serde_json::to_value(resource).unwrap();
        assert_eq!(
            value["identifiers"]["mac_address"],
            json!(["aa:bb:cc:dd:ee:ff"])
        );
        assert_eq!(
            value["interfaces"][0]["addresses"][0]["address"],
            "10.0.0.2/24"
        );
        assert_eq!(value["interfaces"][0]["status"], "up");
        assert_eq!(value["interfaces"][0]["kind"], "ethernet");
        assert_eq!(value["interfaces"][0]["speed_mbps"], 1000);
        assert_eq!(value["interfaces"][0]["mtu"], 1500);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn linux_mac_enrichment_requires_matching_six_byte_nonzero_sysfs_address() {
        for (sysfs, expected) in [
            (Some("AA:BB:CC:DD:EE:FF\n"), Some("aa:bb:cc:dd:ee:ff")),
            (None, None),
            (Some("11:22:33:44:55:66\n"), None),
            (
                Some("00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33\n"),
                None,
            ),
            (Some("00:00:00:00:00:00\n"), None),
            (Some("aa:bb:cc:dd:ee:gg\n"), None),
        ] {
            let root = fixture();
            let base = root.join("sys/class/net/eth0");
            fs::create_dir_all(&base).unwrap();
            if let Some(sysfs) = sysfs {
                fs::write(base.join("address"), sysfs).unwrap();
            }
            let mut interfaces = project_interfaces(vec![NetworkInterface {
                name: "eth0".into(),
                index: 2,
                mac: Some("aa:bb:cc:dd:ee:ff".into()),
                mtu: None,
                up: false,
                running: true,
                loopback: false,
                addresses: vec![],
            }]);

            enrich_interfaces(&root, &mut interfaces);

            assert_eq!(interfaces[0].mac_address.as_deref(), expected, "{sysfs:?}");
            assert_eq!(interfaces[0].status, "down");
            fs::remove_dir_all(root).unwrap();
        }
    }

    fn virtualization(resource: &ServerResource) -> &Component {
        resource
            .components
            .iter()
            .find(|component| component.kind == "virtualization")
            .unwrap()
    }

    #[test]
    fn reports_bare_metal_only_when_both_detectors_report_none() {
        let root = fixture();
        let resource =
            collect_with_detection(&root, Ok("[]"), VirtDetection::None, VirtDetection::None)
                .unwrap();

        assert_eq!(
            virtualization(&resource).attributes["environment"],
            "bare_metal"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unavailable_detectors_without_fallback_evidence_report_unknown() {
        let root = fixture();
        let resource = collect_from_with_ip(&root, Ok("[]")).unwrap();

        assert_eq!(
            virtualization(&resource).attributes["environment"],
            "unknown"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn qemu_sys_vendor_is_positive_vm_fallback() {
        let root = fixture();
        let dmi = root.join("sys/class/dmi/id");
        fs::create_dir_all(&dmi).unwrap();
        fs::write(dmi.join("sys_vendor"), "QEMU\n").unwrap();
        let resource = collect_from_with_ip(&root, Ok("[]")).unwrap();

        assert_eq!(
            virtualization(&resource).attributes["environment"],
            "vm_guest"
        );
        assert_eq!(virtualization(&resource).attributes["provider"], "kvm");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn detected_vm_value_is_the_provider() {
        let root = fixture();
        let resource = collect_with_detection(
            &root,
            Ok("[]"),
            VirtDetection::None,
            VirtDetection::Detected("oracle".into()),
        )
        .unwrap();

        assert_eq!(
            virtualization(&resource).attributes["environment"],
            "vm_guest"
        );
        assert_eq!(virtualization(&resource).attributes["provider"], "oracle");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn container_host_requires_a_runtime_socket() {
        let root = fixture();
        fs::create_dir_all(root.join("run/containerd")).unwrap();
        fs::write(root.join("run/containerd/containerd.sock"), "").unwrap();
        let regular_file =
            collect_with_detection(&root, Ok("[]"), VirtDetection::None, VirtDetection::None)
                .unwrap();
        assert!(
            virtualization(&regular_file)
                .attributes
                .get("container_host")
                .is_none(),
            "a regular file must not identify a container runtime"
        );

        fs::remove_file(root.join("run/containerd/containerd.sock")).unwrap();
        let _listener =
            std::os::unix::net::UnixListener::bind(root.join("run/containerd/containerd.sock"))
                .unwrap();
        let socket =
            collect_with_detection(&root, Ok("[]"), VirtDetection::None, VirtDetection::None)
                .unwrap();

        assert_eq!(virtualization(&socket).attributes["container_host"], true);
        assert_eq!(
            virtualization(&socket).attributes["environment"],
            "bare_metal"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn container_on_vm_retains_vm_provider() {
        let root = fixture();
        let dmi = root.join("sys/class/dmi/id");
        fs::create_dir_all(&dmi).unwrap();
        fs::write(dmi.join("product_name"), "VMware Virtual Platform\n").unwrap();
        fs::write(root.join(".dockerenv"), "").unwrap();
        let resource = collect_with_detection(
            &root,
            Ok("[]"),
            VirtDetection::Detected("docker".into()),
            VirtDetection::Detected("vmware".into()),
        )
        .unwrap();

        assert_eq!(
            virtualization(&resource).attributes["environment"],
            "container_guest"
        );
        assert_eq!(virtualization(&resource).attributes["provider"], "vmware");
        assert_eq!(
            virtualization(&resource).attributes["container_type"],
            "docker"
        );
        assert!(!virtualization(&resource)
            .attributes
            .contains_key("container_host"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn container_markers_are_positive_fallback_evidence() {
        let root = fixture();
        fs::write(root.join(".dockerenv"), "").unwrap();
        let resource = collect_from_with_ip(&root, Ok("[]")).unwrap();

        assert_eq!(
            virtualization(&resource).attributes["environment"],
            "container_guest"
        );
        assert!(!virtualization(&resource)
            .attributes
            .contains_key("container_type"));
        fs::remove_dir_all(root).unwrap();
    }
}
