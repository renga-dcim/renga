//! Turns a switch's OpenConfig state into the switch Renga reconciles (RFD 11, "Switch
//! collection"), the same resource the SNMP poller reports.
//!
//! Everything here is pure, so each model's quirks are tested from recorded trees without a
//! device: identity from `openconfig-system` and `openconfig-platform`, interfaces from
//! `openconfig-interfaces`, VLAN membership from `openconfig-vlan`, and neighbors from
//! `openconfig-lldp`. Values read as identities (`openconfig-if-ethernet:SPEED_10GB`) are
//! compared without their module prefix, since targets differ on sending one.

use crate::{
    collectors::normalize_value,
    payload::{
        CollectorIdentifiers, CollectorResource, CollectorResourceKind, HostAttributes, Interface,
        Neighbor, TaggingMode, VlanMembership,
    },
    switch_report::{Sections, MAX_STRING_CHARS},
};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    net::IpAddr,
};

pub const SYSTEM: &str = "system/state";
pub const COMPONENTS: &str = "components/component/state";
pub const INTERFACES: &str = "interfaces/interface";
pub const VLANS: &str = "network-instances/network-instance/vlans/vlan/state";
pub const LLDP: &str = "lldp/interfaces/interface";

/// What the poller asks every target for, one Get each, so a target that implements only some
/// of these models still answers the rest. Only `COMPONENTS` is required: it holds the serial.
pub const PATHS: &[&str] = &[SYSTEM, COMPONENTS, INTERFACES, VLANS, LLDP];

const MAX_INT32: u64 = 2_147_483_647;
/// A ceiling on what one switch may claim, far beyond real hardware, so a target answering
/// with nonsense cannot exhaust the agent's memory.
const MAX_VLAN_MEMBERSHIPS: usize = 100_000;

/// What a target answered: the tree its Get answers folded into, and which `PATHS` it answered.
#[derive(Debug, Default)]
pub struct Answers {
    pub tree: Value,
    pub answered: BTreeSet<&'static str>,
}

/// Why a reachable switch cannot be reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapError(pub String);

/// The switch behind `answers`, as polled from `target`. Neighbors expire after `ttl_seconds`,
/// like the SNMP poller's, so both modules age evidence the same way.
pub fn switch(
    target: &str,
    answers: &Answers,
    ttl_seconds: u32,
) -> Result<(CollectorResource, Sections), MapError> {
    let tree = &answers.tree;
    let chassis = chassis(tree).ok_or_else(|| {
        MapError(
            "no chassis serial number in openconfig-platform; the switch cannot be identified"
                .into(),
        )
    })?;
    let interfaces_answered = answers.answered.contains(INTERFACES);
    let mut interfaces = if interfaces_answered {
        interfaces(tree)
    } else {
        BTreeMap::new()
    };
    let interface_vlans = interfaces_answered && attach_vlans(answers, &mut interfaces)?;
    let interface_neighbors = interfaces_answered && answers.answered.contains(LLDP);
    if interface_neighbors {
        attach_neighbors(tree, &mut interfaces, ttl_seconds);
    }
    let hostname = tree
        .get("system")
        .and_then(|system| state_or_config(system, "hostname"))
        .and_then(text);
    let resource = CollectorResource {
        kind: CollectorResourceKind::Switch,
        target: Some(target.to_owned()),
        identifiers: CollectorIdentifiers {
            hostname: hostname.clone(),
            serial_number: Some(chassis.serial),
            dmi_uuid: None,
            // As with SNMP, the serial identifies the switch; a chassis MAC is not one of its
            // interfaces' MACs, which is all Renga accepts as MAC identifiers.
            mac_address: Vec::new(),
        },
        attributes: Some(HostAttributes {
            hostname,
            vendor: chassis.vendor,
            model: chassis.model,
            ..Default::default()
        }),
        interfaces: interfaces_answered.then(|| {
            interfaces
                .into_values()
                .map(|entry| entry.interface)
                .collect()
        }),
        domain: None,
    };
    Ok((
        resource,
        Sections {
            interface_neighbors,
            interface_vlans,
        },
    ))
}

struct Chassis {
    serial: String,
    vendor: Option<String>,
    model: Option<String>,
}

