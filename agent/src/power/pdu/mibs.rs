//! Turns what a PDU answered into its identity and power readings (RFD 10, "Collectors and
//! BMCs").
//!
//! Everything here is pure, so each vendor MIB is tested from recorded answers. Two fixed
//! mappings exist, chosen by the device's `sysObjectID`: Raritan's `PDU2-MIB` and APC's
//! `PowerNet-MIB` rack PDU tables (`rPDU2`). Only the first unit of a daisy chain is read, since
//! the others are separate PDUs that this target does not identify.

use crate::{
    power::collector::{Measurement, Reading},
    snmp::mibs::{integer, text, Answers, SnmpValue, SYS_NAME},
};
use std::collections::BTreeMap;

pub const MAPPING_VERSION: u32 = 1;
pub const SYS_OBJECT_ID: &[u32] = &[1, 3, 6, 1, 2, 1, 1, 2, 0];
/// Scalars read before the vendor is known.
pub const SCALARS: &[&[u32]] = &[SYS_OBJECT_ID, SYS_NAME];

const RARITAN: &[u32] = &[1, 3, 6, 1, 4, 1, 13742];
const APC: &[u32] = &[1, 3, 6, 1, 4, 1, 318];
/// Far more than any PDU meters; a device answering more is refused rather than reported.
pub const MAX_READINGS: usize = 1_000;

// Raritan PDU2-MIB. Rows are indexed by pduId first; only pduId 1 is read.
const PX_MANUFACTURER: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 2, 1, 1, 2];
const PX_MODEL: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 2, 1, 1, 3];
const PX_SERIAL: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 2, 1, 1, 4];
const PX_INLET_LABEL: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 3, 3, 1, 2];
const PX_INLET_POLE_LINE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 3, 5, 1, 1];
const PX_INLET_DIGITS: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 3, 4, 1, 7];
const PX_INLET_POLE_DIGITS: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 3, 6, 1, 7];
const PX_OUTLET_LABEL: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 5, 3, 1, 2];
const PX_OUTLET_DIGITS: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 3, 5, 4, 1, 7];
const PX_INLET_AVAILABLE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 2, 3, 1, 2];
const PX_INLET_STATE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 2, 3, 1, 3];
const PX_INLET_VALUE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 2, 3, 1, 4];
const PX_INLET_POLE_AVAILABLE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 2, 4, 1, 2];
const PX_INLET_POLE_STATE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 2, 4, 1, 3];
const PX_INLET_POLE_VALUE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 2, 4, 1, 4];
const PX_OUTLET_AVAILABLE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 4, 3, 1, 2];
const PX_OUTLET_STATE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 4, 3, 1, 3];
const PX_OUTLET_VALUE: &[u32] = &[1, 3, 6, 1, 4, 1, 13742, 6, 5, 4, 3, 1, 4];

const RARITAN_COLUMNS: &[&[u32]] = &[
    PX_MANUFACTURER,
    PX_MODEL,
    PX_SERIAL,
    PX_INLET_LABEL,
    PX_INLET_POLE_LINE,
    PX_INLET_DIGITS,
    PX_INLET_POLE_DIGITS,
    PX_OUTLET_LABEL,
    PX_OUTLET_DIGITS,
    PX_INLET_AVAILABLE,
    PX_INLET_STATE,
    PX_INLET_VALUE,
    PX_INLET_POLE_AVAILABLE,
    PX_INLET_POLE_STATE,
    PX_INLET_POLE_VALUE,
    PX_OUTLET_AVAILABLE,
    PX_OUTLET_STATE,
    PX_OUTLET_VALUE,
];

// PDU2-MIB SensorTypeEnumeration and SensorStateEnumeration values.
const PX_RMS_CURRENT: u32 = 1;
const PX_ACTIVE_POWER: u32 = 5;
const PX_APPARENT_POWER: u32 = 6;
const PX_POWER_FACTOR: u32 = 7;
const PX_ON_OFF: u32 = 14;
const PX_STATE_UNAVAILABLE: i64 = -1;
const PX_STATE_ON: i64 = 7;
const PX_STATE_OFF: i64 = 8;
const TRUTH_TRUE: i64 = 1;

