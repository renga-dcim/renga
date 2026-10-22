//! Turns `virsh` output into the payload's view of each domain.

use crate::payload::{DomainDisk, DomainInterface, DomainInterfaceType, DomainState, VmDomain};
use roxmltree::{Document, Node};

/// Must match `Renga.Inventory.AgentPayload`.
pub const MAX_DOMAIN_DEVICES: usize = 256;
const MAX_STRING: usize = 255;
/// Renga rejects a whole report over a larger count, so a larger value is left out instead.
const MAX_SERVER_INTEGER: u64 = 2_147_483_647;
/// Real domain definitions nest about ten deep. The parser recurses once per level, so a remote
/// daemon's deeply nested answer could overflow the stack and abort the whole agent.
const MAX_XML_DEPTH: usize = 64;

/// One domain as libvirt defines it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Domain {
    /// The SMBIOS system UUID the guest sees, canonical: `<hwuuid>` when set, else the domain
    /// UUID. libvirt refuses a `<sysinfo>` UUID that differs, so sysinfo never changes it.
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
    if nesting_depth(xml) > MAX_XML_DEPTH {
        return Err(ParseError(format!(
            "domain XML nests deeper than {MAX_XML_DEPTH} elements"
        )));
    }
    let document =
        Document::parse(xml).map_err(|error| ParseError(format!("invalid domain XML: {error}")))?;
    let root = document.root_element();
    if !root.has_tag_name("domain") {
        return Err(ParseError("not a domain definition".into()));
    }
    let name = child_text(root, "name")
        .and_then(bounded)
        .ok_or_else(|| ParseError("domain has no usable name".into()))?;
    // Only the domain's own unnamespaced elements count; `<metadata>` can hold anything.
    let dmi_uuid = child_text(root, "hwuuid")
        .or_else(|| child_text(root, "uuid"))
        .and_then(canonical_uuid)
        .ok_or_else(|| ParseError(format!("domain {name} has no usable UUID")))?;
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
                .filter(|vcpus: &u32| (1..=MAX_SERVER_INTEGER).contains(&u64::from(*vcpus))),
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

/// An upper bound on element nesting, found without recursion. It skips comments, CDATA,
/// processing instructions, and declarations, and reads each tag up to its closing `>` outside
/// quoted attribute values. Any other `<` counts as a start tag, so text the parser would reject
/// can only raise the count, never hide a level.
fn nesting_depth(xml: &str) -> usize {
    let bytes = xml.as_bytes();
    let (mut index, mut depth, mut deepest) = (0usize, 0usize, 0usize);
    let skip_past = |from: usize, end: &[u8]| {
        bytes[from..]
            .windows(end.len())
            .position(|window| window == end)
            .map_or(bytes.len(), |at| from + at + end.len())
    };
    while index < bytes.len() {
        if bytes[index] != b'<' {
            index += 1;
            continue;
        }
        let rest = &bytes[index..];
        if rest.starts_with(b"<!--") {
            index = skip_past(index + 4, b"-->");
        } else if rest.starts_with(b"<![CDATA[") {
            index = skip_past(index + 9, b"]]>");
        } else if rest.starts_with(b"<?") {
            index = skip_past(index + 2, b"?>");
        } else if rest.starts_with(b"<!") {
            index = skip_past(index + 2, b">");
        } else if rest.starts_with(b"</") {
            depth = depth.saturating_sub(1);
            index = skip_past(index + 2, b">");
        } else {
            // A start tag: find its `>` outside quotes, and whether `/` precedes it.
            let mut cursor = index + 1;
            let mut quote = None;
            let mut self_closing = false;
            while cursor < bytes.len() {
                let byte = bytes[cursor];
                match quote {
                    Some(open) if byte == open => quote = None,
                    Some(_) => {}
                    None if byte == b'"' || byte == b'\'' => quote = Some(byte),
                    None if byte == b'>' => {
                        self_closing = bytes[cursor - 1] == b'/';
                        break;
                    }
                    None => {}
                }
                cursor += 1;
            }
            depth += 1;
            deepest = deepest.max(depth);
            if self_closing {
                depth -= 1;
            }
            index = cursor + 1;
        }
    }
    deepest
}

/// The UUID in Renga's canonical lowercase, hyphenated form; the server only trims and
/// lowercases identifiers, so a malformed one would match nothing or the wrong thing.
pub fn canonical_uuid(text: &str) -> Option<String> {
    uuid::Uuid::parse_str(text.trim())
        .ok()
        .map(|uuid| uuid.hyphenated().to_string())
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
    Some(amount.checked_mul(bytes_per_unit)? >> 20)
        .filter(|mib| (1..=MAX_SERVER_INTEGER).contains(mib))
}