/// The chassis component with a serial number, preferring one without a parent: stacks and
/// modular systems list member chassis under the system's own.
fn chassis(tree: &Value) -> Option<Chassis> {
    entries(tree.get("components"), "component")
        .filter(|component| leaf(component, "type").and_then(identity) == Some("CHASSIS"))
        .filter_map(|component| {
            let serial = leaf(component, "serial-no").and_then(text)?;
            let chassis = Chassis {
                serial,
                vendor: leaf(component, "mfg-name").and_then(text),
                model: leaf(component, "part-no").and_then(text),
            };
            Some((leaf(component, "parent").is_some(), chassis))
        })
        .min_by_key(|(has_parent, _)| *has_parent)
        .map(|(_, chassis)| chassis)
}

struct Entry<'a> {
    interface: Interface,
    switched_vlan: Option<&'a Value>,
}

/// Top-level interfaces by name. Subinterfaces are left out: they are addressing on a port, not
/// ports.
fn interfaces(tree: &Value) -> BTreeMap<String, Entry<'_>> {
    let mut interfaces = BTreeMap::new();
    for entry in entries(tree.get("interfaces"), "interface") {
        let Some(name) = entry
            .get("name")
            .or_else(|| leaf(entry, "name"))
            .and_then(text)
        else {
            continue;
        };
        // Names identify interfaces in Renga, so a duplicate would merge two ports.
        if interfaces.contains_key(&name) {
            continue;
        }
        let ethernet = entry.get("ethernet");
        let aggregation = entry.get("aggregation");
        let speed_mbps = ethernet
            .and_then(|ethernet| leaf(ethernet, "port-speed"))
            .and_then(identity)
            .and_then(speed_mbps)
            .or_else(|| {
                aggregation
                    .and_then(|aggregation| leaf(aggregation, "lag-speed"))
                    .and_then(number)
            })
            .filter(|speed| (1..=MAX_INT32).contains(speed))
            .map(|speed| speed as u32);
        let interface = Interface {
            name: name.clone(),
            kind: interface_kind(leaf(entry, "type").and_then(identity)).into(),
            status: oper_status(leaf(entry, "oper-status").and_then(identity)).into(),
            mac_address: ethernet.and_then(|ethernet| {
                leaf(ethernet, "mac-address")
                    .and_then(mac)
                    .or_else(|| leaf(ethernet, "hw-mac-address").and_then(mac))
            }),
            mtu: leaf(entry, "mtu")
                .and_then(number)
                .filter(|mtu| (1..=MAX_INT32).contains(mtu))
                .map(|mtu| mtu as u32),
            speed_mbps,
            ..Default::default()
        };
        let switched_vlan = [ethernet, aggregation]
            .into_iter()
            .flatten()
            .find_map(|container| container.get("switched-vlan"));
        interfaces.insert(
            name,
            Entry {
                interface,
                switched_vlan,
            },
        );
    }
    interfaces
}

/// iana-if-type identities to the interface kinds Renga knows.
fn interface_kind(if_type: Option<&str>) -> &'static str {
    match if_type {
        Some("ethernetCsmacd" | "iso88023Csmacd" | "fastEther" | "gigabitEthernet") => "ethernet",
        Some("softwareLoopback") => "loopback",
        Some("ieee8023adLag") => "bond",
        Some("bridge") => "bridge",
        Some("l2vlan" | "l3ipvlan") => "vlan",
        Some("propVirtual") => "virtual",
        _ => "unknown",
    }
}

fn oper_status(status: Option<&str>) -> &'static str {
    match status {
        Some("UP") => "up",
        Some("DOWN" | "LOWER_LAYER_DOWN") => "down",
        Some("DORMANT") => "dormant",
        Some("NOT_PRESENT") => "not_present",
        _ => "unknown",
    }
}

/// `SPEED_10GB` and `SPEED_2500MB` to megabits per second.
fn speed_mbps(speed: &str) -> Option<u64> {
    let speed = speed.strip_prefix("SPEED_")?;
    if let Some(gigabits) = speed.strip_suffix("GB") {
        gigabits.parse::<u64>().ok()?.checked_mul(1_000)
    } else {
        speed.strip_suffix("MB")?.parse().ok()
    }
}

