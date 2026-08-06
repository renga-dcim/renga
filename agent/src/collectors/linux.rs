//! Linux inventory from procfs/sysfs. Missing individual kernel files are tolerated.

use super::CollectError;
use crate::payload::{
    Address, Component, HostAttributes, Identifiers, Interface, ResourceKind, ServerResource,
};
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, path::Path, process::Command};

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

struct SystemdVirtDetector;

impl SystemdVirtDetector {
    fn detect(category: &str) -> VirtDetection {
        let Ok(output) = Command::new("systemd-detect-virt").arg(category).output() else {
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

impl VirtDetector for SystemdVirtDetector {
    fn container(&self) -> VirtDetection {
        Self::detect("--container")
    }

    fn vm(&self) -> VirtDetection {
        Self::detect("--vm")
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

pub fn parse_os_release(input: &str) -> BTreeMap<String, String> {
    input
        .lines()
        .filter_map(|line| {
            let (k, v) = line.split_once('=')?;
            Some((k.into(), v.trim_matches('"').replace("\\\"", "\"")))
        })
        .collect()
}
pub fn parse_meminfo(input: &str) -> Option<u64> {
    input
        .lines()
        .find(|l| l.starts_with("MemTotal:"))?
        .split_whitespace()
        .nth(1)?
        .parse::<u64>()
        .ok()
        .map(|kb| kb * 1024)
}
pub fn parse_cpuinfo(input: &str) -> (usize, Option<String>) {
    let count = input.lines().filter(|l| l.starts_with("processor")).count();
    let model = input.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        (k.trim() == "model name").then(|| v.trim().into())
    });
    (count, model)
}

/// Parses `ip -j address`; malformed output yields no interfaces for parser callers.
#[cfg(test)]
fn parse_ip_json(input: &str) -> Vec<Interface> {
    parse_ip_snapshot(input).unwrap_or_default()
}

fn parse_ip_snapshot(input: &str) -> Result<Vec<Interface>, ()> {
    let Value::Array(items) = serde_json::from_str(input).map_err(|_| ())? else {
        return Err(());
    };
    if items
        .iter()
        .any(|item| item.get("ifname").and_then(Value::as_str).is_none())
    {
        return Err(());
    }
    Ok(items
        .into_iter()
        .filter_map(|item| {
            let name = item.get("ifname")?.as_str()?.into();
            let flags = item.get("flags").and_then(Value::as_array);
            let up = flags.is_some_and(|f| f.iter().any(|x| x.as_str() == Some("UP")));
            let addresses = item
                .get("addr_info")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|a| {
                    let local = a.get("local")?.as_str()?;
                    let prefix = a.get("prefixlen").and_then(Value::as_u64)?;
                    Some(Address {
                        address: format!("{local}/{prefix}"),
                        kind: a.get("family").and_then(Value::as_str).map(|v| {
                            if v == "inet" {
                                "ipv4".into()
                            } else {
                                "ipv6".into()
                            }
                        }),
                        scope: a.get("scope").and_then(Value::as_str).map(Into::into),
                    })
                })
                .collect();
            Some(Interface {
                name,
                kind: "unknown".into(),
                status: if up { "up" } else { "down" }.into(),
                mac_address: item
                    .get("address")
                    .and_then(Value::as_str)
                    .and_then(normalize_mac),
                mtu: item
                    .get("mtu")
                    .and_then(Value::as_u64)
                    .and_then(|v| u32::try_from(v).ok()),
                speed_mbps: None,
                addresses: Some(addresses),
            })
        })
        .collect())
}
fn normalize_mac(v: &str) -> Option<String> {
    let v = v.trim().to_ascii_lowercase();
    if v == "00:00:00:00:00:00" || v.len() != 17 {
        None
    } else {
        Some(v)
    }
}

/// Collects one server resource. `root` permits parser/filesystem fixtures in tests.
pub fn collect_from(root: &Path) -> Result<ServerResource, CollectError> {
    let ip_output = Command::new("ip")
        .args(["-j", "address"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    collect_from_with_ip_and_detector(root, ip_output.as_deref().ok_or(()), &SystemdVirtDetector)
}

fn collect_from_with_ip_and_detector(
    root: &Path,
    ip_output: Result<&str, ()>,
    detector: &dyn VirtDetector,
) -> Result<ServerResource, CollectError> {
    let hostname = read(root, "etc/hostname").ok_or_else(|| {
        CollectError("Linux host has no usable /etc/hostname; observation cannot be matched".into())
    })?;
    let fqdn = Command::new("hostname")
        .arg("-f")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| normalize_value(&s))
        .filter(|s| s.contains('.'));
    // A syntactically valid `ip` response, including `[]`, is authoritative.
    // Command or parse failures only become authoritative if sysfs can be listed.
    let mut interfaces = ip_output
        .and_then(parse_ip_snapshot)
        .or_else(|_| collect_sysfs_interfaces(root).map_err(|_| ()))
        .ok();
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
    let os = read(root, "etc/os-release")
        .map(|s| parse_os_release(&s))
        .unwrap_or_default();
    let (cpu_count, cpu_model) = read(root, "proc/cpuinfo")
        .map(|s| parse_cpuinfo(&s))
        .unwrap_or((0, None));
    let mut components = vec![
        component(
            "os",
            [
                ("name", json!(os.get("NAME"))),
                ("version", json!(os.get("VERSION_ID"))),
                ("kernel", json!(read(root, "proc/sys/kernel/osrelease"))),
                ("architecture", json!(std::env::consts::ARCH)),
            ],
        ),
        component(
            "cpu",
            [
                ("logical_count", json!(cpu_count)),
                ("model", json!(cpu_model)),
            ],
        ),
    ];
    if let Some(bytes) = read(root, "proc/meminfo").and_then(|s| parse_meminfo(&s)) {
        components.push(component("memory", [("total_bytes", json!(bytes))]));
    }
    components.extend(collect_disks(root));
    components.extend(collect_filesystems(root));
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
pub fn collect() -> Result<ServerResource, CollectError> {
    collect_from(Path::new("/"))
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
        i.mtu = read(root, &format!("{base}/mtu"))
            .and_then(|v| v.parse().ok())
            .or(i.mtu);
        i.speed_mbps = read(root, &format!("{base}/speed"))
            .and_then(|v| v.parse().ok())
            .filter(|v| *v > 0);
        i.kind = if i.name == "lo" {
            "loopback"
        } else if root.join(format!("{base}/device")).exists() {
            "ethernet"
        } else {
            "virtual"
        }
        .into();
    }
}
fn collect_sysfs_interfaces(root: &Path) -> std::io::Result<Vec<Interface>> {
    let entries = fs::read_dir(root.join("sys/class/net"))?;
    Ok(entries
        .flatten()
        .map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let base = format!("sys/class/net/{name}");
            let status = match read(root, &format!("{base}/operstate")).as_deref() {
                Some("up") => "up",
                Some("down") => "down",
                Some("dormant") => "dormant",
                _ => "unknown",
            }
            .into();
            Interface {
                name,
                kind: "unknown".into(),
                status,
                mac_address: read(root, &format!("{base}/address")).and_then(|v| normalize_mac(&v)),
                mtu: None,
                speed_mbps: None,
                addresses: None,
            }
        })
        .collect())
}
fn collect_disks(root: &Path) -> Vec<Component> {
    let Ok(entries) = fs::read_dir(root.join("sys/block")) else {
        return vec![];
    };
    entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let sectors = read(root, &format!("sys/block/{name}/size"))?
                .parse::<u64>()
                .ok()?;
            Some(component(
                "disk",
                [
                    ("name", json!(name)),
                    ("size_bytes", json!(sectors.saturating_mul(512))),
                ],
            ))
        })
        .collect()
}
fn collect_filesystems(root: &Path) -> Vec<Component> {
    read(root, "proc/mounts")
        .into_iter()
        .flat_map(|s| {
            s.lines()
                .filter_map(|l| {
                    let mut p = l.split_whitespace();
                    Some(component(
                        "filesystem",
                        [
                            ("device", json!(p.next()?)),
                            ("mountpoint", json!(p.next()?)),
                            ("filesystem_type", json!(p.next()?)),
                        ],
                    ))
                })
                .collect::<Vec<_>>()
        })
        .collect()
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
    .any(|path| root.join(path).exists());
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
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    struct FakeDetector {
        container: VirtDetection,
        vm: VirtDetection,
    }

    impl VirtDetector for FakeDetector {
        fn container(&self) -> VirtDetection {
            self.container.clone()
        }

        fn vm(&self) -> VirtDetection {
            self.vm.clone()
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
        collect_from_with_ip_and_detector(root, ip_output, &FakeDetector { container, vm })
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
    fn parses_proc_data() {
        assert_eq!(parse_meminfo("MemTotal: 1024 kB\n"), Some(1_048_576));
        assert_eq!(
            parse_cpuinfo("processor : 0\nmodel name : Xeon\nprocessor : 1\n"),
            (2, Some("Xeon".into()))
        );
    }
    #[test]
    fn parses_ip_addresses() {
        let v = parse_ip_json(
            r#"[{"ifname":"eth0","flags":["UP"],"mtu":1500,"address":"AA:BB:CC:DD:EE:FF","addr_info":[{"family":"inet","local":"10.0.0.2","prefixlen":24,"scope":"global"}]}]"#,
        );
        assert_eq!(v[0].mac_address.as_deref(), Some("aa:bb:cc:dd:ee:ff"));
        assert_eq!(v[0].addresses.as_ref().unwrap()[0].address, "10.0.0.2/24");
    }

    #[test]
    fn authoritative_interface_with_empty_addr_info_serializes_addresses() {
        let interfaces = parse_ip_snapshot(r#"[{"ifname":"eth0","addr_info":[]}]"#).unwrap();
        let value = serde_json::to_value(&interfaces[0]).unwrap();

        assert!(interfaces[0].addresses.as_ref().is_some_and(Vec::is_empty));
        assert_eq!(value["addresses"], json!([]));
    }
    #[test]
    fn malformed_ip_degrades() {
        assert!(parse_ip_json("nope").is_empty());
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
    fn authoritative_snapshot_preserves_interface_and_top_level_mac_set() {
        let root = fixture();
        let resource = collect_from_with_ip(
            &root,
            Ok(r#"[{"ifname":"eth1","flags":["UP"],"address":"00:11:22:33:44:55"},{"ifname":"eth0","flags":[],"address":"aa:bb:cc:dd:ee:ff"}]"#),
        ).unwrap();
        let value = serde_json::to_value(resource).unwrap();

        assert_eq!(
            value["identifiers"]["mac_address"],
            json!(["00:11:22:33:44:55", "aa:bb:cc:dd:ee:ff"])
        );
        assert_eq!(value["interfaces"].as_array().unwrap().len(), 2);
        assert_eq!(value["interfaces"][0]["name"], "eth1");
        assert_eq!(value["interfaces"][1]["name"], "eth0");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn malformed_ip_output_falls_back_to_sysfs() {
        let root = fixture();
        let interface = root.join("sys/class/net/eth9");
        fs::create_dir_all(&interface).unwrap();
        fs::write(interface.join("operstate"), "up\n").unwrap();
        fs::write(interface.join("address"), "12:34:56:78:9a:bc\n").unwrap();

        let resource = collect_from_with_ip(&root, Ok("malformed")).unwrap();
        let value = serde_json::to_value(&resource).unwrap();
        assert_eq!(resource.interfaces.as_ref().unwrap()[0].name, "eth9");
        assert!(value["interfaces"][0].get("addresses").is_none());
        assert_eq!(resource.identifiers.mac_address, ["12:34:56:78:9a:bc"]);
        fs::remove_dir_all(root).unwrap();
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
        let resource =
            collect_with_detection(&root, Ok("[]"), VirtDetection::None, VirtDetection::None)
                .unwrap();

        assert_eq!(virtualization(&resource).attributes["container_host"], true);
        assert_eq!(
            virtualization(&resource).attributes["environment"],
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
