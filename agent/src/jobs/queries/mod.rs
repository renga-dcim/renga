//! Operational queries (RFD 12): typed, read-only questions Renga asks about
//! this host, such as which sockets are listening.
//!
//! Each query is an `observe` capability named `query.<name>@<version>` that
//! matches a `Renga.Jobs.Queries` module on the server: the same parameters,
//! result shape, sensitivity, and timeout. The agent validates parameters
//! again before it runs and keeps every result inside Renga's bound, cutting
//! lists short and saying so with `truncated`.
//!
//! Queries read procfs, system calls, and package databases directly. Where
//! one must run a program (`busctl`, `ip`, `chronyc`, `rpm`), its argument
//! vector is fixed here and never includes text from the request: a filter
//! such as a package name is applied to the program's output, not passed to
//! it. No query takes a command, a path, or a script.
//!
//! Where the host runs osquery and `[osquery]` is enabled, a query with SQL
//! fixed in the agent answers from osquery's tables instead (RFD 12). The
//! result has the same shape, request text never reaches the SQL, and any
//! osquery failure falls back to the native reading.

pub mod disk_usage;
pub mod listening_sockets;
pub mod packages;
pub mod routes;
pub mod services;
pub mod time_sync;

use super::{Capability, JobFailure, RetryClass, RiskClass};
use crate::{
    cancellation::Cancellation,
    osquery::{self, OsqueryConfig},
};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;
use std::{sync::Arc, time::Duration};
use tracing::warn;

/// How long a query waits on each osquery call before reading natively.
const OSQUERY_TIMEOUT: Duration = Duration::from_secs(20);

/// How revealing a query's answer is. Matches the server's `sensitivity/0`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sensitivity {
    /// No more revealing than an observation; enabled by default.
    Inventory,
    /// Software versions, running services, or other detail an attacker would
    /// value; enabled only by an explicit `[jobs]` entry.
    Sensitive,
}

/// One query's definition and how this host answers it.
pub trait Query: Send + Sync {
    /// `query.<name>`.
    fn name(&self) -> &'static str;
    fn sensitivity(&self) -> Sensitivity;
    fn timeout(&self) -> Duration {
        Duration::from_secs(30)
    }
    fn answer(&self, parameters: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure>;

    /// Whether [`Query::answer_with_osquery`] has SQL to run.
    fn uses_osquery(&self) -> bool {
        false
    }

    /// Answers from osquery's tables with SQL fixed in the agent. `Ok(None)`
    /// means osquery could not answer, and the native reading runs instead.
    fn answer_with_osquery(
        &self,
        _osquery: &mut osquery::Client,
        _parameters: &Value,
    ) -> Result<Option<Value>, JobFailure> {
        Ok(None)
    }
}

/// Runs a [`Query`] as a job capability: version 1, `observe`, idempotent.
pub struct QueryCapability {
    query: Box<dyn Query>,
    osquery: OsqueryConfig,
}

impl QueryCapability {
    pub fn new(query: impl Query + 'static, osquery: OsqueryConfig) -> Self {
        Self {
            query: Box::new(query),
            osquery,
        }
    }

    fn with_osquery(&self, parameters: &Value) -> Result<Option<Value>, JobFailure> {
        if !self.osquery.enabled || !self.query.uses_osquery() {
            return Ok(None);
        }
        match osquery::Client::connect(&self.osquery.socket, OSQUERY_TIMEOUT) {
            Ok(mut client) => self.query.answer_with_osquery(&mut client, parameters),
            Err(_absent) => Ok(None),
        }
    }
}

impl Capability for QueryCapability {
    fn name(&self) -> &'static str {
        self.query.name()
    }

    fn version(&self) -> u32 {
        1
    }

    fn risk_class(&self) -> RiskClass {
        RiskClass::Observe
    }

    fn retry_class(&self) -> RetryClass {
        RetryClass::Idempotent
    }

    fn timeout(&self) -> Duration {
        self.query.timeout()
    }

    fn enabled_by_default(&self) -> bool {
        self.query.sensitivity() == Sensitivity::Inventory
    }

    fn run(&self, parameters: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        if cancellation.cancelled() {
            return Err(JobFailure::Cancelled);
        }
        if let Some(answer) = self.with_osquery(parameters)? {
            return Ok(answer);
        }
        self.query.answer(parameters, cancellation)
    }
}

