//! Switch poller reports (RFD 11, "Observation payload"), shared by every switch module: the
//! outcome of polling each target becomes complete `targets` reports within the observation
//! size limit, whichever protocol read the switch.

use crate::payload::{
    Collector, CollectorKind, CollectorResource, Reachability, ReportScope, ScopedReport,
    SectionCompleteness, TargetStatus, MAX_OBSERVATION_BYTES,
};
use uuid::Uuid;

/// Must match `Renga.Inventory.AgentPayload`'s string limit.
pub const MAX_STRING_CHARS: usize = 255;
/// Generous upper bounds on the JSON around each target and around the whole report.
const TARGET_ENTRY_BYTES: usize = 96;
const REPORT_ENVELOPE_BYTES: usize = 1_024;

/// Which optional sections a switch answered, so a report claims completeness only for what was
/// read from every switch it reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Sections {
    pub interface_neighbors: bool,
    pub interface_vlans: bool,
}

/// One target's poll: its switch, or why it was not read.
#[derive(Debug)]
pub struct TargetOutcome {
    /// The target exactly as configured, so reports name it the way the operator does.
    pub address: String,
    pub result: Result<(CollectorResource, Sections), String>,
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
        address: outcome.address,
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
    resource + outcome.address.len() + TARGET_ENTRY_BYTES
}

/// The encoded report for `outcomes` with its observation ID, or `None` when it is empty or too
/// large.
fn encode(collector_id: &str, outcomes: &[TargetOutcome]) -> Option<(Uuid, Vec<u8>)> {
    if outcomes.is_empty() {
        return None;
    }
    let mut targets = Vec::with_capacity(outcomes.len());
    let mut resources = Vec::new();
    let mut neighbors = true;
    let mut vlans = true;
    let mut reached = false;
    for outcome in outcomes {
        match &outcome.result {
            Ok((resource, sections)) => {
                reached = true;
                neighbors &= sections.interface_neighbors;
                vlans &= sections.interface_vlans;
                targets.push(TargetStatus {
                    address: outcome.address.clone(),
                    status: Reachability::Reachable,
                    error: None,
                });
                resources.push(resource.clone());
            }
            Err(error) => targets.push(TargetStatus {
                address: outcome.address.clone(),
                status: Reachability::Unreachable,
                // Renga rejects the whole report over a longer error, so it is cut short.
                error: Some(error.chars().take(MAX_STRING_CHARS).collect()),
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
        interface_vlans: reached && vlans,
        interface_neighbors: reached && neighbors,
    });
    let body = serde_json::to_vec(&report).ok()?;
    (body.len() <= MAX_OBSERVATION_BYTES).then_some((report.observation_id, body))
}