/// Fills each interface's VLANs from `openconfig-vlan` and says whether every switched port's
/// membership was known, so the report may claim the section complete.
///
/// A trunk's `trunk-vlans` names what the port allows, often as ranges like `1..4094`; the
/// port carries only the allowed VLANs the switch has, which is what SNMP reports too. Allowed
/// VLANs are therefore read against the switch's VLAN table; without that table, a port that
/// allows a range is left undescribed.
fn attach_vlans(
    answers: &Answers,
    interfaces: &mut BTreeMap<String, Entry<'_>>,
) -> Result<bool, MapError> {
    if interfaces
        .values()
        .all(|entry| entry.switched_vlan.is_none())
    {
        return Ok(false);
    }
    let existing: Option<BTreeSet<u16>> = answers.answered.contains(VLANS).then(|| {
        entries(answers.tree.get("network-instances"), "network-instance")
            .flat_map(|instance| entries(instance.get("vlans"), "vlan"))
            .filter_map(|vlan| vlan.get("vlan-id").or_else(|| leaf(vlan, "vlan-id")))
            .filter_map(vid)
            .collect()
    });
    let mut complete = true;
    let mut total = 0;
    for entry in interfaces.values_mut() {
        let Some(switched_vlan) = entry.switched_vlan else {
            entry.interface.vlans = Some(Vec::new());
            continue;
        };
        let Some((mode, vlans)) = membership(switched_vlan, existing.as_ref()) else {
            complete = false;
            continue;
        };
        total += vlans.len();
        if total > MAX_VLAN_MEMBERSHIPS {
            return Err(MapError(format!(
                "the switch reports more than {MAX_VLAN_MEMBERSHIPS} VLAN memberships"
            )));
        }
        entry.interface.vlan_mode = (!vlans.is_empty()).then(|| mode.into());
        entry.interface.vlans = Some(vlans);
    }
    Ok(complete)
}

/// A switched port's mode and memberships, or `None` when the target did not say enough to
/// know them.
fn membership(
    switched_vlan: &Value,
    existing: Option<&BTreeSet<u16>>,
) -> Option<(&'static str, Vec<VlanMembership>)> {
    let read = |name| state_or_config(switched_vlan, name);
    let mode = read("interface-mode").and_then(identity);
    let trunk = read("trunk-vlans");
    if mode == Some("ACCESS") || (mode.is_none() && trunk.is_none()) {
        let vid = read("access-vlan").and_then(vid)?;
        return Some((
            "access",
            vec![VlanMembership {
                vid,
                tagging_mode: TaggingMode::Untagged,
            }],
        ));
    }
    if mode.is_some_and(|mode| mode != "TRUNK") {
        return None;
    }
    let items: Vec<&Value> = match trunk? {
        Value::Array(items) => items.iter().collect(),
        item => vec![item],
    };
    let mut vids = BTreeSet::new();
    for item in items {
        match (vlan_range(item)?, existing) {
            ((first, last), Some(existing)) => vids.extend(existing.range(first..=last)),
            ((first, last), None) if first == last => {
                vids.insert(first);
            }
            (_, None) => return None,
        }
    }
    let native = read("native-vlan").and_then(vid);
    let vlans = vids
        .into_iter()
        .map(|vid| VlanMembership {
            vid,
            tagging_mode: if Some(vid) == native {
                TaggingMode::Untagged
            } else {
                TaggingMode::Tagged
            },
        })
        .collect();
    Some(("trunk", vlans))
}

/// A `trunk-vlans` entry: a VID, or a `first..last` range.
fn vlan_range(item: &Value) -> Option<(u16, u16)> {
    if let Value::String(range) = item {
        if let Some((first, last)) = range.split_once("..") {
            let first = vid(&Value::String(first.trim().into()))?;
            let last = vid(&Value::String(last.trim().into()))?;
            return (first <= last).then_some((first, last));
        }
    }
    let vid = vid(item)?;
    Some((vid, vid))
}

fn vid(value: &Value) -> Option<u16> {
    number(value)
        .and_then(|vid| u16::try_from(vid).ok())
        .filter(|vid| (1..=4094).contains(vid))
}

