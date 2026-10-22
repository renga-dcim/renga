//! `query.services@1`: systemd service units with their load, active, sub,
//! and enablement states, read over systemd's D-Bus interface through
//! `busctl` with fixed arguments. Sensitive. Matches
//! `Renga.Jobs.Queries.Services`.

use super::{clip, failed, parameters, Bounded, Query, Sensitivity};
use crate::{cancellation::Cancellation, command, jobs::JobFailure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, process::Command, time::Duration};

const MAX_UNITS: usize = 4096;
const BUSCTL_TIMEOUT: Duration = Duration::from_secs(10);

/// `org.freedesktop.systemd1.Manager` calls, each a fixed argument vector.
const LIST_UNITS: &[&str] = &[
    "--system",
    "--json=short",
    "call",
    "org.freedesktop.systemd1",
    "/org/freedesktop/systemd1",
    "org.freedesktop.systemd1.Manager",
    "ListUnitsByPatterns",
    "asas",
    "0",
    "1",
    "*.service",
];
const LIST_UNIT_FILES: &[&str] = &[
    "--system",
    "--json=short",
    "call",
    "org.freedesktop.systemd1",
    "/org/freedesktop/systemd1",
    "org.freedesktop.systemd1.Manager",
    "ListUnitFilesByPatterns",
    "asas",
    "0",
    "1",
    "*.service",
];

pub struct Services;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {
    #[serde(default)]
    failed_only: bool,
}

#[derive(Debug, Serialize, PartialEq)]
struct Unit {
    name: String,
    description: Option<String>,
    load_state: String,
    active_state: String,
    sub_state: String,
    enabled_state: Option<String>,
}

impl Query for Services {
    fn name(&self) -> &'static str {
        "query.services"
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Sensitive
    }

    fn answer(&self, raw: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        let params: Parameters = parameters(raw)?;
        let units = busctl(LIST_UNITS, cancellation)?;
        // Enablement is extra detail; a unit list without it still answers.
        let files = busctl(LIST_UNIT_FILES, cancellation).unwrap_or(Value::Null);
        answer(&units, &files, params.failed_only)
    }
}

fn busctl(args: &[&str], cancellation: &Cancellation) -> Result<Value, JobFailure> {
    let output = command::run_with_timeout(
        Command::new("busctl").args(args),
        cancellation,
        BUSCTL_TIMEOUT,
    )
    .map_err(|error| {
        if cancellation.cancelled() {
            JobFailure::Cancelled
        } else if error.kind() == std::io::ErrorKind::NotFound {
            failed("busctl is not installed; systemd is required")
        } else {
            failed("could not reach systemd over D-Bus")
        }
    })?;
    if !output.status.success() {
        return Err(failed("systemd refused the unit list over D-Bus"));
    }
    serde_json::from_slice(&output.stdout).map_err(|_| failed("systemd's answer was not JSON"))
}

/// Joins `ListUnitsByPatterns` (`a(ssssssouso)`) with `ListUnitFilesByPatterns`
/// (`a(ss)`), both as `busctl --json=short` prints them.
fn answer(units: &Value, files: &Value, failed_only: bool) -> Result<Value, JobFailure> {
    let rows = units["data"][0]
        .as_array()
        .ok_or_else(|| failed("systemd's unit list had an unexpected shape"))?;

    let enabled: HashMap<&str, &str> = files["data"][0]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|row| {
            let path = row[0].as_str()?;
            let name = path.rsplit('/').next()?;
            Some((name, row[1].as_str()?))
        })
        .collect();

    let mut list = Bounded::new(MAX_UNITS);
    let mut units: Vec<Unit> = rows
        .iter()
        .filter_map(|row| {
            let field = |index: usize| row[index].as_str().map(str::to_owned);
            let name = field(0)?;
            Some(Unit {
                enabled_state: enabled.get(name.as_str()).map(|state| clip(state, 32)),
                name: clip(&name, 256),
                description: field(1).filter(|d| !d.is_empty()).map(|d| clip(&d, 256)),
                load_state: clip(&field(2)?, 32),
                active_state: clip(&field(3)?, 32),
                sub_state: clip(&field(4)?, 32),
            })
        })
        .filter(|unit| !failed_only || unit.active_state == "failed")
        .collect();
    units.sort_by(|a, b| a.name.cmp(&b.name));
    for unit in units {
        if !list.push(unit) {
            break;
        }
    }
    let (units, truncated) = list.into_parts();
    Ok(serde_json::json!({ "units": units, "truncated": truncated }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn units() -> Value {
        json!({"type": "a(ssssssouso)", "data": [[
            ["sshd.service", "OpenSSH server daemon", "loaded", "active", "running", "",
             "/org/freedesktop/systemd1/unit/sshd_2eservice", 0, "", "/"],
            ["backup.service", "", "loaded", "failed", "failed", "",
             "/org/freedesktop/systemd1/unit/backup_2eservice", 0, "", "/"]
        ]]})
    }

    fn files() -> Value {
        json!({"type": "a(ss)", "data": [[
            ["/usr/lib/systemd/system/sshd.service", "enabled"],
            ["/etc/systemd/system/backup.service", "disabled"]
        ]]})
    }

    #[test]
    fn joins_units_with_their_enablement() {
        assert_eq!(
            answer(&units(), &files(), false).unwrap(),
            json!({
                "units": [
                    {"name": "backup.service", "description": null, "load_state": "loaded",
                     "active_state": "failed", "sub_state": "failed", "enabled_state": "disabled"},
                    {"name": "sshd.service", "description": "OpenSSH server daemon",
                     "load_state": "loaded", "active_state": "active", "sub_state": "running",
                     "enabled_state": "enabled"}
                ],
                "truncated": false
            })
        );
    }

    #[test]
    fn filters_failed_units_and_tolerates_missing_files() {
        let value = answer(&units(), &Value::Null, true).unwrap();
        super::super::contract::assert_conforms("query.services@1", "result", &value);
        super::super::contract::assert_conforms(
            "query.services@1",
            "result",
            &answer(&units(), &files(), false).unwrap(),
        );
        assert_eq!(value["units"].as_array().unwrap().len(), 1);
        assert_eq!(value["units"][0]["enabled_state"], Value::Null);
        assert!(answer(&json!({"data": []}), &Value::Null, false).is_err());
    }

    #[test]
    fn the_argument_vectors_are_fixed() {
        // Nothing from the request can reach busctl.
        assert!(Services
            .answer(&json!({"unit": "x"}), &Cancellation::default())
            .is_err());
        assert_eq!(LIST_UNITS.last(), Some(&"*.service"));
    }
}
