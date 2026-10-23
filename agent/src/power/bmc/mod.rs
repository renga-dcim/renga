//! The `bmc_power` collector (RFD 10, "Collectors and BMCs").
//!
//! Each `[[collectors.bmc]]` module reads its BMCs' Redfish services on its own thread, as every
//! power collector module does (see `power::collector`). A BMC reports the server it manages by
//! the system UUID SMBIOS also reports, so Renga matches it to the server its host agent
//! reports, and the readings land on that server's power ports.

pub mod client;
pub mod config;
pub mod redfish;

use crate::{
    cancellation::Cancellation,
    payload::{Collector, CollectorKind},
    power::{
        collector::{self, Device, Outcome, Sinks, TargetError},
        PowerSources,
    },
    snmp,
};
use chrono::Utc;
use client::{Redfish, WireRedfish};
use config::{BmcCollector, BmcTarget};
use redfish::MapError;
use serde_json::Value;
use std::{thread, time::Instant};
use tracing::warn;

/// A whole target, every request included, must finish within this many request timeouts.
const TARGET_BUDGET_TIMEOUTS: u32 = 4;

/// Polls every target of `collector`. `open` connects to one target; tests pass recordings.
pub fn poll<F>(collector: &BmcCollector, stopped: &Cancellation, open: F) -> Vec<Outcome>
where
    F: Fn(&BmcTarget, Instant) -> Result<Box<dyn Redfish>, TargetError> + Sync,
{
    let budget = collector.timeout * TARGET_BUDGET_TIMEOUTS;
    snmp::each(
        &collector.targets,
        collector.max_concurrent_targets,
        |target| Outcome {
            address: target.target.address.clone(),
            result: if stopped.cancelled() {
                Err(TargetError::Unreachable("polling was cancelled".into()))
            } else {
                open(target, Instant::now() + budget).and_then(|mut service| read(service.as_mut()))
            },
            read_at: Utc::now(),
        },
    )
}

/// Reads the first system the service lists, its chassis, and the chassis's power.
pub fn read(service: &mut dyn Redfish) -> Result<Device, TargetError> {
    let unsupported = |error: MapError| TargetError::Unsupported(error.0);
    let systems = service.get(redfish::SYSTEMS)?;
    let system =
        service.get(&redfish::first_member(&systems, "computer system").map_err(unsupported)?)?;
    let (chassis, linked) = match redfish::chassis_link(&system) {
        Some(link) => (link, true),
        None => (
            redfish::first_member(&service.get(redfish::CHASSIS)?, "chassis")
                .map_err(unsupported)?,
            false,
        ),
    };
    let chassis = service.get(&chassis)?;
    let power = service.get(&redfish::power_link(&chassis).map_err(unsupported)?)?;
    // A shared or unrelated chassis's power is not this server's, so only the server is
    // reported.
    if !redfish::owns(&systems, &system, &chassis, linked) {
        warn!("the BMC's chassis is not one server's own; reporting the server without readings");
        return redfish::device(&system, &Value::Null).map_err(unsupported);
    }
    redfish::device(&system, &power).map_err(unsupported)
}

/// The running BMC modules of one configuration; dropping them stops every thread.
pub struct Pollers {
    collectors: Vec<BmcCollector>,
    stop: Cancellation,
}

impl Pollers {
    /// Starts one thread per module. Each polls immediately, then every interval.
    pub fn start(collectors: Vec<BmcCollector>, sinks: Sinks, sources: PowerSources) -> Self {
        // A removed module is no longer a source this agent reports.
        let ids: Vec<&str> = collectors
            .iter()
            .map(|collector| collector.id.as_str())
            .collect();
        collector::retain_sources(&sources, CollectorKind::BmcPower, &ids);
        let stop = Cancellation::default();
        for collector in &collectors {
            let collector = collector.clone();
            let stop = stop.clone();
            let sinks = sinks.clone();
            let sources = sources.clone();
            let name = format!("bmc-{}", collector.id);
            if let Err(error) = thread::Builder::new().name(name).spawn(move || {
                let module = Collector {
                    id: collector.id.clone(),
                    kind: CollectorKind::BmcPower,
                };
                let open = |target: &BmcTarget, deadline| {
                    WireRedfish::open(&collector, target, deadline)
                        .map(|service| Box::new(service) as Box<dyn Redfish>)
                };
                let poll = |stop: &Cancellation| poll(&collector, stop, open);
                collector::run(&module, collector.interval, &stop, &sinks, &sources, &poll);
            }) {
                warn!(%error, "cannot start a BMC power module");
            }
        }
        Self { collectors, stop }
    }

