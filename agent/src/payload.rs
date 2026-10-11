//! JSON models matching the Phoenix host-agent contract.

use crate::queue::QueueHealth;
use chrono::{DateTime, Utc};
use serde::{ser::SerializeMap, Serialize, Serializer};
use serde_json::Value;
use std::{collections::BTreeMap, time::SystemTime};
use uuid::Uuid;

/// Phoenix's configured maximum encoded request-body size for observations.
/// Keeping this contract shared prevents the agent from sending a body the API cannot parse.
pub const MAX_OBSERVATION_BYTES: usize = 256_000;

#[derive(Debug, Serialize)]
pub struct Observation {
    pub observation_id: Uuid,
    pub observed_at: DateTime<Utc>,
    pub source: Source,
    /// The API requires exactly one host; the fixed-size array enforces that shape.
    pub resources: [ServerResource; 1],
}

impl Observation {
    /// Attaches configured labels to the reported server.
    pub fn with_labels(mut self, labels: &BTreeMap<String, String>) -> Self {
        self.resources[0].labels = labels.clone();
        self
    }

    pub fn new(resource: ServerResource) -> Self {
        Self {
            observation_id: Uuid::new_v4(),
            observed_at: Utc::now(),
            source: Source {
                kind: SourceKind::HostAgent,
                source_id: None,
            },
            resources: [resource],
        }
    }
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interfaces: Option<Vec<Interface>>,
    pub components: Vec<Component>,
    /// Labels from the agent configuration, not collected from the host.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub labels: BTreeMap<String, String>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub addresses: Option<Vec<Address>>,
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
#[derive(Debug)]
pub struct Component {
    pub kind: String,
    pub attributes: BTreeMap<String, Value>,
}

impl Serialize for Component {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.attributes.len() + 1))?;
        map.serialize_entry("kind", &self.kind)?;
        for (key, value) in self
            .attributes
            .iter()
            .filter(|(key, _)| key.as_str() != "kind")
        {
            map.serialize_entry(key, value)?;
        }
        map.end()
    }
}

#[derive(Debug, Serialize)]
pub struct CheckIn {
    pub capabilities: Vec<&'static str>,
    pub metadata: AgentMetadata,
}

#[derive(Debug, Serialize)]
pub struct AgentMetadata {
    pub agent_version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observation_queue: Option<QueueReport>,
}

impl CheckIn {
    pub fn new(capabilities: Vec<&'static str>, observation_queue: Option<QueueReport>) -> Self {
        Self {
            capabilities,
            metadata: AgentMetadata {
                agent_version: env!("CARGO_PKG_VERSION").into(),
                observation_queue,
            },
        }
    }
}

/// The observation queue's health as a check-in reports it, so Renga can show a collector's
/// undelivered backlog. Must match `Renga.Inventory.AgentPayload`. Drop counts cover the agent's
/// current run; the backlog itself survives restarts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct QueueReport {
    pub entries: u64,
    pub bytes: u64,
    /// `null` when nothing is queued.
    pub oldest_age_seconds: Option<u64>,
    pub dropped_for_space: u64,
    pub expired: u64,
    pub rejected: u64,
    pub unreadable: u64,
}

impl QueueReport {
    pub fn new(health: &QueueHealth, now: SystemTime) -> Self {
        Self {
            entries: health.entries as u64,
            bytes: health.bytes,
            oldest_age_seconds: health.oldest_age(now).map(|age| age.as_secs()),
            dropped_for_space: health.counters.dropped_for_space,
            expired: health.counters.expired,
            rejected: health.counters.rejected,
            unreadable: health.counters.unreadable,
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
            interfaces: None,
            components: vec![],
            labels: BTreeMap::new(),
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
        assert!(value["resources"][0].get("interfaces").is_none());
        assert_eq!(value["resources"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn authoritative_empty_interfaces_are_serialized() {
        let resource = ServerResource {
            kind: ResourceKind::Server,
            identifiers: Identifiers {
                hostname: "host".into(),
                ..Default::default()
            },
            attributes: None,
            interfaces: Some(vec![]),
            components: vec![],
            labels: BTreeMap::new(),
        };

        let value = serde_json::to_value(resource).unwrap();
        assert_eq!(value["interfaces"], serde_json::json!([]));
    }
    #[test]
    fn component_serialization_has_one_kind_discriminator() {
        let component = Component {
            kind: "virtualization".into(),
            attributes: BTreeMap::from([
                ("kind".into(), serde_json::json!("vmware")),
                ("environment".into(), serde_json::json!("vm_guest")),
            ]),
        };

        let json = serde_json::to_string(&component).unwrap();
        assert_eq!(json.matches("\"kind\"").count(), 1);
        assert_eq!(
            serde_json::from_str::<Value>(&json).unwrap()["kind"],
            "virtualization"
        );
    }
    #[test]
    fn checkin_has_capability_and_identity() {
        let value = serde_json::to_value(CheckIn::new(vec!["host.inventory"], None)).unwrap();
        assert_eq!(value["capabilities"][0], "host.inventory");
        assert_eq!(
            value["metadata"]["agent_version"],
            env!("CARGO_PKG_VERSION")
        );
        assert!(value["metadata"].get("observation_queue").is_none());
    }

    #[test]
    fn checkin_reports_queue_health_as_of_now() {
        use crate::queue::QueueCounters;
        use serde_json::json;
        use std::time::{Duration, UNIX_EPOCH};

        let queued_at = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let health = QueueHealth {
            entries: 3,
            bytes: 12_000,
            oldest_queued_at: Some(queued_at),
            counters: QueueCounters {
                dropped_for_space: 1,
                expired: 2,
                rejected: 3,
                unreadable: 4,
            },
        };
        let report = QueueReport::new(&health, queued_at + Duration::from_secs(90));
        let value = serde_json::to_value(CheckIn::new(vec![], Some(report))).unwrap();

        assert_eq!(
            value["metadata"]["observation_queue"],
            json!({
                "entries": 3,
                "bytes": 12_000,
                "oldest_age_seconds": 90,
                "dropped_for_space": 1,
                "expired": 2,
                "rejected": 3,
                "unreadable": 4
            })
        );

        let empty = QueueHealth {
            entries: 0,
            bytes: 0,
            oldest_queued_at: None,
            counters: QueueCounters::default(),
        };
        let value = serde_json::to_value(QueueReport::new(&empty, queued_at)).unwrap();
        assert_eq!(value["oldest_age_seconds"], Value::Null);
    }
}