// APC PowerNet-MIB rPDU2. Each table is indexed by a row number and names its unit in a module
// column; only module 1 is read.
const APC_IDENT_MODULE: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 2, 1, 2];
const APC_IDENT_MODEL: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 2, 1, 8];
const APC_IDENT_SERIAL: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 2, 1, 9];
const APC_DEVICE_MODULE: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 4, 3, 1, 2];
const APC_DEVICE_POWER: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 4, 3, 1, 5];
const APC_DEVICE_APPARENT_POWER: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 4, 3, 1, 16];
const APC_PHASE_MODULE: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 6, 3, 1, 2];
const APC_PHASE_NUMBER: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 6, 3, 1, 3];
const APC_PHASE_CURRENT: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 6, 3, 1, 5];
const APC_METERED_MODULE: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 9, 4, 3, 1, 2];
const APC_METERED_NUMBER: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 9, 4, 3, 1, 4];
const APC_METERED_CURRENT: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 9, 4, 3, 1, 6];
const APC_METERED_POWER: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 9, 4, 3, 1, 7];
const APC_SWITCHED_MODULE: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 9, 2, 3, 1, 2];
const APC_SWITCHED_NUMBER: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 9, 2, 3, 1, 4];
const APC_SWITCHED_STATE: &[u32] = &[1, 3, 6, 1, 4, 1, 318, 1, 1, 26, 9, 2, 3, 1, 5];

const APC_COLUMNS: &[&[u32]] = &[
    APC_IDENT_MODULE,
    APC_IDENT_MODEL,
    APC_IDENT_SERIAL,
    APC_DEVICE_MODULE,
    APC_DEVICE_POWER,
    APC_DEVICE_APPARENT_POWER,
    APC_PHASE_MODULE,
    APC_PHASE_NUMBER,
    APC_PHASE_CURRENT,
    APC_METERED_MODULE,
    APC_METERED_NUMBER,
    APC_METERED_CURRENT,
    APC_METERED_POWER,
    APC_SWITCHED_MODULE,
    APC_SWITCHED_NUMBER,
    APC_SWITCHED_STATE,
];

/// The PDU MIB a device answers, chosen by its `sysObjectID`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vendor {
    Raritan,
    Apc,
}

impl Vendor {
    /// The vendor whose enterprise `sys_object_id` is under, if a mapping exists for it.
    pub fn detect(answers: &Answers) -> Option<Self> {
        match answers.scalar(SYS_OBJECT_ID)? {
            SnmpValue::ObjectId(oid) if oid.starts_with(RARITAN) => Some(Self::Raritan),
            SnmpValue::ObjectId(oid) if oid.starts_with(APC) => Some(Self::Apc),
            _ => None,
        }
    }

    pub fn columns(self) -> &'static [&'static [u32]] {
        match self {
            Self::Raritan => RARITAN_COLUMNS,
            Self::Apc => APC_COLUMNS,
        }
    }

    /// The mapping name readings carry, with `MAPPING_VERSION`.
    pub fn mapping(self) -> &'static str {
        match self {
            Self::Raritan => "raritan_pdu2",
            Self::Apc => "apc_rpdu2",
        }
    }
}

/// A PDU as one target reported it.
#[derive(Debug, Clone, PartialEq)]
pub struct Pdu {
    pub mapping: &'static str,
    pub vendor: Option<String>,
    pub model: Option<String>,
    pub serial_number: String,
    pub hostname: Option<String>,
    pub readings: Vec<Reading>,
}

/// Why an answering device cannot be reported as a PDU.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapError(pub String);

/// The PDU behind `answers`, read with `vendor`'s mapping.
pub fn pdu(vendor: Vendor, answers: &Answers) -> Result<Pdu, MapError> {
    let pdu = match vendor {
        Vendor::Raritan => raritan(answers),
        Vendor::Apc => apc(answers),
    }?;
    if pdu.readings.len() > MAX_READINGS {
        return Err(MapError(format!(
            "the PDU reported more than {MAX_READINGS} readings"
        )));
    }
    Ok(pdu)
}

