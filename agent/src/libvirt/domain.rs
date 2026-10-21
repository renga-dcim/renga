//! Turns `virsh` output into the payload's view of each domain.

use crate::payload::{DomainDisk, DomainInterface, DomainInterfaceType, DomainState, VmDomain};
use roxmltree::{Document, Node};

/// Must match `Renga.Inventory.AgentPayload`.
pub const MAX_DOMAIN_DEVICES: usize = 256;
const MAX_STRING: usize = 255;

/// One domain as libvirt defines it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Domain {
    /// The SMBIOS system UUID the guest sees: the domain UUID unless `<sysinfo>` overrides it.
    pub dmi_uuid: String,
    pub domain: VmDomain,
    /// Devices beyond the payload limit, left out of `domain`.
    pub dropped_devices: usize,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ParseError(pub String);

/// UUIDs from `virsh list --all --uuid`, one per line.
pub fn uuids(stdout: &str) -> Vec<String> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
}

/// State and persistence from `virsh dominfo` in the C locale.
pub fn info(stdout: &str) -> (DomainState, Option<bool>) {
    let field = |name: &str| {
        stdout.lines().find_map(|line| {
            let (key, value) = line.split_once(':')?;
            (key.trim() == name).then(|| value.trim())
        })
    };
    let state = match field("State") {
        Some("running") => DomainState::Running,
        Some("idle") => DomainState::Idle,
        Some("paused") => DomainState::Paused,
        Some("in shutdown") => DomainState::ShuttingDown,
        Some("shut off") => DomainState::Shutoff,
        Some("crashed") => DomainState::Crashed,
        Some("pmsuspended") => DomainState::Pmsuspended,
        _ => DomainState::Unknown,
    };
    let persistent = match field("Persistent") {
        Some("yes") => Some(true),
        Some("no") => Some(false),
        _ => None,
    };
    (state, persistent)
}

/// Parses `virsh dumpxml`. State and persistence come from [`info`].
pub fn parse(
    xml: &str,
    state: DomainState,
    persistent: Option<bool>,
) -> Result<Domain, ParseError> {
    let document =
        Document::parse(xml).map_err(|error| ParseError(format!("invalid domain XML: {error}")))?;
    let root = document.root_element();
    if !root.has_tag_name("domain") {
        return Err(ParseError("not a domain definition".into()));
    }
    let name = child_text(root, "name")
        .and_then(bounded)
        .ok_or_else(|| ParseError("domain has no usable name".into()))?;
    let uuid = child_text(root, "uuid")
        .and_then(bounded)
        .ok_or_else(|| ParseError(format!("domain {name} has no UUID")))?;
    let dmi_uuid = smbios_uuid(root).unwrap_or(uuid);
    let devices = root.children().find(|node| node.has_tag_name("devices"));
    let disks: Vec<_> = devices
        .into_iter()
        .flat_map(|devices| devices.children().filter(|node| node.has_tag_name("disk")))
        .filter_map(disk)
        .collect();
    let interfaces: Vec<_> = devices
        .into_iter()
        .flat_map(|devices| {
            devices
                .children()
                .filter(|node| node.has_tag_name("interface"))
        })
        .filter_map(interface)
        .collect();
    let dropped_devices = disks.len().saturating_sub(MAX_DOMAIN_DEVICES)
        + interfaces.len().saturating_sub(MAX_DOMAIN_DEVICES);
    Ok(Domain {
        dmi_uuid,
        domain: VmDomain {
            name,
            state,
            persistent,
            vcpus: child_text(root, "vcpu")
                .and_then(|text| text.parse().ok())
                .filter(|vcpus| *vcpus > 0),
            memory_mib: root
                .children()
                .find(|node| node.has_tag_name("memory"))
                .and_then(memory_mib),
            disks: disks.into_iter().take(MAX_DOMAIN_DEVICES).collect(),
            interfaces: interfaces.into_iter().take(MAX_DOMAIN_DEVICES).collect(),
        },
        dropped_devices,
    })
}

