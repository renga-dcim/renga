//! JSON models matching the Phoenix host-agent contract.

use crate::queue::QueueHealth;
use chrono::{DateTime, Utc};
use serde::{ser::SerializeMap, Deserialize, Serialize, Serializer};
use serde_json::Value;
use std::{collections::BTreeMap, fmt, time::SystemTime};
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
#[derive(Debug, Clone, Default, Serialize)]
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

#[derive(Debug, Clone, Default, Serialize)]
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
    /// `access` or `trunk`; switch pollers report it with `vlans`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vlan_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vlans: Option<Vec<VlanMembership>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub neighbors: Option<Vec<Neighbor>>,
}

/// A VLAN an interface carries, by VID within the reporting source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VlanMembership {
    pub vid: u16,
    pub tagging_mode: TaggingMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TaggingMode {
    Tagged,
    Untagged,
}

/// A device seen on the other end of an interface (RFD 7 neighbor evidence).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Neighbor {
    pub protocol: &'static str,
    pub remote_chassis_id: String,
    pub remote_chassis_id_kind: &'static str,
    pub remote_port_id: String,
    pub remote_port_id_kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_system_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_port_description: Option<String>,
    pub ttl_seconds: u32,
}

#[derive(Debug, Clone, Serialize)]
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

/// A collector module's report about the targets it polls or the hypervisor it reads (RFD 11).
///
/// Unlike a host observation it carries any number of resources, and is authoritative only for
/// its scope. The collector names the stream the server resolves it to, and because the queue
/// stores the exact body, a report replayed after a restart or reconfiguration still lands in the
/// stream that produced it.
#[derive(Debug, Serialize)]
pub struct ScopedReport {
    pub observation_id: Uuid,
    pub observed_at: DateTime<Utc>,
    #[serde(flatten)]
    pub scope: ReportScope,
    pub collector: Collector,
    /// Whether each reachable target's resources are all here, so the server may withdraw what a
    /// target no longer reports. Partial reports never withdraw anything.
    pub complete: bool,
    pub resources: Vec<CollectorResource>,
    /// Interface sections every resource reports in full, so what is missing from them is gone.
    #[serde(skip_serializing_if = "SectionCompleteness::is_empty")]
    pub section_completeness: SectionCompleteness,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct SectionCompleteness {
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub interface_vlans: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub interface_neighbors: bool,
}

impl SectionCompleteness {
    fn is_empty(&self) -> bool {
        !self.interface_vlans && !self.interface_neighbors
    }
}

impl ScopedReport {
    pub fn new(
        collector: Collector,
        scope: ReportScope,
        complete: bool,
        resources: Vec<CollectorResource>,
    ) -> Self {
        Self {
            observation_id: Uuid::new_v4(),
            observed_at: Utc::now(),
            scope,
            collector,
            complete,
            resources,
            section_completeness: SectionCompleteness::default(),
        }
    }

    pub fn with_section_completeness(self, section_completeness: SectionCompleteness) -> Self {
        Self {
            section_completeness,
            ..self
        }
    }
}

/// What a report covers. An unreachable target's or hypervisor's resources are unknown, not gone.
#[derive(Debug, Serialize)]
#[serde(tag = "scope", rename_all = "snake_case")]
pub enum ReportScope {
    Targets { targets: Vec<TargetStatus> },
    Hypervisor { hypervisor: HypervisorStatus },
}

#[derive(Debug, Serialize)]
pub struct TargetStatus {
    pub address: String,
    pub status: Reachability,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct HypervisorStatus {
    pub id: String,
    pub status: Reachability,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reachability {
    Reachable,
    Unreachable,
}

/// The stable, locally configured identity of one collector module instance.
#[derive(Debug, Clone, Serialize)]
pub struct Collector {
    pub id: String,
    pub kind: CollectorKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CollectorKind {
    BmcPower,
    PowerPoller,
    SwitchPoller,
    VmProvider,
}

impl CollectorKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BmcPower => "bmc_power",
            Self::PowerPoller => "power_poller",
            Self::SwitchPoller => "switch_poller",
            Self::VmProvider => "vm_provider",
        }
    }
}

/// A switch, PDU, server, or VM a collector reports. The server matches it only by
/// `serial_number`, `dmi_uuid`, or `machine_id`, so one of them is required.
#[derive(Debug, Clone, Serialize)]
pub struct CollectorResource {
    pub kind: CollectorResourceKind,
    /// The address of the reachable target it was polled from; `targets` scope only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    pub identifiers: CollectorIdentifiers,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attributes: Option<HostAttributes>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interfaces: Option<Vec<Interface>>,
    /// The hypervisor's view of a VM; `hypervisor` scope only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub domain: Option<VmDomain>,
}

/// What a hypervisor reports about one domain (RFD 11, "Virtualization collection"). Its NICs
/// stay here rather than in `interfaces`, which belong to the guest's own view.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VmDomain {
    pub name: String,
    pub state: DomainState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub persistent: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vcpus: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_mib: Option<u64>,
    pub disks: Vec<DomainDisk>,
    pub interfaces: Vec<DomainInterface>,
}

