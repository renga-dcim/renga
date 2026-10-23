//! Checks the agent's requests, and its decoding of responses, against the server's published
//! OpenAPI document.
//!
//! The server generates `priv/openapi/v1.json` from its own validator and fails its tests when the
//! file is stale, so a payload change on either side that breaks the contract fails here.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use renga_agent::{
    cancellation::Cancellation,
    collectors,
    installation_key::InstallationKey,
    payload::{
        Address, AgentHome, CheckIn, CheckInAck, Collector, CollectorIdentifiers, CollectorKind,
        CollectorResource, CollectorResourceKind, Component, DomainDisk, DomainInterface,
        DomainInterfaceType, DomainState, HostAttributes, HypervisorStatus, Identifiers, Interface,
        JobClaim, JobReport, KeyApproval, LeaseRequest, LeaseResponse, LeasedJob, Neighbor,
        Observation, PresentedKey, QueueReport, Reachability, ReportAck, ReportScope, ReportType,
        ResourceKind, ScopedReport, SectionCompleteness, ServerResource, TaggingMode, TargetStatus,
        VlanMembership, VmDomain,
    },
    power::{self, hwmon},
};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

const SPEC: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../priv/openapi/v1.json"
));

/// Lists where `body` violates the named schema under `#/components/schemas`.
fn violations(schema: &str, body: &Value) -> Vec<String> {
    // Rooting the validator at the whole document lets the component's `$ref`s resolve.
    let mut root: Value = serde_json::from_str(SPEC).expect("the OpenAPI document is JSON");
    root["$ref"] = json!(format!("#/components/schemas/{schema}"));
    let validator = jsonschema::draft202012::options()
        .should_validate_formats(true)
        .build(&root)
        .unwrap_or_else(|error| panic!("cannot compile the {schema} schema: {error}"));

    let mut paths: Vec<String> = validator
        .iter_errors(body)
        .map(|error| format!("{}: {error}", error.instance_path()))
        .collect();
    paths.sort();
    paths
}

/// Asserts that `body` satisfies the named schema under `#/components/schemas`.
fn assert_conforms(schema: &str, body: &impl Serialize) {
    let body = serde_json::to_value(body).unwrap();
    let errors = violations(schema, &body);
    assert!(
        errors.is_empty(),
        "{schema} body does not match priv/openapi/v1.json:\n{}\n\nbody: {body:#}",
        errors.join("\n")
    );
}

/// The instance paths where `body` violates the named schema.
fn violation_paths(schema: &str, body: &Value) -> Vec<String> {
    let mut paths: Vec<String> = violations(schema, body)
        .into_iter()
        .map(|error| error.split(": ").next().unwrap().to_owned())
        .collect();
    paths.dedup();
    paths
}

fn interface(name: &str, kind: &str, mac_address: Option<&str>) -> Interface {
    Interface {
        name: name.into(),
        kind: kind.into(),
        status: "up".into(),
        mac_address: mac_address.map(Into::into),
        mtu: Some(1500),
        speed_mbps: Some(10_000),
        addresses: Some(vec![Address {
            address: "192.0.2.10/24".into(),
            kind: Some("ipv4".into()),
            scope: Some("global".into()),
        }]),
        ..Default::default()
    }
}

/// An observation with every field the agent can send populated.
fn full_observation() -> Observation {
    let resource = ServerResource {
        kind: ResourceKind::Server,
        identifiers: Identifiers {
            hostname: "db-01".into(),
            fqdn: Some("db-01.example.net".into()),
            machine_id: Some("4c4c4544004d3610804bc4c04f4e4a31".into()),
            dmi_uuid: Some("4c4c4544-004d-3610-804b-c4c04f4e4a31".into()),
            serial_number: Some("CN7016352E00F9".into()),
            mac_address: vec!["52:54:00:12:34:56".into()],
        },
        attributes: Some(HostAttributes {
            hostname: Some("db-01".into()),
            fqdn: Some("db-01.example.net".into()),
            vendor: Some("Dell Inc.".into()),
            model: Some("PowerEdge R650".into()),
            asset_tag: Some("A-1042".into()),
        }),
        interfaces: Some(vec![
            interface("eno1", "ethernet", Some("52:54:00:12:34:56")),
            interface("lo", "loopback", None),
        ]),
        components: vec![Component {
            kind: "memory".into(),
            attributes: BTreeMap::from([("size_bytes".into(), json!(68_719_476_736_u64))]),
        }],
        labels: BTreeMap::new(),
    };

    Observation::new(resource).with_labels(&BTreeMap::from([
        ("rack".into(), "r12".into()),
        ("team/owner".into(), "storage".into()),
    ]))
}

