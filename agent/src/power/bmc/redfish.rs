//! Turns what a BMC's Redfish service answered into its server and power readings (RFD 10,
//! "Collectors and BMCs").
//!
//! Everything here is pure, so the mapping is tested from recorded resources. The module reads
//! the first computer system the service lists, that system's chassis, and the chassis's `Power`
//! resource: the system's own draw from the chassis's one whole-chassis power control, and each
//! installed supply's input, output, and condition.
//!
//! Readings are attributed to the system only when its chassis is its own. A chassis that holds
//! several systems, such as a multi-node enclosure, shares its supplies between them, so its
//! power is not one server's and is not reported.

use crate::{
    exporters::mapping::supply_sensor,
    payload::{CollectorIdentifiers, CollectorResource, CollectorResourceKind, HostAttributes},
    power::collector::{Device, Measurement, Reading},
};
use serde_json::Value;

pub const MAPPING: &str = "redfish_power";
pub const MAPPING_VERSION: u32 = 1;
pub const SYSTEMS: &str = "/redfish/v1/Systems";
pub const CHASSIS: &str = "/redfish/v1/Chassis";

/// Why an answering BMC cannot be reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapError(pub String);

/// The `@odata.id` of a collection's first member.
pub fn first_member(collection: &Value, what: &str) -> Result<String, MapError> {
    collection["Members"]
        .get(0)
        .and_then(odata_id)
        .ok_or_else(|| MapError(format!("the BMC lists no {what}")))
}

/// The chassis the system links to, if it links to one.
pub fn chassis_link(system: &Value) -> Option<String> {
    system["Links"]["Chassis"].get(0).and_then(odata_id)
}

/// The chassis's `Power` resource.
pub fn power_link(chassis: &Value) -> Result<String, MapError> {
    odata_id(&chassis["Power"]).ok_or_else(|| MapError("the chassis has no Power resource".into()))
}

fn odata_id(value: &Value) -> Option<String> {
    value["@odata.id"].as_str().map(str::to_owned)
}

/// Whether `chassis`'s power is `system`'s alone. `linked` says the system named this chassis
/// itself; otherwise the chassis must name the system as its only one.
pub fn owns(system: &Value, chassis: &Value, linked: bool) -> bool {
    let members: Option<Vec<String>> = chassis["Links"]["ComputerSystems"]
        .as_array()
        .map(|systems| systems.iter().filter_map(odata_id).collect());
    match members {
        Some(members) if members.len() > 1 => false,
        Some(members) if !linked => {
            members.len() == 1 && odata_id(system).is_some_and(|id| members[0] == id)
        }
        _ => linked,
    }
}

/// The server behind `system`, with the readings of its chassis's `power` resource.
pub fn device(system: &Value, power: &Value) -> Result<Device, MapError> {
    let text = |key: &str| {
        system[key]
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    // SMBIOS reports the same UUID to the host agent, so it matches the server either sees.
    let dmi_uuid = text("UUID")
        .filter(|uuid| uuid::Uuid::parse_str(uuid).is_ok_and(|parsed| !parsed.is_nil()))
        .map(|uuid| uuid.to_ascii_lowercase());
    // Some vendors serve a serial here that SMBIOS does not, so it identifies the server only
    // when nothing better does.
    let serial_number = text("SerialNumber").filter(|_| dmi_uuid.is_none());
    if dmi_uuid.is_none() && serial_number.is_none() {
        return Err(MapError(
            "the computer system has neither a UUID nor a serial number".into(),
        ));
    }
    Ok(Device {
        mapping: MAPPING,
        mapping_version: MAPPING_VERSION,
        resource: CollectorResource {
            kind: CollectorResourceKind::Server,
            target: None,
            identifiers: CollectorIdentifiers {
                hostname: text("HostName"),
                serial_number,
                dmi_uuid,
                ..CollectorIdentifiers::default()
            },
            attributes: Some(HostAttributes {
                vendor: text("Manufacturer"),
                model: text("Model"),
                ..HostAttributes::default()
            }),
            interfaces: None,
            domain: None,
        },
        readings: readings(power),
    })
}

/// The system's draw and each installed supply's readings.
pub fn readings(power: &Value) -> Vec<Reading> {
    let mut readings = Vec::new();
    if let Some((index, control)) = whole_chassis_control(power) {
        let member = control["MemberId"]
            .as_str()
            .map(str::trim)
            .filter(|id| !id.is_empty())
            .map_or_else(|| index.to_string(), str::to_owned);
        readings.push(Reading {
            sensor: format!("power_control/{member}"),
            boundary: "host_input",
            quantity: "real_power",
            component: None,
            leg: None,
            measurement: watts(&control["PowerConsumedWatts"]),
        });
    }
    let supplies = power["PowerSupplies"]
        .as_array()
        .map_or(&[][..], Vec::as_slice);
    for (index, supply) in supplies.iter().enumerate() {
        if supply["Status"]["State"] == "Absent" {
            continue;
        }
        let name = supply_name(supply, index);
        let component = || Some(("power_port", name.clone()));
        let mut read = |key: &str, boundary: &'static str, quantity, measurement| {
            if supply.get(key).is_some() {
                readings.push(Reading {
                    sensor: format!("{name}/{}", boundary.trim_start_matches("supply_")),
                    boundary,
                    quantity,
                    component: component(),
                    leg: None,
                    measurement,
                });
            }
        };
        read(
            "PowerInputWatts",
            "supply_input",
            "real_power",
            watts(&supply["PowerInputWatts"]),
        );
        // `LastPowerOutputWatts` is an average over a period Redfish does not give, so only the
        // instantaneous output is read.
        read(
            "PowerOutputWatts",
            "supply_output",
            "real_power",
            watts(&supply["PowerOutputWatts"]),
        );
        read("Status", "supply_input", "state", supply_state(supply));
    }
    readings
}

