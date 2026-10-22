//! The `power_poller` collector's PDU module (RFD 10, "Collectors and BMCs").
//!
//! Each `[[collectors.power]]` module polls its PDUs over SNMP on its own thread. Every poll
//! queues the PDUs' readings as telemetry, and the PDUs themselves as a `targets` inventory
//! report whenever what the targets show changes, or every fifteen minutes, so Renga maps each
//! target to its PDU and the readings to that PDU's outlets and inlet. The module reuses the
//! switch poller's configuration, credentials, and SNMP client (RFD 11), not its mapping.

pub mod mibs;

use crate::{
    cancellation::Cancellation,
    payload::{
        Collector, CollectorIdentifiers, CollectorKind, CollectorResource, CollectorResourceKind,
        HostAttributes, Reachability, ReportScope, SampleComponent, SampleMapping, SampleWindow,
        ScopedReport, TargetStatus, TelemetryBatch, TelemetrySample, MAX_OBSERVATION_BYTES,
        MAX_TELEMETRY_BYTES,
    },
    power::PowerSources,
    snmp::{
        self,
        client::{self, PollError, Session, WireSession},
        config::{Intervals, SnmpCollector, Target},
        mibs::MAX_STRING_CHARS,
        worker::Sink,
    },
};
use chrono::{DateTime, Utc};
use mibs::{Measurement, Pdu, Reading, Vendor, MAPPING_VERSION};
use std::{
    collections::BTreeMap,
    thread,
    time::{Duration, Instant},
};
use tracing::{info, warn};
use uuid::Uuid;

/// Readings go stale within minutes, so PDUs are polled far more often than switches.
pub(crate) const POWER_INTERVALS: Intervals = Intervals {
    default: 60,
    min: 30,
};
/// How often an unchanged set of PDUs is reported again.
const INVENTORY_INTERVAL: Duration = Duration::from_secs(900);
/// A whole target must finish within this many request timeouts.
const TARGET_BUDGET_TIMEOUTS: u32 = 12;
/// A PDU's report entry is a few short strings, so this many always fit in one report.
const TARGETS_PER_REPORT: usize = 100;
/// Samples run to a few hundred bytes, so this many stay well within the batch size limit.
const SAMPLES_PER_BATCH: usize = 1_000;
const MAX_FRESH_FOR_SECONDS: u64 = 86_400;
const WAIT_SLICE: Duration = Duration::from_millis(250);

/// Why a target has no PDU this poll.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetError {
    /// The device did not answer, or not in full.
    Unreachable(String),
    /// The device answered, but not as a PDU this module can map.
    Unsupported(String),
}

impl TargetError {
    fn message(&self) -> &str {
        match self {
            Self::Unreachable(message) | Self::Unsupported(message) => message,
        }
    }
}

/// One target's poll.
#[derive(Debug, Clone)]
pub struct Outcome {
    pub target: Target,
    pub read_at: DateTime<Utc>,
    pub result: Result<Pdu, TargetError>,
}

/// Polls every target of `collector`. `open` connects to one target; tests pass recordings.
pub fn poll<F>(collector: &SnmpCollector, stopped: &Cancellation, open: F) -> Vec<Outcome>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, PollError> + Sync,
{
    let budget = collector.timeout * TARGET_BUDGET_TIMEOUTS;
    snmp::each_target(collector, |target| Outcome {
        target: target.clone(),
        result: if stopped.cancelled() {
            Err(TargetError::Unreachable("polling was cancelled".into()))
        } else {
            poll_target(target, &open, budget, stopped)
        },
        read_at: Utc::now(),
    })
}

fn poll_target<F>(
    target: &Target,
    open: &F,
    budget: Duration,
    stopped: &Cancellation,
) -> Result<Pdu, TargetError>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, PollError>,
{
    let unreachable = |error: PollError| TargetError::Unreachable(error.0);
    let deadline = Instant::now() + budget;
    let mut session = open(target).map_err(unreachable)?;
    let identity = client::read(session.as_mut(), deadline, stopped, mibs::SCALARS, &[])
        .map_err(unreachable)?;
    let vendor = Vendor::detect(&identity).ok_or_else(|| {
        TargetError::Unsupported(
            "the device answers neither Raritan PDU2-MIB nor APC PowerNet-MIB rPDU2".into(),
        )
    })?;
    let mut answers = client::read(session.as_mut(), deadline, stopped, &[], vendor.columns())
        .map_err(unreachable)?;
    for (oid, value) in identity.iter() {
        answers.insert(oid.clone(), value.clone());
    }
    mibs::pdu(vendor, &answers).map_err(|error| TargetError::Unsupported(error.0))
}