#[test]
fn a_fully_populated_observation_matches_the_contract() {
    assert_conforms("Observation", &full_observation());
}

#[test]
fn a_switch_poller_report_matches_the_contract() {
    let report = ScopedReport::new(
        Collector {
            id: "core-switches".into(),
            kind: CollectorKind::SwitchPoller,
        },
        ReportScope::Targets {
            targets: vec![
                TargetStatus {
                    address: "10.0.0.1".into(),
                    status: Reachability::Reachable,
                    error: None,
                },
                TargetStatus {
                    address: "10.0.0.2".into(),
                    status: Reachability::Unreachable,
                    error: Some("timeout after 5s".into()),
                },
            ],
        },
        true,
        vec![CollectorResource {
            kind: CollectorResourceKind::Switch,
            target: Some("10.0.0.1".into()),
            identifiers: CollectorIdentifiers {
                hostname: Some("core1".into()),
                serial_number: Some("CN0SER1".into()),
                dmi_uuid: None,
                mac_address: vec!["52:54:00:aa:00:01".into()],
            },
            attributes: Some(HostAttributes {
                hostname: Some("core1".into()),
                vendor: Some("Dell".into()),
                model: Some("S5248F-ON".into()),
                ..Default::default()
            }),
            interfaces: Some(vec![Interface {
                vlan_mode: Some("trunk".into()),
                vlans: Some(vec![
                    VlanMembership {
                        vid: 10,
                        tagging_mode: TaggingMode::Untagged,
                    },
                    VlanMembership {
                        vid: 20,
                        tagging_mode: TaggingMode::Tagged,
                    },
                ]),
                neighbors: Some(vec![Neighbor {
                    protocol: "lldp",
                    remote_chassis_id: "192.0.2.10".into(),
                    remote_chassis_id_kind: "network_address",
                    remote_port_id: "52:54:00:12:34:56".into(),
                    remote_port_id_kind: "mac_address",
                    remote_system_name: Some("db-01".into()),
                    remote_port_description: None,
                    ttl_seconds: 2_700,
                }]),
                ..interface("ethernet1/1/1", "ethernet", Some("52:54:00:aa:00:01"))
            }]),
            domain: None,
        }],
    )
    .with_section_completeness(SectionCompleteness {
        interface_vlans: true,
        interface_neighbors: true,
    });

    assert_conforms("Observation", &report);
}

#[test]
fn a_hypervisor_report_matches_the_contract() {
    let report = ScopedReport::new(
        Collector {
            id: "local-libvirt".into(),
            kind: CollectorKind::VmProvider,
        },
        ReportScope::Hypervisor {
            hypervisor: HypervisorStatus {
                id: "hv-01".into(),
                status: Reachability::Reachable,
                error: None,
            },
        },
        true,
        vec![CollectorResource {
            kind: CollectorResourceKind::Vm,
            target: None,
            identifiers: CollectorIdentifiers {
                dmi_uuid: Some("4c4c4544-004d-3610-804b-c4c04f4e4a31".into()),
                ..Default::default()
            },
            attributes: None,
            interfaces: None,
            domain: Some(VmDomain {
                name: "web-01".into(),
                state: DomainState::Running,
                persistent: Some(true),
                vcpus: Some(2),
                memory_mib: Some(4_096),
                disks: vec![DomainDisk {
                    target: "vda".into(),
                    device: Some("disk".into()),
                    bus: Some("virtio".into()),
                    format: Some("qcow2".into()),
                    source: Some("/var/lib/libvirt/images/web-01.qcow2".into()),
                }],
                interfaces: vec![DomainInterface {
                    mac_address: "52:54:00:12:34:56".into(),
                    kind: DomainInterfaceType::Bridge,
                    source: Some("br0".into()),
                    model: Some("virtio".into()),
                    target: Some("vnet0".into()),
                }],
            }),
        }],
    );

    assert_conforms("Observation", &report);
}