fn attach_neighbors(tree: &Value, interfaces: &mut BTreeMap<String, Entry<'_>>, ttl_seconds: u32) {
    for entry in interfaces.values_mut() {
        entry.interface.neighbors = Some(Vec::new());
    }
    let lldp_interfaces = tree.get("lldp").and_then(|lldp| lldp.get("interfaces"));
    for lldp_interface in entries(lldp_interfaces, "interface") {
        let Some(entry) = lldp_interface
            .get("name")
            .and_then(text)
            .and_then(|name| interfaces.get_mut(&name))
        else {
            continue;
        };
        for remote in entries(lldp_interface.get("neighbors"), "neighbor") {
            let read = |name| leaf(remote, name);
            let (Some(remote_chassis_id), Some(remote_port_id)) = (
                read("chassis-id").and_then(|id| {
                    chassis_id_value(read("chassis-id-type").and_then(identity), id)
                }),
                read("port-id")
                    .and_then(|id| port_id_value(read("port-id-type").and_then(identity), id)),
            ) else {
                continue;
            };
            let neighbor = Neighbor {
                protocol: "lldp",
                remote_chassis_id: remote_chassis_id.0,
                remote_chassis_id_kind: remote_chassis_id.1,
                remote_port_id: remote_port_id.0,
                remote_port_id_kind: remote_port_id.1,
                remote_system_name: read("system-name").and_then(text),
                remote_port_description: read("port-description").and_then(text),
                ttl_seconds,
            };
            let neighbors = entry.interface.neighbors.get_or_insert_with(Vec::new);
            // Each remote endpoint may appear once per interface.
            if !neighbors.iter().any(|existing| {
                existing.remote_chassis_id == neighbor.remote_chassis_id
                    && existing.remote_port_id == neighbor.remote_port_id
            }) {
                neighbors.push(neighbor);
            }
        }
    }
}

/// The ID and its kind, named as the SNMP poller names LLDP-MIB's subtypes so a neighbor reads
/// the same whichever module saw it.
fn chassis_id_value(kind: Option<&str>, value: &Value) -> Option<(String, &'static str)> {
    match kind {
        Some("MAC_ADDRESS") => Some((mac(value)?, "mac_address")),
        Some("NETWORK_ADDRESS") => Some((network_address(value)?, "network_address")),
        Some("INTERFACE_NAME") => Some((text(value)?, "name")),
        _ => Some((text(value)?, "local")),
    }
}

fn port_id_value(kind: Option<&str>, value: &Value) -> Option<(String, &'static str)> {
    match kind {
        Some("MAC_ADDRESS") => Some((mac(value)?, "mac_address")),
        Some("INTERFACE_ALIAS" | "INTERFACE_NAME") => Some((text(value)?, "name")),
        _ => Some((text(value)?, "local")),
    }
}

fn network_address(value: &Value) -> Option<String> {
    let address: IpAddr = value.as_str()?.trim().parse().ok()?;
    Some(address.to_string())
}

/// The entries of the list `name` under `node`. A target answering for a single entry may send
/// it as a bare object.
fn entries<'a>(node: Option<&'a Value>, name: &str) -> impl Iterator<Item = &'a Value> {
    let entries: &[Value] = match node.and_then(|node| node.get(name)) {
        Some(Value::Array(entries)) => entries,
        Some(entry @ Value::Object(_)) => std::slice::from_ref(entry),
        _ => &[],
    };
    entries.iter()
}

/// A leaf of `node`'s operational `state` container.
fn leaf<'a>(node: &'a Value, name: &str) -> Option<&'a Value> {
    node.get("state")?.get(name)
}

/// A leaf from `state`, or else from `config` for targets that report only what is configured.
fn state_or_config<'a>(node: &'a Value, name: &str) -> Option<&'a Value> {
    leaf(node, name).or_else(|| node.get("config")?.get(name))
}

/// An identity or enumeration value without its module prefix.
fn identity(value: &Value) -> Option<&str> {
    let value = value.as_str()?;
    Some(value.rsplit_once(':').map_or(value, |(_, name)| name))
}

