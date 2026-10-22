//! Read-only VM collection over libvirt (RFD 11, "Virtualization collection").
//!
//! The module lists every domain defined on one hypervisor through `virsh -r`, so it needs only
//! the read-only socket, and reports them in `hypervisor` scope. A hypervisor that cannot be
//! listed is reported unreachable so its VMs stay as Renga last saw them.

pub mod config;
pub mod domain;
pub mod worker;

use crate::{
    cancellation::Cancellation,
    command,
    payload::{
        Collector, CollectorIdentifiers, CollectorKind, CollectorResource, CollectorResourceKind,
        HypervisorStatus, Reachability, ReportScope, ScopedReport, MAX_OBSERVATION_BYTES,
    },
};
use config::LibvirtCollector;
use domain::Domain;
use std::process::Command;
use tracing::warn;
use uuid::Uuid;

/// Must match `Renga.Inventory.AgentPayload`.
const MAX_SCOPE_RESOURCES: usize = 1_000;

/// Runs one `virsh` subcommand and returns its standard output; tests answer from recordings.
pub type Virsh<'a> = &'a (dyn Fn(&[&str]) -> Result<String, String> + Sync);

/// One poll of the hypervisor.
#[derive(Debug)]
pub struct Poll {
    /// Every domain read, or why the hypervisor could not be listed.
    pub result: Result<Vec<Domain>, String>,
    /// Whether every listed domain was read, so the report may retire the ones it omits.
    pub complete: bool,
}

/// Runs `virsh` read-only against `uri` in the C locale, so its output parses the same anywhere.
pub fn virsh(
    collector: &LibvirtCollector,
    stopped: &Cancellation,
    args: &[&str],
) -> Result<String, String> {
    let output = command::run_with_timeout(
        Command::new("virsh")
            .env("LC_ALL", "C")
            .args(["--readonly", "--quiet", "--connect", &collector.uri])
            .args(args),
        stopped,
        collector.timeout,
    )
    .map_err(|error| format!("virsh {}: {error}", args[0]))?;
    if !output.status.success() {
        return Err(format!("virsh {} failed with {}", args[0], output.status));
    }
    String::from_utf8(output.stdout).map_err(|_| format!("virsh {} printed invalid UTF-8", args[0]))
}

/// Reads every domain defined on the hypervisor.
pub fn poll(collector_id: &str, stopped: &Cancellation, virsh: Virsh<'_>) -> Poll {
    let uuids = match virsh(&["list", "--all", "--uuid"]) {
        Ok(stdout) => domain::uuids(&stdout),
        Err(error) => {
            return Poll {
                result: Err(error),
                complete: false,
            }
        }
    };
    let mut domains = Vec::with_capacity(uuids.len());
    let mut complete = true;
    for uuid in &uuids {
        if stopped.cancelled() {
            complete = false;
            break;
        }
        // Each entry goes back to virsh as an argument, so only a UUID may.
        if domain::canonical_uuid(uuid).is_none() {
            warn!(
                collector = collector_id,
                "virsh listed something other than a domain UUID"
            );
            complete = false;
            continue;
        }
        let read = virsh(&["dominfo", uuid]).and_then(|info| {
            let (state, persistent) = domain::info(&info);
            let xml = virsh(&["dumpxml", uuid])?;
            domain::parse(&xml, state, persistent).map_err(|error| error.0)
        });
        match read {
            Ok(domain) => {
                if domain.dropped_devices > 0 {
                    warn!(collector = collector_id, domain = %domain.domain.name, dropped = domain.dropped_devices, "domain has more devices than a report carries");
                }
                domains.push(domain);
            }
            // A domain undefined between the listing and this read looks the same as one that
            // failed to read, so the report must not retire anything.
            Err(error) => {
                warn!(collector = collector_id, domain = %uuid, %error, "libvirt domain not read");
                complete = false;
            }
        }
    }
    Poll {
        result: Ok(domains),
        complete,
    }
}

/// Encodes a poll as `hypervisor` reports within the observation limits. A poll that fits one
/// report keeps its completeness; one split across reports cannot claim it, because no single
/// report lists every domain.
pub fn reports(collector: &LibvirtCollector, poll: Poll) -> Vec<(Uuid, Vec<u8>)> {
    let domains = match poll.result {
        Ok(domains) => domains,
        Err(error) => {
            return encode(collector, Err(error), false, Vec::new())
                .into_iter()
                .collect()
        }
    };
    let resources: Vec<_> = domains.into_iter().map(resource).collect();
    if resources.len() <= MAX_SCOPE_RESOURCES {
        if let Some(report) = encode(collector, Ok(()), poll.complete, resources.clone()) {
            return vec![report];
        }
    }
    let mut batches: Vec<Vec<CollectorResource>> = resources
        .chunks(MAX_SCOPE_RESOURCES)
        .map(<[_]>::to_vec)
        .collect();
    batches.reverse();
    let mut reports = Vec::new();
    while let Some(mut batch) = batches.pop() {
        match encode(collector, Ok(()), false, batch.clone()) {
            Some(report) => reports.push(report),
            None if batch.len() > 1 => {
                let rest = batch.split_off(batch.len() / 2);
                batches.push(rest);
                batches.push(batch);
            }
            None => {
                warn!(collector = %collector.id, "a domain's report exceeds the observation size limit")
            }
        }
    }
    reports
}

fn resource(domain: Domain) -> CollectorResource {
    CollectorResource {
        kind: CollectorResourceKind::Vm,
        target: None,
        identifiers: CollectorIdentifiers {
            dmi_uuid: Some(domain.dmi_uuid),
            ..Default::default()
        },
        attributes: None,
        interfaces: None,
        domain: Some(domain.domain),
    }
}

