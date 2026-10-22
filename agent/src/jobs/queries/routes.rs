//! `query.routes@1`: the routing table of every routing domain. Inventory
//! sensitivity. Matches `Renga.Jobs.Queries.Routes`.
//!
//! iproute2 reads the kernel's tables over netlink and prints them as JSON;
//! the agent runs it with fixed arguments (`ip -j route show table all`, and
//! `ip -j -d link show type vrf` to name each VRF's table). The `family`
//! parameter picks which of the two route commands runs; it never becomes an
//! argument.

use super::{clip, failed, parameters, Bounded, Query, Sensitivity};
use crate::{cancellation::Cancellation, command, jobs::JobFailure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, process::Command, time::Duration};

const MAX_ROUTES: usize = 4096;
const IP_TIMEOUT: Duration = Duration::from_secs(10);
const IPV4_ROUTES: &[&str] = &["-j", "-4", "route", "show", "table", "all"];
const IPV6_ROUTES: &[&str] = &["-j", "-6", "route", "show", "table", "all"];
const VRFS: &[&str] = &["-j", "-d", "link", "show", "type", "vrf"];

/// Local, broadcast, and multicast entries describe addresses, not where
/// traffic goes, so they are left out.
const ADDRESS_TYPES: &[&str] = &["local", "broadcast", "anycast", "multicast"];

pub struct Routes;

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Family {
    Ipv4,
    Ipv6,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {
    family: Option<Family>,
}

#[derive(Debug, Serialize, PartialEq)]
struct Route {
    table: u32,
    vrf: Option<String>,
    family: &'static str,
    destination: String,
    gateway: Option<String>,
    interface: Option<String>,
    metric: Option<u64>,
    protocol: Option<String>,
}

impl Query for Routes {
    fn name(&self) -> &'static str {
        "query.routes"
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Inventory
    }

    fn answer(&self, raw: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        let params: Parameters = parameters(raw)?;
        let mut tables = Vec::new();
        if params.family != Some(Family::Ipv6) {
            tables.push(("ipv4", ip(IPV4_ROUTES, cancellation)?));
        }
        if params.family != Some(Family::Ipv4) {
            // A host without IPv6 answers with its IPv4 routes alone.
            match ip(IPV6_ROUTES, cancellation) {
                Ok(routes) => tables.push(("ipv6", routes)),
                Err(JobFailure::Cancelled) => return Err(JobFailure::Cancelled),
                Err(_) if params.family.is_none() => {}
                Err(error) => return Err(error),
            }
        }
        let vrfs = ip(VRFS, cancellation).unwrap_or(Value::Null);
        Ok(answer(&tables, &vrfs))
    }
}

fn ip(args: &[&str], cancellation: &Cancellation) -> Result<Value, JobFailure> {
    let output = command::run_with_timeout(Command::new("ip").args(args), cancellation, IP_TIMEOUT)
        .map_err(|error| {
            if cancellation.cancelled() {
                JobFailure::Cancelled
            } else if error.kind() == std::io::ErrorKind::NotFound {
                failed("iproute2 (ip) is not installed")
            } else {
                failed("could not read the routing tables")
            }
        })?;
    if !output.status.success() {
        return Err(failed("could not read the routing tables"));
    }
    // `ip -j` prints nothing at all for an empty selection.
    if output.stdout.iter().all(u8::is_ascii_whitespace) {
        return Ok(Value::Array(Vec::new()));
    }
    serde_json::from_slice(&output.stdout).map_err(|_| failed("ip's answer was not JSON"))
}

/// The kernel's names for its reserved tables, as `ip` prints them.
fn table_id(name: &str) -> Option<u32> {
    match name {
        "main" => Some(254),
        "local" => Some(255),
        "default" => Some(253),
        number => number.parse().ok(),
    }
}

