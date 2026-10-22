//! Turns what a switch answered into the switch Renga reconciles (RFD 11, "Switch collection").
//!
//! Everything here is pure, so each MIB's quirks are tested from recorded answers without a
//! device: identity from `SNMPv2-MIB` and `ENTITY-MIB`, interfaces from `IF-MIB`, neighbors from
//! `LLDP-MIB`, and VLAN membership from `Q-BRIDGE-MIB`.

use crate::{
    collectors::normalize_value,
    payload::{
        CollectorIdentifiers, CollectorResource, CollectorResourceKind, HostAttributes, Interface,
        Neighbor, TaggingMode, VlanMembership,
    },
};
use std::collections::{BTreeMap, BTreeSet};

pub type Oid = Vec<u32>;

/// A variable's value, owned so answers outlive the session that read them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnmpValue {
    Integer(i64),
    Unsigned(u64),
    Octets(Vec<u8>),
    ObjectId(Oid),
    IpAddress([u8; 4]),
    /// `noSuchObject`, `noSuchInstance`, or `endOfMibView`: the agent does not have it.
    Missing,
    Other,
}

pub const SYS_DESCR: &[u32] = &[1, 3, 6, 1, 2, 1, 1, 1, 0];
pub const SYS_NAME: &[u32] = &[1, 3, 6, 1, 2, 1, 1, 5, 0];
pub const LLDP_LOC_CHASSIS_ID_SUBTYPE: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 3, 1, 0];
pub const LLDP_LOC_CHASSIS_ID: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 3, 2, 0];
pub const DOT1Q_VLAN_VERSION: &[u32] = &[1, 3, 6, 1, 2, 1, 17, 7, 1, 1, 1, 0];

/// Scalars read with one GET.
pub const SCALARS: &[&[u32]] = &[
    SYS_DESCR,
    SYS_NAME,
    LLDP_LOC_CHASSIS_ID_SUBTYPE,
    LLDP_LOC_CHASSIS_ID,
    DOT1Q_VLAN_VERSION,
];

pub const ENT_PHYSICAL_CLASS: &[u32] = &[1, 3, 6, 1, 2, 1, 47, 1, 1, 1, 1, 5];
pub const ENT_PHYSICAL_MFG_NAME: &[u32] = &[1, 3, 6, 1, 2, 1, 47, 1, 1, 1, 1, 12];
pub const ENT_PHYSICAL_SERIAL_NUM: &[u32] = &[1, 3, 6, 1, 2, 1, 47, 1, 1, 1, 1, 11];
pub const ENT_PHYSICAL_MODEL_NAME: &[u32] = &[1, 3, 6, 1, 2, 1, 47, 1, 1, 1, 1, 13];
pub const IF_DESCR: &[u32] = &[1, 3, 6, 1, 2, 1, 2, 2, 1, 2];
pub const IF_TYPE: &[u32] = &[1, 3, 6, 1, 2, 1, 2, 2, 1, 3];
pub const IF_MTU: &[u32] = &[1, 3, 6, 1, 2, 1, 2, 2, 1, 4];
pub const IF_SPEED: &[u32] = &[1, 3, 6, 1, 2, 1, 2, 2, 1, 5];
pub const IF_PHYS_ADDRESS: &[u32] = &[1, 3, 6, 1, 2, 1, 2, 2, 1, 6];
pub const IF_OPER_STATUS: &[u32] = &[1, 3, 6, 1, 2, 1, 2, 2, 1, 8];
pub const IF_NAME: &[u32] = &[1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1];
pub const IF_HIGH_SPEED: &[u32] = &[1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 15];
pub const LLDP_LOC_PORT_ID_SUBTYPE: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 3, 7, 1, 2];
pub const LLDP_LOC_PORT_ID: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 3, 7, 1, 3];
pub const LLDP_REM_CHASSIS_ID_SUBTYPE: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 4, 1, 1, 4];
pub const LLDP_REM_CHASSIS_ID: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 4, 1, 1, 5];
pub const LLDP_REM_PORT_ID_SUBTYPE: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 4, 1, 1, 6];
pub const LLDP_REM_PORT_ID: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 4, 1, 1, 7];
pub const LLDP_REM_PORT_DESC: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 4, 1, 1, 8];
pub const LLDP_REM_SYS_NAME: &[u32] = &[1, 0, 8802, 1, 1, 2, 1, 4, 1, 1, 9];
pub const DOT1D_BASE_PORT_IF_INDEX: &[u32] = &[1, 3, 6, 1, 2, 1, 17, 1, 4, 1, 2];
pub const DOT1Q_VLAN_CURRENT_EGRESS_PORTS: &[u32] = &[1, 3, 6, 1, 2, 1, 17, 7, 1, 4, 2, 1, 4];
pub const DOT1Q_VLAN_CURRENT_UNTAGGED_PORTS: &[u32] = &[1, 3, 6, 1, 2, 1, 17, 7, 1, 4, 2, 1, 5];