/// The power control that measures the whole chassis: one that reports consumption and names no
/// narrower physical context, such as a CPU or memory. Several such controls are ambiguous, so
/// none is chosen.
fn whole_chassis_control(power: &Value) -> Option<(usize, &Value)> {
    let mut whole = power["PowerControl"]
        .as_array()?
        .iter()
        .enumerate()
        .filter(|(_, control)| control.get("PowerConsumedWatts").is_some())
        .filter(|(_, control)| {
            matches!(
                control["PhysicalContext"].as_str(),
                None | Some("Chassis") | Some("SystemBoard")
            )
        });
    let control = whole.next()?;
    whole.next().is_none().then_some(control)
}

/// A finite, non-negative wattage; anything else, `null` included, is a failed reading.
fn watts(value: &Value) -> Measurement {
    match value.as_f64() {
        Some(watts) if watts.is_finite() && watts >= 0.0 => Measurement::Value(watts),
        _ => Measurement::Failed,
    }
}

/// A supply with no line voltage has lost its feed; otherwise its health says how it is.
fn supply_state(supply: &Value) -> Measurement {
    if supply["LineInputVoltage"].as_f64() == Some(0.0) {
        return Measurement::State("no_input");
    }
    match supply["Status"]["Health"].as_str() {
        Some("OK") => Measurement::State("ok"),
        Some("Warning") => Measurement::State("warning"),
        Some("Critical") => Measurement::State("failed"),
        _ => Measurement::Failed,
    }
}

/// The supply as `PSU<n>`, the way Renga names a server's power ports: from a name such as
/// `PS1 Status` or `Power Supply Bay 2`, else from a member ID such as `PSU.Slot.1`, else from
/// its position, since a numeric member ID counts from zero on some BMCs and from one on others.
fn supply_name(supply: &Value, index: usize) -> String {
    let name = supply["Name"].as_str().unwrap_or_default();
    if let Some((name, _boundary)) = supply_sensor(name) {
        return name;
    }
    let member_id = supply["MemberId"].as_str().unwrap_or_default();
    let numbered = [name, member_id]
        .into_iter()
        .filter(|text| !text.bytes().all(|byte| byte.is_ascii_digit()))
        .find_map(last_number);
    format!("PSU{}", numbered.unwrap_or(index as u64 + 1))
}

