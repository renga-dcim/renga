//! Read-only switch polling over SNMP (RFD 11, "Switch collection").
//!
//! One poll reads every configured target, a few at a time, and turns the answers into scoped
//! reports. A target that does not answer, or that cannot be identified, is reported unreachable
//! so its switch stays as Renga last saw it instead of disappearing.

pub mod client;
pub mod config;
pub mod mibs;
pub mod worker;

pub use crate::switch_report::{reports, TargetOutcome};

use crate::{
    cancellation::Cancellation,
    payload::CollectorResource,
    switch_report::{self, Sections},
};
use client::{PollError, Session};
use config::{SnmpCollector, Target};
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    },
    thread,
    time::{Duration, Instant},
};

/// A whole target, every walk included, must finish within this many request timeouts.
const TARGET_BUDGET_TIMEOUTS: u32 = 24;

/// Polls every target of `collector`, at most `max_concurrent_targets` at once. `open` connects
/// to one target; tests pass recorded sessions.
pub fn poll<F>(collector: &SnmpCollector, stopped: &Cancellation, open: F) -> Vec<TargetOutcome>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, PollError> + Sync,
{
    let ttl = switch_report::neighbor_ttl(collector.interval);
    let budget = collector.timeout * TARGET_BUDGET_TIMEOUTS;
    switch_report::poll_each(
        &collector.targets,
        collector.max_concurrent_targets,
        stopped,
        |target| poll_target(target, &open, budget, ttl, stopped),
    )
}

/// Runs `read` on every target of `collector`, at most `max_concurrent_targets` at once, and
/// returns the results in the targets' order.
pub fn each_target<T, F>(collector: &SnmpCollector, read: F) -> Vec<T>
where
    T: Send,
    F: Fn(&Target) -> T + Sync,
{
    let next = AtomicUsize::new(0);
    let results = Mutex::new(Vec::with_capacity(collector.targets.len()));
    let workers = collector
        .max_concurrent_targets
        .min(collector.targets.len());
    thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| loop {
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some(target) = collector.targets.get(index) else {
                    break;
                };
                let result = read(target);
                results
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .push((index, result));
            });
        }
    });
    let mut results = results
        .into_inner()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    results.sort_by_key(|(index, _)| *index);
    results.into_iter().map(|(_, result)| result).collect()
}

fn poll_target<F>(
    target: &Target,
    open: &F,
    budget: Duration,
    ttl: u32,
    stopped: &Cancellation,
) -> Result<(CollectorResource, Sections), String>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, PollError>,
{
    let deadline = Instant::now() + budget;
    let mut session = open(target).map_err(|error| error.0)?;
    let answers = client::poll(session.as_mut(), deadline, stopped).map_err(|error| error.0)?;
    mibs::switch(&target.address, &answers, ttl).map_err(|error| error.0)
}

#[cfg(test)]
mod tests {
    use super::{
        client::tests::Recorded,
        config::{Credentials, SnmpCollector},
        mibs::{self, SnmpValue},
        *,
    };
    use crate::payload::MAX_OBSERVATION_BYTES;
    use serde_json::Value;

    fn collector(targets: &[&str]) -> SnmpCollector {
        SnmpCollector {
            id: "core".into(),
            targets: targets
                .iter()
                .map(|address| Target::parse(address).unwrap())
                .collect(),
            credentials: Credentials::V2c {
                community_file: "/dev/null".into(),
            },
            interval: Duration::from_secs(900),
            timeout: Duration::from_secs(1),
            max_concurrent_targets: 2,
        }
    }

    fn open(target: &Target) -> Result<Box<dyn Session>, PollError> {
        match target.host.as_str() {
            "10.0.0.1" => Ok(Box::new(Recorded::new(&mibs::tests::answers()))),
            "10.0.0.2" => {
                let mut answers = mibs::tests::answers();
                answers.insert(mibs::LLDP_LOC_CHASSIS_ID.to_vec(), SnmpValue::Missing);
                Ok(Box::new(Recorded::new(&answers)))
            }
            _ => Err(PollError("no answer before the timeout".into())),
        }
    }

    fn decode(body: &[u8]) -> Value {
        serde_json::from_slice(body).unwrap()
    }