fn raritan(answers: &Answers) -> Result<Pdu, MapError> {
    let first = |column| rows(answers, column, &[1]);
    let serial_number = first(PX_SERIAL)
        .get(&Vec::new())
        .and_then(|value| text(value))
        .ok_or_else(|| MapError("the PDU answered PDU2-MIB without a serial number".into()))?;
    let one = |column| first(column).get(&Vec::new()).and_then(|value| text(value));

    let inlet_labels = by_first(&first(PX_INLET_LABEL), text);
    let measured_inlets: Vec<u32> = first(PX_INLET_AVAILABLE)
        .keys()
        .filter_map(|index| index.first().copied())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    let several_inlets = inlet_labels.len().max(measured_inlets.len()) > 1;
    let inlet_component = |inlet: u32| {
        several_inlets.then(|| {
            (
                "power_port",
                inlet_labels
                    .get(&inlet)
                    .cloned()
                    .unwrap_or_else(|| format!("I{inlet}")),
            )
        })
    };

    let mut readings = Vec::new();
    for (index, measurement, digits) in px_sensors(
        answers,
        [PX_INLET_AVAILABLE, PX_INLET_STATE, PX_INLET_VALUE],
        PX_INLET_DIGITS,
    ) {
        let [inlet, sensor_type] = index[..] else {
            continue;
        };
        let Some(quantity) = px_quantity(sensor_type) else {
            continue;
        };
        readings.push(Reading {
            sensor: format!("inlet/{inlet}"),
            boundary: "feed",
            quantity,
            component: inlet_component(inlet),
            leg: None,
            measurement: px_value(measurement, digits),
        });
    }

    // A pole is a leg only on a three-phase inlet; a single-phase inlet's L1 and L2 or N carry
    // the same current and are not phases of a three-phase feed.
    let lines = first(PX_INLET_POLE_LINE);
    let three_phase = |inlet: u32| {
        [1, 2, 3].iter().all(|line| {
            lines.iter().any(|(index, value)| {
                index.first() == Some(&inlet) && integer(value) == Some(*line)
            })
        })
    };
    for (index, measurement, digits) in px_sensors(
        answers,
        [
            PX_INLET_POLE_AVAILABLE,
            PX_INLET_POLE_STATE,
            PX_INLET_POLE_VALUE,
        ],
        PX_INLET_POLE_DIGITS,
    ) {
        let [inlet, pole, sensor_type] = index[..] else {
            continue;
        };
        let leg = match lines
            .get(&vec![inlet, pole])
            .and_then(|value| integer(value))
        {
            Some(1) => "a",
            Some(2) => "b",
            Some(3) => "c",
            _ => continue,
        };
        if sensor_type != PX_RMS_CURRENT || !three_phase(inlet) {
            continue;
        }
        readings.push(Reading {
            sensor: format!("inlet/{inlet}/pole/{pole}"),
            boundary: "leg",
            quantity: "current",
            component: inlet_component(inlet),
            leg: Some(leg),
            measurement: px_value(measurement, digits),
        });
    }

    let outlet_labels = by_first(&first(PX_OUTLET_LABEL), text);
    for (index, measurement, digits) in px_sensors(
        answers,
        [PX_OUTLET_AVAILABLE, PX_OUTLET_STATE, PX_OUTLET_VALUE],
        PX_OUTLET_DIGITS,
    ) {
        let [outlet, sensor_type] = index[..] else {
            continue;
        };
        let name = outlet_labels
            .get(&outlet)
            .cloned()
            .unwrap_or_else(|| outlet.to_string());
        let (quantity, measurement) = if sensor_type == PX_ON_OFF {
            ("state", px_on_off(measurement))
        } else if let Some(quantity) = px_quantity(sensor_type) {
            (quantity, px_value(measurement, digits))
        } else {
            continue;
        };
        readings.push(Reading {
            sensor: format!("outlet/{outlet}"),
            boundary: "outlet",
            quantity,
            component: Some(("power_outlet", name)),
            leg: None,
            measurement,
        });
    }

    Ok(Pdu {
        mapping: Vendor::Raritan.mapping(),
        vendor: one(PX_MANUFACTURER),
        model: one(PX_MODEL),
        serial_number,
        hostname: answers.scalar(SYS_NAME).and_then(text),
        readings,
    })
}

/// One PDU2-MIB measurement row: whether the sensor is present, its state, and its raw value.
#[derive(Debug, Clone, Copy)]
struct PxMeasurement {
    state: Option<i64>,
    value: Option<i64>,
}

/// Every present sensor of unit 1 in a measurements table, by its index after `pduId`, with its
/// decimal digits from the matching configuration table. A sensor whose digits are missing or
/// malformed has `None`: its raw value has no known scale.
fn px_sensors(
    answers: &Answers,
    [available, state, value]: [&[u32]; 3],
    digits: &[u32],
) -> Vec<(Vec<u32>, PxMeasurement, Option<u32>)> {
    let states = rows(answers, state, &[1]);
    let values = rows(answers, value, &[1]);
    let digits = rows(answers, digits, &[1]);
    rows(answers, available, &[1])
        .into_iter()
        .filter(|(_, present)| integer(present) == Some(TRUTH_TRUE))
        .map(|(index, _)| {
            let measurement = PxMeasurement {
                state: states.get(&index).and_then(|value| integer(value)),
                value: values.get(&index).and_then(|value| integer(value)),
            };
            let digits = digits
                .get(&index)
                .and_then(|value| integer(value))
                .and_then(|digits| u32::try_from(digits).ok());
            (index, measurement, digits)
        })
        .collect()
}

fn px_quantity(sensor_type: u32) -> Option<&'static str> {
    match sensor_type {
        PX_RMS_CURRENT => Some("current"),
        PX_ACTIVE_POWER => Some("real_power"),
        PX_APPARENT_POWER => Some("apparent_power"),
        PX_POWER_FACTOR => Some("power_factor"),
        _ => None,
    }
}

/// A numeric reading scaled by its decimal digits. Without them the value's scale is unknown,
/// and 12350 might be 12.35 A, so it is a failed reading rather than a guess.
fn px_value(measurement: PxMeasurement, digits: Option<u32>) -> Measurement {
    match (measurement, digits) {
        (
            PxMeasurement {
                state: Some(state),
                value: Some(value),
            },
            Some(digits),
        ) if state != PX_STATE_UNAVAILABLE && digits <= 6 => {
            Measurement::Value(value as f64 / 10_f64.powi(digits as i32))
        }
        _ => Measurement::Failed,
    }
}

