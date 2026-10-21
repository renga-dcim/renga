//! `[[collectors.snmp]]` configuration (RFD 11, "Deployment").
//!
//! Credentials stay in files on the collector host. The configuration names the files; the
//! poller reads them before each poll, so rotating a password needs no restart and the secret
//! never sits in the parsed configuration.

use serde::Deserialize;
use std::{collections::BTreeSet, fmt, path::PathBuf, time::Duration};

const INTERVAL_DEFAULT: u64 = 900;
const INTERVAL_MIN: u64 = 60;
const TIMEOUT_DEFAULT: u64 = 5;
const TIMEOUT_MAX: u64 = 60;
const CONCURRENCY_DEFAULT: usize = 4;
const CONCURRENCY_MAX: usize = 32;
// Must match `Renga.Inventory.AgentPayload`.
const COLLECTOR_ID_MAX: usize = 64;
const TARGETS_MAX: usize = 1_000;

/// One SNMP poller module instance. Its `id` is the collector stream identity Renga keeps for
/// it, so changing the targets or credentials keeps the same stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnmpCollector {
    pub id: String,
    pub targets: Vec<Target>,
    pub credentials: Credentials,
    pub interval: Duration,
    pub timeout: Duration,
    pub max_concurrent_targets: usize,
}

/// A device address and UDP port, as configured.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Target {
    /// Exactly as configured, so reports name targets the way the operator does.
    pub address: String,
    pub host: String,
    pub port: u16,
}

#[derive(Clone, PartialEq, Eq)]
pub enum Credentials {
    /// SNMPv3 with authentication and privacy, the only v3 level the poller uses.
    V3 {
        username: String,
        auth_protocol: AuthProtocol,
        auth_password_file: PathBuf,
        privacy_protocol: PrivacyProtocol,
        privacy_password_file: PathBuf,
    },
    /// SNMPv2c, only with an explicit `allow_v2c = true`.
    V2c { community_file: PathBuf },
}

impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::V3 {
                username,
                auth_protocol,
                privacy_protocol,
                ..
            } => f
                .debug_struct("V3")
                .field("username", username)
                .field("auth_protocol", auth_protocol)
                .field("privacy_protocol", privacy_protocol)
                .finish_non_exhaustive(),
            Self::V2c { .. } => f.debug_struct("V2c").finish_non_exhaustive(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthProtocol {
    Md5,
    Sha,
    Sha224,
    Sha256,
    Sha384,
    Sha512,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PrivacyProtocol {
    Des,
    Aes128,
    Aes192,
    Aes256,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RawSnmpCollector {
    id: Option<String>,
    targets: Option<Vec<String>>,
    version: Option<String>,
    allow_v2c: Option<bool>,
    username: Option<String>,
    auth_protocol: Option<AuthProtocol>,
    auth_password_file: Option<PathBuf>,
    privacy_protocol: Option<PrivacyProtocol>,
    privacy_password_file: Option<PathBuf>,
    community_file: Option<PathBuf>,
    interval_seconds: Option<u64>,
    timeout_seconds: Option<u64>,
    max_concurrent_targets: Option<usize>,
}

/// Validates every `[[collectors.snmp]]` table. Errors name the module by its position.
pub(crate) fn from_raw(raw: Vec<RawSnmpCollector>) -> Result<Vec<SnmpCollector>, String> {
    let mut ids = BTreeSet::new();
    raw.into_iter()
        .enumerate()
        .map(|(index, raw)| {
            let name = format!("collectors.snmp[{index}]");
            let collector = collector(raw).map_err(|error| format!("{name}: {error}"))?;
            if !ids.insert(collector.id.clone()) {
                return Err(format!("{name}: id {:?} is used twice", collector.id));
            }
            Ok(collector)
        })
        .collect()
}

fn collector(raw: RawSnmpCollector) -> Result<SnmpCollector, String> {
    let id = raw.id.ok_or("id is required")?;
    if !valid_collector_id(&id) {
        return Err(format!(
            "id must be 1-{COLLECTOR_ID_MAX} letters, digits, '.', '_', or '-', starting and ending with a letter or digit"
        ));
    }
    let targets = targets(raw.targets.unwrap_or_default())?;
    let credentials = match raw.version.as_deref().unwrap_or("3") {
        "3" => {
            if raw.community_file.is_some() {
                return Err("community_file is only for version \"2c\"".into());
            }
            Credentials::V3 {
                username: raw
                    .username
                    .filter(|value| !value.trim().is_empty())
                    .ok_or("username is required for SNMPv3")?,
                auth_protocol: raw.auth_protocol.unwrap_or(AuthProtocol::Sha256),
                auth_password_file: raw
                    .auth_password_file
                    .ok_or("auth_password_file is required for SNMPv3")?,
                privacy_protocol: raw.privacy_protocol.unwrap_or(PrivacyProtocol::Aes128),
                privacy_password_file: raw
                    .privacy_password_file
                    .ok_or("privacy_password_file is required for SNMPv3")?,
            }
        }
        "2c" => {
            if raw.allow_v2c != Some(true) {
                return Err(
                    "version \"2c\" sends the community in clear text; set allow_v2c = true to use it"
                        .into(),
                );
            }
            if raw.username.is_some()
                || raw.auth_password_file.is_some()
                || raw.privacy_password_file.is_some()
            {
                return Err("SNMPv3 credentials are not used with version \"2c\"".into());
            }
            Credentials::V2c {
                community_file: raw
                    .community_file
                    .ok_or("community_file is required for version \"2c\"")?,
            }
        }
        other => return Err(format!("version must be \"3\" or \"2c\", not {other:?}")),
    };
    let interval = raw.interval_seconds.unwrap_or(INTERVAL_DEFAULT);
    if interval < INTERVAL_MIN {
        return Err(format!("interval_seconds must be at least {INTERVAL_MIN}"));
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
    Ok(SnmpCollector {
        id,
        targets,
        credentials,
        interval: Duration::from_secs(interval),
        timeout: Duration::from_secs(timeout),
        max_concurrent_targets,
    })
}

fn targets(raw: Vec<String>) -> Result<Vec<Target>, String> {
    if raw.is_empty() {
        return Err("targets must list at least one address".into());
    }
    if raw.len() > TARGETS_MAX {
        return Err(format!("targets must have at most {TARGETS_MAX} entries"));
    }
    let mut seen = BTreeSet::new();
    raw.into_iter()
        .map(|address| {
            let target = Target::parse(&address)
                .ok_or_else(|| format!("target {address:?} must be a host or host:port"))?;
            if !seen.insert((target.host.clone(), target.port)) {
                return Err(format!("target {address:?} is listed twice"));
            }
            Ok(target)
        })
        .collect()
}

impl Target {
    /// Accepts `host`, `host:port`, an IPv6 literal, or `[ipv6]:port`. The port defaults to 161.
    pub fn parse(address: &str) -> Option<Self> {
        let trimmed = address.trim();
        if trimmed.is_empty() || trimmed != address {
            return None;
        }
        let (host, port) = if let Some(rest) = trimmed.strip_prefix('[') {
            let (host, rest) = rest.split_once(']')?;
            let port = match rest {
                "" => 161,
                _ => rest.strip_prefix(':')?.parse().ok()?,
            };
            (host, port)
        } else if trimmed.matches(':').count() > 1 {
            (trimmed, 161)
        } else if let Some((host, port)) = trimmed.split_once(':') {
            (host, port.parse().ok()?)
        } else {
            (trimmed, 161)
        };
        if host.is_empty() || port == 0 || host.chars().any(char::is_whitespace) {
            return None;
        }
        Some(Self {
            address: address.to_owned(),
            host: host.to_owned(),
            port,
        })
    }
}

fn valid_collector_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= COLLECTOR_ID_MAX
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(toml: &str) -> Result<Vec<SnmpCollector>, String> {
        #[derive(Deserialize)]
        struct Wrapper {
            snmp: Vec<RawSnmpCollector>,
        }
        let wrapper: Wrapper = toml::from_str(toml).map_err(|error| error.to_string())?;
        from_raw(wrapper.snmp)
    }

    const V3: &str = r#"
        [[snmp]]
        id = "core-switches"
        targets = ["10.0.0.1", "10.0.0.2:1161", "[2001:db8::1]:162", "2001:db8::2"]
        username = "renga"
        auth_password_file = "/etc/renga/snmp-auth"
        privacy_password_file = "/etc/renga/snmp-priv"
    "#;

    #[test]
    fn defaults_to_snmpv3_with_authentication_and_privacy() {
        let [collector] = <[_; 1]>::try_from(parse(V3).unwrap()).unwrap();

        assert_eq!(collector.id, "core-switches");
        assert_eq!(collector.interval, Duration::from_secs(900));
        assert_eq!(collector.timeout, Duration::from_secs(5));
        assert_eq!(collector.max_concurrent_targets, 4);
        assert!(matches!(
            collector.credentials,
            Credentials::V3 {
                auth_protocol: AuthProtocol::Sha256,
                privacy_protocol: PrivacyProtocol::Aes128,
                ..
            }
        ));
        let targets: Vec<_> = collector
            .targets
            .iter()
            .map(|target| (target.host.as_str(), target.port))
            .collect();
        assert_eq!(
            targets,
            [
                ("10.0.0.1", 161),
                ("10.0.0.2", 1161),
                ("2001:db8::1", 162),
                ("2001:db8::2", 161)
            ]
        );
        assert!(!format!("{:?}", collector.credentials).contains("snmp-auth"));
    }

    #[test]
    fn allows_v2c_only_when_explicitly_enabled() {
        let v2c = r#"
            [[snmp]]
            id = "lab"
            targets = ["10.0.0.1"]
            version = "2c"
            community_file = "/etc/renga/community"
        "#;
        assert!(parse(v2c).unwrap_err().contains("allow_v2c = true"));

        let allowed = v2c.replace("version = \"2c\"", "version = \"2c\"\nallow_v2c = true");
        assert!(matches!(
            parse(&allowed).unwrap()[0].credentials,
            Credentials::V2c { .. }
        ));
    }

    #[test]
    fn rejects_incomplete_or_ambiguous_modules() {
        for (needle, replacement, message) in [
            ("id = \"core-switches\"", "", "id is required"),
            ("id = \"core-switches\"", "id = \"-bad\"", "id must be"),
            (
                "username = \"renga\"",
                "",
                "username is required for SNMPv3",
            ),
            (
                "privacy_password_file = \"/etc/renga/snmp-priv\"",
                "",
                "privacy_password_file is required",
            ),
            (
                "targets = [\"10.0.0.1\", \"10.0.0.2:1161\", \"[2001:db8::1]:162\", \"2001:db8::2\"]",
                "targets = []",
                "at least one address",
            ),
            (
                "targets = [\"10.0.0.1\", \"10.0.0.2:1161\", \"[2001:db8::1]:162\", \"2001:db8::2\"]",
                "targets = [\"10.0.0.1\", \"10.0.0.1:161\"]",
                "listed twice",
            ),
            (
                "username = \"renga\"",
                "username = \"renga\"\ninterval_seconds = 10",
                "at least 60",
            ),
        ] {
            let error = parse(&V3.replace(needle, replacement)).unwrap_err();
            assert!(error.contains(message), "{error}");
        }

        let twice = format!("{V3}\n{V3}");
        assert!(parse(&twice).unwrap_err().contains("used twice"));
    }
}
