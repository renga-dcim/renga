//! `query.time_sync@1`: whether the clock is synchronized, its offset and
//! error, and the source the time daemon follows. Inventory sensitivity.
//! Matches `Renga.Jobs.Queries.TimeSync`.
//!
//! The kernel's view comes from `adjtimex(2)`, which every Linux host has.
//! The source comes from chrony (`chronyc -c tracking`) or, failing that,
//! systemd-timesyncd over D-Bus, both with fixed arguments.
//!
//! The shipped unit sets `ProtectClock=true`, whose seccomp filter refuses
//! `adjtimex` even when it only reads. Without the kernel's view, whether the
//! clock is synchronized comes from the daemon (chrony's leap status, or
//! timedated's `NTPSynchronized`) and the error estimates are null. With no
//! answer from either, the query fails rather than guess.

use super::{clip, failed, parameters, Query, Sensitivity};
use crate::{cancellation::Cancellation, command, jobs::JobFailure};
use serde::Deserialize;
use serde_json::Value;
use std::{process::Command, time::Duration};

const PROGRAM_TIMEOUT: Duration = Duration::from_secs(5);
const NTP_SYNCHRONIZED: &[&str] = &[
    "--system",
    "--json=short",
    "get-property",
    "org.freedesktop.timedate1",
    "/org/freedesktop/timedate1",
    "org.freedesktop.timedate1",
    "NTPSynchronized",
];
const TIMESYNCD_SERVER: &[&str] = &[
    "--system",
    "--json=short",
    "get-property",
    "org.freedesktop.timesync1",
    "/org/freedesktop/timesync1",
    "org.freedesktop.timesync1.Manager",
    "ServerName",
];

pub struct TimeSync;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {}

/// The kernel clock discipline's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Kernel {
    pub synchronized: bool,
    pub offset_us: i64,
    pub max_error_us: i64,
    pub estimated_error_us: i64,
}

/// What a time daemon says it follows.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Daemon {
    pub name: Option<&'static str>,
    pub source: Option<String>,
    pub stratum: Option<u8>,
    /// chrony's own offset estimate, which is finer than the kernel's.
    pub offset_us: Option<i64>,
    /// Whether the daemon considers the clock synchronized.
    pub synchronized: Option<bool>,
}

impl Query for TimeSync {
    fn name(&self) -> &'static str {
        "query.time_sync"
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Inventory
    }

    fn answer(&self, raw: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        let Parameters {} = parameters(raw)?;
        let kernel = read_kernel();
        let daemon = chrony(cancellation)
            .or_else(|| timesyncd(cancellation))
            .unwrap_or_default();
        if cancellation.cancelled() {
            return Err(JobFailure::Cancelled);
        }
        answer(kernel, daemon)
    }
}

fn answer(kernel: Option<Kernel>, daemon: Daemon) -> Result<Value, JobFailure> {
    let synchronized = kernel
        .map(|kernel| kernel.synchronized)
        .or(daemon.synchronized)
        .ok_or_else(|| {
            failed(
                "could not read the clock state: adjtimex was refused and no time daemon answered",
            )
        })?;
    Ok(serde_json::json!({
        "synchronized": synchronized,
        "daemon": daemon.name,
        "source": daemon.source.map(|s| clip(&s, 256)),
        "stratum": daemon.stratum.filter(|s| *s <= 16),
        "offset_us": daemon.offset_us.or(kernel.map(|kernel| kernel.offset_us)),
        "max_error_us": kernel.map(|kernel| kernel.max_error_us.max(0)),
        "estimated_error_us": kernel.map(|kernel| kernel.estimated_error_us.max(0)),
    }))
}

/// The kernel's clock state, or `None` when `adjtimex` is refused, as
/// `ProtectClock=true` does.
#[cfg(target_os = "linux")]
fn read_kernel() -> Option<Kernel> {
    // SAFETY: modes = 0 only reads the clock state into `timex`.
    let mut timex: libc::timex = unsafe { std::mem::zeroed() };
    let state = unsafe { libc::adjtimex(&mut timex) };
    if state == -1 {
        return None;
    }
    // STA_NANO means `offset` is in nanoseconds rather than microseconds.
    let offset_us = if timex.status & libc::STA_NANO != 0 {
        timex.offset as i64 / 1000
    } else {
        timex.offset as i64
    };
    Some(Kernel {
        synchronized: state != libc::TIME_ERROR && timex.status & libc::STA_UNSYNC == 0,
        offset_us,
        max_error_us: timex.maxerror as i64,
        estimated_error_us: timex.esterror as i64,
    })
}

#[cfg(not(target_os = "linux"))]
fn read_kernel() -> Option<Kernel> {
    None
}

fn chrony(cancellation: &Cancellation) -> Option<Daemon> {
    let output = command::run_with_timeout(
        Command::new("chronyc").args(["-c", "-n", "tracking"]),
        cancellation,
        PROGRAM_TIMEOUT,
    )
    .ok()
    .filter(|output| output.status.success())?;
    parse_chrony_tracking(&String::from_utf8_lossy(&output.stdout))
}