#[test]
fn this_hosts_observation_matches_the_contract() {
    // Smoke coverage: collectors map OS facts to the API's vocabularies, so check what they
    // report here too. A host the agent cannot describe is not a contract failure.
    match collectors::collect(&Cancellation::default()) {
        Ok(resource) => assert_conforms("Observation", &Observation::new(resource)),
        Err(error) => eprintln!("skipping: cannot collect this host: {error}"),
    }
}

#[test]
fn check_ins_match_the_contract() {
    let queue = |oldest_age_seconds, dropped: Option<(u64, u64)>| QueueReport {
        entries: 3,
        bytes: 12_000,
        oldest_age_seconds,
        dropped_for_space: 1,
        expired: 2,
        rejected: 3,
        unreadable: 4,
        dropped_earliest_age_seconds: dropped.map(|(earliest, _latest)| earliest),
        dropped_latest_age_seconds: dropped.map(|(_earliest, latest)| latest),
    };

    // What the agent advertises: inventory it reports plus job capabilities its policy enables.
    let capabilities = collectors::capabilities()
        .into_iter()
        .map(String::from)
        .chain(["inventory.collect@1".to_owned()])
        .collect();
    assert_conforms("CheckIn", &CheckIn::new(capabilities, None));
    assert_conforms(
        "CheckIn",
        &CheckIn::new(vec![], Some(queue(Some(90), None))),
    );
    assert_conforms("CheckIn", &CheckIn::new(vec![], Some(queue(None, None))));
    assert_conforms(
        "CheckIn",
        &CheckIn::new(vec![], Some(queue(None, Some((600, 360)))))
            .with_telemetry_queue(Some(queue(Some(30), Some((86_400, 3_600))))),
    );

    let state = std::env::temp_dir().join(format!("renga-contract-{}", uuid::Uuid::new_v4()));
    let key = InstallationKey::load_or_create(&state).unwrap();
    assert_conforms(
        "CheckIn",
        &CheckIn::new(vec![], None).with_installation_key(PresentedKey::ed25519(key.public_key())),
    );
}

#[test]
fn host_power_batches_match_the_contract() {
    let reading = |sensor: &str, boundary, watts| hwmon::Reading {
        sensor: sensor.into(),
        boundary,
        watts,
        window: std::time::Duration::from_secs(30),
    };
    let batch = power::batch(
        &[
            reading(
                "pfe3000/acpi:\\_SB_.PCI0.I2C9.PSU0/power1",
                hwmon::Boundary::SupplyInput,
                Ok(245.5),
            ),
            reading(
                "ibm_cffps1/dt:ahb/apb/i2c@1e78a400/power-supply@68/power1",
                hwmon::Boundary::SupplyInput,
                Err(hwmon::SensorError {
                    message: "busy".into(),
                    denied: false,
                }),
            ),
            reading(
                "ibm_cffps1/dt:ahb/apb/i2c@1e78a400/power-supply@68/power2",
                hwmon::Boundary::SupplyOutput,
                Ok(0.0),
            ),
        ],
        chrono::Utc::now(),
    );

    assert_conforms("TelemetryBatch", &batch);
}

#[test]
fn the_contract_accepts_edge_cases_the_server_accepts() {
    // The server's intake API test posts these same bodies and asserts they are accepted. Its
    // own validator counts characters as Elixir does, so only a standards-compliant validator
    // like this one catches limits and formats that are stricter than the server.
    let fixtures = [
        (
            "CheckIn",
            include_str!("../../test/fixtures/openapi/accepted_check_ins.json"),
        ),
        (
            "Observation",
            include_str!("../../test/fixtures/openapi/accepted_observations.json"),
        ),
        (
            "TelemetryBatch",
            include_str!("../../test/fixtures/openapi/accepted_telemetry.json"),
        ),
    ];

    for (schema, fixture) in fixtures {
        let bodies: Vec<Value> = serde_json::from_str(fixture).unwrap();
        assert!(!bodies.is_empty(), "the {schema} fixture has no bodies");
        for body in &bodies {
            assert_conforms(schema, body);
        }
    }
}

#[test]
fn the_contract_rejects_what_the_server_rejects() {
    // Guards against a validator that silently accepts everything, such as an unresolved $ref.
    let mut observation = serde_json::to_value(full_observation()).unwrap();
    observation["resources"][0]["interfaces"][0]["mtu"] = json!(0);
    observation["resources"][0]["identifiers"]["serial"] = json!("typo");

    assert_eq!(
        violation_paths("Observation", &observation),
        ["/resources/0/identifiers", "/resources/0/interfaces/0/mtu"]
    );

    let mut check_in = serde_json::to_value(CheckIn::new(vec![String::new()], None)).unwrap();
    check_in["metadata"]["observation_queue"] = json!({ "entries": 1 });

    assert_eq!(
        violation_paths("CheckIn", &check_in),
        ["/capabilities/0", "/metadata/observation_queue"]
    );
}