fn px_on_off(measurement: PxMeasurement) -> Measurement {
    match measurement.state {
        Some(PX_STATE_ON) => Measurement::State("on"),
        Some(PX_STATE_OFF) => Measurement::State("off"),
        _ => Measurement::Failed,
    }
}

fn apc(answers: &Answers) -> Result<Pdu, MapError> {
    // The module columns hold each unit's configurable Display ID, which need not be 1. The
    // host, the PDU that answered, is always the first identification row.
    let host = answers
        .column(APC_IDENT_MODULE)
        .filter_map(|(index, value)| match index {
            [row] => Some((*row, integer(value)?)),
            _ => None,
        })
        .min_by_key(|(row, _)| *row);
    let ident_value = |column| {
        host.and_then(|(row, _)| row_value(answers, column, row))
            .and_then(text)
    };
    let serial_number = ident_value(APC_IDENT_SERIAL)
        .ok_or_else(|| MapError("the PDU answered rPDU2 without a serial number".into()))?;
    let module = host.map_or(1, |(_, module)| module);
    let apc_rows = |column| apc_rows(answers, column, module);
    let mut readings = Vec::new();

    if let Some(row) = apc_rows(APC_DEVICE_MODULE).first() {
        // Hundredths of kW and kVA; -1 means the model does not measure it.
        for (column, quantity) in [
            (APC_DEVICE_POWER, "real_power"),
            (APC_DEVICE_APPARENT_POWER, "apparent_power"),
        ] {
            if let Some(measurement) = apc_value(answers, column, *row, (10.0, 1.0)) {
                readings.push(Reading {
                    sensor: "device".into(),
                    boundary: "feed",
                    quantity,
                    component: None,
                    leg: None,
                    measurement,
                });
            }
        }
    }

    // One phase row is the whole inlet; three are the legs of a three-phase inlet.
    let phases: BTreeMap<i64, u32> = apc_rows(APC_PHASE_MODULE)
        .into_iter()
        .filter_map(|row| {
            Some((
                row_value(answers, APC_PHASE_NUMBER, row).and_then(integer)?,
                row,
            ))
        })
        .collect();
    let three_phase = (1..=3).all(|phase| phases.contains_key(&phase));
    for (phase, row) in &phases {
        let (boundary, leg) = match (three_phase, phase) {
            (false, 1) if phases.len() == 1 => ("feed", None),
            (true, 1) => ("leg", Some("a")),
            (true, 2) => ("leg", Some("b")),
            (true, 3) => ("leg", Some("c")),
            _ => continue,
        };
        if let Some(measurement) = apc_value(answers, APC_PHASE_CURRENT, *row, (1.0, 10.0)) {
            readings.push(Reading {
                sensor: format!("phase/{phase}"),
                boundary,
                quantity: "current",
                component: None,
                leg,
                measurement,
            });
        }
    }

    for (number_column, row, column, quantity, scale) in
        apc_rows(APC_METERED_MODULE).into_iter().flat_map(|row| {
            [
                (
                    APC_METERED_NUMBER,
                    row,
                    APC_METERED_POWER,
                    "real_power",
                    (1.0, 1.0),
                ),
                (
                    APC_METERED_NUMBER,
                    row,
                    APC_METERED_CURRENT,
                    "current",
                    (1.0, 10.0),
                ),
            ]
        })
    {
        let Some(outlet) = row_value(answers, number_column, row).and_then(integer) else {
            continue;
        };
        if let Some(measurement) = apc_value(answers, column, row, scale) {
            readings.push(apc_outlet(outlet, quantity, measurement));
        }
    }
    for row in apc_rows(APC_SWITCHED_MODULE) {
        let Some(outlet) = row_value(answers, APC_SWITCHED_NUMBER, row).and_then(integer) else {
            continue;
        };
        let measurement = match row_value(answers, APC_SWITCHED_STATE, row).and_then(integer) {
            Some(1) => Measurement::State("off"),
            Some(2) => Measurement::State("on"),
            _ => Measurement::Failed,
        };
        readings.push(apc_outlet(outlet, "state", measurement));
    }

    Ok(Pdu {
        mapping: Vendor::Apc.mapping(),
        vendor: Some("APC".into()),
        model: ident_value(APC_IDENT_MODEL),
        serial_number,
        hostname: answers.scalar(SYS_NAME).and_then(text),
        readings,
    })
}

fn apc_outlet(outlet: i64, quantity: &'static str, measurement: Measurement) -> Reading {
    Reading {
        sensor: format!("outlet/{outlet}"),
        boundary: "outlet",
        quantity,
        component: Some(("power_outlet", outlet.to_string())),
        leg: None,
        measurement,
    }
}