fn smbios_uuid(root: Node<'_, '_>) -> Option<String> {
    root.descendants()
        .filter(|node| node.has_tag_name("sysinfo") && node.attribute("type") == Some("smbios"))
        .flat_map(|sysinfo| {
            sysinfo
                .children()
                .filter(|node| node.has_tag_name("system"))
        })
        .flat_map(|system| system.children().filter(|node| node.has_tag_name("entry")))
        .find(|entry| entry.attribute("name") == Some("uuid"))
        .and_then(|entry| entry.text())
        .and_then(bounded)
}

fn disk(node: Node<'_, '_>) -> Option<DomainDisk> {
    let target = child(node, "target")?;
    let source = child(node, "source").and_then(|source| {
        ["file", "dev", "dir", "name"]
            .iter()
            .find_map(|key| source.attribute(*key).map(str::to_owned))
            .or_else(|| {
                Some(format!(
                    "{}/{}",
                    source.attribute("pool")?,
                    source.attribute("volume")?
                ))
            })
    });
    Some(DomainDisk {
        target: target.attribute("dev").and_then(bounded)?,
        device: node.attribute("device").and_then(bounded),
        bus: target.attribute("bus").and_then(bounded),
        format: child(node, "driver")
            .and_then(|driver| driver.attribute("type"))
            .and_then(bounded),
        source: source.as_deref().and_then(bounded),
    })
}

fn interface(node: Node<'_, '_>) -> Option<DomainInterface> {
    let source = child(node, "source").and_then(|source| {
        ["bridge", "network", "dev"]
            .iter()
            .find_map(|key| source.attribute(*key))
            .and_then(bounded)
    });
    Some(DomainInterface {
        mac_address: child(node, "mac")?.attribute("address").and_then(bounded)?,
        kind: match node.attribute("type") {
            Some("bridge") => DomainInterfaceType::Bridge,
            Some("network") => DomainInterfaceType::Network,
            Some("direct") => DomainInterfaceType::Direct,
            Some("user") => DomainInterfaceType::User,
            _ => DomainInterfaceType::Other,
        },
        source,
        model: child(node, "model")
            .and_then(|model| model.attribute("type"))
            .and_then(bounded),
        target: child(node, "target")
            .and_then(|target| target.attribute("dev"))
            .and_then(bounded),
    })
}

fn memory_mib(node: Node<'_, '_>) -> Option<u64> {
    let amount: u64 = node.text()?.trim().parse().ok()?;
    let bytes_per_unit: u64 = match node.attribute("unit").unwrap_or("KiB") {
        "b" | "bytes" => 1,
        "KB" => 1_000,
        "k" | "KiB" => 1 << 10,
        "MB" => 1_000_000,
        "M" | "MiB" => 1 << 20,
        "GB" => 1_000_000_000,
        "G" | "GiB" => 1 << 30,
        "TB" => 1_000_000_000_000,
        "T" | "TiB" => 1 << 40,
        _ => return None,
    };
    Some(amount.checked_mul(bytes_per_unit)? >> 20).filter(|mib| *mib > 0)
}

fn child<'a, 'input>(node: Node<'a, 'input>, name: &str) -> Option<Node<'a, 'input>> {
    node.children().find(|child| child.has_tag_name(name))
}

fn child_text<'a>(node: Node<'a, '_>, name: &str) -> Option<&'a str> {
    child(node, name)?.text()
}

/// A trimmed, non-empty value within the payload's string limit; longer values are left out.
fn bounded(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty() && value.chars().count() <= MAX_STRING).then(|| value.to_owned())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) const WEB_01: &str = r#"<domain type='kvm'>
  <name>web-01</name>
  <uuid>6695eb01-f6a4-8304-79aa-97f2502e193f</uuid>
  <memory unit='GiB'>4</memory>
  <vcpu placement='static'>2</vcpu>
  <sysinfo type='smbios'>
    <system>
      <entry name='manufacturer'>Renga</entry>
      <entry name='uuid'>4c4c4544-004d-3610-804b-c4c04f4e4a31</entry>
    </system>
  </sysinfo>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/web-01.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='volume' device='disk'>
      <source pool='default' volume='web-01-data'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <target dev='sda' bus='sata'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:12:34:56'/>
      <source bridge='br0'/>
      <target dev='vnet0'/>
      <model type='virtio'/>
    </interface>
    <interface type='vhostuser'>
      <mac address='52:54:00:12:34:57'/>
    </interface>
    <interface type='network'>
      <source network='default'/>
    </interface>
  </devices>
