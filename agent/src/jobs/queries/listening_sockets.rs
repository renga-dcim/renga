//! `query.listening_sockets@1`: listening TCP and unconnected UDP sockets
//! with the processes that own them, from procfs. Sensitive. Matches
//! `Renga.Jobs.Queries.ListeningSockets`.
//!
//! An owner is named only when the agent may read that process's file
//! descriptors, so on a host where the agent runs unprivileged most sockets
//! report no process rather than a guess. With osquery, its
//! `listening_ports` and `processes` tables answer instead, with osquery's
//! own privileges.

use super::{
    clip, osquery_rows, osquery_text, osquery_u64, parameters, Bounded, Query, Sensitivity,
};
use crate::{cancellation::Cancellation, jobs::JobFailure, osquery};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, net::SocketAddr};

const MAX_SOCKETS: usize = 4096;
/// IPv4 and IPv6 sockets (families 2 and 10) over TCP and UDP (protocols 6
/// and 17), with the owning process's name.
const OSQUERY_SQL: &str = "SELECT lp.protocol, lp.address, lp.port, lp.pid, p.name \
     FROM listening_ports AS lp LEFT JOIN processes AS p USING (pid) \
     WHERE lp.family IN (2, 10) AND lp.protocol IN (6, 17)";

pub struct ListeningSockets;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {
    port: Option<u16>,
}

/// One socket as procfs lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listener {
    pub protocol: &'static str,
    pub local: SocketAddr,
    pub inode: u64,
}

#[derive(Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
struct Socket {
    protocol: &'static str,
    address: String,
    port: u16,
    process: Option<String>,
    pid: Option<i32>,
}

impl Query for ListeningSockets {
    fn name(&self) -> &'static str {
        "query.listening_sockets"
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Sensitive
    }

    fn answer(&self, raw: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        let port = port(raw)?;
        let listeners = read_listeners()?;
        if cancellation.cancelled() {
            return Err(JobFailure::Cancelled);
        }
        let owners = read_owners(cancellation);
        Ok(answer(listeners, &owners, port))
    }

    fn uses_osquery(&self) -> bool {
        true
    }

    fn answer_with_osquery(
        &self,
        osquery: &mut osquery::Client,
        raw: &Value,
    ) -> Result<Option<Value>, JobFailure> {
        let port = port(raw)?;
        let Some(rows) = osquery_rows(osquery, OSQUERY_SQL) else {
            return Ok(None);
        };
        Ok(Some(sockets_answer(
            rows.iter().filter_map(socket_from_osquery).collect(),
            port,
        )))
    }
}

fn port(raw: &Value) -> Result<Option<u16>, JobFailure> {
    let params: Parameters = parameters(raw)?;
    if params.port == Some(0) {
        return Err(super::failed("invalid parameters: port must be 1 to 65535"));
    }
    Ok(params.port)
}

fn answer(
    listeners: Vec<Listener>,
    owners: &HashMap<u64, (i32, String)>,
    port: Option<u16>,
) -> Value {
    let sockets = listeners
        .into_iter()
        .map(|listener| {
            let owner = owners.get(&listener.inode);
            Socket {
                protocol: listener.protocol,
                address: listener.local.ip().to_string(),
                port: listener.local.port(),
                process: owner.map(|(_, name)| clip(name, 64)),
                pid: owner.map(|(pid, _)| *pid),
            }
        })
        .collect();
    sockets_answer(sockets, port)
}

/// One `listening_ports` row; osquery reports an unknown owner as pid -1.
fn socket_from_osquery(row: &osquery::Row) -> Option<Socket> {
    let protocol = match row.get("protocol")?.as_str() {
        "6" => "tcp",
        "17" => "udp",
        _ => return None,
    };
    let pid = row.get("pid")?.parse::<i32>().ok().filter(|pid| *pid > 0);
    Some(Socket {
        protocol,
        address: clip(osquery_text(row, "address")?, 64),
        port: u16::try_from(osquery_u64(row, "port")?).ok()?,
        process: pid
            .and(osquery_text(row, "name"))
            .map(|name| clip(name, 64)),
        pid,
    })
}