fn answer(tables: &[(&'static str, Value)], vrfs: &Value) -> Value {
    let vrf_by_table: HashMap<u32, String> = vrfs
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|link| {
            let table = link["linkinfo"]["info_data"]["table"].as_u64()?;
            Some((
                u32::try_from(table).ok()?,
                link["ifname"].as_str()?.to_owned(),
            ))
        })
        .collect();

    let mut routes = Vec::new();
    for (family, entries) in tables {
        for entry in entries.as_array().into_iter().flatten() {
            if entry["type"]
                .as_str()
                .is_some_and(|kind| ADDRESS_TYPES.contains(&kind))
            {
                continue;
            }
            // `ip` omits the table for the main one and names tables it knows.
            let table = match &entry["table"] {
                Value::Null => Some(254),
                Value::String(name) => table_id(name),
                Value::Number(number) => number.as_u64().and_then(|n| u32::try_from(n).ok()),
                _ => None,
            };
            let (Some(table), Some(destination)) = (table, entry["dst"].as_str()) else {
                continue;
            };
            let text = |key: &str, max: usize| entry[key].as_str().map(|v| clip(v, max));
            routes.push(Route {
                table,
                vrf: vrf_by_table.get(&table).map(|name| clip(name, 64)),
                family,
                destination: clip(&prefix(destination, family), 64),
                gateway: text("gateway", 64),
                interface: text("dev", 64),
                metric: entry["metric"].as_u64(),
                protocol: text("protocol", 32),
            });
        }
    }
    routes.sort_by(|a, b| {
        (a.table, a.family, &a.destination).cmp(&(b.table, b.family, &b.destination))
    });

    let mut list = Bounded::new(MAX_ROUTES);
    for route in routes {
        if !list.push(route) {
            break;
        }
    }
    let (routes, truncated) = list.into_parts();
    serde_json::json!({ "routes": routes, "truncated": truncated })
}

/// Writes every destination as a prefix: `default` and bare host addresses
/// become `0.0.0.0/0` or `::/0` and `/32` or `/128`.
fn prefix(destination: &str, family: &str) -> String {
    match (destination, family) {
        ("default", "ipv4") => "0.0.0.0/0".to_owned(),
        ("default", _) => "::/0".to_owned(),
        (dst, _) if dst.contains('/') => dst.to_owned(),
        (dst, "ipv4") => format!("{dst}/32"),
        (dst, _) => format!("{dst}/128"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn lists_routes_per_table_with_vrf_names() {
        let ipv4 = json!([
            {"dst": "default", "gateway": "192.0.2.1", "dev": "eth0", "protocol": "dhcp", "metric": 100, "flags": []},
            {"dst": "10.20.0.0/16", "gateway": "10.0.0.1", "dev": "eth1", "table": "10", "protocol": "static", "flags": []},
            {"type": "local", "dst": "192.0.2.5", "table": "local", "dev": "eth0", "protocol": "kernel", "flags": []},
            {"type": "blackhole", "dst": "198.51.100.7", "flags": []}
        ]);
        let ipv6 = json!([{"dst": "fe80::/64", "dev": "eth0", "protocol": "kernel", "metric": 256, "flags": []}]);
        let vrfs = json!([{"ifname": "blue", "linkinfo": {"info_kind": "vrf", "info_data": {"table": 10}}}]);

        let value = answer(&[("ipv4", ipv4), ("ipv6", ipv6)], &vrfs);
        super::super::contract::assert_conforms("query.routes@1", "result", &value);
        assert_eq!(
            value,
            json!({
                "routes": [
                    {"table": 10, "vrf": "blue", "family": "ipv4", "destination": "10.20.0.0/16",
                     "gateway": "10.0.0.1", "interface": "eth1", "metric": null, "protocol": "static"},
                    {"table": 254, "vrf": null, "family": "ipv4", "destination": "0.0.0.0/0",
                     "gateway": "192.0.2.1", "interface": "eth0", "metric": 100, "protocol": "dhcp"},
                    {"table": 254, "vrf": null, "family": "ipv4", "destination": "198.51.100.7/32",
                     "gateway": null, "interface": null, "metric": null, "protocol": null},
                    {"table": 254, "vrf": null, "family": "ipv6", "destination": "fe80::/64",
                     "gateway": null, "interface": "eth0", "metric": 256, "protocol": "kernel"}
                ],
                "truncated": false
            })
        );
    }

    #[test]
    fn family_is_a_choice_not_an_argument() {
        for parameters in [
            json!({}),
            json!({"family": "ipv4"}),
            json!({"family": "ipv6"}),
        ] {
            super::super::contract::assert_conforms("query.routes@1", "parameters", &parameters);
        }
        assert!(Routes
            .answer(&json!({"family": "ipx"}), &Cancellation::default())
            .is_err());
        assert!(Routes
            .answer(&json!({"table": "all"}), &Cancellation::default())
            .is_err());
        assert_eq!(prefix("default", "ipv6"), "::/0");
        assert_eq!(prefix("2001:db8::1", "ipv6"), "2001:db8::1/128");
    }
}
