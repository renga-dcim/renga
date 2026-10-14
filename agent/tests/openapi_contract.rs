//! Checks the agent's request bodies against the server's published OpenAPI document.
//!
//! The server generates `priv/openapi/v1.json` from its own validator and fails its tests when the
//! file is stale, so a payload change on either side that breaks the contract fails here.

use renga_agent::{
    cancellation::Cancellation,
    collectors,
    payload::{
        Address, CheckIn, Component, HostAttributes, Identifiers, Interface, Observation,
        QueueReport, ResourceKind, ServerResource,
    },
};
use serde::Serialize;
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
    let queue = |oldest_age_seconds| QueueReport {
        entries: 3,
        bytes: 12_000,
        oldest_age_seconds,
        dropped_for_space: 1,
        expired: 2,
        rejected: 3,
        unreadable: 4,
    };

    assert_conforms("CheckIn", &CheckIn::new(collectors::capabilities(), None));
    assert_conforms("CheckIn", &CheckIn::new(vec![], Some(queue(Some(90)))));
    assert_conforms("CheckIn", &CheckIn::new(vec![], Some(queue(None))));
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

    let mut check_in = serde_json::to_value(CheckIn::new(vec![""], None)).unwrap();
    check_in["metadata"]["observation_queue"] = json!({ "entries": 1 });

    assert_eq!(
        violation_paths("CheckIn", &check_in),
        ["/capabilities/0", "/metadata/observation_queue"]
    );
}
