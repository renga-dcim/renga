//! The fixed, versioned mapping from exporter metrics to power readings (RFD 10, "Local
//! Prometheus exporters"). Everything else an exporter serves stays in Prometheus.
//!
//! * node_exporter (`node_exporter` v1): hwmon power, mapped by the same driver rules as the
//!   agent's own hwmon source, so a GPU's or regulator's watts stay unmapped.
//! * ipmi_exporter (`ipmi_exporter` v1): the DCMI power reading as host input; power sensors
//!   named for a supply (`PSU1 Input`, `PS2 POUT`) as that supply's input or output; and
//!   power-supply sensor states as the supply's status.

use super::text::Sample;
use crate::power::hwmon::{self, Boundary};
use std::collections::BTreeMap;

pub const NODE_EXPORTER: &str = "node_exporter";
pub const IPMI_EXPORTER: &str = "ipmi_exporter";
pub const MAPPING_VERSION: u32 = 1;

const NODE_CHIP_NAMES: &str = "node_hwmon_chip_names";
const NODE_SENSOR_LABEL: &str = "node_hwmon_sensor_label";
const NODE_AVERAGE_INTERVAL: &str = "node_hwmon_power_average_interval_seconds";
const IPMI_DCMI: &str = "ipmi_dcmi_power_consumption_watts";
const IPMI_POWER: &str = "ipmi_power_watts";
const IPMI_STATE: &str = "ipmi_sensor_state";

