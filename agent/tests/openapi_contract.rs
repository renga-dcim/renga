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

/// Asserts that `body` satisfies the named schema under `#/components/schemas`.
fn assert_conforms(schema: &str, body: &impl Serialize) {
    // Rooting the validator at the whole document lets the component's `$ref`s resolve.
    let mut root: Value = serde_json::from_str(SPEC).expect("the OpenAPI document is JSON");
    root["$ref"] = json!(format!("#/components/schemas/{schema}"));
    let validator = jsonschema::draft202012::options()
        .should_validate_formats(true)
        .build(&root)
        .unwrap_or_else(|error| panic!("cannot compile the {schema} schema: {error}"));

    let body = serde_json::to_value(body).unwrap();
    let errors: Vec<String> = validator
        .iter_errors(&body)
        .map(|error| format!("{}: {error}", error.instance_path()))
        .collect();
    assert!(
        errors.is_empty(),
        "{schema} body does not match priv/openapi/v1.json:\n{}\n\nbody: {body:#}",
        errors.join("\n")
    );
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
    // Collectors map OS facts to the API's vocabularies, so check what they report here too.
    let resource =
        collectors::collect(&Cancellation::default()).expect("collecting this host succeeds");
    assert_conforms("Observation", &Observation::new(resource));
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
fn the_contract_rejects_what_the_server_rejects() {
    // Guards against a validator that silently accepts everything, such as an unresolved $ref.
    let mut observation = serde_json::to_value(full_observation()).unwrap();
    observation["resources"][0]["interfaces"][0]["mtu"] = json!(0);
    observation["resources"][0]["identifiers"]["serial"] = json!("typo");

    let mut root: Value = serde_json::from_str(SPEC).unwrap();
    root["$ref"] = json!("#/components/schemas/Observation");
    let validator = jsonschema::draft202012::new(&root).unwrap();
    let mut paths: Vec<String> = validator
        .iter_errors(&observation)
        .map(|error| error.instance_path().to_string())
        .collect();
    paths.sort();

    assert_eq!(
        paths,
        ["/resources/0/identifiers", "/resources/0/interfaces/0/mtu"]
    );
}