fn encode(
    collector: &LibvirtCollector,
    reached: Result<(), String>,
    complete: bool,
    resources: Vec<CollectorResource>,
) -> Option<(Uuid, Vec<u8>)> {
    let (status, error) = match reached {
        Ok(()) => (Reachability::Reachable, None),
        Err(error) => (Reachability::Unreachable, Some(error)),
    };
    let report = ScopedReport::new(
        Collector {
            id: collector.id.clone(),
            kind: CollectorKind::VmProvider,
        },
        ReportScope::Hypervisor {
            hypervisor: HypervisorStatus {
                id: collector.uri.clone(),
                status,
                error,
            },
        },
        complete,
        resources,
    );
    let body = serde_json::to_vec(&report).ok()?;
    (body.len() <= MAX_OBSERVATION_BYTES).then_some((report.observation_id, body))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::time::Duration;

    fn collector() -> LibvirtCollector {
        LibvirtCollector {
            id: "libvirt".into(),
            uri: "qemu:///system".into(),
            interval: Duration::from_secs(300),
            timeout: Duration::from_secs(10),
        }
    }

    fn recorded(args: &[&str]) -> Result<String, String> {
        match args {
            ["list", ..] => Ok("6695eb01-f6a4-8304-79aa-97f2502e193f\ngone\n".into()),
            ["dominfo", "gone"] => Err("virsh dominfo failed with exit status: 1".into()),
            ["dominfo", _] => Ok("State:          paused\nPersistent:     yes\n".into()),
            ["dumpxml", _] => Ok(domain::tests::WEB_01.into()),
            _ => Err("unexpected".into()),
        }
    }

    fn decode(body: &[u8]) -> Value {
        serde_json::from_slice(body).unwrap()
    }

    #[test]
    fn reports_each_domain_and_withholds_completeness_when_one_is_unread() {
        let poll = poll("libvirt", &Cancellation::default(), &recorded);
        assert!(!poll.complete);
        let [(_, report)] = <[_; 1]>::try_from(reports(&collector(), poll)).unwrap();
        let report = decode(&report);

        assert_eq!(report["scope"], "hypervisor");
        assert_eq!(report["collector"]["kind"], "vm_provider");
        assert_eq!(report["hypervisor"]["id"], "qemu:///system");
        assert_eq!(report["hypervisor"]["status"], "reachable");
        assert_eq!(report["complete"], false);
        let vm = &report["resources"][0];
        assert_eq!(vm["kind"], "vm");
        assert_eq!(
            vm["identifiers"]["dmi_uuid"],
            "4c4c4544-004d-3610-804b-c4c04f4e4a31"
        );
        assert_eq!(vm["domain"]["state"], "paused");
        assert_eq!(vm["domain"]["interfaces"][0]["type"], "bridge");
        assert!(
            vm.get("interfaces").is_none(),
            "NICs belong to the guest's own view"
        );
    }

    #[test]
    fn a_fully_read_hypervisor_is_complete() {
        let virsh = |args: &[&str]| match args {
            ["list", ..] => Ok("6695eb01-f6a4-8304-79aa-97f2502e193f\n".to_owned()),
            other => recorded(other),
        };
        let poll = poll("libvirt", &Cancellation::default(), &virsh);
        let report = decode(&reports(&collector(), poll)[0].1);
        assert_eq!(report["complete"], true);
    }

    #[test]
    fn an_unlisted_hypervisor_is_unreachable() {
        let virsh = |_: &[&str]| Err("virsh list: command timed out".to_owned());
        let poll = poll("libvirt", &Cancellation::default(), &virsh);
        let report = decode(&reports(&collector(), poll)[0].1);
        assert_eq!(report["hypervisor"]["status"], "unreachable");
        assert_eq!(
            report["hypervisor"]["error"],
            "virsh list: command timed out"
        );
        assert_eq!(report["complete"], false);
        assert_eq!(report["resources"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn splits_large_hypervisors_without_claiming_completeness() {
        let parsed = domain::parse(
            domain::tests::WEB_01,
            crate::payload::DomainState::Running,
            None,
        )
        .unwrap();
        let poll = Poll {
            result: Ok(vec![parsed; 1_500]),
            complete: true,
        };
        let reports = reports(&collector(), poll);
        assert!(reports.len() > 1);
        let mut total = 0;
        for (_, body) in &reports {
            assert!(body.len() <= MAX_OBSERVATION_BYTES);
            let report = decode(body);
            assert_eq!(report["complete"], false);
            total += report["resources"].as_array().unwrap().len();
        }
        assert_eq!(total, 1_500);
    }

    /// Runs against libvirt's built-in test driver, which needs no daemon.
    #[test]
    fn reads_the_libvirt_test_driver() {
        if Command::new("virsh").arg("--version").output().is_err() {
            eprintln!("skipping: virsh is not installed");
            return;
        }
        let collector = LibvirtCollector {
            uri: "test:///default".into(),
            ..collector()
        };
        let stopped = Cancellation::default();
        let run = |args: &[&str]| virsh(&collector, &stopped, args);
        let poll = poll(&collector.id, &stopped, &run);
        assert!(poll.complete);
        let domains = poll.result.unwrap();
        assert_eq!(domains.len(), 1);
        assert_eq!(domains[0].dmi_uuid, "6695eb01-f6a4-8304-79aa-97f2502e193f");
        assert_eq!(domains[0].domain.name, "test");
        assert_eq!(
            domains[0].domain.state,
            crate::payload::DomainState::Running
        );
        assert_eq!(domains[0].domain.persistent, Some(true));
        assert_eq!(
            domains[0].domain.interfaces[0].source.as_deref(),
            Some("default")
        );
    }
}
