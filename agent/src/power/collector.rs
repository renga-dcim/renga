//! What the power collector modules share (RFD 10, "Collectors and BMCs"): the PDU poller and
//! the BMC collector each poll a list of targets on their own thread, queue every poll's readings
//! as telemetry, and report the devices behind their targets to inventory when what the targets
//! show changes, or every fifteen minutes, so Renga maps each target to its device and the
//! readings to that device.

use crate::{
    cancellation::Cancellation,
    payload::{
        Collector, CollectorKind, CollectorResource, Reachability, ReportScope, SampleComponent,
        SampleMapping, SampleWindow, ScopedReport, TargetStatus, TelemetryBatch, TelemetrySample,
        MAX_OBSERVATION_BYTES, MAX_TELEMETRY_BYTES,
    },
    power::PowerSources,
    queue,
    snmp::{mibs::MAX_STRING_CHARS, worker::Sink},
};
use chrono::{DateTime, Utc};
use std::{
    collections::BTreeMap,
    thread,
    time::{Duration, Instant},
};
use tracing::{info, warn};

/// How often an unchanged set of devices is reported again.
const INVENTORY_INTERVAL: Duration = Duration::from_secs(900);
/// A device's report entry is a few short strings, so this many always fit in one report.
const TARGETS_PER_REPORT: usize = 100;
/// Samples run to a few hundred bytes, so this many stay well within the batch size limit.
const SAMPLES_PER_BATCH: usize = 1_000;
const MAX_FRESH_FOR_SECONDS: u64 = 86_400;
const WAIT_SLICE: Duration = Duration::from_millis(250);

/// One instantaneous reading. The sensor names the meter, so a meter's real power, apparent
/// power, and power factor share it and Renga can combine them.
#[derive(Debug, Clone, PartialEq)]
pub struct Reading {
    pub sensor: String,
    pub boundary: &'static str,
    pub quantity: &'static str,
    /// The outlet or power port the reading is about, as the device names it.
    pub component: Option<(&'static str, String)>,
    pub leg: Option<&'static str>,
    pub measurement: Measurement,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Measurement {
    Value(f64),
    State(&'static str),
    /// The device has the sensor but cannot read it now.
    Failed,
}

impl Reading {
    pub fn unit(&self) -> Option<&'static str> {
        match self.quantity {
            "real_power" => Some("W"),
            "apparent_power" => Some("VA"),
            "current" => Some("A"),
            "power_factor" => Some("1"),
            _ => None,
        }
    }

    /// An inlet meter covers everything its inlet feeds.
    pub fn coverage(&self) -> Option<&'static str> {
        (self.boundary == "feed").then_some("complete")
    }
}

/// A device as one target reported it: the resource Renga reconciles, without its target, and
/// its readings under one mapping.
#[derive(Debug, Clone)]
pub struct Device {
    pub mapping: &'static str,
    pub mapping_version: u32,
    pub resource: CollectorResource,
    pub readings: Vec<Reading>,
}

/// Why a target has no device this poll.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetError {
    /// The device did not answer, or not in full.
    Unreachable(String),
    /// The device refused the module's credentials.
    NotPermitted(String),
    /// The device answered, but not in a way the module can map.
    Unsupported(String),
}

impl TargetError {
    pub fn message(&self) -> &str {
        match self {
            Self::Unreachable(message)
            | Self::NotPermitted(message)
            | Self::Unsupported(message) => message,
        }
    }
}

/// One target's poll.
#[derive(Debug, Clone)]
pub struct Outcome {
    /// The target exactly as configured.
    pub address: String,
    pub read_at: DateTime<Utc>,
    pub result: Result<Device, TargetError>,
}

/// The status of a module as one power source: available while any device is read.
pub fn source_status(outcomes: &[Outcome]) -> &'static str {
    let any = |matches: fn(&Result<Device, TargetError>) -> bool| {
        outcomes.iter().any(|outcome| matches(&outcome.result))
    };
    if any(Result::is_ok) {
        "available"
    } else if any(|result| matches!(result, Err(TargetError::NotPermitted(_)))) {
        "not_permitted"
    } else if any(|result| matches!(result, Err(TargetError::Unsupported(_)))) {
        "not_present"
    } else {
        "unreachable"
    }
}

/// The source name a module reports in check-ins, such as `power_poller/rack-pdus`.
pub fn source(kind: CollectorKind, collector_id: &str) -> String {
    format!("{}/{collector_id}", kind.as_str())
}