#[test]
fn job_requests_match_the_contract() {
    let capabilities = ["inventory.collect@1".to_owned()];
    assert_conforms(
        "JobLeaseRequest",
        &LeaseRequest {
            capabilities: &capabilities,
            limit: 1,
        },
    );

    // The client signs claims of privileged offers with the installation key.
    let state = std::env::temp_dir().join(format!("renga-contract-{}", uuid::Uuid::new_v4()));
    let key = InstallationKey::load_or_create(&state).unwrap();
    assert_conforms(
        "JobClaim",
        &JobClaim {
            lease_token: "lease-token",
            nonce: "nonce",
            signature: URL_SAFE_NO_PAD.encode(key.sign(b"offer")),
        },
    );

    // The payloads the job worker sends for each report type.
    let reports = [
        (ReportType::Started, json!({})),
        (ReportType::Progress, json!({})),
        (
            ReportType::Succeeded,
            json!({"result": {"observation_id": "67e55044-10b1-426f-9247-bb680e5fe0c8"}}),
        ),
        (
            ReportType::Failed,
            json!({"reason": "timed out after 300s"}),
        ),
        (ReportType::Cancelled, json!({})),
    ];
    for (sequence, (kind, payload)) in (1..).zip(&reports) {
        assert_conforms(
            "JobReport",
            &JobReport {
                lease_token: "lease-token",
                sequence,
                kind: *kind,
                payload,
            },
        );
    }
}

/// Asserts that `body` is a valid `schema` response and that the agent can decode it.
fn assert_decodes<T: DeserializeOwned>(schema: &str, body: Value) -> T {
    let errors = violations(schema, &body);
    assert!(errors.is_empty(), "{schema} example is invalid: {errors:?}");
    serde_json::from_value(body)
        .unwrap_or_else(|error| panic!("the agent cannot decode a valid {schema}: {error}"))
}

#[test]
fn the_agent_asks_for_its_home_as_documented() {
    let spec: Value = serde_json::from_str(SPEC).unwrap();
    let operation = &spec["paths"]["/api/v1/agent/home"]["get"];
    assert_eq!(operation["operationId"], "getAgentHome");
    // The request carries no credential, so the document must not demand one.
    assert!(operation.get("security").is_none() && spec.get("security").is_none());
    let parameters = operation["parameters"].as_array().unwrap();
    assert!(parameters
        .iter()
        .any(|parameter| parameter["name"] == "deployment" && parameter["in"] == "query"));

    let home: AgentHome = assert_decodes("AgentHome", json!({ "home": "https://renga.example" }));
    assert_eq!(home.home, "https://renga.example");
    assert!(!violations("AgentHome", &json!({})).is_empty());
}