/// The status of the module as one power source: available while any PDU is read.
pub fn source_status(outcomes: &[Outcome]) -> &'static str {
    if outcomes.iter().any(|outcome| outcome.result.is_ok()) {
        "available"
    } else if outcomes
        .iter()
        .any(|outcome| matches!(outcome.result, Err(TargetError::Unsupported(_))))
    {
        "not_present"
    } else {
        "unreachable"
    }
}

/// The source name a module reports in check-ins.
pub fn source(collector_id: &str) -> String {
    format!("power_poller/{collector_id}")
}

/// Complete `targets` reports of the PDUs, in order. A target without a PDU is reported
/// unreachable, so the PDU Renga last saw there stays as it was instead of being withdrawn.
pub fn reports(collector_id: &str, outcomes: &[Outcome]) -> Vec<(Uuid, Vec<u8>)> {
    outcomes
        .chunks(TARGETS_PER_REPORT)
        .filter_map(|chunk| {
            let mut targets = Vec::with_capacity(chunk.len());
            let mut resources = Vec::new();
            for outcome in chunk {
                let address = outcome.target.address.clone();
                match &outcome.result {
                    Ok(pdu) => {
                        targets.push(TargetStatus {
                            address: address.clone(),
                            status: Reachability::Reachable,
                            error: None,
                        });
                        resources.push(resource(&address, pdu));
                    }
                    Err(error) => targets.push(TargetStatus {
                        address,
                        status: Reachability::Unreachable,
                        error: Some(error.message().chars().take(MAX_STRING_CHARS).collect()),
                    }),
                }
            }
            let report = ScopedReport::new(
                Collector {
                    id: collector_id.to_owned(),
                    kind: CollectorKind::PowerPoller,
                },
                ReportScope::Targets { targets },
                true,
                resources,
            );
            let body = serde_json::to_vec(&report).ok()?;
            (body.len() <= MAX_OBSERVATION_BYTES).then_some((report.observation_id, body))
        })
        .collect()
}

/// The PDU as Renga reconciles it: matched by serial number, named by its target.
pub fn resource(target: &str, pdu: &Pdu) -> CollectorResource {
    CollectorResource {
        kind: CollectorResourceKind::Pdu,
        target: Some(target.to_owned()),
        identifiers: CollectorIdentifiers {
            hostname: pdu.hostname.clone(),
            serial_number: Some(pdu.serial_number.clone()),
            ..CollectorIdentifiers::default()
        },
        attributes: Some(HostAttributes {
            vendor: pdu.vendor.clone(),
            model: pdu.model.clone(),
            ..HostAttributes::default()
        }),
        interfaces: None,
        domain: None,
    }
}