/// The queries this platform answers. Each reads Linux interfaces, so other
/// platforms offer none yet. Those with fixed SQL ask `osquery` first.
pub fn catalog(osquery: &OsqueryConfig) -> Vec<Arc<dyn Capability>> {
    if !cfg!(target_os = "linux") {
        return Vec::new();
    }
    let osquery = || osquery.clone();
    vec![
        Arc::new(QueryCapability::new(
            listening_sockets::ListeningSockets,
            osquery(),
        )),
        Arc::new(QueryCapability::new(services::Services, osquery())),
        Arc::new(QueryCapability::new(disk_usage::DiskUsage, osquery())),
        Arc::new(QueryCapability::new(routes::Routes, osquery())),
        Arc::new(QueryCapability::new(time_sync::TimeSync, osquery())),
        Arc::new(QueryCapability::new(packages::Packages, osquery())),
    ]
}

/// Runs fixed SQL, or returns `None` when osquery cannot answer it so the
/// caller reads natively. The failure is logged, not reported.
pub fn osquery_rows(osquery: &mut osquery::Client, sql: &str) -> Option<Vec<osquery::Row>> {
    osquery
        .query(sql)
        .map_err(|error| warn!(%error, sql, "osquery could not answer; reading natively"))
        .ok()
}

/// An osquery cell as an unsigned number; osquery renders NULL as "".
pub fn osquery_u64(row: &osquery::Row, column: &str) -> Option<u64> {
    row.get(column)?.parse().ok()
}

/// An osquery cell as text, with osquery's empty NULL as `None`.
pub fn osquery_text<'a>(row: &'a osquery::Row, column: &str) -> Option<&'a str> {
    row.get(column)
        .map(String::as_str)
        .filter(|text| !text.is_empty())
}

/// Parses a query's parameters. A missing or `null` object means no
/// parameters; unknown fields are refused, as Renga refuses them.
pub fn parameters<T: DeserializeOwned + Default>(parameters: &Value) -> Result<T, JobFailure> {
    match parameters {
        Value::Null => Ok(T::default()),
        value => serde_json::from_value(value.clone())
            .map_err(|error| JobFailure::Failed(format!("invalid parameters: {error}"))),
    }
}

/// The compact JSON size a list result may reach. Renga stores each report
/// as JSONB, whose text adds a space after every separator, and caps it at
/// 64 KiB, so this leaves room for that and the report around the result.
pub const RESULT_BUDGET_BYTES: usize = 48 * 1024;

/// A list result that stops growing at its item limit or the byte budget,
/// remembering whether anything was left out.
pub struct Bounded<T> {
    items: Vec<T>,
    max_items: usize,
    bytes: usize,
    truncated: bool,
}

impl<T: Serialize> Bounded<T> {
    pub fn new(max_items: usize) -> Self {
        Self {
            items: Vec::new(),
            max_items,
            bytes: 0,
            truncated: false,
        }
    }

    /// Adds `item` if it fits; returns false once the list is full, so a
    /// caller can stop reading.
    pub fn push(&mut self, item: T) -> bool {
        if self.truncated {
            return false;
        }
        // Each item costs its own JSON plus a separating comma.
        let size = serde_json::to_vec(&item).map_or(usize::MAX, |bytes| bytes.len() + 1);
        if self.items.len() >= self.max_items
            || self.bytes.saturating_add(size) > RESULT_BUDGET_BYTES
        {
            self.truncated = true;
            return false;
        }
        self.bytes += size;
        self.items.push(item);
        true
    }

    pub fn truncated(&self) -> bool {
        self.truncated
    }

    pub fn into_parts(self) -> (Vec<T>, bool) {
        (self.items, self.truncated)
    }
}