/// Complete `targets` reports of the devices, in order. A target without a device is reported
/// unreachable, so the device Renga last saw there stays as it was instead of being withdrawn.
pub fn reports(collector: &Collector, outcomes: &[Outcome]) -> Vec<(uuid::Uuid, Vec<u8>)> {
    outcomes
        .chunks(TARGETS_PER_REPORT)
        .filter_map(|chunk| {
            let mut targets = Vec::with_capacity(chunk.len());
            let mut resources = Vec::new();
            for outcome in chunk {
                let address = outcome.address.clone();
                match &outcome.result {
                    Ok(device) => {
                        targets.push(TargetStatus {
                            address: address.clone(),
                            status: Reachability::Reachable,
                            error: None,
                        });
                        resources.push(CollectorResource {
                            target: Some(address),
                            ..device.resource.clone()
                        });
                    }
                    Err(error) => targets.push(TargetStatus {
                        address,
                        status: Reachability::Unreachable,
                        error: Some(error.message().chars().take(MAX_STRING_CHARS).collect()),
                    }),
                }
            }
            let report = ScopedReport::new(
                collector.clone(),
                ReportScope::Targets { targets },
                true,
                resources,
            );
            let body = serde_json::to_vec(&report).ok()?;
            (body.len() <= MAX_OBSERVATION_BYTES).then_some((report.observation_id, body))
        })
        .collect()
}

