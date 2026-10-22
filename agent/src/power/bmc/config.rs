//! `[[collectors.bmc]]` configuration (RFD 10, "Collectors and BMCs").
//!
//! The password stays in a file on the collector host. The configuration names the file and the
//! module reads it before each poll, so rotating it needs no restart. A BMC's certificate is
//! trusted through the module's `ca_file`, or through a pin of the target's own certificate,
//! since most BMCs serve one their vendor signed for no name the operator uses. Without either,
//! the public web roots apply.

use crate::{
    power::pdu::POWER_INTERVALS,
    snmp::config::{self as snmp_config, Target, COLLECTOR_ID_MAX},
};
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    time::Duration,
};

const HTTPS_PORT: u16 = 443;
/// A BMC can take seconds to answer while it is busy, so the default is generous.
const TIMEOUT_DEFAULT: u64 = 10;
const TIMEOUT_MAX: u64 = 60;
const CONCURRENCY_DEFAULT: usize = 4;
const CONCURRENCY_MAX: usize = 32;

/// One BMC module instance. Its `id` is the collector stream identity Renga keeps for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BmcCollector {
    pub id: String,
    pub targets: Vec<BmcTarget>,
    pub username: String,
    pub password_file: PathBuf,
    /// PEM certificates that sign the BMCs' certificates, read before each poll.
    pub ca_file: Option<PathBuf>,
    pub interval: Duration,
    pub timeout: Duration,
    pub max_concurrent_targets: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BmcTarget {
    pub target: Target,
    /// The SHA-256 digest of the certificate this BMC must present, if pinned.
    pub pin: Option<[u8; 32]>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RawBmcCollector {
    id: Option<String>,
    targets: Option<Vec<String>>,
    username: Option<String>,
    password_file: Option<PathBuf>,
    ca_file: Option<PathBuf>,
    /// Certificate fingerprints by target, exactly as the target is listed.
    pins: Option<BTreeMap<String, String>>,
    interval_seconds: Option<u64>,
    timeout_seconds: Option<u64>,
    max_concurrent_targets: Option<usize>,
}

/// Validates every `[[collectors.bmc]]` table. Errors name the module by its position.
pub(crate) fn from_raw(raw: Vec<RawBmcCollector>) -> Result<Vec<BmcCollector>, String> {
    let mut ids = BTreeSet::new();
    raw.into_iter()
        .enumerate()
        .map(|(index, raw)| {
            let name = format!("collectors.bmc[{index}]");
            let collector = collector(raw).map_err(|error| format!("{name}: {error}"))?;
            if !ids.insert(collector.id.clone()) {
                return Err(format!("{name}: id {:?} is used twice", collector.id));
            }
            Ok(collector)
        })
        .collect()
}

fn collector(raw: RawBmcCollector) -> Result<BmcCollector, String> {
    let id = raw.id.ok_or("id is required")?;
    if !snmp_config::valid_collector_id(&id) {
        return Err(format!(
            "id must be 1-{COLLECTOR_ID_MAX} letters, digits, '.', '_', or '-', starting and ending with a letter or digit"
        ));
    }
    let targets = snmp_config::targets(raw.targets.unwrap_or_default(), HTTPS_PORT)?;
    let mut pins = raw.pins.unwrap_or_default();
    let targets = targets
        .into_iter()
        .map(|target| {
            let pin = pins
                .remove(&target.address)
                .map(|pin| {
                    fingerprint(&pin).ok_or_else(|| {
                        format!(
                            "the pin for {:?} must be a SHA-256 fingerprint in hex",
                            target.address
                        )
                    })
                })
                .transpose()?;
            Ok(BmcTarget { target, pin })
        })
        .collect::<Result<Vec<_>, String>>()?;
    if let Some(address) = pins.keys().next() {
        return Err(format!("pins names {address:?}, which is not a target"));
    }
    let username = raw
        .username
        .filter(|value| !value.trim().is_empty())
        .ok_or("username is required")?;
    let password_file = raw.password_file.ok_or("password_file is required")?;
    let interval = raw.interval_seconds.unwrap_or(POWER_INTERVALS.default);
    if interval < POWER_INTERVALS.min {
        return Err(format!(
            "interval_seconds must be at least {}",
            POWER_INTERVALS.min
        ));
    }
    let timeout = raw.timeout_seconds.unwrap_or(TIMEOUT_DEFAULT);
    if !(1..=TIMEOUT_MAX).contains(&timeout) {
        return Err(format!(
            "timeout_seconds must be between 1 and {TIMEOUT_MAX}"
        ));
    }
    let max_concurrent_targets = raw.max_concurrent_targets.unwrap_or(CONCURRENCY_DEFAULT);
    if !(1..=CONCURRENCY_MAX).contains(&max_concurrent_targets) {
        return Err(format!(
            "max_concurrent_targets must be between 1 and {CONCURRENCY_MAX}"
        ));
    }
    Ok(BmcCollector {
        id,
        targets,
        username,
        password_file,
        ca_file: raw.ca_file,
        interval: Duration::from_secs(interval),
        timeout: Duration::from_secs(timeout),
        max_concurrent_targets,
    })
}

/// A SHA-256 fingerprint as `openssl x509 -fingerprint -sha256` prints it, with or without the
/// colons and the `sha256` prefix.
fn fingerprint(pin: &str) -> Option<[u8; 32]> {
    let pin = pin.trim();
    let pin = pin
        .split_once('=')
        .filter(|(prefix, _)| prefix.trim().eq_ignore_ascii_case("sha256 fingerprint"))
        .map_or(pin, |(_, rest)| rest.trim());
    let pin = pin
        .get(..7)
        .filter(|prefix| prefix.eq_ignore_ascii_case("sha256:"))
        .map_or(pin, |_| &pin[7..]);
    let hex: Vec<u8> = pin.bytes().filter(|byte| *byte != b':').collect();
    if hex.len() != 64 {
        return None;
    }
    let mut digest = [0; 32];
    for (byte, pair) in digest.iter_mut().zip(hex.chunks(2)) {
        *byte = u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()?;
    }
    Some(digest)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(toml: &str) -> Result<Vec<BmcCollector>, String> {
        #[derive(Deserialize)]
        struct Wrapper {
            bmc: Vec<RawBmcCollector>,
        }
        let wrapper: Wrapper = toml::from_str(toml).map_err(|error| error.to_string())?;
        from_raw(wrapper.bmc)
    }

    const PIN: &str = "3F:2A:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD";

    #[test]
    fn reads_a_module_with_pinned_targets() {
        let collectors = parse(&format!(
            "[[bmc]]\nid='rack-bmcs'\ntargets=['10.0.1.5', 'bmc-r1-07.example.net:8443']\n\
             username='renga'\npassword_file='/etc/renga/bmc-password'\n\
             [bmc.pins]\n'10.0.1.5'='{PIN}'\n"
        ))
        .unwrap();
        let [collector] = collectors.as_slice() else {
            panic!("expected one module");
        };
        assert_eq!(collector.targets[0].target.port, 443);
        assert_eq!(collector.targets[1].target.port, 8443);
        assert_eq!(collector.targets[0].pin.unwrap()[..2], [0x3f, 0x2a]);
        assert_eq!(collector.targets[1].pin, None);
        assert_eq!(collector.interval, Duration::from_secs(60));
        assert_eq!(collector.timeout, Duration::from_secs(10));
        assert_eq!(collector.ca_file, None);
    }

    #[test]
    fn accepts_fingerprints_as_openssl_prints_them() {
        let bare = PIN.replace(':', "").to_ascii_lowercase();
        let expected = fingerprint(PIN).unwrap();
        for pin in [
            bare.clone(),
            format!("sha256:{bare}"),
            format!("sha256 Fingerprint={PIN}"),
        ] {
            assert_eq!(fingerprint(&pin), Some(expected), "{pin}");
        }
        assert_eq!(fingerprint(&bare[2..]), None);
        assert_eq!(fingerprint(&bare.replace('3', "g")), None);
    }

    #[test]
    fn rejects_incomplete_or_ambiguous_modules() {
        let module = "[[bmc]]\nid='rack-bmcs'\ntargets=['10.0.1.5']\nusername='renga'\n\
                      password_file='/etc/renga/bmc-password'\n";
        for (extra, error) in [
            (
                "interval_seconds=10\n",
                "interval_seconds must be at least 30",
            ),
            ("[bmc.pins]\n'10.0.1.5'='00'\n", "the pin for"),
            (
                &format!("[bmc.pins]\n'10.0.1.6'='{PIN}'\n"),
                "pins names \"10.0.1.6\", which is not a target",
            ),
            ("password='x'\n", "unknown field"),
        ] {
            let message = parse(&format!("{module}{extra}")).unwrap_err();
            assert!(message.contains(error), "{extra}: {message}");
        }
        let message = parse(&module.replace("username='renga'\n", "")).unwrap_err();
        assert!(
            message.contains("collectors.bmc[0]: username is required"),
            "{message}"
        );
        let message = parse(&format!("{module}{module}")).unwrap_err();
        assert!(message.contains("is used twice"), "{message}");
    }
}
