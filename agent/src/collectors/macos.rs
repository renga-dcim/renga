//! macOS inventory from portable system facts and native Darwin interfaces.

use super::{
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
use std::{io, mem, process::Command, ptr};

const MAX_DISK_COMPONENTS: usize = 128;
const MAX_FILESYSTEM_COMPONENTS: usize = 512;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct PlatformFacts {
    product_name: Option<String>,
    model: Option<String>,
    platform_uuid: Option<String>,
    serial_number: Option<String>,
    fqdn: Option<String>,
    vm_present: Option<bool>,
}

trait PlatformFactsSource {
    fn collect(&self) -> PlatformFacts;
}

struct NativePlatformSource<'a>(&'a Cancellation);

impl NativePlatformSource<'_> {
    fn output(&self, program: &str, args: &[&str]) -> Option<String> {
        command::run(Command::new(program).args(args), self.0)
            .ok()
            .filter(|output| output.status.success())
            .and_then(|output| String::from_utf8(output.stdout).ok())
    }
}

impl PlatformFactsSource for NativePlatformSource<'_> {
    fn collect(&self) -> PlatformFacts {
        let ioreg = self
            .output("/usr/sbin/ioreg", &["-rd1", "-c", "IOPlatformExpertDevice"])
            .unwrap_or_default();

        PlatformFacts {
            product_name: self
                .output(
                    "/usr/sbin/system_profiler",
                    &["SPHardwareDataType", "-json"],
                )
                .and_then(|output| system_profiler_product_name(&output)),
            model: self
                .output("/usr/sbin/sysctl", &["-n", "hw.model"])
                .and_then(|value| normalize(&value)),
            platform_uuid: quoted_property(&ioreg, "IOPlatformUUID"),
            serial_number: quoted_property(&ioreg, "IOPlatformSerialNumber"),
            fqdn: self
                .output("/bin/hostname", &["-f"])
                .and_then(|value| normalize(&value))
                .filter(|value| value.contains('.')),
            vm_present: self
                .output("/usr/sbin/sysctl", &["-n", "kern.hv_vmm_present"])
                .and_then(|value| match value.trim() {
                    "0" => Some(false),
                    "1" => Some(true),
                    _ => None,
                }),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct FilesystemFacts {
    device: String,
    mountpoint: String,
    filesystem_type: String,
}

trait FilesystemFactsSource {
    fn collect(&self) -> io::Result<Vec<FilesystemFacts>>;
}

struct DarwinFilesystemSource;

impl FilesystemFactsSource for DarwinFilesystemSource {
    fn collect(&self) -> io::Result<Vec<FilesystemFacts>> {
        load_filesystem_stats(mounted_filesystem_count, read_mounted_filesystems)?
            .iter()
            .map(|mount| {
                let device = c_string(&mount.f_mntfromname).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "mount has no device")
                })?;
                let mountpoint = c_string(&mount.f_mntonname).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "mount has no mountpoint")
                })?;
                let filesystem_type = c_string(&mount.f_fstypename).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "mount has no filesystem type")
                })?;
                Ok(FilesystemFacts {
                    device,
                    mountpoint,
                    filesystem_type,
                })
            })
            .collect()
    }
}

fn mounted_filesystem_count() -> io::Result<usize> {
    // SAFETY: a null buffer with zero size asks getfsstat only for the mount count.
    let count = unsafe { libc::getfsstat(ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    if count < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(count as usize)
    }
}

fn read_mounted_filesystems(capacity: usize) -> io::Result<Vec<libc::statfs>> {
    let byte_size = capacity
        .checked_mul(mem::size_of::<libc::statfs>())
        .and_then(|size| libc::c_int::try_from(size).ok())
        .ok_or_else(|| io::Error::other("filesystem buffer is too large"))?;
    let mut mounts = Vec::with_capacity(capacity);
    // SAFETY: getfsstat may initialize at most byte_size bytes in caller-owned storage.
    let count = unsafe { libc::getfsstat(mounts.as_mut_ptr(), byte_size, libc::MNT_NOWAIT) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    let initialized = count as usize;
    if initialized > capacity {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "filesystem count exceeds allocated buffer",
        ));
    }
    // SAFETY: getfsstat initialized the number of entries it returned.
    unsafe { mounts.set_len(initialized) };
    Ok(mounts)
}

