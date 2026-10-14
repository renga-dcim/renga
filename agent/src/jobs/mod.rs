//! On-demand jobs (RFD 9): capabilities compiled into the agent, the local
//! policy that enables them, and the worker that runs leased jobs.
//!
//! Renga can only ask for work an agent advertises, and an agent advertises a
//! capability only when it is compiled in and enabled by its own
//! configuration. Renga cannot widen that set remotely.

pub mod inventory_collect;
pub mod record;
pub mod worker;

use crate::cancellation::Cancellation;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{fmt, sync::Arc, time::Duration};

/// What running a capability can do to the host, fixed by its definition.
/// Must match the capability's risk class in `Renga.Jobs.Registry`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RiskClass {
    /// Reads the host and reports, changing nothing else.
    Observe,
    /// Changes host or guest state.
    Operate,
    /// Opens a session a person drives.
    Interactive,
}

/// What running a job twice means, fixed by its definition. Decides what
/// the agent does with a redelivered job it started but never finished.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RetryClass {
    Idempotent,
    Convergent,
    Imperative,
}

/// Why a capability stopped without a result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobFailure {
    /// The job's cancellation was signalled and the capability stopped early.
    Cancelled,
    /// The capability ran and failed. The reason is shown to people in Renga,
    /// so it must not carry secrets.
    Failed(String),
}

/// One operation the agent can run on request. Implementations check the
/// cancellation between steps so a cancelled or timed-out job stops promptly.
pub trait Capability: Send + Sync {
    fn name(&self) -> &'static str;
    fn version(&self) -> u32;
    fn risk_class(&self) -> RiskClass;
    fn retry_class(&self) -> RetryClass;
    /// The longest a run may take before the agent reports it failed.
    fn timeout(&self) -> Duration;
    /// Runs the job and returns the `result` object Renga checks against
    /// the capability's result schema.
    fn run(&self, parameters: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure>;

    fn key(&self) -> String {
        format!("{}@{}", self.name(), self.version())
    }
}

/// A `name@version` capability key, as Renga writes it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct CapabilityKey {
    pub name: String,
    pub version: u32,
}

impl CapabilityKey {
    /// Parses `name@version`. Unversioned entries such as `host.inventory`
    /// describe what an agent reports, not jobs it accepts, so they are not keys.
    pub fn parse(key: &str) -> Option<Self> {
        let (name, raw_version) = key.split_once('@')?;
        let version = raw_version.parse::<u32>().ok().filter(|v| *v > 0)?;
        // Leading zeros or a sign would parse but never match Renga's key.
        if !valid_name(name) || version.to_string() != raw_version {
            return None;
        }
        Some(Self {
            name: name.to_owned(),
            version,
        })
    }
}

impl fmt::Display for CapabilityKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}@{}", self.name, self.version)
    }
}

/// Matches `Renga.Jobs.Capability.parse_key/1`: two or more dot-separated
/// segments of lowercase letters, digits, and underscores, each starting
/// with a letter.
pub fn valid_name(name: &str) -> bool {
    let segments: Vec<&str> = name.split('.').collect();
    segments.len() >= 2
        && segments.iter().all(|segment| {
            let mut bytes = segment.bytes();
            bytes.next().is_some_and(|b| b.is_ascii_lowercase())
                && bytes.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        })
}

/// One `[jobs] enabled` entry: a capability name, enabling every version,
/// or a `name@version` key, enabling just that one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selector {
    Name(String),
    Key(CapabilityKey),
}

impl Selector {
    pub fn parse(entry: &str) -> Option<Self> {
        if entry.contains('@') {
            CapabilityKey::parse(entry).map(Self::Key)
        } else {
            valid_name(entry).then(|| Self::Name(entry.to_owned()))
        }
    }

    fn matches(&self, capability: &dyn Capability) -> bool {
        match self {
            Self::Name(name) => name == capability.name(),
            Self::Key(key) => key.name == capability.name() && key.version == capability.version(),
        }
    }
}

/// The operator's `[jobs]` policy from the agent configuration.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct JobPolicy {
    /// `None` when the operator has not chosen: every compiled-in `observe`
    /// capability is enabled, so on-demand collection works out of the box.
    /// An explicit list, even an empty one, enables exactly what it names.
    pub enabled: Option<Vec<Selector>>,
}