/// Parses `chronyc -c tracking`: reference ID, reference name or address,
/// stratum, reference time, system time offset (seconds; positive means
/// the clock is slow), eight more figures, and the leap status, which is
/// `Not synchronised` until chrony has a source.
pub fn parse_chrony_tracking(output: &str) -> Option<Daemon> {
    let fields: Vec<&str> = output.trim().split(',').collect();
    if fields.len() < 5 {
        return None;
    }
    let synchronized = fields
        .get(13)
        .map(|leap| !leap.eq_ignore_ascii_case("not synchronised"));
    let seconds: f64 = fields[4].parse().ok()?;
    let source = Some(fields[1]).filter(|s| !s.is_empty()).map(str::to_owned);
    Some(Daemon {
        name: Some("chronyd"),
        source,
        stratum: fields[2].parse().ok(),
        // chrony reports how far the clock is behind; offset is the clock's
        // own error, so the sign flips.
        offset_us: Some((-seconds * 1_000_000.0).round() as i64),
        synchronized,
    })
}

fn timesyncd(cancellation: &Cancellation) -> Option<Daemon> {
    let output = command::run_with_timeout(
        Command::new("busctl").args(TIMESYNCD_SERVER),
        cancellation,
        PROGRAM_TIMEOUT,
    )
    .ok()
    .filter(|output| output.status.success())?;
    let value: Value = serde_json::from_slice(&output.stdout).ok()?;
    // timedated reads the kernel's state itself, outside this sandbox.
    let synchronized = command::run_with_timeout(
        Command::new("busctl").args(NTP_SYNCHRONIZED),
        cancellation,
        PROGRAM_TIMEOUT,
    )
    .ok()
    .filter(|output| output.status.success())
    .and_then(|output| serde_json::from_slice::<Value>(&output.stdout).ok())
    .and_then(|value| value["data"].as_bool());
    Some(Daemon {
        name: Some("systemd-timesyncd"),
        source: value["data"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_owned),
        synchronized,
        ..Daemon::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_chrony_tracking() {
        let line = "A9FEA97B,169.254.169.123,4,1729600000.123456789,-0.000012345,0.000001,0.000002,-12.345,0.001,0.002,0.0003,0.0004,64.5,Normal\n";
        assert_eq!(
            parse_chrony_tracking(line),
            Some(Daemon {
                name: Some("chronyd"),
                source: Some("169.254.169.123".into()),
                stratum: Some(4),
                offset_us: Some(12),
                synchronized: Some(true),
            })
        );
        let unsynchronized =
            "7F7F0101,,10,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,Not synchronised\n";
        assert_eq!(
            parse_chrony_tracking(unsynchronized).unwrap().synchronized,
            Some(false)
        );
        assert_eq!(parse_chrony_tracking("506 Cannot talk to daemon"), None);
    }

    #[test]
    fn prefers_the_daemon_offset_and_keeps_the_kernel_view() {
        let kernel = Kernel {
            synchronized: true,
            offset_us: 5,
            max_error_us: 1200,
            estimated_error_us: 300,
        };
        assert_eq!(
            answer(Some(kernel), Daemon::default()).unwrap(),
            json!({"synchronized": true, "daemon": null, "source": null, "stratum": null,
                   "offset_us": 5, "max_error_us": 1200, "estimated_error_us": 300})
        );
        let chrony = parse_chrony_tracking("0,time.example.net,2,0,0.000042,0").unwrap();
        let value = answer(Some(kernel), chrony).unwrap();
        assert_eq!(value["offset_us"], json!(-42));
        super::super::contract::assert_conforms("query.time_sync@1", "result", &value);
    }

    #[test]
    fn answers_from_the_daemon_when_adjtimex_is_refused() {
        // ProtectClock=true refuses adjtimex; the kernel's view is then absent.
        let line = "0,time.example.net,2,0,0.000042,0,0,0,0,0,0,0,0,Not synchronised";
        let value = answer(None, parse_chrony_tracking(line).unwrap()).unwrap();
        assert_eq!(
            value,
            json!({"synchronized": false, "daemon": "chronyd", "source": "time.example.net",
                   "stratum": 2, "offset_us": -42, "max_error_us": null,
                   "estimated_error_us": null})
        );
        super::super::contract::assert_conforms("query.time_sync@1", "result", &value);

        let timesyncd = Daemon {
            name: Some("systemd-timesyncd"),
            synchronized: Some(true),
            ..Daemon::default()
        };
        assert_eq!(
            answer(None, timesyncd).unwrap()["synchronized"],
            json!(true)
        );

        // Unknown is not "not synchronized".
        assert!(answer(None, Daemon::default()).is_err());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn reads_this_host() {
        let value = TimeSync
            .answer(&Value::Null, &Cancellation::default())
            .unwrap();
        super::super::contract::assert_conforms("query.time_sync@1", "result", &value);
    }
}