/// The readings each target last served, with their mapping, so a target that stops answering
/// reports them as failed.
pub type Known = BTreeMap<String, (&'static str, Vec<Reading>)>;

/// The poll's telemetry batches. A target without a PDU this poll sends every reading it last
/// served as failed, so Renga knows those series are unknown now rather than waiting for them to
/// expire, never zero.
pub fn batches(
    collector_id: &str,
    outcomes: &[Outcome],
    known: &mut Known,
    fresh_for_seconds: u32,
) -> Vec<TelemetryBatch> {
    known.retain(|address, _| {
        outcomes
            .iter()
            .any(|outcome| &outcome.target.address == address)
    });
    let mut samples = Vec::new();
    for outcome in outcomes {
        let address = &outcome.target.address;
        let (mapping, readings, failed) = match &outcome.result {
            Ok(pdu) => {
                known.insert(address.clone(), (pdu.mapping, pdu.readings.clone()));
                (pdu.mapping, &pdu.readings, false)
            }
            Err(_) => match known.get(address) {
                Some((mapping, readings)) => (*mapping, readings, true),
                None => continue,
            },
        };
        samples.extend(readings.iter().map(|reading| {
            sample(
                address,
                reading,
                mapping,
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
        let batch = TelemetryBatch::collector(collector_id, CollectorKind::PowerPoller, chunk);
        if serde_json::to_vec(&batch).is_ok_and(|body| body.len() <= MAX_TELEMETRY_BYTES) {
            batches.push(batch);
            continue;
        }
        let mut chunk = batch.samples;
        if chunk.len() == 1 {
            warn!(
                collector = collector_id,
                "a PDU sample is too large to send"
            );
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
    mapping: &'static str,
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
        // The MIBs report instantaneous values.
        window: SampleWindow {
            start: read_at,
            end: read_at,
        },
        event_at: read_at,
        mapping: SampleMapping {
            name: mapping,
            version: MAPPING_VERSION,
        },
        fresh_for_seconds,
    }
}

/// Readings stay current through two missed polls.
pub fn fresh_for_seconds(interval: Duration) -> u32 {
    u32::try_from(
        interval
            .as_secs()
            .saturating_mul(3)
            .clamp(180, MAX_FRESH_FOR_SECONDS),
    )
    .unwrap_or(u32::MAX)
}

/// Where a module's output goes: inventory reports and telemetry use separate queues.
#[derive(Clone)]
pub struct Sinks {
    pub observations: Sink,
    pub telemetry: Sink,
}

/// The running PDU modules of one configuration; dropping them stops every thread.
pub struct Pollers {
    collectors: Vec<SnmpCollector>,
    stop: Cancellation,
}

impl Pollers {
    /// Starts one thread per module. Each polls immediately, then every interval.
    pub fn start(collectors: Vec<SnmpCollector>, sinks: Sinks, sources: PowerSources) -> Self {
        let configured: Vec<String> = collectors
            .iter()
            .map(|collector| source(&collector.id))
            .collect();
        // A removed module is no longer a source this agent reports.
        sources.retain(|name| {
            !name.starts_with("power_poller/") || configured.iter().any(|kept| kept == name)
        });
        let stop = Cancellation::default();
        for collector in &collectors {
            let collector = collector.clone();
            let stop = stop.clone();
            let sinks = sinks.clone();
            let sources = sources.clone();
            let name = format!("power-{}", collector.id);
            if let Err(error) = thread::Builder::new().name(name).spawn(move || {
                let credentials = collector.credentials.clone();
                let timeout = collector.timeout;
                let open = move |target: &Target| {
                    WireSession::open(target, &credentials, timeout)
                        .map(|session| Box::new(session) as Box<dyn Session>)
                };
                run(&collector, &stop, &sinks, &sources, &open);
            }) {
                warn!(%error, "cannot start a PDU power module");
            }
        }
        Self { collectors, stop }
    }

    pub fn collectors(&self) -> &[SnmpCollector] {
        &self.collectors
    }
}

impl Drop for Pollers {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

type Opener<'a> = &'a (dyn Fn(&Target) -> Result<Box<dyn Session>, PollError> + Sync);

/// What the targets showed, to tell when the PDUs need reporting again.
type Shown = Vec<(String, Option<(String, Option<String>)>)>;

fn shown(outcomes: &[Outcome]) -> Shown {
    outcomes
        .iter()
        .map(|outcome| {
            (
                outcome.target.address.clone(),
                outcome
                    .result
                    .as_ref()
                    .ok()
                    .map(|pdu| (pdu.serial_number.clone(), pdu.hostname.clone())),
            )
        })
        .collect()
}

fn run(
    collector: &SnmpCollector,
    stop: &Cancellation,
    sinks: &Sinks,
    sources: &PowerSources,
    open: Opener<'_>,
) {
    let source = source(&collector.id);
    let fresh_for = fresh_for_seconds(collector.interval);
    let mut known = Known::new();
    let mut reported: Option<(Instant, Shown)> = None;
    while !stop.cancelled() {
        let started = Instant::now();
        let outcomes = poll(collector, stop, open);
        if stop.cancelled() {
            break;
        }
        for outcome in &outcomes {
            if let Err(error) = &outcome.result {
                warn!(collector = %collector.id, target = %outcome.target.address, error = error.message(), "PDU not read");
            }
        }
        let status = source_status(&outcomes);
        if sources.status(&source) != Some(status) {
            info!(collector = %collector.id, status, "PDU power source status");
        }
        sources.publish(&source, status);

        for batch in batches(&collector.id, &outcomes, &mut known, fresh_for) {
            match serde_json::to_vec(&batch) {
                Ok(body) => (sinks.telemetry)(batch.replay_id, &body),
                Err(error) => {
                    warn!(collector = %collector.id, %error, "cannot encode PDU readings")
                }
            }
        }

        let now_shown = shown(&outcomes);
        let due = reported
            .as_ref()
            .is_none_or(|(at, before)| *before != now_shown || at.elapsed() >= INVENTORY_INTERVAL);
        if due {
            for (observation_id, body) in reports(&collector.id, &outcomes) {
                (sinks.observations)(observation_id, &body);
            }
            reported = Some((Instant::now(), now_shown));
        }

        let next = started + collector.interval;
        while !stop.cancelled() && Instant::now() < next {
            thread::sleep(WAIT_SLICE.min(next.saturating_duration_since(Instant::now())));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snmp::{client::tests::Recorded, config::Credentials};
    use serde_json::{json, Value};
    use std::sync::{mpsc, Arc, Mutex};

    fn collector(targets: &[&str]) -> SnmpCollector {
        SnmpCollector {
            id: "rack-pdus".into(),
            targets: targets
                .iter()
                .map(|address| Target::parse(address).unwrap())
                .collect(),
            credentials: Credentials::V2c {
                community_file: "/dev/null".into(),
            },
            interval: Duration::from_secs(60),
            timeout: Duration::from_secs(1),
            max_concurrent_targets: 2,
        }
    }

    fn open(target: &Target) -> Result<Box<dyn Session>, PollError> {
        match target.host.as_str() {
            "10.0.0.5" => Ok(Box::new(Recorded::new(&mibs::tests::raritan_answers()))),
            "10.0.0.6" => Ok(Box::new(Recorded::new(&mibs::tests::apc_answers()))),
            "10.0.0.7" => Ok(Box::new(
                Recorded::new(&crate::snmp::mibs::tests::answers()),
            )),
            _ => Err(PollError("no answer before the timeout".into())),
        }
    }

    fn decode(body: &[u8]) -> Value {
        serde_json::from_slice(body).unwrap()
    }

    fn encode(batch: &TelemetryBatch) -> Value {
        serde_json::to_value(batch).unwrap()
    }

    #[test]
    fn polls_each_vendor_and_tells_unsupported_devices_from_silent_ones() {
        let outcomes = poll(
            &collector(&["10.0.0.5", "10.0.0.6", "10.0.0.7", "10.0.0.9"]),
            &Cancellation::default(),
            open,
        );

        assert_eq!(outcomes[0].result.as_ref().unwrap().mapping, "raritan_pdu2");
        assert_eq!(outcomes[1].result.as_ref().unwrap().mapping, "apc_rpdu2");
        // A switch answers SNMP, but not as a PDU.
        assert!(matches!(
            outcomes[2].result,
            Err(TargetError::Unsupported(_))
        ));
        assert!(matches!(
            outcomes[3].result,
            Err(TargetError::Unreachable(_))
        ));
        assert_eq!(source_status(&outcomes), "available");
        assert_eq!(source_status(&outcomes[2..]), "not_present");
        assert_eq!(source_status(&outcomes[3..]), "unreachable");
    }

    #[test]
    fn reports_pdus_by_target_and_unread_targets_as_unreachable() {
        let outcomes = poll(
            &collector(&["10.0.0.5", "10.0.0.9"]),
            &Cancellation::default(),
            open,
        );
        let [(_, report)] = <[_; 1]>::try_from(reports("rack-pdus", &outcomes)).unwrap();
        let report = decode(&report);

        assert_eq!(report["scope"], "targets");
        assert_eq!(report["collector"]["kind"], "power_poller");
        assert_eq!(report["complete"], true);
        assert_eq!(report["targets"][1]["status"], "unreachable");
        assert_eq!(
            report["resources"],
            json!([{
                "kind": "pdu",
                "target": "10.0.0.5",
                "identifiers": {"hostname": "pdu-a1", "serial_number": "PKE0954001"},
                "attributes": {"vendor": "Raritan", "model": "PX3-5190R"}
            }])
        );
    }

    #[test]
    fn splits_reports_by_target_count() {
        let outcomes: Vec<_> = (0..250)
            .map(|index| Outcome {
                target: Target::parse(&format!("10.1.0.{index}")).unwrap(),
                read_at: Utc::now(),
                result: Err(TargetError::Unreachable("x".repeat(1_000))),
            })
            .collect();
        let reports = reports("rack-pdus", &outcomes);
        assert_eq!(reports.len(), 3);
        assert!(reports
            .iter()
            .all(|(_, body)| body.len() <= MAX_OBSERVATION_BYTES));
    }

    #[test]
    fn a_pdu_that_stops_answering_reports_its_series_as_failed() {
        let mut known = Known::new();
        let read_at = DateTime::parse_from_rfc3339("2026-10-22T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let mut outcomes = poll(&collector(&["10.0.0.5"]), &Cancellation::default(), open);
        outcomes[0].read_at = read_at;

        let [batch] = <[_; 1]>::try_from(batches("rack-pdus", &outcomes, &mut known, 180)).unwrap();
        let batch = encode(&batch);
        assert_eq!(
            batch["collector"],
            json!({"id": "rack-pdus", "kind": "power_poller"})
        );
        let samples = batch["samples"].as_array().unwrap();
        let inlet = samples
            .iter()
            .find(|sample| sample["sensor"] == "inlet/1" && sample["quantity"] == "real_power")
            .unwrap();
        assert_eq!(
            inlet,
            &json!({
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
        let leg = samples
            .iter()
            .find(|sample| sample["boundary"] == "leg")
            .unwrap();
        assert_eq!(leg["leg"], "a");
        let off = samples
            .iter()
            .find(|sample| sample["sensor"] == "outlet/2" && sample["quantity"] == "state")
            .unwrap();
        assert_eq!(off["state"], "off");
        assert!(off.get("unit").is_none());
        let unavailable = samples
            .iter()
            .find(|sample| sample["sensor"] == "outlet/3" && sample["quantity"] == "real_power")
            .unwrap();
        assert_eq!(unavailable["status"], "failed");
        assert!(unavailable.get("value").is_none());

        let silent = vec![Outcome {
            result: Err(TargetError::Unreachable("timeout".into())),
            ..outcomes[0].clone()
        }];
        let [failed] = <[_; 1]>::try_from(batches("rack-pdus", &silent, &mut known, 180)).unwrap();
        let failed = encode(&failed);
        let failed = failed["samples"].as_array().unwrap();
        assert_eq!(failed.len(), samples.len());
        assert!(failed
            .iter()
            .all(|sample| sample["status"] == "failed" && sample.get("value").is_none()));

        // A target removed from the configuration is forgotten.
        assert!(batches("rack-pdus", &[], &mut known, 180).is_empty());
        assert!(known.is_empty());
    }

    #[test]
    fn freshness_covers_two_missed_polls() {
        assert_eq!(fresh_for_seconds(Duration::from_secs(30)), 180);
        assert_eq!(fresh_for_seconds(Duration::from_secs(300)), 900);
    }

    /// The recorded PDU as the mapper reports it. Renga's collector report tests post this
    /// file, so a mapping the server would reject fails there. Set `RENGA_UPDATE_FIXTURES=1` to
    /// rewrite it after an intended mapping change.
    #[test]
    fn the_recorded_pdu_matches_the_server_fixture() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../test/fixtures/collectors/recorded_pdu.json"
        );
        let pdu = mibs::pdu(Vendor::Raritan, &mibs::tests::raritan_answers()).unwrap();
        let mapped = serde_json::to_value(resource("10.0.0.5", &pdu)).unwrap();
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
    fn reports_inventory_when_it_changes_and_readings_every_poll() {
        let mut collector = collector(&["10.0.0.5"]);
        collector.interval = Duration::from_millis(50);
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
            thread::spawn(move || run(&collector, &stop, &sinks, &sources, &open))
        };

        let wait = Duration::from_secs(5);
        observed.recv_timeout(wait).unwrap();
        let first = measured.recv_timeout(wait).unwrap();
        let second = measured.recv_timeout(wait).unwrap();
        assert_ne!(first, second, "each poll is a new batch");
        stop.cancel();
        worker.join().unwrap();

        // The unchanged PDU was reported once.
        assert!(observed.try_recv().is_err());
        assert_eq!(sources.status("power_poller/rack-pdus"), Some("available"));
    }
}