impl JobPolicy {
    pub fn allows(&self, capability: &dyn Capability) -> bool {
        match &self.enabled {
            None => capability.risk_class() == RiskClass::Observe,
            Some(selectors) => selectors.iter().any(|s| s.matches(capability)),
        }
    }
}

/// The capabilities compiled into this agent.
#[derive(Clone, Default)]
pub struct Catalog(Vec<Arc<dyn Capability>>);

impl Catalog {
    pub fn new(capabilities: Vec<Arc<dyn Capability>>) -> Self {
        Self(capabilities)
    }

    /// The `name@version` keys the agent will run under `policy`, which are
    /// what it advertises at check-in and asks to lease.
    pub fn enabled_keys(&self, policy: &JobPolicy) -> Vec<String> {
        self.0
            .iter()
            .filter(|capability| policy.allows(capability.as_ref()))
            .map(|capability| capability.key())
            .collect()
    }

    /// The capability for a leased job's key, only while policy enables it.
    /// Leasing re-checks here because the policy may have been reloaded since
    /// the agent last advertised.
    pub fn enabled(&self, key: &str, policy: &JobPolicy) -> Option<Arc<dyn Capability>> {
        self.0
            .iter()
            .find(|capability| capability.key() == key && policy.allows(capability.as_ref()))
            .cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake(&'static str, u32, RiskClass);

    impl Capability for Fake {
        fn name(&self) -> &'static str {
            self.0
        }
        fn version(&self) -> u32 {
            self.1
        }
        fn risk_class(&self) -> RiskClass {
            self.2
        }
        fn retry_class(&self) -> RetryClass {
            RetryClass::Idempotent
        }
        fn timeout(&self) -> Duration {
            Duration::from_secs(1)
        }
        fn run(&self, _: &Value, _: &Cancellation) -> Result<Value, JobFailure> {
            Ok(Value::Null)
        }
    }

    fn catalog() -> Catalog {
        Catalog::new(vec![
            Arc::new(Fake("inventory.collect", 1, RiskClass::Observe)),
            Arc::new(Fake("inventory.collect", 2, RiskClass::Observe)),
            Arc::new(Fake("service.restart", 1, RiskClass::Operate)),
            Arc::new(Fake("console.open", 1, RiskClass::Interactive)),
        ])
    }

    fn policy(entries: &[&str]) -> JobPolicy {
        JobPolicy {
            enabled: Some(
                entries
                    .iter()
                    .map(|e| Selector::parse(e).unwrap())
                    .collect(),
            ),
        }
    }

    #[test]
    fn parses_only_keys_renga_would_write() {
        assert_eq!(
            CapabilityKey::parse("inventory.collect@1"),
            Some(CapabilityKey {
                name: "inventory.collect".into(),
                version: 1
            })
        );
        for key in [
            "host.inventory",
            "inventory.collect@0",
            "inventory.collect@01",
            "inventory.collect@+1",
            "inventory.collect@",
            "inventory@1",
            "Inventory.collect@1",
            "inventory.1collect@1",
            "inventory..collect@1",
            "inventory.collect@1@2",
        ] {
            assert_eq!(CapabilityKey::parse(key), None, "{key}");
        }
    }

    #[test]
    fn default_policy_enables_only_observe_capabilities() {
        assert_eq!(
            catalog().enabled_keys(&JobPolicy::default()),
            ["inventory.collect@1", "inventory.collect@2"]
        );
    }

    #[test]
    fn an_explicit_policy_enables_exactly_what_it_names() {
        let catalog = catalog();
        assert!(catalog.enabled_keys(&policy(&[])).is_empty());
        assert_eq!(
            catalog.enabled_keys(&policy(&["inventory.collect@2", "service.restart"])),
            ["inventory.collect@2", "service.restart@1"]
        );
        assert!(catalog
            .enabled("inventory.collect@1", &policy(&["inventory.collect@2"]))
            .is_none());
        assert!(catalog
            .enabled("inventory.collect@2", &policy(&["inventory.collect"]))
            .is_some());
        assert!(catalog
            .enabled("unknown.thing@1", &JobPolicy::default())
            .is_none());
    }
}