fn sockets_answer(mut sockets: Vec<Socket>, port: Option<u16>) -> Value {
    sockets.retain(|socket| port.is_none_or(|port| socket.port == port));
    sockets.sort_by(|a, b| (a.port, a.protocol, &a.address).cmp(&(b.port, b.protocol, &b.address)));
    sockets.dedup();
    let mut list = Bounded::new(MAX_SOCKETS);
    for socket in sockets {
        if !list.push(socket) {
            break;
        }
    }
    let (sockets, truncated) = list.into_parts();
    serde_json::json!({ "sockets": sockets, "truncated": truncated })
}

#[cfg(target_os = "linux")]
fn read_listeners() -> Result<Vec<Listener>, JobFailure> {
    use procfs::net::{TcpState, UdpState};

    // Every Linux host has the IPv4 tables; one without IPv6 has no others.
    let tcp4 = procfs::net::tcp().map_err(|_| super::failed("could not read the socket tables"))?;
    let tcp = tcp4
        .into_iter()
        .chain(procfs::net::tcp6().unwrap_or_default());
    let mut listeners: Vec<Listener> = tcp
        .filter(|e| e.state == TcpState::Listen)
        .map(|e| Listener {
            protocol: "tcp",
            local: e.local_address,
            inode: e.inode,
        })
        .collect();
    let udp = procfs::net::udp()
        .unwrap_or_default()
        .into_iter()
        .chain(procfs::net::udp6().unwrap_or_default());
    // An unconnected UDP socket is the one that receives from anyone.
    listeners.extend(
        udp.filter(|e| e.state == UdpState::Close && e.remote_address.port() == 0)
            .map(|e| Listener {
                protocol: "udp",
                local: e.local_address,
                inode: e.inode,
            }),
    );
    Ok(listeners)
}

#[cfg(not(target_os = "linux"))]
fn read_listeners() -> Result<Vec<Listener>, JobFailure> {
    Err(super::failed("listening sockets are only read on Linux"))
}

/// Socket inode to owning process, for the processes the agent may inspect.
#[cfg(target_os = "linux")]
fn read_owners(cancellation: &Cancellation) -> HashMap<u64, (i32, String)> {
    use procfs::process::FDTarget;

    let mut owners = HashMap::new();
    let Ok(processes) = procfs::process::all_processes() else {
        return owners;
    };
    for process in processes.flatten() {
        if cancellation.cancelled() {
            break;
        }
        let Ok(fds) = process.fd() else {
            continue;
        };
        let name = process.stat().map(|stat| stat.comm).unwrap_or_default();
        for fd in fds.flatten() {
            if let FDTarget::Socket(inode) = fd.target {
                owners.entry(inode).or_insert((process.pid, name.clone()));
            }
        }
    }
    owners
}

#[cfg(not(target_os = "linux"))]
fn read_owners(_: &Cancellation) -> HashMap<u64, (i32, String)> {
    HashMap::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn listener(protocol: &'static str, address: &str, inode: u64) -> Listener {
        Listener {
            protocol,
            local: address.parse().unwrap(),
            inode,
        }
    }

    #[test]
    fn names_owners_it_can_see_and_filters_by_port() {
        let listeners = vec![
            listener("udp", "[::]:53", 2),
            listener("tcp", "0.0.0.0:22", 1),
            listener("tcp", "0.0.0.0:22", 1),
        ];
        let owners = HashMap::from([(1, (812, "sshd".to_owned()))]);

        assert_eq!(
            answer(listeners.clone(), &owners, None),
            json!({
                "sockets": [
                    {"protocol": "tcp", "address": "0.0.0.0", "port": 22, "process": "sshd", "pid": 812},
                    {"protocol": "udp", "address": "::", "port": 53, "process": null, "pid": null}
                ],
                "truncated": false
            })
        );
        super::super::contract::assert_conforms(
            "query.listening_sockets@1",
            "result",
            &answer(listeners.clone(), &owners, None),
        );
        assert_eq!(
            answer(listeners, &owners, Some(53))["sockets"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn refuses_unknown_parameters() {
        assert!(ListeningSockets
            .answer(&json!({"pid": 1}), &Cancellation::default())
            .is_err());
        assert!(ListeningSockets
            .answer(&json!({"port": 0}), &Cancellation::default())
            .is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn reads_this_host() {
        let value = ListeningSockets
            .answer(&Value::Null, &Cancellation::default())
            .unwrap();
        super::super::contract::assert_conforms("query.listening_sockets@1", "result", &value);
    }
}
