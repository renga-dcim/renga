//! Read-only switch polling over gNMI with OpenConfig models (RFD 11, "Switch collection"), for
//! switches whose SNMP agents are incomplete. It reports the same switch resource, in the same
//! `targets` reports, as the SNMP poller.
//!
//! Each target gets one `Get` per path in [`openconfig::PATHS`], so a switch that lacks one
//! model still reports the rest. Only the platform model is required, since it holds the
//! chassis serial that identifies the switch.

pub mod client;
pub mod config;
pub mod openconfig;
pub mod proto;
pub mod tree;
pub mod worker;

use crate::{
    cancellation::Cancellation,
    payload::CollectorResource,
    snmp::config::Target,
    switch_report::{self, Sections, TargetOutcome},
};
use client::{GetError, Session};
use config::GnmiCollector;
use openconfig::Answers;
use tracing::debug;

/// Polls every target of `collector`, at most `max_concurrent_targets` at once. `open` connects
/// to one target; tests pass recorded sessions.
pub fn poll<F>(collector: &GnmiCollector, stopped: &Cancellation, open: F) -> Vec<TargetOutcome>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, String> + Sync,
{
    let ttl = switch_report::neighbor_ttl(collector.interval);
    switch_report::poll_each(
        &collector.targets,
        collector.max_concurrent_targets,
        stopped,
        |target| poll_target(target, &open, ttl),
    )
}

fn poll_target<F>(
    target: &Target,
    open: &F,
    ttl: u32,
) -> Result<(CollectorResource, Sections), String>
where
    F: Fn(&Target) -> Result<Box<dyn Session>, String>,
{
    let mut session = open(target)?;
    let mut answers = Answers::default();
    for path in openconfig::PATHS {
        match session.get(path) {
            Ok(notifications) => {
                tree::merge(&mut answers.tree, &notifications)?;
                answers.answered.insert(path);
            }
            Err(GetError::Unsupported(error)) if *path != openconfig::COMPONENTS => {
                debug!(target = %target.address, path, %error, "gNMI path not supported");
            }
            Err(GetError::Unsupported(error) | GetError::Failed(error)) => {
                return Err(format!("{path}: {error}"));
            }
        }
    }
    openconfig::switch(&target.address, &answers, ttl).map_err(|error| error.0)
}

#[cfg(test)]
mod tests {
    use super::{
        client::tests::Recorded,
        config::{GnmiCollector, Transport},
        *,
    };
    use std::time::Duration;

    pub(crate) fn collector(targets: &[&str]) -> GnmiCollector {
        GnmiCollector {
            id: "spines".into(),
            targets: targets
                .iter()
                .map(|address| Target::parse_with_default_port(address, 9339).unwrap())
                .collect(),
            credentials: None,
            transport: Transport::Plaintext,
            interval: Duration::from_secs(900),
            timeout: Duration::from_secs(1),
            max_concurrent_targets: 2,
        }
    }

    #[test]
    fn reports_each_target_and_skips_unsupported_models() {
        let outcomes = poll(
            &collector(&["10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"]),
            &Cancellation::default(),
            |target: &Target| -> Result<Box<dyn Session>, String> {
                match target.host.as_str() {
                    "10.0.0.2" => Ok(Box::new(Recorded::switch().without(openconfig::LLDP))),
                    "10.0.0.3" => Ok(Box::new(Recorded::switch().without(openconfig::INTERFACES))),
                    "10.0.0.4" => Ok(Box::new(Recorded::switch().without(openconfig::COMPONENTS))),
                    _ => Err("cannot connect: connection refused".into()),
                }
            },
        );

        let (resource, sections) = outcomes[0].result.as_ref().unwrap();
        assert_eq!(
            resource.identifiers.serial_number.as_deref(),
            Some("JPE12345678")
        );
        assert!(!sections.interface_neighbors);
        assert!(sections.interface_vlans);
        let (resource, sections) = outcomes[1].result.as_ref().unwrap();
        assert!(resource.interfaces.is_none());
        assert!(!sections.interface_neighbors && !sections.interface_vlans);
        assert_eq!(
            outcomes[2].result.as_ref().unwrap_err(),
            "components/component/state: Unimplemented: no such model"
        );
        assert_eq!(
            outcomes[3].result.as_ref().unwrap_err(),
            "cannot connect: connection refused"
        );
        let addresses: Vec<_> = outcomes
            .iter()
            .map(|outcome| outcome.address.as_str())
            .collect();
        assert_eq!(addresses, ["10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"]);
    }

    #[test]
    fn a_failed_path_makes_the_target_unreachable() {
        let outcomes = poll(
            &collector(&["10.0.0.2"]),
            &Cancellation::default(),
            |_: &Target| -> Result<Box<dyn Session>, String> {
                Ok(Box::new(Recorded::switch().failing(openconfig::INTERFACES)))
            },
        );

        assert_eq!(
            outcomes[0].result.as_ref().unwrap_err(),
            "interfaces/interface: Unavailable: connection reset"
        );
    }
}