/// Table columns walked one by one. A device missing a MIB simply answers nothing for it.
pub const COLUMNS: &[&[u32]] = &[
    ENT_PHYSICAL_CLASS,
    ENT_PHYSICAL_MFG_NAME,
    ENT_PHYSICAL_SERIAL_NUM,
    ENT_PHYSICAL_MODEL_NAME,
    IF_DESCR,
    IF_TYPE,
    IF_MTU,
    IF_SPEED,
    IF_PHYS_ADDRESS,
    IF_OPER_STATUS,
    IF_NAME,
    IF_HIGH_SPEED,
    LLDP_LOC_PORT_ID_SUBTYPE,
    LLDP_LOC_PORT_ID,
    LLDP_REM_CHASSIS_ID_SUBTYPE,
    LLDP_REM_CHASSIS_ID,
    LLDP_REM_PORT_ID_SUBTYPE,
    LLDP_REM_PORT_ID,
    LLDP_REM_PORT_DESC,
    LLDP_REM_SYS_NAME,
    DOT1D_BASE_PORT_IF_INDEX,
    DOT1Q_VLAN_CURRENT_EGRESS_PORTS,
    DOT1Q_VLAN_CURRENT_UNTAGGED_PORTS,
];

const ENT_CLASS_CHASSIS: i64 = 3;
// Postgres integer columns hold MTU and speed.
const MAX_INT32: u64 = 2_147_483_647;
/// Must match `Renga.Inventory.AgentPayload`'s string limit.
pub const MAX_STRING_CHARS: usize = 255;

/// Every variable a switch answered, by OID.
#[derive(Debug, Default, Clone)]
pub struct Answers(BTreeMap<Oid, SnmpValue>);

impl Answers {
    pub fn insert(&mut self, oid: Oid, value: SnmpValue) {
        self.0.insert(oid, value);
    }

    pub fn iter(&self) -> impl Iterator<Item = (&Oid, &SnmpValue)> {
        self.0.iter()
    }

    fn scalar(&self, oid: &[u32]) -> Option<&SnmpValue> {
        self.0
            .get(oid)
            .filter(|value| !matches!(value, SnmpValue::Missing))
    }

    /// A column's rows as `(index, value)`, the index being the OID after the column.
    fn column<'a>(
        &'a self,
        column: &[u32],
    ) -> impl Iterator<Item = (&'a [u32], &'a SnmpValue)> + use<'a> {
        let prefix = column.to_vec();
        let length = prefix.len();
        self.0
            .range(prefix.clone()..)
            .take_while(move |(oid, _)| oid.starts_with(&prefix))
            .filter(move |(oid, value)| oid.len() > length && !matches!(value, SnmpValue::Missing))
            .map(move |(oid, value)| (&oid[length..], value))
    }

    /// A column indexed by one integer, such as `ifIndex`.
    fn by_index(&self, column: &[u32]) -> BTreeMap<u32, &SnmpValue> {
        self.column(column)
            .filter_map(|(index, value)| match index {
                [index] => Some((*index, value)),
                _ => None,
            })
            .collect()
    }
}

/// Which optional MIBs answered, so the report claims completeness only for what it read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Support {
    pub lldp: bool,
    pub q_bridge: bool,
}

/// Why a reachable switch cannot be reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapError(pub String);