/// Keeps `value` within `max` characters, as Renga's schema requires.
pub fn clip(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

/// How much a query keeps of a program's answer (`ip`, `busctl`, `rpm`)
/// before it gives up. The answer is parsed whole and then cut down to the
/// result bound, so a cut answer would be broken JSON or a silently short
/// list; past this limit the query fails and says so instead.
pub const PROGRAM_OUTPUT_BYTES: u64 = 32 * 1024 * 1024;

/// Runs one of a query's fixed programs, keeping up to
/// [`PROGRAM_OUTPUT_BYTES`]. `what` names the answer in failures, such as
/// "the routing tables". The program's own exit status is the caller's to
/// read.
pub fn run_program(
    command: &mut std::process::Command,
    cancellation: &Cancellation,
    timeout: Duration,
    what: &str,
) -> Result<crate::command::Output, JobFailure> {
    let output =
        crate::command::run_with_limits(command, cancellation, timeout, PROGRAM_OUTPUT_BYTES)
            .map_err(|error| {
                if cancellation.cancelled() {
                    JobFailure::Cancelled
                } else if error.kind() == std::io::ErrorKind::NotFound {
                    failed(&format!(
                        "could not read {what}: the program is not installed"
                    ))
                } else {
                    failed(&format!("could not read {what}"))
                }
            })?;
    if output.overflowed {
        return Err(failed(&format!("{what} are too large to read")));
    }
    Ok(output)
}

/// A failure people can read in Renga, without the program output or paths
/// that could reveal more than the query itself.
pub fn failed(reason: &str) -> JobFailure {
    JobFailure::Failed(reason.to_owned())
}

/// Checks query answers against Renga's contract for each query, which the
/// server generates from its own schemas and fails its tests when stale.
#[cfg(test)]
pub(crate) mod contract {
    use serde_json::Value;

    const CONTRACT: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../priv/queries/v1.json"
    ));

    pub fn all() -> Value {
        serde_json::from_str(CONTRACT).expect("the query contract is JSON")
    }

    /// Asserts that `value` is a `part` ("parameters" or "result") Renga
    /// accepts for the query `key`.
    pub fn assert_conforms(key: &str, part: &str, value: &Value) {
        let schema = &all()[key][part];
        assert!(schema.is_object(), "{key} has no {part} in the contract");
        let validator = jsonschema::draft202012::new(schema)
            .unwrap_or_else(|error| panic!("cannot compile {key} {part}: {error}"));
        let errors: Vec<String> = validator
            .iter_errors(value)
            .map(|error| format!("{}: {error}", error.instance_path()))
            .collect();
        assert!(
            errors.is_empty(),
            "{key} {part} does not match priv/queries/v1.json:\n{}\n\n{value:#}",
            errors.join("\n")
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::json;

    #[cfg(target_os = "linux")]
    #[test]
    fn the_catalog_matches_renga_s_contract() {
        let contract = contract::all();
        let mut keys: Vec<String> = catalog(&OsqueryConfig::default())
            .iter()
            .map(|c| c.key())
            .collect();
        let mut expected: Vec<String> = contract.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        expected.sort();
        assert_eq!(keys, expected);

        for capability in catalog(&OsqueryConfig::default()) {
            let entry = &contract[capability.key()];
            assert_eq!(
                capability.enabled_by_default(),
                entry["sensitivity"] == "inventory",
                "{}",
                capability.key()
            );
            assert_eq!(
                capability.timeout().as_millis(),
                u128::from(entry["timeout_ms"].as_u64().unwrap()),
                "{}",
                capability.key()
            );
            // The agent's budget leaves room for JSONB's extra spaces.
            assert!(
                RESULT_BUDGET_BYTES * 5 / 4
                    < entry["output_limit_bytes"].as_u64().unwrap() as usize
            );
        }
    }

    #[derive(Debug, Default, Deserialize, PartialEq)]
    #[serde(deny_unknown_fields)]
    struct Params {
        port: Option<u16>,
    }

    #[test]
    fn parameters_refuse_unknown_fields() {
        assert_eq!(
            parameters::<Params>(&Value::Null).unwrap(),
            Params::default()
        );
        assert_eq!(
            parameters::<Params>(&json!({"port": 22})).unwrap(),
            Params { port: Some(22) }
        );
        assert!(parameters::<Params>(&json!({"command": "id"})).is_err());
        assert!(parameters::<Params>(&json!({"port": "22"})).is_err());
    }

    #[test]
    fn bounded_lists_stop_at_items_or_bytes() {
        let mut list = Bounded::new(2);
        assert!(list.push("a"));
        assert!(list.push("b"));
        assert!(!list.push("c"));
        assert_eq!(list.into_parts(), (vec!["a", "b"], true));

        let big = "x".repeat(RESULT_BUDGET_BYTES / 2);
        let mut list = Bounded::new(100);
        assert!(list.push(big.clone()));
        assert!(!list.push(big));
        assert!(list.truncated());
    }

    #[test]
    fn sensitive_queries_are_off_by_default() {
        let names: Vec<(String, bool)> = catalog(&OsqueryConfig::default())
            .iter()
            .map(|c| (c.key(), c.enabled_by_default()))
            .collect();
        if cfg!(target_os = "linux") {
            assert_eq!(
                names,
                [
                    ("query.listening_sockets@1".to_owned(), false),
                    ("query.services@1".to_owned(), false),
                    ("query.disk_usage@1".to_owned(), true),
                    ("query.routes@1".to_owned(), true),
                    ("query.time_sync@1".to_owned(), true),
                    ("query.packages@1".to_owned(), false),
                ]
            );
        }
    }

    #[test]
    fn clip_counts_characters() {
        assert_eq!(clip("héllo", 2), "hé");
    }
}