    pub fn collectors(&self) -> &[BmcCollector] {
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
    use crate::{payload::CollectorResource, snmp::config::Target};
    use serde_json::json;
    use std::{collections::BTreeMap, time::Duration};

    struct Recorded(BTreeMap<&'static str, Value>);

    impl Redfish for Recorded {
        fn get(&mut self, path: &str) -> Result<Value, TargetError> {
            self.0
                .get(path)
                .cloned()
                .ok_or_else(|| TargetError::Unsupported(format!("{path} answered 404 Not Found")))
        }
    }

    fn collector(targets: &[&str]) -> BmcCollector {
        BmcCollector {
            id: "rack-bmcs".into(),
            targets: targets
                .iter()
                .map(|address| BmcTarget {
                    target: Target::parse_with_default_port(address, 443).unwrap(),
                    pin: None,
                })
                .collect(),
            username: "renga".into(),
            password_file: "/dev/null".into(),
            ca_file: None,
            interval: Duration::from_secs(60),
            timeout: Duration::from_secs(1),
            max_concurrent_targets: 2,
        }
    }

    fn open(target: &BmcTarget, _deadline: Instant) -> Result<Box<dyn Redfish>, TargetError> {
        match target.target.host.as_str() {
            "10.0.1.5" => Ok(Box::new(Recorded(redfish::tests::idrac()))),
            "10.0.1.6" => {
                // No chassis link, and only the newer PowerSubsystem.
                let mut service = redfish::tests::idrac();
                let system = service
                    .get_mut("/redfish/v1/Systems/System.Embedded.1")
                    .unwrap();
                system.as_object_mut().unwrap().remove("Links");
                service.insert(
                    redfish::CHASSIS,
                    json!({"Members": [{"@odata.id": "/redfish/v1/Chassis/1"}]}),
                );
                service.insert("/redfish/v1/Chassis/1", json!({"PowerSubsystem": {}}));
                Ok(Box::new(Recorded(service)))
            }
            "10.0.1.7" => Err(TargetError::NotPermitted(
                "https://10.0.1.7:443/redfish/v1/Systems answered 401 Unauthorized".into(),
            )),
            _ => Err(TargetError::Unreachable(
                "no answer before the timeout".into(),
            )),
        }
    }

    #[test]
    fn reads_each_bmc_and_says_why_others_were_not_read() {
        let outcomes = poll(
            &collector(&["10.0.1.5", "10.0.1.6", "10.0.1.7", "10.0.1.9"]),
            &Cancellation::default(),
            open,
        );

        let device = outcomes[0].result.as_ref().unwrap();
        assert_eq!(device.mapping, "redfish_power");
        assert_eq!(device.readings.len(), 7);
        assert_eq!(
            outcomes[1].result.as_ref().unwrap_err(),
            &TargetError::Unsupported("the chassis has no Power resource".into())
        );
        assert!(matches!(
            outcomes[2].result,
            Err(TargetError::NotPermitted(_))
        ));
        assert!(matches!(
            outcomes[3].result,
            Err(TargetError::Unreachable(_))
        ));
        assert_eq!(collector::source_status(&outcomes), "available");
        assert_eq!(collector::source_status(&outcomes[1..]), "not_permitted");
        assert_eq!(collector::source_status(&outcomes[3..]), "unreachable");
    }

    #[test]
    fn reports_the_server_and_its_supplies_readings() {
        let module = Collector {
            id: "rack-bmcs".into(),
            kind: CollectorKind::BmcPower,
        };
        let outcomes = poll(&collector(&["10.0.1.5"]), &Cancellation::default(), open);
        let [(_, report)] = <[_; 1]>::try_from(collector::reports(&module, &outcomes)).unwrap();
        let report: Value = serde_json::from_slice(&report).unwrap();
        assert_eq!(
            report["collector"],
            json!({"id": "rack-bmcs", "kind": "bmc_power"})
        );
        assert_eq!(report["resources"][0]["target"], "10.0.1.5");
        assert_eq!(report["resources"][0]["kind"], "server");

        let mut known = collector::Known::new();
        let [batch] =
            <[_; 1]>::try_from(collector::batches(&module, &outcomes, &mut known, 180)).unwrap();
        let batch = serde_json::to_value(&batch).unwrap();
        let supply = batch["samples"]
            .as_array()
            .unwrap()
            .iter()
            .find(|sample| sample["sensor"] == "PSU2/input" && sample["quantity"] == "state")
            .unwrap();
        assert_eq!(
            supply,
            &json!({
                "target": "10.0.1.5",
                "sensor": "PSU2/input",
                "boundary": "supply_input",
                "quantity": "state",
                "component": {"kind": "power_port", "name": "PSU2"},
                "status": "valid",
                "origin": "native",
                "state": "no_input",
                "window": supply["window"],
                "event_at": supply["event_at"],
                "mapping": {"name": "redfish_power", "version": 1},
                "fresh_for_seconds": 180
            })
        );
    }

    #[test]
    fn a_shared_or_unlinked_chassis_reports_the_server_without_readings() {
        let mut shared = redfish::tests::idrac();
        shared
            .get_mut("/redfish/v1/Chassis/System.Embedded.1")
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert(
                "Links".into(),
                json!({"ComputerSystems": [
                    {"@odata.id": "/redfish/v1/Systems/System.Embedded.1"},
                    {"@odata.id": "/redfish/v1/Systems/System.Embedded.2"}
                ]}),
            );
        let device = read(&mut Recorded(shared)).unwrap();
        assert!(device.resource.identifiers.dmi_uuid.is_some());
        assert!(device.readings.is_empty());

        // No chassis link: the service's first chassis need not be this server's.
        let mut unlinked = redfish::tests::idrac();
        unlinked
            .get_mut("/redfish/v1/Systems/System.Embedded.1")
            .unwrap()
            .as_object_mut()
            .unwrap()
            .remove("Links");
        unlinked.insert(
            redfish::CHASSIS,
            json!({"Members": [{"@odata.id": "/redfish/v1/Chassis/System.Embedded.1"}]}),
        );
        assert!(read(&mut Recorded(unlinked)).unwrap().readings.is_empty());

        // A second system with no reverse links on the chassis may share it.
        let mut two = redfish::tests::idrac();
        two.insert(
            redfish::SYSTEMS,
            json!({"Members": [
                {"@odata.id": "/redfish/v1/Systems/System.Embedded.1"},
                {"@odata.id": "/redfish/v1/Systems/System.Embedded.2"}
            ]}),
        );
        let device = read(&mut Recorded(two)).unwrap();
        assert!(device.resource.identifiers.dmi_uuid.is_some());
        assert!(device.readings.is_empty());

        // So may one on a page the collection does not show.
        let mut paged = redfish::tests::idrac();
        paged.insert(
            redfish::SYSTEMS,
            json!({
                "Members": [{"@odata.id": "/redfish/v1/Systems/System.Embedded.1"}],
                "Members@odata.count": 2,
                "Members@odata.nextLink": "/redfish/v1/Systems?$skip=1"
            }),
        );
        assert!(read(&mut Recorded(paged)).unwrap().readings.is_empty());

        // Or one the chassis's empty reverse list counts but does not show.
        let mut hidden = redfish::tests::idrac();
        hidden
            .get_mut("/redfish/v1/Chassis/System.Embedded.1")
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert(
                "Links".into(),
                json!({
                    "ComputerSystems": [],
                    "ComputerSystems@odata.count": 2,
                    "ComputerSystems@odata.nextLink": "/redfish/v1/Chassis/1/ComputerSystems"
                }),
            );
        assert!(read(&mut Recorded(hidden)).unwrap().readings.is_empty());
    }

    /// The recorded server as the mapper reports it. Renga's collector report tests post this
    /// file, so a mapping the server would reject fails there. Set `RENGA_UPDATE_FIXTURES=1` to
    /// rewrite it after an intended mapping change.
    #[test]
    fn the_recorded_bmc_matches_the_server_fixture() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../test/fixtures/collectors/recorded_bmc.json"
        );
        let device = read(&mut Recorded(redfish::tests::idrac())).unwrap();
        let mapped = serde_json::to_value(CollectorResource {
            target: Some("10.0.1.5".into()),
            ..device.resource
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
