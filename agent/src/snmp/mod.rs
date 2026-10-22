//! Read-only switch polling over SNMP (RFD 11, "Switch collection").
//!
//! One poll reads every configured target, a few at a time, and turns the answers into scoped
//! reports. A target that does not answer, or that cannot be identified, is reported unreachable
//! so its switch stays as Renga last saw it instead of disappearing.

pub mod client;
pub mod config;
pub mod mibs;
pub mod worker;

use crate::{
    cancellation::Cancellation,
    payload::{
        Collector, CollectorKind, CollectorResource, Reachability, ReportScope, ScopedReport,
        SectionCompleteness, TargetStatus, MAX_OBSERVATION_BYTES,
    },
};
use client::{PollError, Session};
use config::{SnmpCollector, Target};
use mibs::Support;
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

/// Neighbor evidence outlives a missed poll or two, but not a switch that stopped answering.
const NEIGHBOR_TTL_POLLS: u32 = 3;
/// A whole target, every walk included, must finish within this many request timeouts.
const TARGET_BUDGET_TIMEOUTS: u32 = 24;
/// Generous upper bounds on the JSON around each target and around the whole report.
const TARGET_ENTRY_BYTES: usize = 96;
const REPORT_ENVELOPE_BYTES: usize = 1_024;

/// One target's poll: its switch, or why it was not read.
#[derive(Debug)]
pub struct TargetOutcome {
    pub target: Target,
    pub result: Result<(CollectorResource, Support), String>,
}

/// Polls every target of `collector`, at most `max_concurrent_targets` at once. `open` connects
/// to one target; tests pass recorded sessions.
pub fn poll<F>(collector: &SnmpCollector, stopped: &Cancellation, open: F) -> Vec<TargetOutcome>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, PollError> + Sync,
{
    let ttl = u32::try_from(collector.interval.as_secs())
        .unwrap_or(u32::MAX)
        .saturating_mul(NEIGHBOR_TTL_POLLS)
        .min(u32::from(u16::MAX));
    let budget = collector.timeout * TARGET_BUDGET_TIMEOUTS;
    let next = AtomicUsize::new(0);
    let outcomes = Mutex::new(Vec::with_capacity(collector.targets.len()));
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
                let result = if stopped.cancelled() {
                    Err("polling was cancelled".into())
                } else {
                    poll_target(target, &open, budget, ttl)
                };
                outcomes
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .push((
                        index,
                        TargetOutcome {
                            target: target.clone(),
                            result,
                        },
                    ));
            });
        }
    });
    let mut outcomes = outcomes
        .into_inner()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    outcomes.sort_by_key(|(index, _)| *index);
    outcomes.into_iter().map(|(_, outcome)| outcome).collect()
}

fn poll_target<F>(
    target: &Target,
    open: &F,
    budget: Duration,
    ttl: u32,
) -> Result<(CollectorResource, Support), String>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, PollError>,
{
    let deadline = Instant::now() + budget;
    let mut session = open(target).map_err(|error| error.0)?;
    let answers = client::poll(session.as_mut(), deadline).map_err(|error| error.0)?;
    mibs::switch(&target.address, &answers, ttl).map_err(|error| error.0)
}

/// Encodes the outcomes as complete `targets` reports, each within the observation size limit.
/// Every target appears in exactly one report; one whose switch alone exceeds the limit is
/// reported unreachable, so its last known state stands.
pub fn reports(collector_id: &str, outcomes: Vec<TargetOutcome>) -> Vec<(Uuid, Vec<u8>)> {
    // Packs by each target's own encoded size, leaving room for the report's envelope, then
    // halves any batch that still comes out too large.
    let budget = MAX_OBSERVATION_BYTES - REPORT_ENVELOPE_BYTES;
    let mut batches: Vec<Vec<TargetOutcome>> = Vec::new();
    let mut used = 0;
    for outcome in outcomes {
        let outcome = within_limit(collector_id, outcome);
        let size = encoded_size(&outcome);
        if used + size > budget || batches.is_empty() {
            batches.push(Vec::new());
            used = 0;
        }
        used += size;
        batches.last_mut().expect("pushed above").push(outcome);
    }
    let mut reports = Vec::new();
    while let Some(mut batch) = batches.pop() {
        match encode(collector_id, &batch) {
            Some(report) => reports.push(report),
            None if batch.len() > 1 => {
                let rest = batch.split_off(batch.len() / 2);
                batches.push(rest);
                batches.push(batch);
            }
            None => {}
        }
    }
    reports.reverse();
    reports
}

/// The outcome, or an unreachable one when its switch alone cannot fit in a report.
fn within_limit(collector_id: &str, outcome: TargetOutcome) -> TargetOutcome {
    if outcome.result.is_err() || encode(collector_id, std::slice::from_ref(&outcome)).is_some() {
        return outcome;
    }
    TargetOutcome {
        target: outcome.target,
        result: Err(format!(
            "the switch's report exceeds {MAX_OBSERVATION_BYTES} bytes"
        )),
    }
}

fn encoded_size(outcome: &TargetOutcome) -> usize {
    let resource = match &outcome.result {
        Ok((resource, _)) => serde_json::to_vec(resource).map_or(0, |body| body.len()),
        Err(error) => error.len(),
    };
    resource + outcome.target.address.len() + TARGET_ENTRY_BYTES
}

/// The encoded report for `outcomes` with its observation ID, or `None` when it is empty or too
/// large.
fn encode(collector_id: &str, outcomes: &[TargetOutcome]) -> Option<(Uuid, Vec<u8>)> {
    if outcomes.is_empty() {
        return None;
    }
    let mut targets = Vec::with_capacity(outcomes.len());
    let mut resources = Vec::new();
    let mut lldp = true;
    let mut q_bridge = true;
    let mut reached = false;
    for outcome in outcomes {
        match &outcome.result {
            Ok((resource, support)) => {
                reached = true;
                lldp &= support.lldp;
                q_bridge &= support.q_bridge;
                targets.push(TargetStatus {
                    address: outcome.target.address.clone(),
                    status: Reachability::Reachable,
                    error: None,
                });
                resources.push(resource.clone());
            }
            Err(error) => targets.push(TargetStatus {
                address: outcome.target.address.clone(),
                status: Reachability::Unreachable,
                // Renga rejects the whole report over a longer error, so it is cut short.
                error: Some(error.chars().take(mibs::MAX_STRING_CHARS).collect()),
            }),
        }
    }
    let report = ScopedReport::new(
        Collector {
            id: collector_id.to_owned(),
            kind: CollectorKind::SwitchPoller,
        },
        ReportScope::Targets { targets },
        true,
        resources,
    )
    .with_section_completeness(SectionCompleteness {
        interface_vlans: reached && q_bridge,
        interface_neighbors: reached && lldp,
    });
    let body = serde_json::to_vec(&report).ok()?;
    (body.len() <= MAX_OBSERVATION_BYTES).then_some((report.observation_id, body))
}

#[cfg(test)]
mod tests {
    use super::{
        client::tests::Recorded,
        config::{Credentials, SnmpCollector},
        mibs::{self, SnmpValue},
        *,
    };
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
                target: Target::parse(&format!("10.1.{}.{}", index / 200, index % 200)).unwrap(),
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
                target: Target::parse("10.0.0.1").unwrap(),
                result: mibs::switch("10.0.0.1", &answers, 60).map_err(|error| error.0),
            },
            TargetOutcome {
                target: Target::parse("10.0.0.9").unwrap(),
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
        assert_eq!(error.chars().count(), mibs::MAX_STRING_CHARS);
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