fn last_number(text: &str) -> Option<u64> {
    let digits: String = text
        .chars()
        .rev()
        .skip_while(|char| !char.is_ascii_digit())
        .take_while(char::is_ascii_digit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    digits.parse().ok()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;

    /// A Dell iDRAC 9, as its Redfish service answers, trimmed to what the module reads.
    pub(crate) fn idrac() -> BTreeMap<&'static str, Value> {
        BTreeMap::from([
            (
                SYSTEMS,
                json!({
                    "@odata.id": "/redfish/v1/Systems",
                    "Members": [{"@odata.id": "/redfish/v1/Systems/System.Embedded.1"}],
                    "Members@odata.count": 1
                }),
            ),
            (
                "/redfish/v1/Systems/System.Embedded.1",
                json!({
                    "@odata.id": "/redfish/v1/Systems/System.Embedded.1",
                    "Id": "System.Embedded.1",
                    "HostName": "r1-07",
                    "Manufacturer": "Dell Inc.",
                    "Model": "PowerEdge R650",
                    "SerialNumber": "CNIVC0012K0042",
                    "SKU": "B5RTM42",
                    "UUID": "4C4C4544-0042-3510-8052-B4C04F4C4D32",
                    "Links": {
                        "Chassis": [{"@odata.id": "/redfish/v1/Chassis/System.Embedded.1"}]
                    }
                }),
            ),
            (
                "/redfish/v1/Chassis/System.Embedded.1",
                json!({
                    "@odata.id": "/redfish/v1/Chassis/System.Embedded.1",
                    "Power": {"@odata.id": "/redfish/v1/Chassis/System.Embedded.1/Power"}
                }),
            ),
            (
                "/redfish/v1/Chassis/System.Embedded.1/Power",
                json!({
                    "PowerControl": [{
                        "MemberId": "PowerControl",
                        "Name": "System Power Control",
                        "PowerConsumedWatts": 312
                    }],
                    "PowerSupplies": [
                        {
                            "MemberId": "PSU.Slot.1",
                            "Name": "PS1 Status",
                            "PowerInputWatts": 172.0,
                            "PowerOutputWatts": 156,
                            "LastPowerOutputWatts": 150,
                            "LineInputVoltage": 230,
                            "Status": {"State": "Enabled", "Health": "OK"}
                        },
                        {
                            "MemberId": "PSU.Slot.2",
                            "Name": "PS2 Status",
                            "PowerInputWatts": null,
                            "PowerOutputWatts": 0,
                            "LineInputVoltage": 0,
                            "Status": {"State": "Enabled", "Health": "Critical"}
                        }
                    ]
                }),
            ),
        ])
    }

    fn find<'a>(readings: &'a [Reading], sensor: &str, quantity: &str) -> &'a Reading {
        readings
            .iter()
            .find(|reading| reading.sensor == sensor && reading.quantity == quantity)
            .unwrap_or_else(|| panic!("no {sensor} {quantity} in {readings:#?}"))
    }

    #[test]
    fn maps_a_dell_server_by_its_smbios_uuid() {
        let idrac = idrac();
        let device = device(
            &idrac["/redfish/v1/Systems/System.Embedded.1"],
            &idrac["/redfish/v1/Chassis/System.Embedded.1/Power"],
        )
        .unwrap();

        assert_eq!(
            serde_json::to_value(&device.resource).unwrap(),
            json!({
                "kind": "server",
                "identifiers": {
                    "hostname": "r1-07",
                    "dmi_uuid": "4c4c4544-0042-3510-8052-b4c04f4c4d32"
                },
                "attributes": {"vendor": "Dell Inc.", "model": "PowerEdge R650"}
            })
        );
        let readings = &device.readings;
        assert_eq!(
            find(readings, "power_control/PowerControl", "real_power").measurement,
            Measurement::Value(312.0)
        );
        let input = find(readings, "PSU1/input", "real_power");
        assert_eq!(input.boundary, "supply_input");
        assert_eq!(input.component, Some(("power_port", "PSU1".into())));
        assert_eq!(input.measurement, Measurement::Value(172.0));
        assert_eq!(
            find(readings, "PSU1/output", "real_power").measurement,
            Measurement::Value(156.0)
        );
        assert_eq!(
            find(readings, "PSU1/input", "state").measurement,
            Measurement::State("ok")
        );
        // A supply without line voltage has lost its feed; its unread input is not zero.
        assert_eq!(
            find(readings, "PSU2/input", "state").measurement,
            Measurement::State("no_input")
        );
        assert_eq!(
            find(readings, "PSU2/input", "real_power").measurement,
            Measurement::Failed
        );
        assert_eq!(readings.len(), 7);
    }

    #[test]
    fn falls_back_to_the_serial_number_without_a_uuid() {
        let system =
            json!({"SerialNumber": "MXQ12345", "UUID": "00000000-0000-0000-0000-000000000000"});
        let device = device(&system, &json!({})).unwrap();
        assert_eq!(
            device.resource.identifiers.serial_number.as_deref(),
            Some("MXQ12345")
        );
        assert_eq!(device.resource.identifiers.dmi_uuid, None);
        assert!(device.readings.is_empty());

        assert!(device_error(&json!({"Model": "x"})).contains("neither a UUID nor a serial number"));
    }

    fn device_error(system: &Value) -> String {
        device(system, &json!({})).unwrap_err().0
    }

    #[test]
    fn host_input_comes_only_from_one_whole_chassis_control() {
        let host = |controls: Value| -> Vec<(String, Measurement)> {
            readings(&json!({"PowerControl": controls}))
                .into_iter()
                .map(|reading| (reading.sensor, reading.measurement))
                .collect()
        };
        // A component's control listed first is not the host's draw.
        assert_eq!(
            host(json!([
                {"MemberId": "cpu", "PhysicalContext": "CPU", "PowerConsumedWatts": 90},
                {"MemberId": "0", "PhysicalContext": "Chassis", "PowerConsumedWatts": 312}
            ])),
            [("power_control/0".to_owned(), Measurement::Value(312.0))]
        );
        // Without a MemberId the position names it.
        assert_eq!(
            host(json!([{"PowerConsumedWatts": 200}])),
            [("power_control/0".to_owned(), Measurement::Value(200.0))]
        );
        // Two candidates, or only components, say nothing about the whole host.
        assert!(host(json!([
            {"MemberId": "a", "PowerConsumedWatts": 100},
            {"MemberId": "b", "PowerConsumedWatts": 120}
        ]))
        .is_empty());
        assert!(host(json!([
            {"MemberId": "mem", "PhysicalContext": "Memory", "PowerConsumedWatts": 20}
        ]))
        .is_empty());
    }

    #[test]
    fn a_chassis_is_a_systems_own_only_when_nothing_else_shares_it() {
        let system = json!({"@odata.id": "/redfish/v1/Systems/1"});
        let listing = |systems: &[&str]| {
            json!({"Links": {"ComputerSystems": systems
                .iter()
                .map(|id| json!({"@odata.id": id}))
                .collect::<Vec<_>>()}})
        };
        assert!(owns(&system, &json!({}), true));
        assert!(owns(&system, &listing(&["/redfish/v1/Systems/1"]), true));
        assert!(owns(&system, &listing(&["/redfish/v1/Systems/1"]), false));
        // A multi-node enclosure shares its supplies.
        let shared = listing(&["/redfish/v1/Systems/1", "/redfish/v1/Systems/2"]);
        assert!(!owns(&system, &shared, true));
        // A chassis found without the system's link must name the system.
        assert!(!owns(&system, &json!({}), false));
        assert!(!owns(&system, &listing(&["/redfish/v1/Systems/2"]), false));
    }

    #[test]
    fn supply_output_is_the_instantaneous_reading_not_the_average() {
        let power = json!({"PowerSupplies": [
            {"Name": "PS1", "PowerOutputWatts": 156, "LastPowerOutputWatts": 150,
             "Status": {"State": "Enabled", "Health": "OK"}},
            {"Name": "PS2", "LastPowerOutputWatts": 150,
             "Status": {"State": "Enabled", "Health": "OK"}}
        ]});
        let outputs: Vec<_> = readings(&power)
            .into_iter()
            .filter(|reading| reading.boundary == "supply_output")
            .map(|reading| (reading.sensor, reading.measurement))
            .collect();
        assert_eq!(
            outputs,
            [("PSU1/output".to_owned(), Measurement::Value(156.0))]
        );
    }

    #[test]
    fn skips_absent_supplies_and_names_the_rest_as_renga_does() {
        let power = json!({
            "PowerSupplies": [
                {"MemberId": "0", "Name": "HpeServerPowerSupply", "PowerInputWatts": 120,
                 "Status": {"State": "Enabled", "Health": "Warning"}},
                {"MemberId": "1", "Name": "HpeServerPowerSupply",
                 "Status": {"State": "Absent"}},
                {"MemberId": "2", "Name": "Power Supply Bay 3", "PowerInputWatts": 98,
                 "Status": {"State": "Enabled"}}
            ]
        });
        let readings = readings(&power);
        let names: Vec<_> = readings
            .iter()
            .map(|reading| (reading.sensor.as_str(), reading.quantity))
            .collect();
        assert_eq!(
            names,
            [
                ("PSU1/input", "real_power"),
                ("PSU1/input", "state"),
                ("PSU3/input", "real_power"),
                ("PSU3/input", "state"),
            ]
        );
        assert_eq!(readings[1].measurement, Measurement::State("warning"));
        // A supply that reports no health has an unknown condition.
        assert_eq!(readings[3].measurement, Measurement::Failed);
    }

    #[test]
    fn follows_links_only_where_the_service_names_them() {
        let idrac = idrac();
        assert_eq!(
            first_member(&idrac[SYSTEMS], "computer system").unwrap(),
            "/redfish/v1/Systems/System.Embedded.1"
        );
        assert_eq!(
            first_member(&json!({"Members": []}), "computer system")
                .unwrap_err()
                .0,
            "the BMC lists no computer system"
        );
        assert_eq!(chassis_link(&json!({})), None);
        assert!(power_link(&json!({"PowerSubsystem": {}})).is_err());
    }
}