    #[test]
    fn reports_reachable_switches_and_unreachable_targets() {
        let collector = collector(&["10.0.0.1", "10.0.0.9"]);
        let outcomes = poll(&collector, &Cancellation::default(), open);
        let [(_, report)] = <[_; 1]>::try_from(reports("core", outcomes)).unwrap();
        let report = decode(&report);

        assert_eq!(report["scope"], "targets");
        assert_eq!(report["collector"]["kind"], "switch_poller");
        assert_eq!(report["complete"], true);
        assert_eq!(report["targets"][0]["status"], "reachable");
        assert_eq!(report["targets"][1]["status"], "unreachable");
        assert_eq!(
            report["targets"][1]["error"],
            "no answer before the timeout"
        );
        assert_eq!(report["resources"].as_array().unwrap().len(), 1);
        assert_eq!(report["resources"][0]["target"], "10.0.0.1");
        assert_eq!(
            report["resources"][0]["interfaces"][0]["neighbors"][0]["ttl_seconds"],
            2_700
        );
        assert_eq!(report["section_completeness"]["interface_neighbors"], true);
        assert_eq!(report["section_completeness"]["interface_vlans"], true);
    }

    #[test]
    fn claims_a_section_only_when_every_reached_switch_answered_it() {
        let collector = collector(&["10.0.0.1", "10.0.0.2"]);
        let outcomes = poll(&collector, &Cancellation::default(), open);
        let report = decode(&reports("core", outcomes)[0].1);

        assert_eq!(report["section_completeness"]["interface_vlans"], true);
        assert!(report["section_completeness"]
            .get("interface_neighbors")
            .is_none());

        let unreachable = poll(
            &self::collector(&["10.0.0.9"]),
            &Cancellation::default(),
            open,
        );
        let report = decode(&reports("core", unreachable)[0].1);
        assert!(report.get("section_completeness").is_none());
    }

    #[test]
    fn splits_reports_at_the_size_limit() {
        let outcomes = (0..400)
            .map(|index| TargetOutcome {
                address: format!("10.1.{}.{}", index / 200, index % 200),
                result: Err("x".repeat(1_000)),
            })
            .collect();
        let reports = reports("core", outcomes);

        assert!(reports.len() > 1);
        assert!(reports
            .iter()
            .all(|(_, body)| body.len() <= MAX_OBSERVATION_BYTES));
        let targets: usize = reports
            .iter()
            .map(|(_, body)| decode(body)["targets"].as_array().unwrap().len())
            .sum();
        assert_eq!(targets, 400);
    }

    #[test]
    fn keeps_every_string_within_the_server_limit() {
        let long = "x".repeat(300);
        let mut answers = mibs::tests::answers();
        answers.insert(
            mibs::SYS_NAME.to_vec(),
            SnmpValue::Octets(long.clone().into_bytes()),
        );
        let outcomes = vec![
            TargetOutcome {
                address: "10.0.0.1".into(),
                result: mibs::switch("10.0.0.1", &answers, 60).map_err(|error| error.0),
            },
            TargetOutcome {
                address: "10.0.0.9".into(),
                result: Err(format!("cannot resolve {long}")),
            },
        ];
        let report = decode(&reports("core", outcomes)[0].1);

        assert!(report["resources"][0]["identifiers"]
            .get("hostname")
            .is_none());
        assert_eq!(
            report["resources"][0]["identifiers"]["serial_number"],
            "FDO1234X0YZ"
        );
        let error = report["targets"][1]["error"].as_str().unwrap();
        assert_eq!(
            error.chars().count(),
            crate::switch_report::MAX_STRING_CHARS
        );
    }

    /// The recorded switch as the mapper reports it. Renga's collector report tests post this
    /// file, so a mapping the server would reject fails there. Set `RENGA_UPDATE_FIXTURES=1` to
    /// rewrite it after an intended mapping change.
    #[test]
    fn the_recorded_switch_matches_the_server_fixture() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../test/fixtures/collectors/recorded_switch.json"
        );
        let (resource, _) = mibs::switch("10.0.0.1", &mibs::tests::answers(), 2_700).unwrap();
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
    fn stops_polling_once_cancelled() {
        let stopped = Cancellation::default();
        stopped.cancel();
        let outcomes = poll(&collector(&["10.0.0.1"]), &stopped, open);
        assert_eq!(
            outcomes[0].result.as_ref().unwrap_err(),
            "polling was cancelled"
        );
    }
}
