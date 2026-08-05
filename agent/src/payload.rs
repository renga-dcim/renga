//! JSON models matching the Phoenix host-agent contract.

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;
use uuid::Uuid;

#[derive(Debug, Serialize)]
pub struct Observation {
    pub observation_id: Uuid,
    pub observed_at: DateTime<Utc>,
    pub source: Source,
    /// The API requires exactly one host; the fixed-size array enforces that shape.
    pub resources: [ServerResource; 1],
}

#[derive(Debug, Serialize)]
pub struct Source {
    pub kind: SourceKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    HostAgent,
}

#[derive(Debug, Serialize)]
pub struct ServerResource {
    pub kind: ResourceKind,
    pub identifiers: Identifiers,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attributes: Option<HostAttributes>,
    pub interfaces: Vec<Interface>,
    pub components: Vec<Component>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceKind {
    Server,
}

#[derive(Debug, Default, Serialize)]
pub struct Identifiers {
    pub hostname: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fqdn: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dmi_uuid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub serial_number: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub mac_address: Vec<String>,
}

/// Only fields projected by `AgentPayload` belong here; hardware detail is a component.
#[derive(Debug, Default, Serialize)]
pub struct HostAttributes {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fqdn: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vendor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub asset_tag: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Interface {
    pub name: String,
    pub kind: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mac_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mtu: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed_mbps: Option<u32>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub addresses: Vec<Address>,
}

#[derive(Debug, Serialize)]
pub struct Address {
    pub address: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
}

/// Components are deliberately shape-open while retaining a stable type discriminator.
#[derive(Debug, Serialize)]
pub struct Component {
    pub kind: String,
    #[serde(flatten)]
    pub attributes: BTreeMap<String, Value>,
}

#[derive(Debug, Serialize)]
pub struct CheckIn {
    pub capabilities: [&'static str; 1],
    pub metadata: AgentMetadata,
}
#[derive(Debug, Serialize)]
pub struct AgentMetadata {
    pub agent_version: String,
    pub installation_id: Uuid,
}
impl CheckIn {
    pub fn new(installation_id: Uuid) -> Self {
        Self {
            capabilities: ["host.inventory"],
            metadata: AgentMetadata {
                agent_version: env!("CARGO_PKG_VERSION").into(),
                installation_id,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn observation_contract_omits_absent_values() {
        let resource = ServerResource {
            kind: ResourceKind::Server,
            identifiers: Identifiers {
                hostname: "host".into(),
                ..Default::default()
            },
            attributes: None,
            interfaces: vec![],
            components: vec![],
        };
        let value = serde_json::to_value(Observation {
            observation_id: Uuid::nil(),
            observed_at: DateTime::parse_from_rfc3339("2026-01-02T03:04:05Z")
                .unwrap()
                .to_utc(),
            source: Source {
                kind: SourceKind::HostAgent,
                source_id: None,
            },
            resources: [resource],
        })
        .unwrap();
        assert_eq!(value["observed_at"], "2026-01-02T03:04:05Z");
        assert_eq!(value["source"]["kind"], "host_agent");
        assert!(value["source"].get("source_id").is_none());
        assert!(value["resources"][0].get("attributes").is_none());
        assert_eq!(value["resources"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn checkin_has_capability_and_identity() {
        let value = serde_json::to_value(CheckIn::new(Uuid::nil())).unwrap();
        assert_eq!(value["capabilities"][0], "host.inventory");
        assert_eq!(
            value["metadata"]["installation_id"],
            Uuid::nil().to_string()
        );
    }
}