/// The switch behind `answers`, as polled from `target`. Neighbors expire after `ttl_seconds`,
/// since LLDP-MIB does not carry the remote's own hold time.
pub fn switch(
    target: &str,
    answers: &Answers,
    ttl_seconds: u32,
) -> Result<(CollectorResource, Support), MapError> {
    let chassis = chassis(answers).ok_or_else(|| {
        MapError("no chassis serial number in ENTITY-MIB; the switch cannot be identified".into())
    })?;
    let support = Support {
        lldp: answers.scalar(LLDP_LOC_CHASSIS_ID).is_some(),
        q_bridge: answers.scalar(DOT1Q_VLAN_VERSION).is_some(),
    };
    let mut interfaces = interfaces(answers);
    if support.lldp {
        attach_neighbors(answers, &mut interfaces, ttl_seconds);
    }
    if support.q_bridge {
        attach_vlans(answers, &mut interfaces);
    }
    let hostname = answers.scalar(SYS_NAME).and_then(text);
    let resource = CollectorResource {
        kind: CollectorResourceKind::Switch,
        target: Some(target.to_owned()),
        identifiers: CollectorIdentifiers {
            hostname: hostname.clone(),
            serial_number: Some(chassis.serial),
            dmi_uuid: None,
            mac_address: local_chassis_mac(answers).into_iter().collect(),
        },
        attributes: Some(HostAttributes {
            hostname,
            vendor: chassis.vendor,
            model: chassis.model,
            ..Default::default()
        }),
        interfaces: Some(
            interfaces
                .into_values()
                .map(|entry| entry.interface)
                .collect(),
        ),
    };
    Ok((resource, support))
}

struct Chassis {
    serial: String,
    vendor: Option<String>,
    model: Option<String>,
}

/// The first chassis entity with a serial number. Stacks list one chassis per member; the
/// lowest index is the stack's own identity on every platform that numbers them.
fn chassis(answers: &Answers) -> Option<Chassis> {
    let serials = answers.by_index(ENT_PHYSICAL_SERIAL_NUM);
    let vendors = answers.by_index(ENT_PHYSICAL_MFG_NAME);
    let models = answers.by_index(ENT_PHYSICAL_MODEL_NAME);
    answers
        .by_index(ENT_PHYSICAL_CLASS)
        .into_iter()
        .filter(|(_, class)| **class == SnmpValue::Integer(ENT_CLASS_CHASSIS))
        .find_map(|(index, _)| {
            let serial = serials.get(&index).and_then(|value| text(value))?;
            Some(Chassis {
                serial,
                vendor: vendors.get(&index).and_then(|value| text(value)),
                model: models.get(&index).and_then(|value| text(value)),
            })
        })
}

fn local_chassis_mac(answers: &Answers) -> Option<String> {
    // Subtype 4 is macAddress (IEEE 802.1AB LldpChassisIdSubtype).
    match answers.scalar(LLDP_LOC_CHASSIS_ID_SUBTYPE)? {
        SnmpValue::Integer(4) => mac(answers.scalar(LLDP_LOC_CHASSIS_ID)?),
        _ => None,
    }
}

struct Entry {
    interface: Interface,
    descr: Option<String>,
    mac: Option<String>,
}

fn interfaces(answers: &Answers) -> BTreeMap<u32, Entry> {
    let descrs = answers.by_index(IF_DESCR);
    let names = answers.by_index(IF_NAME);
    let types = answers.by_index(IF_TYPE);
    let mtus = answers.by_index(IF_MTU);
    let speeds = answers.by_index(IF_SPEED);
    let high_speeds = answers.by_index(IF_HIGH_SPEED);
    let addresses = answers.by_index(IF_PHYS_ADDRESS);
    let statuses = answers.by_index(IF_OPER_STATUS);
    let indexes: BTreeSet<u32> = descrs.keys().chain(names.keys()).copied().collect();
    let mut seen = BTreeSet::new();
    indexes
        .into_iter()
        .filter_map(|index| {
            let descr = descrs.get(&index).and_then(|value| text(value));
            let name = names
                .get(&index)
                .and_then(|value| text(value))
                .or_else(|| descr.clone())?;
            // Names identify interfaces in Renga, so a duplicate would merge two ports.
            if !seen.insert(name.clone()) {
                return None;
            }
            let mac = addresses.get(&index).and_then(|value| mac(value));
            let speed_mbps = high_speeds
                .get(&index)
                .and_then(|value| unsigned(value))
                .filter(|speed| *speed > 0)
                .or_else(|| {
                    speeds
                        .get(&index)
                        .and_then(|value| unsigned(value))
                        .map(|bits| bits / 1_000_000)
                        .filter(|speed| *speed > 0)
                })
                .filter(|speed| *speed <= MAX_INT32)
                .map(|speed| speed as u32);
            let interface = Interface {
                name,
                kind: interface_kind(types.get(&index).and_then(|value| integer(value))).into(),
                status: oper_status(statuses.get(&index).and_then(|value| integer(value))).into(),
                mac_address: mac.clone(),
                mtu: mtus
                    .get(&index)
                    .and_then(|value| unsigned(value))
                    .filter(|mtu| (1..=MAX_INT32).contains(mtu))
                    .map(|mtu| mtu as u32),
                speed_mbps,
                ..Default::default()
            };
            Some((
                index,
                Entry {
                    interface,
                    descr,
                    mac,
                },
            ))
        })
        .collect()
}