/// The rows of an rPDU2 table whose module column names the unit with Display ID `module`.
fn apc_rows(answers: &Answers, column: &[u32], module: i64) -> Vec<u32> {
    answers
        .column(column)
        .filter_map(|(index, value)| match index {
            [row] if integer(value) == Some(module) => Some(*row),
            _ => None,
        })
        .collect()
}

fn row_value<'a>(answers: &'a Answers, column: &[u32], row: u32) -> Option<&'a SnmpValue> {
    answers
        .column(column)
        .find_map(|(index, value)| (index == [row]).then_some(value))
}

/// An rPDU2 reading scaled by `(multiplier, divisor)`, or `None` when the model does not
/// measure it (`-1`).
fn apc_value(
    answers: &Answers,
    column: &[u32],
    row: u32,
    (multiplier, divisor): (f64, f64),
) -> Option<Measurement> {
    match row_value(answers, column, row).map(integer) {
        None | Some(Some(-1)) => None,
        Some(Some(value)) if value >= 0 => {
            Some(Measurement::Value(value as f64 * multiplier / divisor))
        }
        Some(_) => Some(Measurement::Failed),
    }
}

/// A column's rows under `prefix`, keyed by the rest of the index.
fn rows<'a>(
    answers: &'a Answers,
    column: &[u32],
    prefix: &[u32],
) -> BTreeMap<Vec<u32>, &'a SnmpValue> {
    answers
        .column(column)
        .filter_map(|(index, value)| {
            index
                .strip_prefix(prefix)
                .map(|rest| (rest.to_vec(), value))
        })
        .collect()
}