fn child<'a, 'input>(node: Node<'a, 'input>, name: &str) -> Option<Node<'a, 'input>> {
    node.children()
        .find(|child| child.has_tag_name(name) && child.tag_name().namespace().is_none())
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
  <hwuuid>4C4C4544-004D-3610-804B-C4C04F4E4A31</hwuuid>
  <sysinfo type='smbios'>
    <system>
      <entry name='manufacturer'>Renga</entry>
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
    fn refuses_xml_nested_deeper_than_a_domain() {
        let nested = format!(
            "<domain><name>a</name><uuid>6695eb01-f6a4-8304-79aa-97f2502e193f</uuid>\
             <metadata>{}{}</metadata></domain>",
            "<x>".repeat(50_000),
            "</x>".repeat(50_000)
        );
        let error = parse(&nested, DomainState::Running, None).unwrap_err();
        assert!(error.0.contains("nests deeper"), "{}", error.0);

        assert!(nesting_depth(WEB_01) < MAX_XML_DEPTH);
        assert_eq!(nesting_depth("<a><b/><c><d/></c></a>"), 3);

        // Lexical tricks that must not hide a level from the bound.
        let deep = |open: &str, close: &str| {
            format!(
                "<domain><name>a</name><uuid>6695eb01-f6a4-8304-79aa-97f2502e193f</uuid>\\
                 <metadata>{}{}</metadata></domain>",
                open.repeat(20_000),
                close.repeat(20_000)
            )
        };
        for (open, close) in [
            ("<\u{e9}>", "</\u{e9}>"),
            ("<x a='/>'>", "</x>"),
            ("<x><!-- </x> -->", "</x>"),
            ("<x><![CDATA[</x>]]>", "</x>"),
        ] {
            let error = parse(&deep(open, close), DomainState::Running, None).unwrap_err();
            assert!(error.0.contains("nests deeper"), "{open}: {}", error.0);
        }

        // The same constructs in a shallow document still parse.
        let shallow = "<domain><name>a</name><uuid>6695eb01-f6a4-8304-79aa-97f2502e193f</uuid>\\
                       <metadata><\u{e9} a='/>'><!-- </x></x> --><![CDATA[</x>]]></\u{e9}>\\
                       </metadata></domain>";
        assert!(parse(shallow, DomainState::Running, None).is_ok());
    }

    #[test]
    fn leaves_out_allocations_renga_cannot_store() {
        let xml = |vcpu: &str, memory: &str| {
            format!(
                "<domain><name>a</name><uuid>6695eb01-f6a4-8304-79aa-97f2502e193f</uuid>\\
                 <vcpu>{vcpu}</vcpu><memory unit='MiB'>{memory}</memory></domain>"
            )
        };
        let fits = parse(&xml("2147483647", "2147483647"), DomainState::Running, None).unwrap();
        assert_eq!(fits.domain.vcpus, Some(2_147_483_647));
        assert_eq!(fits.domain.memory_mib, Some(2_147_483_647));
        let over = parse(&xml("2147483648", "2147483648"), DomainState::Running, None).unwrap();
        assert_eq!(over.domain.vcpus, None);
        assert_eq!(over.domain.memory_mib, None);
    }

    #[test]
    fn ignores_uuids_in_namespaced_metadata() {
        let xml = "<domain><name>a</name><uuid>6695EB01-F6A4-8304-79AA-97F2502E193F</uuid>\
                   <metadata><x:hwuuid xmlns:x='urn:example'>not-a-uuid</x:hwuuid>\
                   <x:sysinfo xmlns:x='urn:example' type='smbios'><x:system>\
                   <x:entry name='uuid'>00000000-0000-0000-0000-000000000001</x:entry>\
                   </x:system></x:sysinfo></metadata></domain>";
        let parsed = parse(xml, DomainState::Running, None).unwrap();
        assert_eq!(parsed.dmi_uuid, "6695eb01-f6a4-8304-79aa-97f2502e193f");
    }

    #[test]
    fn rejects_definitions_it_cannot_identify() {
        assert!(parse(
            "<domain><name>a</name><uuid>not-a-uuid</uuid></domain>",
            DomainState::Running,
            None
        )
        .is_err());
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
        let xml = format!("<domain><name>a</name><uuid>6695eb01-f6a4-8304-79aa-97f2502e193f</uuid><devices>{nics}</devices></domain>");
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