/// IANAifType to the interface kinds Renga knows.
fn interface_kind(if_type: Option<i64>) -> &'static str {
    match if_type {
        // ethernetCsmacd, iso88023Csmacd, fastEther, gigabitEthernet, fastEtherFX
        Some(6 | 7 | 62 | 69 | 117) => "ethernet",
        Some(24) => "loopback",
        // ieee8023adLag
        Some(161) => "bond",
        Some(209) => "bridge",
        // l2vlan, l3ipvlan
        Some(135 | 136) => "vlan",
        // propVirtual
        Some(53) => "virtual",
        _ => "unknown",
    }
}

fn oper_status(status: Option<i64>) -> &'static str {
    match status {
        Some(1) => "up",
        // down, lowerLayerDown
        Some(2 | 7) => "down",
        Some(5) => "dormant",
        Some(6) => "not_present",
        _ => "unknown",
    }
}

/// LLDP numbers local ports itself. Most switches use the ifIndex, but the standard ties a port
/// to an interface only through its port ID, so that is matched first.
fn local_ports(answers: &Answers, interfaces: &BTreeMap<u32, Entry>) -> BTreeMap<u32, u32> {
    let subtypes = answers.by_index(LLDP_LOC_PORT_ID_SUBTYPE);
    answers
        .by_index(LLDP_LOC_PORT_ID)
        .into_iter()
        .filter_map(|(port, id)| {
            let matched = match subtypes.get(&port) {
                // macAddress
                Some(SnmpValue::Integer(3)) => mac(id).and_then(|address| {
                    interfaces
                        .iter()
                        .find(|(_, entry)| entry.mac.as_deref() == Some(address.as_str()))
                }),
                // interfaceAlias, interfaceName, local
                Some(SnmpValue::Integer(1 | 5 | 7)) => text(id).and_then(|name| {
                    interfaces.iter().find(|(_, entry)| {
                        entry.interface.name == name || entry.descr.as_deref() == Some(&name)
                    })
                }),
                _ => None,
            };
            matched
                .map(|(index, _)| *index)
                .or_else(|| interfaces.contains_key(&port).then_some(port))
                .map(|index| (port, index))
        })
        .collect()
}