/// A number, which JSON_IETF sends as a string when it is 64 bits wide.
fn number(value: &Value) -> Option<u64> {
    match value {
        Value::Number(number) => number.as_u64(),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

/// Renga rejects a whole report over one longer string, so a longer value is left out rather
/// than cut short, which could make two different names or IDs equal.
fn text(value: &Value) -> Option<String> {
    let text = match value {
        Value::String(text) => text.trim_matches(|c: char| c.is_whitespace() || c == '\0'),
        Value::Number(number) => return Some(number.to_string()),
        _ => return None,
    };
    normalize_value(text).filter(|text| text.chars().count() <= MAX_STRING_CHARS)
}

/// A MAC written with `:`, `-`, or `.` separators (or none), as lowercase colon-separated
/// octets, the way the SNMP poller writes them.
fn mac(value: &Value) -> Option<String> {
    let digits: String = value
        .as_str()?
        .chars()
        .filter(|c| !matches!(c, ':' | '-' | '.'))
        .collect();
    if digits.len() != 12 || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let digits = digits.to_ascii_lowercase();
    if digits.chars().all(|c| c == '0') {
        return None;
    }
    Some(
        digits
            .as_bytes()
            .chunks(2)
            .map(|pair| std::str::from_utf8(pair).expect("ASCII hex digits"))
            .collect::<Vec<_>>()
            .join(":"),
    )
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::gnmi::{
        proto::{typed_value::Value as Typed, Notification},
        tree::{
            self,
            tests::{json_ietf, path, update},
        },
    };
    use serde_json::json;

    /// A recorded leaf switch's answer to each of `PATHS`, split the ways real targets split
    /// them: whole subtrees, one update per list entry, and single leaves.
    pub(crate) fn recorded() -> Vec<(&'static str, Notification)> {
        let notifications = [
            Notification {
                update: vec![update(
                    "system/state",
                    json_ietf(
                        json!({"openconfig-system:hostname": "leaf-02", "domain-name": "dc1.example"}),
                    ),
                )],
                ..Default::default()
            },
            Notification {
                prefix: Some(path("components")),
                update: vec![
                    update(
                        "component[name=Chassis]/state",
                        json_ietf(json!({
                            "type": "openconfig-platform-types:CHASSIS",
                            "serial-no": "JPE12345678",
                            "mfg-name": "Example Networks",
                            "part-no": "EX-7050-48",
                        })),
                    ),
                    update(
                        "component[name=Linecard1]/state",
                        json_ietf(json!({
                            "type": "openconfig-platform-types:LINECARD",
                            "serial-no": "LC0001",
                        })),
                    ),
                    update(
                        "component[name=Member2]/state",
                        json_ietf(json!({
                            "type": "openconfig-platform-types:CHASSIS",
                            "serial-no": "JPE87654321",
                            "parent": "Chassis",
                        })),
                    ),
                ],
                ..Default::default()
            },
            Notification {
                update: vec![update(
                    "interfaces",
                    json_ietf(json!({"openconfig-interfaces:interface": [
                        {
                            "name": "Ethernet1",
                            "state": {
                                "type": "iana-if-type:ethernetCsmacd",
                                "oper-status": "UP",
                                "mtu": 9214,
                            },
                            "openconfig-if-ethernet:ethernet": {
                                "state": {
                                    "mac-address": "00:1C:73:AA:BB:01",
                                    "port-speed": "openconfig-if-ethernet:SPEED_25GB",
                                },
                                "openconfig-vlan:switched-vlan": {"state": {
                                    "interface-mode": "ACCESS",
                                    "access-vlan": 10,
                                }},
                            },
                        },
                        {
                            "name": "Ethernet2",
                            "state": {
                                "type": "iana-if-type:ethernetCsmacd",
                                "oper-status": "LOWER_LAYER_DOWN",
                            },
                            "ethernet": {
                                "state": {
                                    "hw-mac-address": "001c.73aa.bb02",
                                    "port-speed": "SPEED_2500MB",
                                },
                                "switched-vlan": {"state": {
                                    "interface-mode": "TRUNK",
                                    "native-vlan": 10,
                                    "trunk-vlans": [20, "1..100", "4000..4094"],
                                }},
                            },
                        },
                        {
                            "name": "Port-Channel1",
                            "state": {"type": "iana-if-type:ieee8023adLag", "oper-status": "UP"},
                            "aggregation": {
                                "state": {"lag-speed": 50000},
                                "switched-vlan": {"config": {
                                    "interface-mode": "TRUNK",
                                    "trunk-vlans": ["20"],
                                }},
                            },
                        },
                        {
                            "name": "Management1",
                            "state": {"type": "iana-if-type:ethernetCsmacd", "oper-status": "UP", "mtu": "1500"},
                            "ethernet": {"state": {"mac-address": "00:00:00:00:00:00"}},
                            "subinterfaces": {"subinterface": [{"index": 0}]},
                        },
                        {"name": "Ethernet1", "state": {"oper-status": "DOWN"}},
                    ]})),
                )],
                ..Default::default()
            },
            Notification {
                prefix: Some(path(
                    "network-instances/network-instance[name=default]/vlans",
                )),
                update: vec![
                    update("vlan[vlan-id=10]/state/vlan-id", Typed::UintVal(10)),
                    update("vlan[vlan-id=20]/state/vlan-id", Typed::UintVal(20)),
                    update("vlan[vlan-id=30]/state/vlan-id", Typed::UintVal(30)),
                    update("vlan[vlan-id=4001]/state/vlan-id", Typed::UintVal(4001)),
                ],
                ..Default::default()
            },
            Notification {
                prefix: Some(path("lldp/interfaces")),
                update: vec![
                    update(
                        "interface[name=Ethernet1]/neighbors/neighbor[id=1]/state",
                        json_ietf(json!({
                            "chassis-id": "52-54-00-12-34-56",
                            "chassis-id-type": "MAC_ADDRESS",
                            "port-id": "eno1",
                            "port-id-type": "INTERFACE_NAME",
                            "system-name": "web-01",
                            "port-description": "uplink",
                        })),
                    ),
                    // The same endpoint again under another ID, then an unreadable one.
                    update(
                        "interface[name=Ethernet1]/neighbors/neighbor[id=2]/state",
                        json_ietf(json!({
                            "chassis-id": "52:54:00:12:34:56",
                            "chassis-id-type": "openconfig-lldp-types:MAC_ADDRESS",
                            "port-id": "eno1",
                            "port-id-type": "INTERFACE_NAME",
                        })),
                    ),
                    update(
                        "interface[name=Ethernet1]/neighbors/neighbor[id=3]/state",
                        json_ietf(
                            json!({"chassis-id": "not a mac", "chassis-id-type": "MAC_ADDRESS", "port-id": "x"}),
                        ),
                    ),
                    update(
                        "interface[name=Port-Channel1]/neighbors/neighbor[id=1]/state",
                        json_ietf(json!({
                            "chassis-id": "192.0.2.10",
                            "chassis-id-type": "NETWORK_ADDRESS",
                            "port-id": "Gi0/1",
                            "port-id-type": "LOCAL",
                        })),
                    ),
                    update(
                        "interface[name=Ethernet9]/neighbors/neighbor[id=1]/state",
                        json_ietf(json!({"chassis-id": "spine", "port-id": "Ethernet9"})),
                    ),
                ],
                ..Default::default()
            },
        ];
        PATHS.iter().copied().zip(notifications).collect()
    }

    pub(crate) fn answers() -> Answers {
        let mut answers = Answers::default();
        for (path, notification) in recorded() {
            tree::merge(&mut answers.tree, &[notification]).unwrap();
            answers.answered.insert(path);
        }
        answers
    }

    fn interface<'a>(resource: &'a CollectorResource, name: &str) -> &'a Interface {
        resource
            .interfaces
            .as_ref()
            .unwrap()
            .iter()
            .find(|interface| interface.name == name)
            .unwrap()
    }

    #[test]
    fn identifies_the_switch_by_its_top_level_chassis_serial() {
        let (resource, _) = switch("10.0.0.2", &answers(), 2_700).unwrap();

        assert_eq!(resource.kind, CollectorResourceKind::Switch);
        assert_eq!(resource.target.as_deref(), Some("10.0.0.2"));
        assert_eq!(
            resource.identifiers.serial_number.as_deref(),
            Some("JPE12345678")
        );
        assert_eq!(resource.identifiers.hostname.as_deref(), Some("leaf-02"));
        assert!(resource.identifiers.mac_address.is_empty());
        let attributes = resource.attributes.unwrap();
        assert_eq!(attributes.vendor.as_deref(), Some("Example Networks"));
        assert_eq!(attributes.model.as_deref(), Some("EX-7050-48"));
    }

    #[test]
    fn reports_top_level_interfaces_once_each() {
        let (resource, _) = switch("10.0.0.2", &answers(), 2_700).unwrap();
        let names: Vec<_> = resource
            .interfaces
            .iter()
            .flatten()
            .map(|interface| interface.name.as_str())
            .collect();
        assert_eq!(
            names,
            ["Ethernet1", "Ethernet2", "Management1", "Port-Channel1"]
        );

        let ethernet1 = interface(&resource, "Ethernet1");
        assert_eq!(
            (ethernet1.kind.as_str(), ethernet1.status.as_str()),
            ("ethernet", "up")
        );
        assert_eq!(ethernet1.mac_address.as_deref(), Some("00:1c:73:aa:bb:01"));
        assert_eq!(
            (ethernet1.mtu, ethernet1.speed_mbps),
            (Some(9214), Some(25_000))
        );

        let ethernet2 = interface(&resource, "Ethernet2");
        assert_eq!(ethernet2.status, "down");
        assert_eq!(ethernet2.mac_address.as_deref(), Some("00:1c:73:aa:bb:02"));
        assert_eq!(ethernet2.speed_mbps, Some(2_500));

        let lag = interface(&resource, "Port-Channel1");
        assert_eq!((lag.kind.as_str(), lag.speed_mbps), ("bond", Some(50_000)));

        let management = interface(&resource, "Management1");
        assert_eq!(
            (management.mac_address.as_deref(), management.mtu),
            (None, Some(1500))
        );
    }

    #[test]
    fn distinguishes_an_unanswered_interface_model_from_an_empty_one() {
        let mut unanswered = answers();
        unanswered.answered.remove(INTERFACES);

        let (resource, sections) = switch("10.0.0.2", &unanswered, 2_700).unwrap();

        assert!(resource.interfaces.is_none());
        assert_eq!(
            sections,
            Sections {
                interface_neighbors: false,
                interface_vlans: false
            }
        );

        let mut empty = answers();
        empty.tree["interfaces"]["interface"] = json!([]);

        let (resource, _) = switch("10.0.0.2", &empty, 2_700).unwrap();

        assert!(resource.interfaces.unwrap().is_empty());
    }

    #[test]
    fn reads_vlan_membership_against_the_vlan_table() {
        let (resource, sections) = switch("10.0.0.2", &answers(), 2_700).unwrap();

        assert!(sections.interface_vlans);
        let ethernet1 = interface(&resource, "Ethernet1");
        assert_eq!(ethernet1.vlan_mode.as_deref(), Some("access"));
        assert_eq!(
            ethernet1.vlans,
            Some(vec![VlanMembership {
                vid: 10,
                tagging_mode: TaggingMode::Untagged
            }])
        );
        // Allowed VLANs the switch does not have are not carried.
        let ethernet2 = interface(&resource, "Ethernet2");
        assert_eq!(ethernet2.vlan_mode.as_deref(), Some("trunk"));
        let vlans: Vec<_> = ethernet2
            .vlans
            .iter()
            .flatten()
            .map(|vlan| (vlan.vid, vlan.tagging_mode))
            .collect();
        assert_eq!(
            vlans,
            [
                (10, TaggingMode::Untagged),
                (20, TaggingMode::Tagged),
                (30, TaggingMode::Tagged),
                (4001, TaggingMode::Tagged)
            ]
        );
        assert_eq!(
            interface(&resource, "Port-Channel1")
                .vlans
                .as_ref()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(interface(&resource, "Management1").vlans, Some(vec![]));
        assert_eq!(interface(&resource, "Management1").vlan_mode, None);
    }

    #[test]
    fn leaves_ranges_undescribed_without_the_vlan_table() {
        let mut answers = answers();
        answers.answered.remove(VLANS);

        let (resource, sections) = switch("10.0.0.2", &answers, 2_700).unwrap();

        assert!(!sections.interface_vlans);
        assert_eq!(interface(&resource, "Ethernet2").vlans, None);
        // Single VIDs need no table.
        assert_eq!(
            interface(&resource, "Port-Channel1").vlans,
            Some(vec![VlanMembership {
                vid: 20,
                tagging_mode: TaggingMode::Tagged
            }])
        );
    }

    #[test]
    fn attaches_lldp_neighbors_to_their_local_ports() {
        let (resource, sections) = switch("10.0.0.2", &answers(), 2_700).unwrap();

        assert!(sections.interface_neighbors);
        assert_eq!(
            interface(&resource, "Ethernet1").neighbors.as_deref(),
            Some(
                &[Neighbor {
                    protocol: "lldp",
                    remote_chassis_id: "52:54:00:12:34:56".into(),
                    remote_chassis_id_kind: "mac_address",
                    remote_port_id: "eno1".into(),
                    remote_port_id_kind: "name",
                    remote_system_name: Some("web-01".into()),
                    remote_port_description: Some("uplink".into()),
                    ttl_seconds: 2_700,
                }][..]
            )
        );
        let lag = interface(&resource, "Port-Channel1")
            .neighbors
            .clone()
            .unwrap();
        assert_eq!(
            (
                lag[0].remote_chassis_id.as_str(),
                lag[0].remote_chassis_id_kind,
                lag[0].remote_port_id_kind
            ),
            ("192.0.2.10", "network_address", "local")
        );
        assert_eq!(interface(&resource, "Ethernet2").neighbors, Some(vec![]));
    }

    #[test]
    fn leaves_sections_unclaimed_when_their_model_is_missing() {
        let mut answers = answers();
        answers.answered.remove(LLDP);
        if let Some(interfaces) = answers.tree["interfaces"]["interface"].as_array_mut() {
            for interface in interfaces {
                for container in ["ethernet", "aggregation"] {
                    if let Some(container) = interface.get_mut(container) {
                        container.as_object_mut().unwrap().remove("switched-vlan");
                    }
                }
            }
        }

        let (resource, sections) = switch("10.0.0.2", &answers, 2_700).unwrap();

        assert_eq!(
            sections,
            Sections {
                interface_neighbors: false,
                interface_vlans: false
            }
        );
        let ethernet1 = interface(&resource, "Ethernet1");
        assert_eq!((&ethernet1.neighbors, &ethernet1.vlans), (&None, &None));
    }

    #[test]
    fn refuses_a_switch_without_a_chassis_serial() {
        let mut answers = answers();
        answers.tree["components"] = json!({"component": [
            {"name": "Chassis", "state": {"type": "CHASSIS", "serial-no": "Unknown"}}
        ]});

        let error = switch("10.0.0.2", &answers, 2_700).unwrap_err();

        assert!(error.0.contains("no chassis serial number"), "{error:?}");
    }

    #[test]
    fn refuses_a_switch_claiming_too_many_memberships() {
        let mut answers = answers();
        answers.tree["network-instances"]["network-instance"][0]["vlans"]["vlan"] =
            Value::Array((1..=4094).map(|vid| json!({"vlan-id": vid})).collect());
        let trunk = json!({"name": "", "ethernet": {"switched-vlan": {"state": {
            "interface-mode": "TRUNK", "trunk-vlans": ["1..4094"]
        }}}});
        let interfaces = answers.tree["interfaces"]["interface"]
            .as_array_mut()
            .unwrap();
        for port in 0..30 {
            let mut trunk = trunk.clone();
            trunk["name"] = json!(format!("Ethernet{}", 100 + port));
            interfaces.push(trunk);
        }

        let error = switch("10.0.0.2", &answers, 2_700).unwrap_err();

        assert!(error.0.contains("VLAN memberships"), "{error:?}");
    }

    /// The recorded switch as the mapper reports it. Renga's collector report tests post this
    /// file next to the SNMP poller's, so a mapping the server would reject fails there. Set
    /// `RENGA_UPDATE_FIXTURES=1` to rewrite it after an intended mapping change.
    #[test]
    fn the_recorded_switch_matches_the_server_fixture() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../test/fixtures/collectors/recorded_gnmi_switch.json"
        );
        let (resource, _) = switch("10.0.0.2", &answers(), 2_700).unwrap();
        let mapped = serde_json::to_value(&resource).unwrap();
        if std::env::var_os("RENGA_UPDATE_FIXTURES").is_some() {
            let body = serde_json::to_string_pretty(&mapped).unwrap();
            std::fs::write(path, body + "\n").unwrap();
        }
        let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(
            mapped, fixture,
            "rerun with RENGA_UPDATE_FIXTURES=1 if intended"
        );
    }

    #[test]
    fn normalizes_macs_and_speeds() {
        for (raw, expected) in [
            ("00:1C:73:AA:BB:01", Some("00:1c:73:aa:bb:01")),
            ("001c.73aa.bb01", Some("00:1c:73:aa:bb:01")),
            ("00-1c-73-aa-bb-01", Some("00:1c:73:aa:bb:01")),
            ("001c73aabb01", Some("00:1c:73:aa:bb:01")),
            ("00:00:00:00:00:00", None),
            ("00:1c:73:aa:bb", None),
            ("zz:1c:73:aa:bb:01", None),
        ] {
            assert_eq!(mac(&json!(raw)).as_deref(), expected, "{raw}");
        }
        assert_eq!(speed_mbps("SPEED_100GB"), Some(100_000));
        assert_eq!(speed_mbps("SPEED_10MB"), Some(10));
        assert_eq!(speed_mbps("SPEED_UNKNOWN"), None);
    }
}