</domain>"#;

    #[test]
    fn reads_allocation_disks_and_nics() {
        let parsed = parse(WEB_01, DomainState::Running, Some(true)).unwrap();
        assert_eq!(parsed.dmi_uuid, "4c4c4544-004d-3610-804b-c4c04f4e4a31");
        let domain = parsed.domain;
        assert_eq!(domain.name, "web-01");
        assert_eq!(domain.vcpus, Some(2));
        assert_eq!(domain.memory_mib, Some(4_096));
        assert_eq!(
            domain.disks[0],
            DomainDisk {
                target: "vda".into(),
                device: Some("disk".into()),
                bus: Some("virtio".into()),
                format: Some("qcow2".into()),
                source: Some("/var/lib/libvirt/images/web-01.qcow2".into()),
            }
        );
        assert_eq!(
            domain.disks[1].source.as_deref(),
            Some("default/web-01-data")
        );
        assert_eq!(domain.disks[2].source, None);
        assert_eq!(
            domain.interfaces,
            vec![
                DomainInterface {
                    mac_address: "52:54:00:12:34:56".into(),
                    kind: DomainInterfaceType::Bridge,
                    source: Some("br0".into()),
                    model: Some("virtio".into()),
                    target: Some("vnet0".into()),
                },
                DomainInterface {
                    mac_address: "52:54:00:12:34:57".into(),
                    kind: DomainInterfaceType::Other,
                    source: None,
                    model: None,
                    target: None,
                },
            ],
            "a NIC without a MAC address is left out"
        );
    }

    #[test]
    fn uses_the_domain_uuid_without_an_smbios_override() {
        let xml = "<domain><name>a</name><uuid>6695eb01-f6a4-8304-79aa-97f2502e193f</uuid>\
                   <memory>2097152</memory></domain>";
        let parsed = parse(xml, DomainState::Shutoff, Some(true)).unwrap();
        assert_eq!(parsed.dmi_uuid, "6695eb01-f6a4-8304-79aa-97f2502e193f");
        assert_eq!(parsed.domain.memory_mib, Some(2_048));
        assert!(parsed.domain.disks.is_empty());
    }

    #[test]
    fn rejects_definitions_it_cannot_identify() {
        assert!(parse(
            "<domain><name>a</name></domain>",
            DomainState::Running,
            None
        )
        .is_err());
        assert!(parse("<network/>", DomainState::Running, None).is_err());
        assert!(parse("<domain", DomainState::Running, None).is_err());
    }

    #[test]
    fn caps_devices_at_the_payload_limit() {
        let nics: String = (0..300)
            .map(|index| {
                format!(
                    "<interface type='user'><mac address='52:54:00:00:{:02x}:{:02x}'/></interface>",
                    index / 256,
                    index % 256
                )
            })
            .collect();
        let xml = format!("<domain><name>a</name><uuid>u</uuid><devices>{nics}</devices></domain>");
        let parsed = parse(&xml, DomainState::Running, None).unwrap();
        assert_eq!(parsed.domain.interfaces.len(), MAX_DOMAIN_DEVICES);
        assert_eq!(parsed.dropped_devices, 300 - MAX_DOMAIN_DEVICES);
    }

    #[test]
    fn reads_state_and_persistence_from_dominfo() {
        let stdout = "Id:             1\nName:           test\nState:          in shutdown\nPersistent:     no\n";
        assert_eq!(info(stdout), (DomainState::ShuttingDown, Some(false)));
        assert_eq!(info("State: blocked\n"), (DomainState::Unknown, None));
        assert_eq!(uuids("a\n\n b \n"), vec!["a", "b"]);
    }
}