fn load_filesystem_stats(
    mut count: impl FnMut() -> io::Result<usize>,
    mut read: impl FnMut(usize) -> io::Result<Vec<libc::statfs>>,
) -> io::Result<Vec<libc::statfs>> {
    loop {
        let expected = count()?;
        let mounts = read(expected)?;

        if count()? <= mounts.len() {
            return Ok(mounts);
        }
    }
}

fn c_string<const N: usize>(value: &[libc::c_char; N]) -> Option<String> {
    let bytes = value
        .iter()
        .map(|byte| *byte as u8)
        .take_while(|byte| *byte != 0)
        .collect::<Vec<_>>();
    String::from_utf8(bytes)
        .ok()
        .filter(|value| !value.is_empty())
}

fn normalize(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn quoted_property(output: &str, key: &str) -> Option<String> {
    let prefix = format!("\"{key}\" = \"");
    output.lines().find_map(|line| {
        line.trim()
            .strip_prefix(&prefix)
            .and_then(|value| value.strip_suffix('"'))
            .and_then(normalize)
    })
}

fn system_profiler_product_name(output: &str) -> Option<String> {
    serde_json::from_str::<Value>(output)
        .ok()?
        .get("SPHardwareDataType")?
        .as_array()?
        .first()?
        .get("machine_name")?
        .as_str()
        .and_then(normalize)
}

fn hardware_model(platform: &PlatformFacts) -> Option<String> {
    match (&platform.product_name, &platform.model) {
        (Some(product_name), Some(model)) if product_name != model => {
            Some(format!("{product_name} ({model})"))
        }

        (Some(product_name), _) => Some(product_name.clone()),
        (None, model) => model.clone(),
    }
}

fn collect_from_sources(
    system_source: &dyn SystemFactsSource,
    platform_source: &dyn PlatformFactsSource,
    network_source: &dyn NetworkFactsSource,
    filesystem_source: &dyn FilesystemFactsSource,
) -> Result<ServerResource, CollectError> {
    let system = system_source.collect();
    let platform = platform_source.collect();
    let model = hardware_model(&platform);
    let hostname = system
        .hostname
        .as_deref()
        .and_then(normalize)
        .ok_or_else(|| CollectError("macOS host has no usable hostname".into()))?;
    let interfaces = network_source.collect().ok().map(project_interfaces);
    let macs = interfaces
        .as_deref()
        .unwrap_or_default()
        .iter()
        .filter(|interface| interface.kind == "ethernet")
        .filter_map(|interface| interface.mac_address.clone())
        .collect();
    let mut components = vec![
        component(
            "os",
            [
                ("name", json!("macOS")),
                ("version", json!(system.os.version)),
                ("kernel", json!(system.os.kernel)),
                ("architecture", json!(system.os.architecture)),
            ],
        ),
        component(
            "cpu",
            [
                ("logical_count", json!(system.cpu.logical_count)),
                ("physical_count", json!(system.cpu.physical_count)),
                ("model", json!(system.cpu.brand)),
            ],
        ),
    ];
    if let Some(bytes) = system.total_memory_bytes {
        components.push(component("memory", [("total_bytes", json!(bytes))]));
    }
    components.extend(collect_disks(system.disks));
    components.extend(collect_filesystems(filesystem_source));
    components.push(virtualization_component(&platform));

    Ok(ServerResource {
        kind: ResourceKind::Server,
        identifiers: Identifiers {
            hostname: hostname.clone(),
            fqdn: platform.fqdn.clone(),
            machine_id: platform.platform_uuid,
            dmi_uuid: None,
            serial_number: platform.serial_number,
            mac_address: macs,
        },
        attributes: Some(HostAttributes {
            hostname: Some(hostname),
            fqdn: platform.fqdn,
            vendor: Some("Apple Inc.".into()),
            model,
            asset_tag: None,
        }),
        interfaces,
        components,
    })
}

/// Collects from the running macOS host.
pub fn collect(cancellation: &Cancellation) -> Result<ServerResource, CollectError> {
    collect_from_sources(
        &SysinfoSource,
        &NativePlatformSource(cancellation),
        &GetifsSource,
        &DarwinFilesystemSource,
    )
}

fn component<const N: usize>(kind: &str, values: [(&str, Value); N]) -> Component {
    Component {
        kind: kind.into(),
        attributes: values
            .into_iter()
            .filter(|(_, value)| !value.is_null())
            .map(|(key, value)| (key.into(), value))
            .collect(),
    }
}

fn project_interfaces(facts: Vec<NetworkInterface>) -> Vec<Interface> {
    facts
        .into_iter()
        .map(|fact| {
            let kind = if fact.loopback {
                "loopback"
            } else if fact.name.starts_with("en") {
                "ethernet"
            } else {
                "virtual"
            };
            Interface {
                name: fact.name,
                kind: kind.into(),
                status: if fact.up { "up" } else { "down" }.into(),
                mac_address: fact.mac.and_then(|value| ethernet_mac(&value)),
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
            }
        })
        .collect()
}

fn ethernet_mac(value: &str) -> Option<String> {
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
            component(
                "disk",
                [
                    ("name", json!(normalize(&disk.name))),
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

fn virtualization_component(platform: &PlatformFacts) -> Component {
    let provider = platform.vm_present.is_some_and(|present| present).then(|| {
        let model = platform.model.as_deref().unwrap_or_default().to_lowercase();
        if model.contains("virtualmac") {
            "apple"
        } else if model.contains("vmware") {
            "vmware"
        } else if model.contains("parallels") {
            "parallels"
        } else {
            "unknown"
        }
    });
    let environment = match platform.vm_present {
        Some(true) => "vm_guest",
        Some(false) => "bare_metal",
        None => "unknown",
    };
    component(
        "virtualization",
        [
            ("environment", json!(environment)),
            ("provider", json!(provider)),
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collectors::{
        network_facts::NetworkAddress,
        system_facts::{CpuFacts, OsFacts, SystemFacts},
    };

    struct FakeSystem(SystemFacts);
    impl SystemFactsSource for FakeSystem {
        fn collect(&self) -> SystemFacts {
            self.0.clone()
        }
    }

    struct FakePlatform(PlatformFacts);
    impl PlatformFactsSource for FakePlatform {
        fn collect(&self) -> PlatformFacts {
            self.0.clone()
        }
    }

    struct FakeNetwork(Option<Vec<NetworkInterface>>);
    impl NetworkFactsSource for FakeNetwork {
        fn collect(&self) -> io::Result<Vec<NetworkInterface>> {
            self.0
                .clone()
                .ok_or_else(|| io::Error::other("unavailable"))
        }
    }

    struct FakeFilesystems(Option<Vec<FilesystemFacts>>);
    impl FilesystemFactsSource for FakeFilesystems {
        fn collect(&self) -> io::Result<Vec<FilesystemFacts>> {
            self.0
                .clone()
                .ok_or_else(|| io::Error::other("unavailable"))
        }
    }

    fn complete_system() -> FakeSystem {
        FakeSystem(SystemFacts {
            os: OsFacts {
                name: Some("macOS".into()),
                version: Some("26.0".into()),
                kernel: Some("25.0.0".into()),
                architecture: Some("aarch64".into()),
            },
            hostname: Some("test-mac".into()),
            cpu: CpuFacts {
                logical_count: Some(10),
                physical_count: Some(10),
                brand: Some("Apple M4".into()),
            },
            total_memory_bytes: Some(16_384),
            disks: Some(vec![DiskFacts {
                name: "Macintosh HD".into(),
                medium: DiskMedium::Ssd,
                total_bytes: Some(1_000_000),
                mount_point: Some("/".into()),
            }]),
        })
    }

    #[test]
    fn parses_ioreg_string_properties() {
        let output = r#"
          "IOPlatformSerialNumber" = "SERIAL123"
          "IOPlatformUUID" = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        "#;
        assert_eq!(
            quoted_property(output, "IOPlatformSerialNumber").as_deref(),
            Some("SERIAL123")
        );
        assert_eq!(
            quoted_property(output, "IOPlatformUUID").as_deref(),
            Some("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        );
        assert_eq!(quoted_property(output, "missing"), None);
    }

    #[test]
    fn parses_system_profiler_product_name() {
        let output = r#"{
          "SPHardwareDataType": [{"machine_name": "MacBook Pro", "machine_model": "Mac16,5"}]
        }"#;

        assert_eq!(
            system_profiler_product_name(output).as_deref(),
            Some("MacBook Pro")
        );
        assert_eq!(system_profiler_product_name("{}"), None);
        assert_eq!(system_profiler_product_name("not-json"), None);
    }

    #[test]
    fn preserves_whitespace_in_c_filesystem_paths() {
        let mut value = [0; 64];
        let path = b"/Volumes/Archive ";
        for (destination, source) in value.iter_mut().zip(path) {
            *destination = *source as libc::c_char;
        }

        assert_eq!(c_string(&value).as_deref(), Some("/Volumes/Archive "));
    }

    #[test]
    fn retries_filesystem_snapshot_when_mount_count_grows() {
        use std::{cell::RefCell, collections::VecDeque};

        let counts = RefCell::new(VecDeque::from([1, 2, 2, 2]));
        let capacities = RefCell::new(Vec::new());
        let mounts = load_filesystem_stats(
            || Ok(counts.borrow_mut().pop_front().unwrap()),
            |capacity| {
                capacities.borrow_mut().push(capacity);
                Ok((0..capacity).map(|_| unsafe { mem::zeroed() }).collect())
            },
        )
        .unwrap();

        assert_eq!(capacities.into_inner(), [1, 2]);
        assert_eq!(mounts.len(), 2);
    }

    #[test]
    fn combines_product_name_with_model_identifier_and_preserves_fallbacks() {
        assert_eq!(
            hardware_model(&PlatformFacts {
                product_name: Some("MacBook Pro".into()),
                model: Some("Mac16,5".into()),
                ..PlatformFacts::default()
            })
            .as_deref(),
            Some("MacBook Pro (Mac16,5)")
        );
        assert_eq!(
            hardware_model(&PlatformFacts {
                model: Some("Mac16,5".into()),
                ..PlatformFacts::default()
            })
            .as_deref(),
            Some("Mac16,5")
        );
    }

    #[test]
    fn maps_native_facts_to_inventory_contract() {
        let platform = FakePlatform(PlatformFacts {
            product_name: Some("MacBook Pro".into()),
            model: Some("Mac16,1".into()),
            platform_uuid: Some("platform-id".into()),
            serial_number: Some("serial".into()),
            fqdn: Some("test-mac.example.com".into()),
            vm_present: Some(false),
        });
        let network = FakeNetwork(Some(vec![NetworkInterface {
            name: "en0".into(),
            index: 1,
            mac: Some("AA:BB:CC:DD:EE:FF".into()),
            mtu: Some(1500),
            up: true,
            running: true,
            loopback: false,
            addresses: vec![NetworkAddress {
                ip: "192.0.2.10".parse().unwrap(),
                prefix: 24,
                family: AddressFamily::Ipv4,
            }],
        }]));
        let filesystems = FakeFilesystems(Some(vec![FilesystemFacts {
            device: "/dev/disk3s1s1".into(),
            mountpoint: "/".into(),
            filesystem_type: "apfs".into(),
        }]));

        let resource =
            collect_from_sources(&complete_system(), &platform, &network, &filesystems).unwrap();
        let value = serde_json::to_value(resource).unwrap();

        assert_eq!(value["identifiers"]["hostname"], "test-mac");
        assert_eq!(value["identifiers"]["fqdn"], "test-mac.example.com");
        assert_eq!(value["identifiers"]["machine_id"], "platform-id");
        assert_eq!(value["identifiers"]["serial_number"], "serial");
        assert_eq!(
            value["identifiers"]["mac_address"],
            json!(["aa:bb:cc:dd:ee:ff"])
        );
        assert_eq!(value["attributes"]["vendor"], "Apple Inc.");
        assert_eq!(value["attributes"]["model"], "MacBook Pro (Mac16,1)");
        assert_eq!(value["interfaces"][0]["kind"], "ethernet");
        assert_eq!(
            value["interfaces"][0]["addresses"][0]["address"],
            "192.0.2.10/24"
        );
        assert!(value["components"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| { item == &json!({"kind":"os","name":"macOS","version":"26.0","kernel":"25.0.0","architecture":"aarch64"}) }));
        assert!(value["components"].as_array().unwrap().iter().any(|item| {
            item == &json!({"kind":"filesystem","device":"/dev/disk3s1s1","mountpoint":"/","filesystem_type":"apfs"})
        }));
        assert!(value["components"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| { item == &json!({"kind":"virtualization","environment":"bare_metal"}) }));
    }

    #[test]
    fn optional_sources_degrade_without_losing_host_inventory() {
        let resource = collect_from_sources(
            &complete_system(),
            &FakePlatform(PlatformFacts::default()),
            &FakeNetwork(None),
            &FakeFilesystems(None),
        )
        .unwrap();
        let value = serde_json::to_value(resource).unwrap();

        assert!(value.get("interfaces").is_none());
        assert!(value["identifiers"].get("machine_id").is_none());
        assert!(value["components"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| { item == &json!({"kind":"virtualization","environment":"unknown"}) }));
    }

    #[test]
    fn identifies_common_macos_virtual_machine_providers() {
        for (model, provider) in [
            ("VirtualMac2,1", "apple"),
            ("VMware20,1", "vmware"),
            ("Parallels19,1", "parallels"),
            ("Other1,1", "unknown"),
        ] {
            let component = virtualization_component(&PlatformFacts {
                model: Some(model.into()),
                vm_present: Some(true),
                ..PlatformFacts::default()
            });
            assert_eq!(component.attributes["environment"], "vm_guest");
            assert_eq!(component.attributes["provider"], provider);
        }
    }

    #[test]
    fn bounds_filesystems_and_reports_truncation() {
        let filesystems = (0..=MAX_FILESYSTEM_COMPONENTS)
            .map(|index| FilesystemFacts {
                device: format!("/dev/disk{index}"),
                mountpoint: format!("/Volumes/{index}"),
                filesystem_type: "apfs".into(),
            })
            .collect();

        let components = collect_filesystems(&FakeFilesystems(Some(filesystems)));
        let status = components.last().unwrap();
        assert_eq!(components.len(), MAX_FILESYSTEM_COMPONENTS + 1);
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
    fn classifies_darwin_interfaces_and_rejects_non_ethernet_macs() {
        let interfaces = project_interfaces(vec![
            NetworkInterface {
                name: "lo0".into(),
                index: 1,
                mac: None,
                mtu: None,
                up: true,
                running: true,
                loopback: true,
                addresses: vec![],
            },
            NetworkInterface {
                name: "utun0".into(),
                index: 2,
                mac: Some("not-a-mac".into()),
                mtu: None,
                up: true,
                running: true,
                loopback: false,
                addresses: vec![],
            },
        ]);

        assert_eq!(interfaces[0].kind, "loopback");
        assert_eq!(interfaces[1].kind, "virtual");
        assert_eq!(interfaces[1].mac_address, None);
    }

    #[test]
    fn native_sources_smoke_test_on_macos() {
        let resource = collect(&Cancellation::default()).unwrap();
        assert!(!resource.identifiers.hostname.is_empty());
        assert_eq!(
            resource.attributes.as_ref().unwrap().vendor.as_deref(),
            Some("Apple Inc.")
        );
        assert!(resource
            .components
            .iter()
            .any(|component| component.kind == "os"));
        assert!(resource
            .components
            .iter()
            .any(|component| component.kind == "cpu"));
        assert!(resource
            .components
            .iter()
            .any(|component| component.kind == "filesystem"));
    }
}