/// Running, idle, paused, and shutting-down domains occupy the hypervisor; the rest are only
/// defined on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DomainState {
    Running,
    Idle,
    Paused,
    ShuttingDown,
    Shutoff,
    Crashed,
    Pmsuspended,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DomainDisk {
    pub target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bus: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DomainInterface {
    pub mac_address: String,
    #[serde(rename = "type")]
    pub kind: DomainInterfaceType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DomainInterfaceType {
    Bridge,
    Network,
    Direct,
    User,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CollectorResourceKind {
    Pdu,
    Server,
    Switch,
    Vm,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct CollectorIdentifiers {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub serial_number: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dmi_uuid: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub mac_address: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct CheckIn {
    /// Unversioned entries describe what the agent reports; `name@version`
    /// entries are job capabilities it will run on request (RFD 9).
    pub capabilities: Vec<String>,
    pub metadata: AgentMetadata,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installation_key: Option<PresentedKey>,
}

/// The installation's public key, presented on every check-in (RFD 13).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PresentedKey {
    pub algorithm: &'static str,
    /// The raw 32-byte Ed25519 public key in unpadded base64url.
    pub public_key: String,
}

impl PresentedKey {
    pub fn ed25519(public_key: String) -> Self {
        Self {
            algorithm: "ed25519",
            public_key,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct AgentMetadata {
    pub agent_version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observation_queue: Option<QueueReport>,
    /// The telemetry queue, bounded and reported separately (RFD 10, "Measured history").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub telemetry_queue: Option<QueueReport>,
    /// Whether each power source can be read here (RFD 10, "Source status").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub power_sources: Option<Vec<PowerSourceReport>>,
}

/// One power source's status as a check-in reports it. Must match
/// `Renga.Inventory.AgentPayload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PowerSourceReport {
    /// The source, such as `hwmon` or an exporter's URL.
    pub source: String,
    /// `available`, `not_permitted`, `not_present`, or `unreachable`.
    pub status: &'static str,
}

impl CheckIn {
    pub fn new(capabilities: Vec<String>, observation_queue: Option<QueueReport>) -> Self {
        Self {
            capabilities,
            metadata: AgentMetadata {
                agent_version: env!("CARGO_PKG_VERSION").into(),
                observation_queue,
                telemetry_queue: None,
                power_sources: None,
            },
            installation_key: None,
        }
    }

    pub fn with_telemetry_queue(mut self, report: Option<QueueReport>) -> Self {
        self.metadata.telemetry_queue = report;
        self
    }

    pub fn with_power_sources(mut self, reports: Option<Vec<PowerSourceReport>>) -> Self {
        self.metadata.power_sources = reports;
        self
    }

    pub fn with_installation_key(mut self, key: PresentedKey) -> Self {
        self.installation_key = Some(key);
        self
    }
}

/// A queue's health as a check-in reports it, so Renga can show a collector's undelivered
/// backlog. Must match `Renga.Inventory.AgentPayload`. Drop counts cover the agent's current
/// run; the backlog itself survives restarts.
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
    /// How long ago the earliest and latest entries dropped for space or age were queued,
    /// omitted when none were.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dropped_earliest_age_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dropped_latest_age_seconds: Option<u64>,
}

impl QueueReport {
    pub fn new(health: &QueueHealth, now: SystemTime) -> Self {
        // A clock stepped backwards makes a drop look recent rather than failing the report.
        let age = |at: SystemTime| now.duration_since(at).unwrap_or_default().as_secs();
        let dropped = health.counters.dropped_range;
        Self {
            entries: health.entries as u64,
            bytes: health.bytes,
            oldest_age_seconds: health.oldest_age(now).map(|age| age.as_secs()),
            dropped_for_space: health.counters.dropped_for_space,
            expired: health.counters.expired,
            rejected: health.counters.rejected,
            unreadable: health.counters.unreadable,
            dropped_earliest_age_seconds: dropped.map(|(earliest, _latest)| age(earliest)),
            dropped_latest_age_seconds: dropped.map(|(_earliest, latest)| age(latest)),
        }
    }
}

/// Phoenix's maximum encoded telemetry batch size (`Renga.Telemetry.Payload`).
pub const MAX_TELEMETRY_BYTES: usize = 512_000;

/// A batch of timed readings (RFD 10, "Measured history"). Must match
/// `Renga.Telemetry.Payload`. The replay ID makes a resent batch idempotent, and the batch can
/// never be mistaken for an inventory observation.
#[derive(Debug, Clone, Serialize)]
pub struct TelemetryBatch {
    pub version: u32,
    pub replay_id: Uuid,
    /// The collector module that produced the batch; absent for the host's own readings.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collector: Option<TelemetryCollector>,
    pub samples: Vec<TelemetrySample>,
}

impl TelemetryBatch {
    pub fn host(samples: Vec<TelemetrySample>) -> Self {
        Self {
            version: 1,
            replay_id: Uuid::new_v4(),
            collector: None,
            samples,
        }
    }

    /// A batch from one collector module, whose samples each name their target.
    pub fn collector(id: &str, kind: CollectorKind, samples: Vec<TelemetrySample>) -> Self {
        Self {
            collector: Some(TelemetryCollector {
                id: id.to_owned(),
                kind: kind.as_str(),
            }),
            ..Self::host(samples)
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TelemetryCollector {
    pub id: String,
    pub kind: &'static str,
}

/// One reading with its canonical identity. A failed read is sent as `status: "failed"` with
/// no value, so Renga records the series as unknown rather than zero.
#[derive(Debug, Clone, Serialize)]
pub struct TelemetrySample {
    /// The collector's target; absent for the host's own readings.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    pub sensor: String,
    pub boundary: &'static str,
    pub quantity: &'static str,
    /// Absent for a `state` reading.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<&'static str>,
    /// The power port or outlet the reading is about, when the source names one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub component: Option<SampleComponent>,
    /// The phase of a `leg` reading: `a`, `b`, or `c`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub leg: Option<&'static str>,
    /// Whether an aggregate such as a PDU inlet's meter covers all of its load (`complete`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub coverage: Option<&'static str>,
    pub status: &'static str,
    pub origin: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    /// A `state` reading's value, such as `ok` or `failed`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<&'static str>,
    pub window: SampleWindow,
    pub event_at: DateTime<Utc>,
    pub mapping: SampleMapping,
    pub fresh_for_seconds: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SampleComponent {
    pub kind: &'static str,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SampleWindow {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SampleMapping {
    pub name: &'static str,
    pub version: u32,
}

/// What a check-in response tells the agent beyond acceptance. Missing fields
/// mean an older server, so every field is optional.
#[derive(Debug, Default, Clone, PartialEq, Eq, Deserialize)]
pub struct CheckInAck {
    /// `true` when Renga holds queued jobs for this installation (RFD 9).
    #[serde(default)]
    pub jobs_waiting: Option<bool>,
    /// Whether an owner or admin approved the presented key (RFD 13).
    #[serde(default)]
    pub installation_key: Option<KeyStatus>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct KeyStatus {
    pub fingerprint: String,
    pub status: KeyApproval,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KeyApproval {
    Pending,
    Approved,
}

/// Where an agent's home deployment is (RFD 23), answered without a credential.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct AgentHome {
    /// The home's origin, validated before any request is sent to it.
    pub home: String,
}

/// Asks Renga to lease queued jobs for the capabilities the agent runs now.
#[derive(Debug, Serialize)]
pub struct LeaseRequest<'a> {
    pub capabilities: &'a [String],
    pub limit: u32,
}

#[derive(Debug, Deserialize)]
pub struct LeaseResponse {
    pub jobs: Vec<LeasedJob>,
    /// Privileged jobs this installation may claim with a signature (RFD 13).
    #[serde(default)]
    pub offers: Vec<JobOffer>,
}

/// A privileged job Renga offers without its parameters. Claiming it with
/// the installation key's signature over `JobOffer::message` leases it.
#[derive(Clone, Deserialize)]
pub struct JobOffer {
    pub job_id: Uuid,
    pub capability: String,
    pub lease_token: String,
    pub nonce: String,
    pub resource_id: Uuid,
    pub binding_version: u64,
    pub expires_at: DateTime<Utc>,
}

impl JobOffer {
    /// The bytes the installation key signs to claim this offer. Matches
    /// `Renga.Jobs.SignedLeases.message/6`.
    pub fn message(&self, installation_id: Uuid) -> Vec<u8> {
        format!(
            "renga-job-lease-v1\n{}\n{}\n{}\n{}\n{}\n{}\n",
            self.job_id,
            self.lease_token,
            self.nonce,
            installation_id,
            self.resource_id,
            self.binding_version
        )
        .into_bytes()
    }
}

impl fmt::Debug for JobOffer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("JobOffer")
            .field("job_id", &self.job_id)
            .field("capability", &self.capability)
            .field("lease_token", &"[REDACTED]")
            .field("resource_id", &self.resource_id)
            .field("binding_version", &self.binding_version)
            .field("expires_at", &self.expires_at)
            .finish_non_exhaustive()
    }
}

/// Claims a `JobOffer` with the installation key's signature.
#[derive(Debug, Serialize)]
pub struct JobClaim<'a> {
    pub lease_token: &'a str,
    pub nonce: &'a str,
    /// The Ed25519 signature in unpadded base64url.
    pub signature: String,
}

/// A job Renga leased to this agent. Matches `RengaWeb.Api.V1.JobController`.
#[derive(Clone, Deserialize)]
pub struct LeasedJob {
    pub id: Uuid,
    /// The `name@version` key of the capability to run.
    pub capability: String,
    #[serde(default)]
    pub parameters: Value,
    /// Counts leases of this job, so a redelivery has a higher attempt.
    pub attempt: u32,
    /// Proves this agent holds the lease on every report.
    pub lease_token: String,
    pub lease_expires_at: DateTime<Utc>,
    pub timeout_ms: u64,
    pub output_limit_bytes: u64,
}

impl fmt::Debug for LeasedJob {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LeasedJob")
            .field("id", &self.id)
            .field("capability", &self.capability)
            .field("attempt", &self.attempt)
            .field("lease_token", &"[REDACTED]")
            .field("lease_expires_at", &self.lease_expires_at)
            .field("timeout_ms", &self.timeout_ms)
            .field("output_limit_bytes", &self.output_limit_bytes)
            .finish()
    }
}

/// A report type the agent may post on a job it holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReportType {
    Started,
    Progress,
    Output,
    Succeeded,
    Failed,
    Cancelled,
}

impl ReportType {
    /// Whether the report ends the job, releasing its lease.
    pub fn terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Cancelled)
    }
}

/// One numbered report on a leased job. A retried post carries the same
/// sequence, so Renga records it once.
#[derive(Serialize)]
pub struct JobReport<'a> {
    pub lease_token: &'a str,
    pub sequence: u64,
    #[serde(rename = "type")]
    pub kind: ReportType,
    pub payload: &'a Value,
}

/// Renga's answer to an accepted report.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ReportAck {
    /// `true` once someone asked to cancel the job; the agent stops and
    /// reports `cancelled`.
    #[serde(default)]
    pub cancel_requested: bool,
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
    fn a_scoped_report_names_its_scope_and_collector() {
        let report = ScopedReport::new(
            Collector {
                id: "core-switches".into(),
                kind: CollectorKind::SwitchPoller,
            },
            ReportScope::Targets {
                targets: vec![TargetStatus {
                    address: "10.0.0.1".into(),
                    status: Reachability::Unreachable,
                    error: Some("timeout".into()),
                }],
            },
            false,
            vec![],
        );
        let value = serde_json::to_value(&report).unwrap();

        assert_eq!(value["scope"], "targets");
        assert_eq!(value["collector"]["id"], "core-switches");
        assert_eq!(value["collector"]["kind"], "switch_poller");
        assert_eq!(value["targets"][0]["status"], "unreachable");
        assert_eq!(value["complete"], false);
        assert_eq!(value["resources"], serde_json::json!([]));
        assert!(value.get("hypervisor").is_none());
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
        let value =
            serde_json::to_value(CheckIn::new(vec!["host.inventory".into()], None)).unwrap();
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
                dropped_range: None,
            },
        };
        let report = QueueReport::new(&health, queued_at + Duration::from_secs(90));
        let value = serde_json::to_value(CheckIn::new(vec![], Some(report))).unwrap();
        assert!(value["metadata"].get("telemetry_queue").is_none());

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

    #[test]
    fn checkin_reports_the_telemetry_queue_and_when_its_drops_were_queued() {
        use crate::queue::QueueCounters;
        use std::time::{Duration, UNIX_EPOCH};

        let start = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let health = QueueHealth {
            entries: 1,
            bytes: 100,
            oldest_queued_at: Some(start + Duration::from_secs(500)),
            counters: QueueCounters {
                dropped_for_space: 4,
                expired: 1,
                dropped_range: Some((start, start + Duration::from_secs(240))),
                ..QueueCounters::default()
            },
        };
        let report = QueueReport::new(&health, start + Duration::from_secs(600));
        let value =
            serde_json::to_value(CheckIn::new(vec![], None).with_telemetry_queue(Some(report)))
                .unwrap();

        let queue = &value["metadata"]["telemetry_queue"];
        assert_eq!(queue["entries"], 1);
        assert_eq!(queue["oldest_age_seconds"], 100);
        assert_eq!(queue["dropped_for_space"], 4);
        assert_eq!(queue["dropped_earliest_age_seconds"], 600);
        assert_eq!(queue["dropped_latest_age_seconds"], 360);
        assert!(value["metadata"].get("observation_queue").is_none());
    }

    #[test]
    fn offers_sign_the_same_lines_renga_verifies() {
        let leased: LeaseResponse = serde_json::from_value(serde_json::json!({
            "jobs": [],
            "offers": [{
                "job_id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
                "capability": "service.restart@1",
                "lease_token": "secret-token",
                "nonce": "nonce",
                "resource_id": "1f0e9b2a-3c4d-4e5f-8a9b-0c1d2e3f4a5b",
                "binding_version": 3,
                "expires_at": "2026-10-14T12:00:00.000Z"
            }]
        }))
        .unwrap();
        let offer = &leased.offers[0];
        let installation = Uuid::parse_str("7d444840-9dc0-11d1-b245-5ffdce74fad2").unwrap();
        assert_eq!(
            String::from_utf8(offer.message(installation)).unwrap(),
            "renga-job-lease-v1\n67e55044-10b1-426f-9247-bb680e5fe0c8\nsecret-token\nnonce\n\
             7d444840-9dc0-11d1-b245-5ffdce74fad2\n1f0e9b2a-3c4d-4e5f-8a9b-0c1d2e3f4a5b\n3\n"
        );
        assert!(!format!("{offer:?}").contains("secret-token"));
    }

    #[test]
    fn job_contract_round_trips_and_redacts_the_lease_token() {
        let leased: LeaseResponse = serde_json::from_value(serde_json::json!({
            "jobs": [{
                "id": "67e55044-10b1-426f-9247-bb680e5fe0c8",
                "capability": "inventory.collect@1",
                "parameters": {},
                "attempt": 2,
                "lease_token": "secret-token",
                "lease_expires_at": "2026-10-14T12:00:00.000Z",
                "not_after": "2026-10-14T13:00:00.000Z",
                "timeout_ms": 300000,
                "output_limit_bytes": 65536
            }]
        }))
        .unwrap();
        let job = &leased.jobs[0];
        assert!(leased.offers.is_empty(), "older servers send no offers");
        assert_eq!(job.capability, "inventory.collect@1");
        assert_eq!(job.attempt, 2);
        assert!(!format!("{job:?}").contains("secret-token"));

        let payload = serde_json::json!({"result": {"observation_id": "x"}});
        let report = serde_json::to_value(JobReport {
            lease_token: &job.lease_token,
            sequence: 3,
            kind: ReportType::Succeeded,
            payload: &payload,
        })
        .unwrap();
        assert_eq!(report["type"], "succeeded");
        assert_eq!(report["sequence"], 3);

        let ack: CheckInAck = serde_json::from_str(r#"{"status":"accepted"}"#).unwrap();
        assert_eq!(ack.jobs_waiting, None);
        let ack: ReportAck =
            serde_json::from_str(r#"{"status":"accepted","cancel_requested":true}"#).unwrap();
        assert!(ack.cancel_requested);
    }
}