/// A column indexed by one integer after the unit, mapped through `read`.
fn by_first<T>(
    rows: &BTreeMap<Vec<u32>, &SnmpValue>,
    read: impl Fn(&SnmpValue) -> Option<T>,
) -> BTreeMap<u32, T> {
    rows.iter()
        .filter_map(|(index, value)| match index[..] {
            [first] => Some((first, read(value)?)),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::snmp::mibs::Oid;

    fn oid(base: &[u32], index: &[u32]) -> Oid {
        base.iter().chain(index).copied().collect()
    }

    fn octets(text: &str) -> SnmpValue {
        SnmpValue::Octets(text.as_bytes().to_vec())
    }

    /// A Raritan PX3 with one three-phase inlet and three outlets: outlet 2 is off, and outlet
    /// 3's power sensor is unavailable.
    pub(crate) fn raritan_answers() -> Answers {
        let mut answers = Answers::default();
        let mut put = |base: &[u32], index: &[u32], value: SnmpValue| {
            answers.insert(oid(base, index), value);
        };
        put(
            SYS_OBJECT_ID,
            &[],
            SnmpValue::ObjectId(vec![1, 3, 6, 1, 4, 1, 13742, 6]),
        );
        put(SYS_NAME, &[], octets("pdu-a1"));
        put(PX_MANUFACTURER, &[1], octets("Raritan"));
        put(PX_MODEL, &[1], octets("PX3-5190R"));
        put(PX_SERIAL, &[1], octets("PKE0954001"));
        put(PX_INLET_LABEL, &[1, 1], octets("I1"));
        // A second unit in the daisy chain is a different PDU.
        put(PX_SERIAL, &[2], octets("PKE0954002"));
        put(PX_OUTLET_LABEL, &[2, 1], octets("1"));
        put(
            PX_OUTLET_AVAILABLE,
            &[2, 1, PX_ACTIVE_POWER],
            SnmpValue::Integer(1),
        );
        for (pole, line) in [(1, 1), (2, 2), (3, 3)] {
            put(PX_INLET_POLE_LINE, &[1, 1, pole], SnmpValue::Integer(line));
            let index = [1, 1, pole, PX_RMS_CURRENT];
            put(PX_INLET_POLE_DIGITS, &index, SnmpValue::Unsigned(3));
            put(PX_INLET_POLE_AVAILABLE, &index, SnmpValue::Integer(1));
            put(PX_INLET_POLE_STATE, &index, SnmpValue::Integer(4));
            put(
                PX_INLET_POLE_VALUE,
                &index,
                SnmpValue::Unsigned(4_100 + u64::from(pole)),
            );
        }
        for (sensor_type, digits, value) in [
            (PX_RMS_CURRENT, 3, 12_350),
            (PX_ACTIVE_POWER, 0, 2_455),
            (PX_APPARENT_POWER, 0, 2_550),
            (PX_POWER_FACTOR, 2, 96),
            // Temperature is not a power reading.
            (10, 1, 231),
        ] {
            let index = [1, 1, sensor_type];
            put(PX_INLET_DIGITS, &index, SnmpValue::Unsigned(digits));
            put(PX_INLET_AVAILABLE, &index, SnmpValue::Integer(1));
            put(PX_INLET_STATE, &index, SnmpValue::Integer(4));
            put(PX_INLET_VALUE, &index, SnmpValue::Unsigned(value));
        }
        for outlet in 1..=3 {
            put(PX_OUTLET_LABEL, &[1, outlet], octets(&outlet.to_string()));
            let power = [1, outlet, PX_ACTIVE_POWER];
            put(PX_OUTLET_DIGITS, &power, SnmpValue::Unsigned(0));
            put(PX_OUTLET_AVAILABLE, &power, SnmpValue::Integer(1));
            let on_off = [1, outlet, PX_ON_OFF];
            put(PX_OUTLET_AVAILABLE, &on_off, SnmpValue::Integer(1));
            put(
                PX_OUTLET_STATE,
                &on_off,
                SnmpValue::Integer(if outlet == 2 {
                    PX_STATE_OFF
                } else {
                    PX_STATE_ON
                }),
            );
        }
        put(
            PX_OUTLET_STATE,
            &[1, 1, PX_ACTIVE_POWER],
            SnmpValue::Integer(4),
        );
        put(
            PX_OUTLET_VALUE,
            &[1, 1, PX_ACTIVE_POWER],
            SnmpValue::Unsigned(212),
        );
        put(
            PX_OUTLET_STATE,
            &[1, 2, PX_ACTIVE_POWER],
            SnmpValue::Integer(4),
        );
        put(
            PX_OUTLET_VALUE,
            &[1, 2, PX_ACTIVE_POWER],
            SnmpValue::Unsigned(0),
        );
        put(
            PX_OUTLET_STATE,
            &[1, 3, PX_ACTIVE_POWER],
            SnmpValue::Integer(PX_STATE_UNAVAILABLE),
        );
        // A sensor the PDU does not have is not reported at all.
        put(
            PX_OUTLET_AVAILABLE,
            &[1, 3, PX_RMS_CURRENT],
            SnmpValue::Integer(2),
        );
        answers
    }

    /// An APC AP8941: single-phase, two outlets, outlet 2 off.
    pub(crate) fn apc_answers() -> Answers {
        let mut answers = Answers::default();
        let mut put = |base: &[u32], index: &[u32], value: SnmpValue| {
            answers.insert(oid(base, index), value);
        };
        put(
            SYS_OBJECT_ID,
            &[],
            SnmpValue::ObjectId(vec![1, 3, 6, 1, 4, 1, 318, 1, 3, 4, 6]),
        );
        put(SYS_NAME, &[], octets("pdu-b1"));
        put(APC_IDENT_MODULE, &[1], SnmpValue::Integer(1));
        put(APC_IDENT_MODEL, &[1], octets("AP8941"));
        put(APC_IDENT_SERIAL, &[1], octets("5A1234E01234"));
        put(APC_DEVICE_MODULE, &[1], SnmpValue::Integer(1));
        put(APC_DEVICE_POWER, &[1], SnmpValue::Integer(42));
        put(APC_DEVICE_APPARENT_POWER, &[1], SnmpValue::Integer(-1));
        put(APC_PHASE_MODULE, &[1], SnmpValue::Integer(1));
        put(APC_PHASE_NUMBER, &[1], SnmpValue::Integer(1));
        put(APC_PHASE_CURRENT, &[1], SnmpValue::Integer(19));
        for outlet in 1..=2 {
            put(APC_METERED_MODULE, &[outlet], SnmpValue::Integer(1));
            put(
                APC_METERED_NUMBER,
                &[outlet],
                SnmpValue::Integer(outlet.into()),
            );
            put(
                APC_METERED_POWER,
                &[outlet],
                SnmpValue::Integer(if outlet == 1 { 410 } else { 0 }),
            );
            put(
                APC_METERED_CURRENT,
                &[outlet],
                SnmpValue::Integer(if outlet == 1 { 18 } else { 0 }),
            );
            put(APC_SWITCHED_MODULE, &[outlet], SnmpValue::Integer(1));
            put(
                APC_SWITCHED_NUMBER,
                &[outlet],
                SnmpValue::Integer(outlet.into()),
            );
            put(
                APC_SWITCHED_STATE,
                &[outlet],
                SnmpValue::Integer(if outlet == 1 { 2 } else { 1 }),
            );
        }
        answers
    }

    fn find<'a>(pdu: &'a Pdu, sensor: &str, quantity: &str) -> &'a Reading {
        pdu.readings
            .iter()
            .find(|reading| reading.sensor == sensor && reading.quantity == quantity)
            .unwrap_or_else(|| panic!("no {sensor} {quantity} in {:#?}", pdu.readings))
    }

    #[test]
    fn detects_the_vendor_from_sys_object_id() {
        assert_eq!(Vendor::detect(&raritan_answers()), Some(Vendor::Raritan));
        assert_eq!(Vendor::detect(&apc_answers()), Some(Vendor::Apc));

        let mut other = Answers::default();
        other.insert(
            SYS_OBJECT_ID.to_vec(),
            SnmpValue::ObjectId(vec![1, 3, 6, 1, 4, 1, 9, 1, 1]),
        );
        assert_eq!(Vendor::detect(&other), None);
        assert_eq!(Vendor::detect(&Answers::default()), None);
    }

    #[test]
    fn maps_a_raritan_pdu_with_scaled_inlet_leg_and_outlet_readings() {
        let pdu = pdu(Vendor::Raritan, &raritan_answers()).unwrap();

        assert_eq!(pdu.mapping, "raritan_pdu2");
        assert_eq!(pdu.serial_number, "PKE0954001");
        assert_eq!(pdu.vendor.as_deref(), Some("Raritan"));
        assert_eq!(pdu.model.as_deref(), Some("PX3-5190R"));
        assert_eq!(pdu.hostname.as_deref(), Some("pdu-a1"));

        // One inlet: its readings name no port, so they are about the PDU's only inlet.
        let power = find(&pdu, "inlet/1", "real_power");
        assert_eq!(power.boundary, "feed");
        assert_eq!(power.component, None);
        assert_eq!(power.coverage(), Some("complete"));
        assert_eq!(power.measurement, Measurement::Value(2_455.0));
        assert_eq!(
            find(&pdu, "inlet/1", "current").measurement,
            Measurement::Value(12.35)
        );
        assert_eq!(
            find(&pdu, "inlet/1", "power_factor").measurement,
            Measurement::Value(0.96)
        );
        assert_eq!(find(&pdu, "inlet/1", "power_factor").unit(), Some("1"));
        assert!(pdu
            .readings
            .iter()
            .all(|reading| reading.sensor != "inlet/1"
                || ["current", "real_power", "apparent_power", "power_factor"]
                    .contains(&reading.quantity)));

        let leg = find(&pdu, "inlet/1/pole/2", "current");
        assert_eq!((leg.boundary, leg.leg), ("leg", Some("b")));
        assert_eq!(leg.measurement, Measurement::Value(4.102));

        let outlet = find(&pdu, "outlet/1", "real_power");
        assert_eq!(outlet.boundary, "outlet");
        assert_eq!(outlet.component, Some(("power_outlet", "1".into())));
        assert_eq!(outlet.measurement, Measurement::Value(212.0));
        assert_eq!(
            find(&pdu, "outlet/2", "state").measurement,
            Measurement::State("off")
        );
        assert_eq!(
            find(&pdu, "outlet/3", "real_power").measurement,
            Measurement::Failed
        );
        assert!(!pdu
            .readings
            .iter()
            .any(|reading| reading.sensor == "outlet/3" && reading.quantity == "current"));
        // Nothing from the second unit in the chain.
        assert_eq!(
            pdu.readings
                .iter()
                .filter(|reading| reading.boundary == "outlet" && reading.quantity == "real_power")
                .count(),
            3
        );
    }

    #[test]
    fn a_single_phase_raritan_inlet_has_no_legs_and_several_inlets_are_named() {
        let mut answers = raritan_answers();
        answers.insert(oid(PX_INLET_POLE_LINE, &[1, 1, 3]), SnmpValue::Integer(4));
        let single = pdu(Vendor::Raritan, &answers).unwrap();
        assert!(!single
            .readings
            .iter()
            .any(|reading| reading.boundary == "leg"));

        let mut answers = raritan_answers();
        answers.insert(oid(PX_INLET_LABEL, &[1, 2]), octets("I2"));
        let several = pdu(Vendor::Raritan, &answers).unwrap();
        assert_eq!(
            find(&several, "inlet/1", "real_power").component,
            Some(("power_port", "I1".into()))
        );
    }

    #[test]
    fn maps_an_apc_pdu_skipping_what_the_model_does_not_measure() {
        let pdu = pdu(Vendor::Apc, &apc_answers()).unwrap();

        assert_eq!(pdu.mapping, "apc_rpdu2");
        assert_eq!(pdu.serial_number, "5A1234E01234");
        assert_eq!(pdu.model.as_deref(), Some("AP8941"));
        assert_eq!(
            find(&pdu, "device", "real_power").measurement,
            Measurement::Value(420.0)
        );
        assert!(!pdu
            .readings
            .iter()
            .any(|reading| reading.quantity == "apparent_power"));

        // A single phase is the whole inlet, not a leg.
        let phase = find(&pdu, "phase/1", "current");
        assert_eq!((phase.boundary, phase.leg), ("feed", None));
        assert_eq!(phase.measurement, Measurement::Value(1.9));

        assert_eq!(
            find(&pdu, "outlet/1", "current").measurement,
            Measurement::Value(1.8)
        );
        assert_eq!(
            find(&pdu, "outlet/1", "real_power").component,
            Some(("power_outlet", "1".into()))
        );
        assert_eq!(
            find(&pdu, "outlet/2", "state").measurement,
            Measurement::State("off")
        );
    }

    #[test]
    fn the_apc_host_is_the_first_unit_whatever_its_display_id() {
        // The host's Display ID is 2.
        let mut host = apc_answers();
        let rows: Vec<(Oid, SnmpValue)> = host
            .iter()
            .map(|(index, value)| (index.clone(), value.clone()))
            .collect();
        for (index, value) in &rows {
            let module = [
                APC_IDENT_MODULE,
                APC_DEVICE_MODULE,
                APC_PHASE_MODULE,
                APC_METERED_MODULE,
                APC_SWITCHED_MODULE,
            ]
            .iter()
            .any(|column| index.starts_with(column));
            if module && integer(value) == Some(1) {
                host.insert(index.clone(), SnmpValue::Integer(2));
            }
        }
        let alone = pdu(Vendor::Apc, &host).unwrap();
        assert_eq!(alone.serial_number, "5A1234E01234");
        assert_eq!(
            find(&alone, "device", "real_power").measurement,
            Measurement::Value(420.0)
        );
        assert_eq!(
            find(&alone, "outlet/1", "current").measurement,
            Measurement::Value(1.8)
        );

        // A guest in the chain with Display ID 1, listed after the host.
        let mut chained = host;
        chained.insert(oid(APC_IDENT_MODULE, &[2]), SnmpValue::Integer(1));
        chained.insert(oid(APC_IDENT_SERIAL, &[2]), octets("GUEST-SERIAL"));
        chained.insert(oid(APC_DEVICE_MODULE, &[2]), SnmpValue::Integer(1));
        chained.insert(oid(APC_DEVICE_POWER, &[2]), SnmpValue::Integer(99));
        chained.insert(oid(APC_METERED_MODULE, &[3]), SnmpValue::Integer(1));
        chained.insert(oid(APC_METERED_NUMBER, &[3]), SnmpValue::Integer(1));
        chained.insert(oid(APC_METERED_CURRENT, &[3]), SnmpValue::Integer(77));
        let pdu = pdu(Vendor::Apc, &chained).unwrap();
        assert_eq!(pdu.serial_number, "5A1234E01234");
        assert_eq!(
            find(&pdu, "device", "real_power").measurement,
            Measurement::Value(420.0)
        );
        assert_eq!(
            pdu.readings
                .iter()
                .filter(|reading| reading.sensor == "outlet/1" && reading.quantity == "current")
                .map(|reading| reading.measurement)
                .collect::<Vec<_>>(),
            [Measurement::Value(1.8)]
        );
    }

    #[test]
    fn a_raritan_reading_without_its_scale_is_failed_not_unscaled() {
        let current = [1, 1, PX_RMS_CURRENT];
        for digits in [SnmpValue::Missing, SnmpValue::Integer(-1), octets("3")] {
            let mut answers = raritan_answers();
            answers.insert(oid(PX_INLET_DIGITS, &current), digits);
            let pdu = pdu(Vendor::Raritan, &answers).unwrap();
            assert_eq!(
                find(&pdu, "inlet/1", "current").measurement,
                Measurement::Failed
            );
            // Explicit zero digits still scale nothing, and on/off needs no digits.
            assert_eq!(
                find(&pdu, "inlet/1", "real_power").measurement,
                Measurement::Value(2_455.0)
            );
            assert_eq!(
                find(&pdu, "outlet/2", "state").measurement,
                Measurement::State("off")
            );
        }
    }

    #[test]
    fn three_apc_phases_are_legs() {
        let mut answers = apc_answers();
        for phase in 2..=3 {
            answers.insert(oid(APC_PHASE_MODULE, &[phase]), SnmpValue::Integer(1));
            answers.insert(
                oid(APC_PHASE_NUMBER, &[phase]),
                SnmpValue::Integer(phase.into()),
            );
            answers.insert(oid(APC_PHASE_CURRENT, &[phase]), SnmpValue::Integer(50));
        }
        let pdu = pdu(Vendor::Apc, &answers).unwrap();
        let legs: Vec<_> = pdu
            .readings
            .iter()
            .filter(|reading| reading.boundary == "leg")
            .map(|reading| reading.leg.unwrap())
            .collect();
        assert_eq!(legs, ["a", "b", "c"]);
    }

    #[test]
    fn a_pdu_without_a_serial_number_cannot_be_reported() {
        let mut answers = raritan_answers();
        answers.insert(oid(PX_SERIAL, &[1]), SnmpValue::Missing);
        assert!(pdu(Vendor::Raritan, &answers)
            .unwrap_err()
            .0
            .contains("serial number"));
        assert!(pdu(Vendor::Apc, &Answers::default()).is_err());
    }
}
