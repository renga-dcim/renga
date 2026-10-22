//! The `power_poller` collector's PDU module (RFD 10, "Collectors and BMCs").
//!
//! Each `[[collectors.power]]` module polls its PDUs over SNMP on its own thread, as every power
//! collector module does (see `power::collector`), so Renga maps each target to its PDU and the
//! readings to that PDU's outlets and inlet. The module reuses the switch poller's
//! configuration, credentials, and SNMP client (RFD 11), not its mapping.

pub mod mibs;

use crate::{
    cancellation::Cancellation,
    payload::{
        Collector, CollectorIdentifiers, CollectorKind, CollectorResource, CollectorResourceKind,
        HostAttributes,
    },
    power::{
        collector::{self, Device, Outcome, Sinks, TargetError},
        PowerSources,
    },
    snmp::{
        self,
        client::{self, PollError, Session, WireSession},
        config::{Intervals, SnmpCollector, Target},
    },
};
use chrono::Utc;
use mibs::{Pdu, Vendor, MAPPING_VERSION};
use std::{
    thread,
    time::{Duration, Instant},
};
use tracing::warn;

/// Readings go stale within minutes, so PDUs are polled far more often than switches.
pub(crate) const POWER_INTERVALS: Intervals = Intervals {
    default: 60,
    min: 30,
};
/// A whole target must finish within this many request timeouts.
const TARGET_BUDGET_TIMEOUTS: u32 = 12;

/// Polls every target of `collector`. `open` connects to one target; tests pass recordings.
pub fn poll<F>(collector: &SnmpCollector, stopped: &Cancellation, open: F) -> Vec<Outcome>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, PollError> + Sync,
{
    let budget = collector.timeout * TARGET_BUDGET_TIMEOUTS;
    snmp::each_target(collector, |target| Outcome {
        address: target.address.clone(),
        result: if stopped.cancelled() {
            Err(TargetError::Unreachable("polling was cancelled".into()))
        } else {
            poll_target(target, &open, budget, stopped).map(device)
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

/// The PDU as Renga reconciles it: matched by serial number, named by its target.
pub fn device(pdu: Pdu) -> Device {
    Device {
        mapping: pdu.mapping,
        mapping_version: MAPPING_VERSION,
        resource: CollectorResource {
            kind: CollectorResourceKind::Pdu,
            target: None,
            identifiers: CollectorIdentifiers {
                hostname: pdu.hostname,
                serial_number: Some(pdu.serial_number),
                ..CollectorIdentifiers::default()
            },
            attributes: Some(HostAttributes {
                vendor: pdu.vendor,
                model: pdu.model,
                ..HostAttributes::default()
            }),
            interfaces: None,
            domain: None,
        },
        readings: pdu.readings,
    }
}

/// The running PDU modules of one configuration; dropping them stops every thread.
pub struct Pollers {
    collectors: Vec<SnmpCollector>,
    stop: Cancellation,
}

impl Pollers {
    /// Starts one thread per module. Each polls immediately, then every interval.
    pub fn start(collectors: Vec<SnmpCollector>, sinks: Sinks, sources: PowerSources) -> Self {
        // A removed module is no longer a source this agent reports.
        let ids: Vec<&str> = collectors
            .iter()
            .map(|collector| collector.id.as_str())
            .collect();
        collector::retain_sources(&sources, CollectorKind::PowerPoller, &ids);
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
                let module = Collector {
                    id: collector.id.clone(),
                    kind: CollectorKind::PowerPoller,
                };
                let poll = |stop: &Cancellation| poll(&collector, stop, &open);
                collector::run(&module, collector.interval, &stop, &sinks, &sources, &poll);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snmp::{client::tests::Recorded, config::Credentials};
    use serde_json::{json, Value};

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

    #[test]
    fn polls_each_vendor_and_tells_unsupported_devices_from_silent_ones() {
        let outcomes = poll(
            &collector(&["10.0.0.5", "10.0.0.6", "10.0.0.7", "10.0.0.9"]),
            &Cancellation::default(),
            open,
        );

        let read = outcomes[0].result.as_ref().unwrap();
        assert_eq!((read.mapping, read.mapping_version), ("raritan_pdu2", 1));
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
        assert_eq!(collector::source_status(&outcomes), "available");
        assert_eq!(collector::source_status(&outcomes[2..]), "not_present");
        assert_eq!(collector::source_status(&outcomes[3..]), "unreachable");
    }

    #[test]
    fn reports_pdus_by_target_with_their_legs_and_outlets() {
        let module = Collector {
            id: "rack-pdus".into(),
            kind: CollectorKind::PowerPoller,
        };
        let outcomes = poll(&collector(&["10.0.0.5"]), &Cancellation::default(), open);
        let [(_, report)] = <[_; 1]>::try_from(collector::reports(&module, &outcomes)).unwrap();
        let report: Value = serde_json::from_slice(&report).unwrap();
        assert_eq!(
            report["resources"],
            json!([{
                "kind": "pdu",
                "target": "10.0.0.5",
                "identifiers": {"hostname": "pdu-a1", "serial_number": "PKE0954001"},
                "attributes": {"vendor": "Raritan", "model": "PX3-5190R"}
            }])
        );

        let mut known = collector::Known::new();
        let [batch] =
            <[_; 1]>::try_from(collector::batches(&module, &outcomes, &mut known, 180)).unwrap();
        let samples = serde_json::to_value(&batch).unwrap()["samples"].clone();
        let samples = samples.as_array().unwrap();
        let leg = samples
            .iter()
            .find(|sample| sample["boundary"] == "leg")
            .unwrap();
        assert_eq!(leg["leg"], "a");
        assert_eq!(
            leg["mapping"],
            json!({"name": "raritan_pdu2", "version": 1})
        );
        let outlet = samples
            .iter()
            .find(|sample| sample["sensor"] == "outlet/2" && sample["quantity"] == "state")
            .unwrap();
        assert_eq!(
            outlet["component"],
            json!({"kind": "power_outlet", "name": "2"})
        );
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
        let mapped = serde_json::to_value(CollectorResource {
            target: Some("10.0.0.5".into()),
            ..device(pdu).resource
        })
        .unwrap();
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
}