/// The readings each target last served, with their mapping, so a target that stops answering
/// reports them as failed.
pub type Known = BTreeMap<String, (&'static str, u32, Vec<Reading>)>;

/// The poll's telemetry batches. A target without a device this poll sends every reading it
/// last served as failed, so Renga knows those series are unknown now rather than waiting for
/// them to expire, never zero.
pub fn batches(
    collector: &Collector,
    outcomes: &[Outcome],
    known: &mut Known,
    fresh_for_seconds: u32,
) -> Vec<TelemetryBatch> {
    known.retain(|address, _| outcomes.iter().any(|outcome| &outcome.address == address));
    let mut samples = Vec::new();
    for outcome in outcomes {
        let address = &outcome.address;
        let (mapping, version, readings, failed) = match &outcome.result {
            Ok(device) => {
                known.insert(
                    address.clone(),
                    (
                        device.mapping,
                        device.mapping_version,
                        device.readings.clone(),
                    ),
                );
                (
                    device.mapping,
                    device.mapping_version,
                    &device.readings,
                    false,
                )
            }
            Err(_) => match known.get(address) {
                Some((mapping, version, readings)) => (*mapping, *version, readings, true),
                None => continue,
            },
        };
        let mapping = SampleMapping {
            name: mapping,
            version,
        };
        samples.extend(readings.iter().map(|reading| {
            sample(
                address,
                reading,
                &mapping,
                failed,
                outcome.read_at,
                fresh_for_seconds,
            )
        }));
    }
    let mut batches = Vec::new();
    let mut pending: Vec<Vec<TelemetrySample>> = samples
        .chunks(SAMPLES_PER_BATCH)
        .map(<[_]>::to_vec)
        .rev()
        .collect();
    while let Some(chunk) = pending.pop() {
        let batch = TelemetryBatch::collector(&collector.id, collector.kind, chunk);
        if serde_json::to_vec(&batch).is_ok_and(|body| body.len() <= MAX_TELEMETRY_BYTES) {
            batches.push(batch);
            continue;
        }
        let mut chunk = batch.samples;
        if chunk.len() == 1 {
            warn!(collector = %collector.id, "a power sample is too large to send");
            continue;
        }
        let rest = chunk.split_off(chunk.len() / 2);
        pending.push(rest);
        pending.push(chunk);
    }
    batches
}

fn sample(
    target: &str,
    reading: &Reading,
    mapping: &SampleMapping,
    failed: bool,
    read_at: DateTime<Utc>,
    fresh_for_seconds: u32,
) -> TelemetrySample {
    let (status, value, state) = match reading.measurement {
        _ if failed => ("failed", None, None),
        Measurement::Value(value) if value.is_finite() => ("valid", Some(value), None),
        Measurement::State(state) => ("valid", None, Some(state)),
        Measurement::Value(_) | Measurement::Failed => ("failed", None, None),
    };
    TelemetrySample {
        target: Some(target.to_owned()),
        sensor: reading.sensor.clone(),
        boundary: reading.boundary,
        quantity: reading.quantity,
        unit: reading.unit(),
        component: reading
            .component
            .clone()
            .map(|(kind, name)| SampleComponent { kind, name }),
        leg: reading.leg,
        coverage: reading.coverage(),
        status,
        origin: "native",
        value,
        state,
        // The modules read instantaneous values.
        window: SampleWindow {
            start: read_at,
            end: read_at,
        },
        event_at: read_at,
        mapping: mapping.clone(),
        fresh_for_seconds,
    }
}

/// Readings stay current through two missed polls and the wait for the queue flush that delivers
/// them, never for less than the host's own readings.
pub fn fresh_for_seconds(interval: Duration) -> u32 {
    u32::try_from(
        interval
            .as_secs()
            .saturating_mul(3)
            .saturating_add(queue::FLUSH_INTERVAL.as_secs())
            .clamp(super::FRESH_FOR_SECONDS.into(), MAX_FRESH_FOR_SECONDS),
    )
    .unwrap_or(u32::MAX)
}

/// Where a module's output goes: inventory reports and telemetry use separate queues.
#[derive(Clone)]
pub struct Sinks {
    pub observations: Sink,
    pub telemetry: Sink,
}

/// What the targets showed, to tell when the devices need reporting again.
type Shown = Vec<(String, Option<String>)>;

fn shown(outcomes: &[Outcome]) -> Shown {
    outcomes
        .iter()
        .map(|outcome| {
            (
                outcome.address.clone(),
                outcome
                    .result
                    .as_ref()
                    .ok()
                    .and_then(|device| serde_json::to_string(&device.resource).ok()),
            )
        })
        .collect()
}

/// Forgets the sources of `kind` that `collectors` no longer configures.
pub fn retain_sources(sources: &PowerSources, kind: CollectorKind, collector_ids: &[&str]) {
    let prefix = format!("{}/", kind.as_str());
    let configured: Vec<String> = collector_ids.iter().map(|id| source(kind, id)).collect();
    sources.retain(|name| !name.starts_with(&prefix) || configured.iter().any(|kept| kept == name));
}

/// Polls with `poll` every `interval` until `stop`, queuing readings each poll and reports when
/// they are due, and publishing the module's power source status.
pub fn run(
    collector: &Collector,
    interval: Duration,
    stop: &Cancellation,
    sinks: &Sinks,
    sources: &PowerSources,
    poll: &dyn Fn(&Cancellation) -> Vec<Outcome>,
) {
    let source = source(collector.kind, &collector.id);
    let fresh_for = fresh_for_seconds(interval);
    let mut known = Known::new();
    let mut reported: Option<(Instant, Shown)> = None;
    while !stop.cancelled() {
        let started = Instant::now();
        let outcomes = poll(stop);
        if stop.cancelled() {
            break;
        }
        for outcome in &outcomes {
            if let Err(error) = &outcome.result {
                warn!(collector = %collector.id, target = %outcome.address, error = error.message(), "power target not read");
            }
        }
        let status = source_status(&outcomes);
        if sources.status(&source) != Some(status) {
            info!(collector = %collector.id, status, "power source status");
        }
        sources.publish(&source, status);

        for batch in batches(collector, &outcomes, &mut known, fresh_for) {
            match serde_json::to_vec(&batch) {
                Ok(body) => (sinks.telemetry)(batch.replay_id, &body),
                Err(error) => {
                    warn!(collector = %collector.id, %error, "cannot encode power readings")
                }
            }
        }

        let now_shown = shown(&outcomes);
        let due = reported
            .as_ref()
            .is_none_or(|(at, before)| *before != now_shown || at.elapsed() >= INVENTORY_INTERVAL);
        if due {
            for (observation_id, body) in reports(collector, &outcomes) {
                (sinks.observations)(observation_id, &body);
            }
            reported = Some((Instant::now(), now_shown));
        }

        let next = started + interval;
        while !stop.cancelled() && Instant::now() < next {
            thread::sleep(WAIT_SLICE.min(next.saturating_duration_since(Instant::now())));
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::payload::{CollectorIdentifiers, CollectorResourceKind};
    use serde_json::{json, Value};

    pub(crate) fn collector() -> Collector {
        Collector {
            id: "rack-pdus".into(),
            kind: CollectorKind::PowerPoller,
        }
    }

    fn device() -> Device {
        Device {
            mapping: "raritan_pdu2",
            mapping_version: 1,
            resource: CollectorResource {
                kind: CollectorResourceKind::Pdu,
                target: None,
                identifiers: CollectorIdentifiers {
                    serial_number: Some("PKE0954001".into()),
                    ..CollectorIdentifiers::default()
                },
                attributes: None,
                interfaces: None,
                domain: None,
            },
            readings: vec![
                Reading {
                    sensor: "inlet/1".into(),
                    boundary: "feed",
                    quantity: "real_power",
                    component: None,
                    leg: None,
                    measurement: Measurement::Value(2_455.0),
                },
                Reading {
                    sensor: "outlet/2".into(),
                    boundary: "outlet",
                    quantity: "state",
                    component: Some(("power_outlet", "2".into())),
                    leg: None,
                    measurement: Measurement::State("off"),
                },
                Reading {
                    sensor: "outlet/3".into(),
                    boundary: "outlet",
                    quantity: "real_power",
                    component: Some(("power_outlet", "3".into())),
                    leg: None,
                    measurement: Measurement::Failed,
                },
            ],
        }
    }

    fn outcome(address: &str, result: Result<Device, TargetError>) -> Outcome {
        Outcome {
            address: address.into(),
            read_at: DateTime::parse_from_rfc3339("2026-10-22T12:00:00Z")
                .unwrap()
                .with_timezone(&Utc),
            result,
        }
    }

    fn encode(batch: &TelemetryBatch) -> Value {
        serde_json::to_value(batch).unwrap()
    }

    #[test]
    fn the_source_status_says_why_nothing_was_read() {
        let status = |errors: &[TargetError]| {
            source_status(
                &errors
                    .iter()
                    .map(|error| outcome("10.0.0.9", Err(error.clone())))
                    .collect::<Vec<_>>(),
            )
        };
        let unreachable = TargetError::Unreachable("timeout".into());
        let denied = TargetError::NotPermitted("401".into());
        let unsupported = TargetError::Unsupported("no MIB".into());
        assert_eq!(status(std::slice::from_ref(&unreachable)), "unreachable");
        assert_eq!(
            status(&[unreachable.clone(), unsupported.clone()]),
            "not_present"
        );
        assert_eq!(status(&[unsupported, denied]), "not_permitted");
        assert_eq!(
            source_status(&[
                outcome("10.0.0.5", Ok(device())),
                outcome("10.0.0.9", Err(unreachable))
            ]),
            "available"
        );
    }

    #[test]
    fn reports_devices_by_target_and_unread_targets_as_unreachable() {
        let outcomes = [
            outcome("10.0.0.5", Ok(device())),
            outcome("10.0.0.9", Err(TargetError::Unreachable("timeout".into()))),
        ];
        let [(_, report)] = <[_; 1]>::try_from(reports(&collector(), &outcomes)).unwrap();
        let report: Value = serde_json::from_slice(&report).unwrap();

        assert_eq!(report["scope"], "targets");
        assert_eq!(report["collector"]["kind"], "power_poller");
        assert_eq!(report["complete"], true);
        assert_eq!(report["targets"][1]["status"], "unreachable");
        assert_eq!(report["targets"][1]["error"], "timeout");
        assert_eq!(
            report["resources"],
            json!([{
                "kind": "pdu",
                "target": "10.0.0.5",
                "identifiers": {"serial_number": "PKE0954001"}
            }])
        );
    }

    #[test]
    fn splits_reports_by_target_count() {
        let outcomes: Vec<_> = (0..250)
            .map(|index| {
                outcome(
                    &format!("10.1.0.{index}"),
                    Err(TargetError::Unreachable("x".repeat(1_000))),
                )
            })
            .collect();
        let reports = reports(&collector(), &outcomes);
        assert_eq!(reports.len(), 3);
        assert!(reports
            .iter()
            .all(|(_, body)| body.len() <= MAX_OBSERVATION_BYTES));
    }

    #[test]
    fn a_device_that_stops_answering_reports_its_series_as_failed() {
        let mut known = Known::new();
        let [batch] = <[_; 1]>::try_from(batches(
            &collector(),
            &[outcome("10.0.0.5", Ok(device()))],
            &mut known,
            180,
        ))
        .unwrap();
        let batch = encode(&batch);
        assert_eq!(
            batch["collector"],
            json!({"id": "rack-pdus", "kind": "power_poller"})
        );
        assert_eq!(
            batch["samples"][0],
            json!({
                "target": "10.0.0.5",
                "sensor": "inlet/1",
                "boundary": "feed",
                "quantity": "real_power",
                "unit": "W",
                "coverage": "complete",
                "status": "valid",
                "origin": "native",
                "value": 2455.0,
                "window": {"start": "2026-10-22T12:00:00Z", "end": "2026-10-22T12:00:00Z"},
                "event_at": "2026-10-22T12:00:00Z",
                "mapping": {"name": "raritan_pdu2", "version": 1},
                "fresh_for_seconds": 180
            })
        );
        assert_eq!(batch["samples"][1]["state"], "off");
        assert!(batch["samples"][1].get("unit").is_none());
        assert_eq!(batch["samples"][2]["status"], "failed");
        assert!(batch["samples"][2].get("value").is_none());

        let [failed] = <[_; 1]>::try_from(batches(
            &collector(),
            &[outcome(
                "10.0.0.5",
                Err(TargetError::Unreachable("timeout".into())),
            )],
            &mut known,
            180,
        ))
        .unwrap();
        let failed = encode(&failed);
        let failed = failed["samples"].as_array().unwrap();
        assert_eq!(failed.len(), 3);
        assert!(failed
            .iter()
            .all(|sample| sample["status"] == "failed" && sample.get("value").is_none()));

        // A target removed from the configuration is forgotten.
        assert!(batches(&collector(), &[], &mut known, 180).is_empty());
        assert!(known.is_empty());
    }

    #[test]
    fn freshness_covers_two_missed_polls_and_delivery() {
        assert_eq!(fresh_for_seconds(Duration::from_secs(30)), 300);
        assert_eq!(fresh_for_seconds(Duration::from_secs(300)), 1_020);

        // A reading delivered by one flush is up to a poll old and must stay current until the
        // next flush, through a missed poll, with time to spare for the request itself.
        for seconds in [10, 60, 90, 120, 600] {
            let interval = Duration::from_secs(seconds);
            let oldest_at_flush = seconds + queue::FLUSH_INTERVAL.as_secs();
            assert!(u64::from(fresh_for_seconds(interval)) >= oldest_at_flush + seconds + 60);
        }
    }

    #[test]
    fn reports_inventory_when_it_changes_and_readings_every_poll() {
        use std::sync::{mpsc, Arc, Mutex};

        let (observations, observed) = mpsc::channel();
        let (telemetry, measured) = mpsc::channel();
        let observations = Mutex::new(observations);
        let telemetry = Mutex::new(telemetry);
        let sinks = Sinks {
            observations: Arc::new(move |id, _body: &[u8]| {
                observations.lock().unwrap().send(id).unwrap();
            }),
            telemetry: Arc::new(move |id, _body: &[u8]| {
                telemetry.lock().unwrap().send(id).unwrap();
            }),
        };
        let sources = PowerSources::default();
        let stop = Cancellation::default();
        let worker = {
            let stop = stop.clone();
            let sources = sources.clone();
            thread::spawn(move || {
                let poll = |_: &Cancellation| vec![outcome("10.0.0.5", Ok(device()))];
                run(
                    &collector(),
                    Duration::from_millis(50),
                    &stop,
                    &sinks,
                    &sources,
                    &poll,
                );
            })
        };

        let wait = Duration::from_secs(5);
        observed.recv_timeout(wait).unwrap();
        let first = measured.recv_timeout(wait).unwrap();
        let second = measured.recv_timeout(wait).unwrap();
        assert_ne!(first, second, "each poll is a new batch");
        stop.cancel();
        worker.join().unwrap();

        // The unchanged device was reported once.
        assert!(observed.try_recv().is_err());
        assert_eq!(sources.status("power_poller/rack-pdus"), Some("available"));
    }

    #[test]
    fn forgets_only_the_removed_modules_of_its_kind() {
        let sources = PowerSources::default();
        for source in ["hwmon", "power_poller/a", "power_poller/b", "bmc_power/a"] {
            sources.publish(source, "available");
        }
        retain_sources(&sources, CollectorKind::PowerPoller, &["a"]);
        let names: Vec<_> = sources
            .reports()
            .unwrap()
            .into_iter()
            .map(|report| report.source)
            .collect();
        assert_eq!(names, ["bmc_power/a", "hwmon", "power_poller/a"]);
    }
}