#[test]
fn the_agent_decodes_documented_responses() {
    let ack: CheckInAck = assert_decodes(
        "CheckInAccepted",
        json!({
            "status": "accepted",
            "source": {
                "id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
                "kind": "host_agent",
                "name": "host-agent-67e55044",
                "last_seen_at": "2026-10-14T12:00:00.000Z"
            },
            "agent": {
                "id": "8ea9ae04-bf9b-4c34-8192-4f617eade95e",
                "name": "db-01",
                "lease_expires_at": "2026-10-14T12:05:00.000Z"
            },
            "jobs_waiting": true
        }),
    );
    assert_eq!(ack.jobs_waiting, Some(true));
    assert_eq!(ack.installation_key, None);

    let ack: CheckInAck = assert_decodes(
        "CheckInAccepted",
        json!({
            "status": "accepted",
            "source": {
                "id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
                "kind": "host_agent",
                "name": "host-agent-67e55044",
                "last_seen_at": "2026-10-14T12:00:00.000Z"
            },
            "agent": {
                "id": "8ea9ae04-bf9b-4c34-8192-4f617eade95e",
                "name": "db-01",
                "lease_expires_at": "2026-10-14T12:05:00.000Z"
            },
            "jobs_waiting": false,
            "installation_key": {
                "fingerprint": "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU",
                "status": "pending"
            }
        }),
    );
    assert_eq!(
        ack.installation_key.map(|key| key.status),
        Some(KeyApproval::Pending)
    );

    let leased: LeaseResponse = assert_decodes(
        "JobLease",
        json!({
            "jobs": [{
                "id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
                "capability": "inventory.collect@1",
                "parameters": {},
                "attempt": 1,
                "lease_token": "lease-token",
                "lease_expires_at": "2026-10-14T12:01:00.000Z",
                "not_after": "2026-10-14T13:00:00.000Z",
                "timeout_ms": 300000,
                "output_limit_bytes": 65536
            }]
        }),
    );
    assert_eq!(leased.jobs.len(), 1);
    assert!(leased.offers.is_empty());

    let offered: LeaseResponse = assert_decodes(
        "JobLease",
        json!({
            "jobs": [],
            "offers": [{
                "job_id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
                "capability": "service.restart@1",
                "lease_token": "lease-token",
                "nonce": "nonce",
                "resource_id": "8ea9ae04-bf9b-4c34-8192-4f617eade95e",
                "binding_version": 1,
                "expires_at": "2026-10-14T12:01:00.000Z"
            }]
        }),
    );
    assert_eq!(offered.offers[0].binding_version, 1);

    // A successful claim answers with the leased job.
    let claimed: LeasedJob = assert_decodes(
        "LeasedJob",
        json!({
            "id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
            "capability": "service.restart@1",
            "parameters": {"service": "sshd"},
            "attempt": 1,
            "lease_token": "lease-token",
            "lease_expires_at": "2026-10-14T12:01:00.000Z",
            "not_after": "2026-10-14T13:00:00.000Z",
            "timeout_ms": 300000,
            "output_limit_bytes": 65536
        }),
    );
    assert_eq!(claimed.parameters["service"], "sshd");

    // A finished job has no lease left to report.
    let ack: ReportAck = assert_decodes(
        "JobReportAccepted",
        json!({
            "status": "accepted",
            "job": {
                "id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
                "state": "succeeded",
                "lease_expires_at": null
            },
            "cancel_requested": false
        }),
    );
    assert!(!ack.cancel_requested);
}

/// Polls a real SNMP agent when `RENGA_SNMPD_TEST` names one (see `snmp::client`'s live test)
/// and checks the report the poller would send. The agent must expose a chassis serial in
/// ENTITY-MIB. Skipped otherwise.
#[test]
fn a_live_switch_poll_matches_the_contract() {
    use renga_agent::snmp::{
        self,
        client::{PollError, Session, WireSession},
        config::{AuthProtocol, Credentials, PrivacyProtocol, SnmpCollector, Target},
    };
    use std::time::Duration;

    let (Ok(address), Ok(auth), Ok(privacy)) = (
        std::env::var("RENGA_SNMPD_TEST"),
        std::env::var("RENGA_SNMPD_AUTH"),
        std::env::var("RENGA_SNMPD_PRIV"),
    ) else {
        return;
    };
    let collector = SnmpCollector {
        id: "lab".into(),
        targets: vec![Target::parse(&address).unwrap()],
        credentials: Credentials::V3 {
            username: "renga".into(),
            auth_protocol: AuthProtocol::Sha256,
            auth_password_file: auth.into(),
            privacy_protocol: PrivacyProtocol::Aes128,
            privacy_password_file: privacy.into(),
        },
        interval: Duration::from_secs(900),
        timeout: Duration::from_secs(2),
        max_concurrent_targets: 1,
    };
    let open = |target: &Target| -> Result<Box<dyn Session>, PollError> {
        WireSession::open(target, &collector.credentials, collector.timeout)
            .map(|session| Box::new(session) as Box<dyn Session>)
    };
    let outcomes = snmp::poll(&collector, &Cancellation::default(), open);
    assert!(outcomes[0].result.is_ok(), "{:?}", outcomes[0].result);

    let [(_, body)] = <[_; 1]>::try_from(snmp::reports("lab", outcomes)).unwrap();
    let report: Value = serde_json::from_slice(&body).unwrap();
    let errors = violations("Observation", &report);
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(report["targets"][0]["status"], "reachable");
    assert!(!report["resources"][0]["interfaces"]
        .as_array()
        .unwrap()
        .is_empty());
}