fn attach_neighbors(answers: &Answers, interfaces: &mut BTreeMap<u32, Entry>, ttl_seconds: u32) {
    let local = local_ports(answers, interfaces);
    let chassis_subtypes = remote_rows(answers, LLDP_REM_CHASSIS_ID_SUBTYPE);
    let port_ids = remote_rows(answers, LLDP_REM_PORT_ID);
    let port_subtypes = remote_rows(answers, LLDP_REM_PORT_ID_SUBTYPE);
    let port_descs = remote_rows(answers, LLDP_REM_PORT_DESC);
    let names = remote_rows(answers, LLDP_REM_SYS_NAME);
    for entry in interfaces.values_mut() {
        entry.interface.neighbors = Some(Vec::new());
    }
    for (key, chassis_id) in remote_rows(answers, LLDP_REM_CHASSIS_ID) {
        let Some(entry) = local
            .get(&key.0)
            .and_then(|index| interfaces.get_mut(index))
        else {
            continue;
        };
        let (Some(remote_chassis_id), Some(remote_port_id)) = (
            chassis_subtypes
                .get(&key)
                .and_then(|subtype| chassis_id_value(subtype, chassis_id)),
            port_ids
                .get(&key)
                .and_then(|port| port_id_value(port_subtypes.get(&key).copied(), port)),
        ) else {
            continue;
        };
        let neighbor = Neighbor {
            protocol: "lldp",
            remote_chassis_id: remote_chassis_id.0,
            remote_chassis_id_kind: remote_chassis_id.1,
            remote_port_id: remote_port_id.0,
            remote_port_id_kind: remote_port_id.1,
            remote_system_name: names.get(&key).and_then(|value| text(value)),
            remote_port_description: port_descs.get(&key).and_then(|value| text(value)),
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

/// Remote table rows keyed by `(localPortNum, remIndex)`, dropping the leading `timeMark`.
fn remote_rows<'a>(answers: &'a Answers, column: &[u32]) -> BTreeMap<(u32, u32), &'a SnmpValue> {
    answers
        .column(column)
        .filter_map(|(index, value)| match index {
            [_time_mark, port, remote] => Some(((*port, *remote), value)),
            _ => None,
        })
        .collect()
}

fn chassis_id_value(subtype: &SnmpValue, value: &SnmpValue) -> Option<(String, &'static str)> {
    match subtype {
        SnmpValue::Integer(4) => Some((mac(value)?, "mac_address")),
        SnmpValue::Integer(5) => Some((network_address(value)?, "network_address")),
        SnmpValue::Integer(6) => Some((text(value)?, "name")),
        SnmpValue::Integer(_) => Some((text_or_hex(value)?, "local")),
        _ => None,
    }
}

fn port_id_value(subtype: Option<&SnmpValue>, value: &SnmpValue) -> Option<(String, &'static str)> {
    match subtype {
        Some(SnmpValue::Integer(3)) => Some((mac(value)?, "mac_address")),
        Some(SnmpValue::Integer(1 | 5)) => Some((text(value)?, "name")),
        _ => Some((text_or_hex(value)?, "local")),
    }
}

/// An LLDP network address: an IANA address family octet, then the address.
fn network_address(value: &SnmpValue) -> Option<String> {
    let SnmpValue::Octets(bytes) = value else {
        return None;
    };
    match bytes.as_slice() {
        [1, a, b, c, d] => Some(std::net::Ipv4Addr::new(*a, *b, *c, *d).to_string()),
        [2, rest @ ..] if rest.len() == 16 => {
            let octets: [u8; 16] = rest.try_into().ok()?;
            Some(std::net::Ipv6Addr::from(octets).to_string())
        }
        _ => None,
    }
}

fn attach_vlans(answers: &Answers, interfaces: &mut BTreeMap<u32, Entry>) {
    let bridge_ports: BTreeMap<u32, u32> = answers
        .by_index(DOT1D_BASE_PORT_IF_INDEX)
        .into_iter()
        .filter_map(|(port, if_index)| Some((port, u32::try_from(integer(if_index)?).ok()?)))
        .collect();
    let vlan_ports = |column| -> BTreeMap<u16, BTreeSet<u32>> {
        answers
            .column(column)
            .filter_map(|(index, value)| match (index, value) {
                ([_time_mark, vid], SnmpValue::Octets(bitmap)) => {
                    let vid = u16::try_from(*vid)
                        .ok()
                        .filter(|vid| (1..=4094).contains(vid))?;
                    Some((vid, port_list(bitmap)))
                }
                _ => None,
            })
            .collect()
    };
    let egress = vlan_ports(DOT1Q_VLAN_CURRENT_EGRESS_PORTS);
    let untagged = vlan_ports(DOT1Q_VLAN_CURRENT_UNTAGGED_PORTS);
    let mut memberships: BTreeMap<u32, Vec<VlanMembership>> = BTreeMap::new();
    for (vid, ports) in &egress {
        for port in ports {
            let Some(if_index) = bridge_ports.get(port) else {
                continue;
            };
            let tagging_mode = if untagged.get(vid).is_some_and(|ports| ports.contains(port)) {
                TaggingMode::Untagged
            } else {
                TaggingMode::Tagged
            };
            memberships
                .entry(*if_index)
                .or_default()
                .push(VlanMembership {
                    vid: *vid,
                    tagging_mode,
                });
        }
    }
    for (index, entry) in interfaces.iter_mut() {
        let mut vlans = memberships.remove(index).unwrap_or_default();
        // At most one VLAN may be untagged; a port reporting more is described only as tagged.
        if vlans
            .iter()
            .filter(|vlan| vlan.tagging_mode == TaggingMode::Untagged)
            .count()
            > 1
        {
            for vlan in &mut vlans {
                vlan.tagging_mode = TaggingMode::Tagged;
            }
        }
        if vlans.is_empty() {
            entry.interface.vlans = Some(vlans);
            continue;
        }
        let access = matches!(
            vlans.as_slice(),
            [VlanMembership {
                tagging_mode: TaggingMode::Untagged,
                ..
            }]
        );
        entry.interface.vlan_mode = Some(if access { "access" } else { "trunk" }.into());
        entry.interface.vlans = Some(vlans);
    }
}

/// A Q-BRIDGE PortList: the first octet's high bit is bridge port 1.
fn port_list(bitmap: &[u8]) -> BTreeSet<u32> {
    bitmap
        .iter()
        .enumerate()
        .flat_map(|(octet, bits)| {
            (0..8)
                .filter(move |bit| bits & (0x80 >> bit) != 0)
                .map(move |bit| octet as u32 * 8 + bit + 1)
        })
        .collect()
}

fn text(value: &SnmpValue) -> Option<String> {
    match value {
        SnmpValue::Octets(bytes) => {
            let text = std::str::from_utf8(bytes).ok()?;
            let text = text.trim_matches(|c: char| c.is_whitespace() || c == '\0');
            normalize_value(text).filter(|text| within_string_limit(text))
        }
        _ => None,
    }
}

fn text_or_hex(value: &SnmpValue) -> Option<String> {
    text(value).or_else(|| match value {
        SnmpValue::Octets(bytes) if !bytes.is_empty() => Some(
            bytes
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<Vec<_>>()
                .join(":"),
        )
        .filter(|hex| within_string_limit(hex)),
        _ => None,
    })
}

/// Renga rejects a whole report over one longer string, which would lose every switch in it,
/// so a value too long to send is left out instead. Cutting it short could make two different
/// names or IDs equal.
fn within_string_limit(text: &str) -> bool {
    text.chars().count() <= MAX_STRING_CHARS
}

fn mac(value: &SnmpValue) -> Option<String> {
    match value {
        SnmpValue::Octets(bytes) if bytes.len() == 6 && bytes.iter().any(|byte| *byte != 0) => {
            Some(
                bytes
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<Vec<_>>()
                    .join(":"),
            )
        }
        _ => None,
    }
}

fn integer(value: &SnmpValue) -> Option<i64> {
    match value {
        SnmpValue::Integer(value) => Some(*value),
        SnmpValue::Unsigned(value) => i64::try_from(*value).ok(),
        _ => None,
    }
}

fn unsigned(value: &SnmpValue) -> Option<u64> {
    match value {
        SnmpValue::Unsigned(value) => Some(*value),
        SnmpValue::Integer(value) => u64::try_from(*value).ok(),
        _ => None,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn oid(base: &[u32], index: &[u32]) -> Oid {
        base.iter().chain(index).copied().collect()
    }

    fn octets(text: &str) -> SnmpValue {
        SnmpValue::Octets(text.as_bytes().to_vec())
    }

    /// A two-port access switch with one uplink trunk, as a typical switch answers.
    pub(crate) fn answers() -> Answers {
        let mut answers = Answers::default();
        let mut put = |base: &[u32], index: &[u32], value: SnmpValue| {
            answers.insert(oid(base, index), value);
        };
        put(SYS_NAME, &[], octets("leaf-01"));
        put(SYS_DESCR, &[], octets("Example OS 1.2"));
        put(LLDP_LOC_CHASSIS_ID_SUBTYPE, &[], SnmpValue::Integer(4));
        put(
            LLDP_LOC_CHASSIS_ID,
            &[],
            SnmpValue::Octets(vec![0x00, 0x1b, 0x21, 0xaa, 0xbb, 0xcc]),
        );
        put(DOT1Q_VLAN_VERSION, &[], SnmpValue::Integer(1));

        // A module (class 9) listed before the chassis must not win.
        put(ENT_PHYSICAL_CLASS, &[1], SnmpValue::Integer(9));
        put(ENT_PHYSICAL_SERIAL_NUM, &[1], octets("MODULE-SN"));
        put(ENT_PHYSICAL_CLASS, &[2], SnmpValue::Integer(3));
        put(ENT_PHYSICAL_SERIAL_NUM, &[2], octets("FDO1234X0YZ "));
        put(ENT_PHYSICAL_MFG_NAME, &[2], octets("Example Networks"));
        put(ENT_PHYSICAL_MODEL_NAME, &[2], octets("EX-48T"));

        for (index, name, mac, status) in [
            (1, "Gi1/0/1", 0x01, 1),
            (2, "Gi1/0/2", 0x02, 2),
            (49, "Te1/1/1", 0x31, 1),
        ] {
            put(
                IF_DESCR,
                &[index],
                octets(&format!("GigabitEthernet{name}")),
            );
            put(IF_NAME, &[index], octets(name));
            put(IF_TYPE, &[index], SnmpValue::Integer(6));
            put(IF_MTU, &[index], SnmpValue::Integer(1500));
            put(IF_SPEED, &[index], SnmpValue::Unsigned(1_000_000_000));
            put(
                IF_HIGH_SPEED,
                &[index],
                SnmpValue::Unsigned(if index == 49 { 10_000 } else { 0 }),
            );
            put(
                IF_PHYS_ADDRESS,
                &[index],
                SnmpValue::Octets(vec![0x00, 0x1b, 0x21, 0xaa, 0xbb, mac]),
            );
            put(IF_OPER_STATUS, &[index], SnmpValue::Integer(status));
            // Bridge ports count from 1 in port order; the uplink is bridge port 3.
            let bridge_port = if index == 49 { 3 } else { index };
            put(
                DOT1D_BASE_PORT_IF_INDEX,
                &[bridge_port],
                SnmpValue::Integer(i64::from(index)),
            );
        }
        put(IF_DESCR, &[100], octets("Vlan10"));
        put(IF_TYPE, &[100], SnmpValue::Integer(53));
        put(IF_OPER_STATUS, &[100], SnmpValue::Integer(1));

        // LLDP local port 49 is named by interface name; port 1 falls back to the ifIndex.
        put(LLDP_LOC_PORT_ID_SUBTYPE, &[49], SnmpValue::Integer(5));
        put(LLDP_LOC_PORT_ID, &[49], octets("Te1/1/1"));
        put(LLDP_LOC_PORT_ID_SUBTYPE, &[1], SnmpValue::Integer(7));
        put(LLDP_LOC_PORT_ID, &[1], octets("1"));
        put(
            LLDP_REM_CHASSIS_ID_SUBTYPE,
            &[0, 49, 1],
            SnmpValue::Integer(4),
        );
        put(
            LLDP_REM_CHASSIS_ID,
            &[0, 49, 1],
            SnmpValue::Octets(vec![0x00, 0x1c, 0x73, 0x01, 0x02, 0x03]),
        );
        put(LLDP_REM_PORT_ID_SUBTYPE, &[0, 49, 1], SnmpValue::Integer(5));
        put(LLDP_REM_PORT_ID, &[0, 49, 1], octets("Ethernet1/49"));
        put(LLDP_REM_PORT_DESC, &[0, 49, 1], octets("to leaf-01"));
        put(LLDP_REM_SYS_NAME, &[0, 49, 1], octets("spine-01"));
        put(
            LLDP_REM_CHASSIS_ID_SUBTYPE,
            &[0, 1, 4],
            SnmpValue::Integer(5),
        );
        put(
            LLDP_REM_CHASSIS_ID,
            &[0, 1, 4],
            SnmpValue::Octets(vec![1, 192, 0, 2, 10]),
        );
        put(LLDP_REM_PORT_ID_SUBTYPE, &[0, 1, 4], SnmpValue::Integer(3));
        put(
            LLDP_REM_PORT_ID,
            &[0, 1, 4],
            SnmpValue::Octets(vec![0x52, 0x54, 0x00, 0x12, 0x34, 0x56]),
        );

        // VLAN 10 is untagged on ports 1 and 2 and tagged on the uplink; VLAN 20 only rides the
        // uplink. Bitmap: ports 1, 2, and 3 are 0b1110_0000.
        put(
            DOT1Q_VLAN_CURRENT_EGRESS_PORTS,
            &[0, 10],
            SnmpValue::Octets(vec![0b1110_0000]),
        );
        put(
            DOT1Q_VLAN_CURRENT_UNTAGGED_PORTS,
            &[0, 10],
            SnmpValue::Octets(vec![0b1100_0000]),
        );
        put(
            DOT1Q_VLAN_CURRENT_EGRESS_PORTS,
            &[0, 20],
            SnmpValue::Octets(vec![0b0010_0000]),
        );
        put(
            DOT1Q_VLAN_CURRENT_UNTAGGED_PORTS,
            &[0, 20],
            SnmpValue::Octets(vec![0]),
        );
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
    fn identifies_the_switch_by_its_chassis_serial() {
        let (resource, support) = switch("10.0.0.1", &answers(), 2_700).unwrap();

        assert_eq!(resource.kind, CollectorResourceKind::Switch);
        assert_eq!(resource.target.as_deref(), Some("10.0.0.1"));
        assert_eq!(
            resource.identifiers.serial_number.as_deref(),
            Some("FDO1234X0YZ")
        );
        assert_eq!(resource.identifiers.hostname.as_deref(), Some("leaf-01"));
        assert_eq!(resource.identifiers.mac_address, ["00:1b:21:aa:bb:cc"]);
        let attributes = resource.attributes.as_ref().unwrap();
        assert_eq!(attributes.vendor.as_deref(), Some("Example Networks"));
        assert_eq!(attributes.model.as_deref(), Some("EX-48T"));
        assert_eq!(
            support,
            Support {
                lldp: true,
                q_bridge: true
            }
        );
    }

    #[test]
    fn reports_interfaces_from_if_mib() {
        let (resource, _) = switch("10.0.0.1", &answers(), 2_700).unwrap();

        let access = interface(&resource, "Gi1/0/1");
        assert_eq!(access.kind, "ethernet");
        assert_eq!(access.status, "up");
        assert_eq!(access.mac_address.as_deref(), Some("00:1b:21:aa:bb:01"));
        assert_eq!(access.mtu, Some(1500));
        assert_eq!(access.speed_mbps, Some(1_000));
        assert_eq!(interface(&resource, "Gi1/0/2").status, "down");
        assert_eq!(interface(&resource, "Te1/1/1").speed_mbps, Some(10_000));
        // Without ifName, the description names the interface.
        assert_eq!(interface(&resource, "Vlan10").kind, "virtual");
    }

    #[test]
    fn attaches_lldp_neighbors_to_their_local_ports() {
        let (resource, _) = switch("10.0.0.1", &answers(), 2_700).unwrap();

        let uplink = interface(&resource, "Te1/1/1").neighbors.as_ref().unwrap();
        assert_eq!(
            uplink,
            &[Neighbor {
                protocol: "lldp",
                remote_chassis_id: "00:1c:73:01:02:03".into(),
                remote_chassis_id_kind: "mac_address",
                remote_port_id: "Ethernet1/49".into(),
                remote_port_id_kind: "name",
                remote_system_name: Some("spine-01".into()),
                remote_port_description: Some("to leaf-01".into()),
                ttl_seconds: 2_700,
            }]
        );
        let host = &interface(&resource, "Gi1/0/1").neighbors.as_ref().unwrap()[0];
        assert_eq!(host.remote_chassis_id, "192.0.2.10");
        assert_eq!(host.remote_chassis_id_kind, "network_address");
        assert_eq!(host.remote_port_id, "52:54:00:12:34:56");
        assert_eq!(host.remote_port_id_kind, "mac_address");
        // LLDP answered, so a port without neighbors says so.
        assert_eq!(interface(&resource, "Gi1/0/2").neighbors, Some(vec![]));
    }

    #[test]
    fn maps_vlan_membership_through_bridge_ports() {
        let (resource, _) = switch("10.0.0.1", &answers(), 2_700).unwrap();

        let access = interface(&resource, "Gi1/0/2");
        assert_eq!(access.vlan_mode.as_deref(), Some("access"));
        assert_eq!(
            access.vlans,
            Some(vec![VlanMembership {
                vid: 10,
                tagging_mode: TaggingMode::Untagged
            }])
        );
        let uplink = interface(&resource, "Te1/1/1");
        assert_eq!(uplink.vlan_mode.as_deref(), Some("trunk"));
        assert_eq!(
            uplink.vlans,
            Some(vec![
                VlanMembership {
                    vid: 10,
                    tagging_mode: TaggingMode::Tagged
                },
                VlanMembership {
                    vid: 20,
                    tagging_mode: TaggingMode::Tagged
                },
            ])
        );
        assert_eq!(interface(&resource, "Vlan10").vlans, Some(vec![]));
    }

    #[test]
    fn leaves_sections_unclaimed_when_their_mib_is_missing() {
        let mut answers = answers();
        answers.insert(LLDP_LOC_CHASSIS_ID.to_vec(), SnmpValue::Missing);
        answers.0.remove(DOT1Q_VLAN_VERSION);
        let (resource, support) = switch("10.0.0.1", &answers, 2_700).unwrap();

        assert_eq!(
            support,
            Support {
                lldp: false,
                q_bridge: false
            }
        );
        let uplink = interface(&resource, "Te1/1/1");
        assert_eq!(uplink.neighbors, None);
        assert_eq!(uplink.vlans, None);
    }

    #[test]
    fn refuses_a_switch_without_a_chassis_serial() {
        let mut answers = answers();
        answers.insert(oid(ENT_PHYSICAL_SERIAL_NUM, &[2]), octets("  "));
        assert!(switch("10.0.0.1", &answers, 2_700)
            .unwrap_err()
            .0
            .contains("chassis serial"));
    }

    #[test]
    fn reads_port_lists_most_significant_bit_first() {
        assert_eq!(
            port_list(&[0b1000_0001, 0b0100_0000]),
            BTreeSet::from([1, 8, 10])
        );
    }
}