/// A mapped reading. `measurement` is watts, or a supply's state.
#[derive(Debug, Clone, PartialEq)]
pub struct Reading {
    pub mapping: &'static str,
    pub sensor: String,
    pub boundary: Boundary,
    pub supply: Option<String>,
    pub measurement: Measurement,
    pub window_seconds: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Measurement {
    /// `None` when the exporter served a value that is not a reading, such as NaN.
    Watts(Option<f64>),
    State(&'static str),
}

/// The metric names any mapping reads, so the parser can drop the rest early.
pub fn wanted(name: &str) -> bool {
    matches!(
        name,
        NODE_CHIP_NAMES
            | NODE_SENSOR_LABEL
            | NODE_AVERAGE_INTERVAL
            | IPMI_DCMI
            | IPMI_POWER
            | IPMI_STATE
    ) || node_power_element(name).is_some()
}

/// `node_hwmon_power_<element>_watt`, in either spelling node_exporter has used.
fn node_power_element(name: &str) -> Option<&str> {
    let element = name.strip_prefix("node_hwmon_power_")?;
    let element = element
        .strip_suffix("_watts")
        .or_else(|| element.strip_suffix("_watt"))?;
    matches!(element, "average" | "input").then_some(element)
}

pub fn map(samples: &[Sample]) -> Vec<Reading> {
    let mut readings = node_exporter(samples);
    readings.extend(ipmi_exporter(samples));
    readings
}

fn node_exporter(samples: &[Sample]) -> Vec<Reading> {
    let label = |sample: &Sample, key: &str| sample.labels.get(key).cloned().unwrap_or_default();
    let drivers: BTreeMap<String, String> = samples
        .iter()
        .filter(|sample| sample.name == NODE_CHIP_NAMES)
        .map(|sample| (label(sample, "chip"), label(sample, "chip_name")))
        .collect();
    let keyed = |name: &str| -> BTreeMap<(String, String), &Sample> {
        samples
            .iter()
            .filter(|sample| sample.name == name)
            .map(|sample| ((label(sample, "chip"), label(sample, "sensor")), sample))
            .collect()
    };
    let labels = keyed(NODE_SENSOR_LABEL);
    let intervals = keyed(NODE_AVERAGE_INTERVAL);

    // An averaged reading replaces the instantaneous one for the same sensor.
    let mut power: BTreeMap<(String, String), (&str, &Sample)> = BTreeMap::new();
    for sample in samples {
        if let Some(element) = node_power_element(&sample.name) {
            let key = (label(sample, "chip"), label(sample, "sensor"));
            if element == "average" || !power.contains_key(&key) {
                power.insert(key, (element, sample));
            }
        }
    }

    power
        .into_iter()
        .filter_map(|((chip, sensor), (element, sample))| {
            let driver = drivers
                .get(&chip)
                .map(String::as_str)
                .or_else(|| power_meter_chip(&chip).then_some(hwmon::POWER_METER))?;
            let sensor_label = labels
                .get(&(chip.clone(), sensor.clone()))
                .and_then(|label| label.labels.get("label").cloned());
            let boundary = hwmon::boundary(driver, sensor_label)?;
            let window_seconds = if element == "average" {
                intervals
                    .get(&(chip.clone(), sensor.clone()))
                    .map_or(0.0, |interval| interval.value)
            } else {
                0.0
            };
            Some(Reading {
                mapping: NODE_EXPORTER,
                sensor: format!("{NODE_EXPORTER}/{chip}/{sensor}"),
                boundary,
                supply: None,
                measurement: Measurement::Watts(watts(sample.value)),
                window_seconds: if window_seconds.is_finite() && window_seconds > 0.0 {
                    window_seconds
                } else {
                    0.0
                },
            })
        })
        .collect()
}

/// Whether node_exporter's `chip` names an ACPI power meter. Its hwmon device has no `name`,
/// so node_exporter reports no `chip_name` for it; the chip is named for its device path's last
/// two components, lowercased, such as `lnxsybus:00_acpi000d:00`.
fn power_meter_chip(chip: &str) -> bool {
    chip.rsplit('_')
        .next()
        .is_some_and(|device| device.starts_with("acpi000d:"))
}

fn ipmi_exporter(samples: &[Sample]) -> Vec<Reading> {
    let id = |sample: &Sample| sample.labels.get("id").cloned().unwrap_or_default();
    let name = |sample: &Sample| sample.labels.get("name").cloned().unwrap_or_default();
    samples
        .iter()
        .filter_map(|sample| match sample.name.as_str() {
            IPMI_DCMI => Some(Reading {
                mapping: IPMI_EXPORTER,
                sensor: format!("{IPMI_EXPORTER}/dcmi"),
                boundary: Boundary::HostInput,
                supply: None,
                measurement: Measurement::Watts(watts(sample.value)),
                window_seconds: 0.0,
            }),
            IPMI_POWER => {
                let (supply, direction) = supply_sensor(&name(sample))?;
                Some(Reading {
                    mapping: IPMI_EXPORTER,
                    sensor: format!("{IPMI_EXPORTER}/sensor/{}", id(sample)),
                    boundary: direction?,
                    supply: Some(supply),
                    measurement: Measurement::Watts(watts(sample.value)),
                    window_seconds: 0.0,
                })
            }
            IPMI_STATE if sample.labels.get("type").map(String::as_str) == Some("Power Supply") => {
                let (supply, _direction) = supply_sensor(&name(sample))?;
                Some(Reading {
                    mapping: IPMI_EXPORTER,
                    sensor: format!("{IPMI_EXPORTER}/sensor/{}", id(sample)),
                    boundary: Boundary::SupplyInput,
                    supply: Some(supply),
                    measurement: Measurement::State(supply_state(sample.value)),
                    window_seconds: 0.0,
                })
            }
            _ => None,
        })
        .collect()
}

/// A finite, non-negative wattage; anything else is not a reading.
fn watts(value: f64) -> Option<f64> {
    (value.is_finite() && value >= 0.0).then_some(value)
}

/// ipmi_exporter's sensor state: 0 nominal, 1 warning, 2 critical.
fn supply_state(value: f64) -> &'static str {
    match value {
        0.0 => "ok",
        1.0 => "warning",
        _ => "failed",
    }
}

/// The supply a sensor name refers to as `PSU<n>`, and whether it measures the supply's input
/// or output. `PS1`, `PSU 1`, and `PSU1` all name the first supply.
fn supply_sensor(name: &str) -> Option<(String, Option<Boundary>)> {
    let upper = name.trim().to_ascii_uppercase();
    let rest = upper
        .strip_prefix("PSU")
        .or_else(|| upper.strip_prefix("PS"))?
        .trim_start();
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() {
        return None;
    }
    let words: Vec<&str> = rest[digits.len()..]
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect();
    let direction = if words
        .iter()
        .any(|word| matches!(*word, "IN" | "INPUT" | "PIN"))
    {
        Some(Boundary::SupplyInput)
    } else if words
        .iter()
        .any(|word| matches!(*word, "OUT" | "OUTPUT" | "POUT"))
    {
        Some(Boundary::SupplyOutput)
    } else {
        None
    };
    let number = digits.trim_start_matches('0');
    Some((
        format!("PSU{}", if number.is_empty() { "0" } else { number }),
        direction,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::exporters::text::{parse, Limits};

    fn readings(text: &str) -> Vec<Reading> {
        map(&parse(text, Limits::default(), wanted).unwrap())
    }

    #[test]
    fn maps_node_exporter_hwmon_power_by_driver() {
        let text = r#"
node_hwmon_chip_names{chip="pci0000:00_0000:03:00_0",chip_name="amdgpu"} 1
node_hwmon_power_average_interval_seconds{chip="lnxsybus:00_acpi000d:00",sensor="power1"} 1
node_hwmon_power_average_watt{chip="lnxsybus:00_acpi000d:00",sensor="power1"} 245.5
node_hwmon_power_input_watt{chip="lnxsybus:00_acpi000d:00",sensor="power1"} 250
node_hwmon_power_average_watt{chip="pci0000:00_0000:03:00_0",sensor="power1"} 90
node_hwmon_power_input_watt{chip="unknown_chip",sensor="power1"} 10
"#;
        assert_eq!(
            readings(text),
            [Reading {
                mapping: NODE_EXPORTER,
                sensor: "node_exporter/lnxsybus:00_acpi000d:00/power1".into(),
                boundary: Boundary::HostInput,
                supply: None,
                measurement: Measurement::Watts(Some(245.5)),
                window_seconds: 1.0,
            }]
        );
    }

    #[test]
    fn maps_node_exporter_supply_sensors_by_label() {
        let text = r#"
node_hwmon_chip_names{chip="i2c_3_3_0068",chip_name="ibm_cffps1"} 1
node_hwmon_sensor_label{chip="i2c_3_3_0068",label="pin",sensor="power1"} 1
node_hwmon_sensor_label{chip="i2c_3_3_0068",label="pout1",sensor="power2"} 1
node_hwmon_power_input_watts{chip="i2c_3_3_0068",sensor="power1"} 512
node_hwmon_power_input_watts{chip="i2c_3_3_0068",sensor="power2"} 480
"#;
        let boundaries: Vec<_> = readings(text)
            .iter()
            .map(|reading| reading.boundary)
            .collect();
        assert_eq!(boundaries, [Boundary::SupplyInput, Boundary::SupplyOutput]);
    }

    #[test]
    fn maps_ipmi_exporter_dcmi_supply_power_and_supply_state() {
        let text = r#"
ipmi_dcmi_power_consumption_watts 312
ipmi_power_watts{id="98",name="PSU1 Input"} 151
ipmi_power_watts{id="99",name="PS2 POUT"} 140
ipmi_power_watts{id="100",name="Pwr Consumption"} 312
ipmi_power_watts{id="101",name="PSU3"} 1
ipmi_sensor_state{id="120",name="PS2 Status",type="Power Supply"} 2
ipmi_sensor_state{id="121",name="CPU1 Temp",type="Temperature"} 0
ipmi_sensor_state{id="122",name="PSU 01 Status",type="Power Supply"} 0
"#;
        let readings = readings(text);
        let summary: Vec<_> = readings
            .iter()
            .map(|reading| {
                (
                    reading.sensor.as_str(),
                    reading.boundary,
                    reading.supply.as_deref(),
                    reading.measurement.clone(),
                )
            })
            .collect();
        assert_eq!(
            summary,
            [
                (
                    "ipmi_exporter/dcmi",
                    Boundary::HostInput,
                    None,
                    Measurement::Watts(Some(312.0))
                ),
                (
                    "ipmi_exporter/sensor/98",
                    Boundary::SupplyInput,
                    Some("PSU1"),
                    Measurement::Watts(Some(151.0))
                ),
                (
                    "ipmi_exporter/sensor/99",
                    Boundary::SupplyOutput,
                    Some("PSU2"),
                    Measurement::Watts(Some(140.0))
                ),
                (
                    "ipmi_exporter/sensor/120",
                    Boundary::SupplyInput,
                    Some("PSU2"),
                    Measurement::State("failed")
                ),
                (
                    "ipmi_exporter/sensor/122",
                    Boundary::SupplyInput,
                    Some("PSU1"),
                    Measurement::State("ok")
                ),
            ]
        );
    }

    #[test]
    fn a_value_that_is_not_a_reading_is_not_zero() {
        let readings = readings("ipmi_dcmi_power_consumption_watts NaN\n");
        assert_eq!(readings[0].measurement, Measurement::Watts(None));
        assert_eq!(watts(-1.0), None);
        assert_eq!(watts(f64::INFINITY), None);
    }

    #[test]
    fn supply_names_normalize() {
        assert_eq!(
            supply_sensor("psu1 pin"),
            Some(("PSU1".into(), Some(Boundary::SupplyInput)))
        );
        assert_eq!(
            supply_sensor("PS 2 Output"),
            Some(("PSU2".into(), Some(Boundary::SupplyOutput)))
        );
        assert_eq!(supply_sensor("PSU1 Status"), Some(("PSU1".into(), None)));
        assert_eq!(supply_sensor("PSUX"), None);
        assert_eq!(supply_sensor("Pwr Consumption"), None);
    }
}
