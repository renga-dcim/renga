//! `[[collectors.gnmi]]` configuration (RFD 11, "Deployment").
//!
//! As with SNMP, secrets stay in files on the collector host and are read before each poll.
//! gNMI runs over TLS; plaintext is refused unless `allow_plaintext = true` says the target is
//! lab gear, the same way SNMPv2c needs `allow_v2c`.

use crate::snmp::config::{targets, valid_collector_id, Target, COLLECTOR_ID_MAX};
use serde::Deserialize;
use std::{collections::BTreeSet, fmt, path::PathBuf, time::Duration};

/// The port IANA assigned to gNMI.
pub const GNMI_PORT: u16 = 9339;
const INTERVAL_DEFAULT: u64 = 900;
const INTERVAL_MIN: u64 = 60;
const TIMEOUT_DEFAULT: u64 = 10;
const TIMEOUT_MAX: u64 = 120;
const CONCURRENCY_DEFAULT: usize = 4;
const CONCURRENCY_MAX: usize = 32;

/// One gNMI poller module instance. Its `id` is the collector stream identity Renga keeps for
/// it, exactly like an SNMP module's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GnmiCollector {
    pub id: String,
    pub targets: Vec<Target>,
    pub credentials: Option<Credentials>,
    pub transport: Transport,
    pub interval: Duration,
    pub timeout: Duration,
    pub max_concurrent_targets: usize,
}

/// Username and password sent as gRPC metadata on every call, as gNMI specifies.
#[derive(Clone, PartialEq, Eq)]
pub struct Credentials {
    pub username: String,
    pub password_file: PathBuf,
}

impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credentials")
            .field("username", &self.username)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Transport {
    /// TLS, verified against `ca_file` or else the public web roots. `server_name` replaces the
    /// target's host for verification, for targets configured by address.
    Tls {
        ca_file: Option<PathBuf>,
        client_identity: Option<ClientIdentity>,
        server_name: Option<String>,
    },
    /// Plaintext HTTP/2, only with an explicit `allow_plaintext = true`.
    Plaintext,
}

/// A client certificate for targets that authenticate the poller with mutual TLS.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientIdentity {
    pub cert_file: PathBuf,
    pub key_file: PathBuf,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RawGnmiCollector {
    id: Option<String>,
    targets: Option<Vec<String>>,
    username: Option<String>,
    password_file: Option<PathBuf>,
    tls_ca_file: Option<PathBuf>,
    tls_client_cert_file: Option<PathBuf>,
    tls_client_key_file: Option<PathBuf>,
    tls_server_name: Option<String>,
    allow_plaintext: Option<bool>,
    interval_seconds: Option<u64>,
    timeout_seconds: Option<u64>,
    max_concurrent_targets: Option<usize>,
}

/// Validates every `[[collectors.gnmi]]` table. Errors name the module by its position.
pub(crate) fn from_raw(raw: Vec<RawGnmiCollector>) -> Result<Vec<GnmiCollector>, String> {
    let mut ids = BTreeSet::new();
    raw.into_iter()
        .enumerate()
        .map(|(index, raw)| {
            let name = format!("collectors.gnmi[{index}]");
            let collector = collector(raw).map_err(|error| format!("{name}: {error}"))?;
            if !ids.insert(collector.id.clone()) {
                return Err(format!("{name}: id {:?} is used twice", collector.id));
            }
            Ok(collector)
        })
        .collect()
}

fn collector(raw: RawGnmiCollector) -> Result<GnmiCollector, String> {
    let id = raw.id.ok_or("id is required")?;
    if !valid_collector_id(&id) {
        return Err(format!(
            "id must be 1-{COLLECTOR_ID_MAX} letters, digits, '.', '_', or '-', starting and ending with a letter or digit"
        ));
    }
    let targets = targets(raw.targets.unwrap_or_default(), GNMI_PORT)?;
    let credentials = match (raw.username, raw.password_file) {
        (Some(username), Some(password_file)) if !username.trim().is_empty() => Some(Credentials {
            username,
            password_file,
        }),
        (None, None) => None,
        _ => return Err("username and password_file must be set together".into()),
    };
    let transport = if raw.allow_plaintext == Some(true) {
        if raw.tls_ca_file.is_some()
            || raw.tls_client_cert_file.is_some()
            || raw.tls_client_key_file.is_some()
            || raw.tls_server_name.is_some()
        {
            return Err("TLS settings are not used with allow_plaintext = true".into());
        }
        Transport::Plaintext
    } else {
        let client_identity = match (raw.tls_client_cert_file, raw.tls_client_key_file) {
            (Some(cert_file), Some(key_file)) => Some(ClientIdentity {
                cert_file,
                key_file,
            }),
            (None, None) => None,
            _ => {
                return Err(
                    "tls_client_cert_file and tls_client_key_file must be set together".into(),
                )
            }
        };
        let server_name = raw
            .tls_server_name
            .map(|name| {
                rustls::pki_types::ServerName::try_from(name.as_str())
                    .map(|_| name.clone())
                    .map_err(|_| format!("tls_server_name {name:?} is not a host name or address"))
            })
            .transpose()?;
        Transport::Tls {
            ca_file: raw.tls_ca_file,
            client_identity,
            server_name,
        }
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
    Ok(GnmiCollector {
        id,
        targets,
        credentials,
        transport,
        interval: Duration::from_secs(interval),
        timeout: Duration::from_secs(timeout),
        max_concurrent_targets,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(toml: &str) -> Result<Vec<GnmiCollector>, String> {
        #[derive(Deserialize)]
        struct Wrapper {
            gnmi: Vec<RawGnmiCollector>,
        }
        let wrapper: Wrapper = toml::from_str(toml).map_err(|error| error.to_string())?;
        from_raw(wrapper.gnmi)
    }

    const TLS: &str = r#"
        [[gnmi]]
        id = "spines"
        targets = ["10.0.0.1", "spine2.example:6030", "[2001:db8::1]:57400"]
        username = "renga"
        password_file = "/etc/renga/gnmi-password"
        tls_ca_file = "/etc/renga/gnmi-ca.pem"
    "#;

    #[test]
    fn defaults_to_verified_tls_on_the_gnmi_port() {
        let [collector] = <[_; 1]>::try_from(parse(TLS).unwrap()).unwrap();

        assert_eq!(collector.id, "spines");
        assert_eq!(collector.interval, Duration::from_secs(900));
        assert_eq!(collector.timeout, Duration::from_secs(10));
        assert_eq!(collector.max_concurrent_targets, 4);
        assert_eq!(
            collector.transport,
            Transport::Tls {
                ca_file: Some("/etc/renga/gnmi-ca.pem".into()),
                client_identity: None,
                server_name: None,
            }
        );
        let targets: Vec<_> = collector
            .targets
            .iter()
            .map(|target| (target.host.as_str(), target.port))
            .collect();
        assert_eq!(
            targets,
            [
                ("10.0.0.1", 9339),
                ("spine2.example", 6030),
                ("2001:db8::1", 57400)
            ]
        );
        assert!(!format!("{:?}", collector.credentials).contains("gnmi-password"));
    }

    #[test]
    fn accepts_mutual_tls_without_a_password() {
        let toml = r#"
            [[gnmi]]
            id = "leaves"
            targets = ["10.0.1.1"]
            tls_client_cert_file = "/etc/renga/gnmi.crt"
            tls_client_key_file = "/etc/renga/gnmi.key"
            tls_server_name = "leaf1.example"
        "#;
        let collector = &parse(toml).unwrap()[0];

        assert_eq!(collector.credentials, None);
        assert!(matches!(
            &collector.transport,
            Transport::Tls {
                client_identity: Some(_),
                server_name: Some(name),
                ..
            } if name == "leaf1.example"
        ));
    }

    #[test]
    fn allows_plaintext_only_when_explicitly_enabled() {
        let plaintext = r#"
            [[gnmi]]
            id = "lab"
            targets = ["10.0.0.1:6030"]
            allow_plaintext = true
        "#;
        assert_eq!(parse(plaintext).unwrap()[0].transport, Transport::Plaintext);

        let mixed = plaintext.replace(
            "allow_plaintext = true",
            "allow_plaintext = true\ntls_ca_file = '/ca.pem'",
        );
        assert!(parse(&mixed).unwrap_err().contains("not used with"));
    }

    #[test]
    fn rejects_incomplete_or_ambiguous_modules() {
        for (needle, replacement, message) in [
            ("id = \"spines\"", "", "id is required"),
            ("id = \"spines\"", "id = \"bad-\"", "id must be"),
            (
                "password_file = \"/etc/renga/gnmi-password\"",
                "",
                "must be set together",
            ),
            (
                "tls_ca_file = \"/etc/renga/gnmi-ca.pem\"",
                "tls_client_cert_file = '/c.pem'",
                "must be set together",
            ),
            (
                "tls_ca_file = \"/etc/renga/gnmi-ca.pem\"",
                "tls_server_name = 'not a name'",
                "tls_server_name",
            ),
            (
                "targets = [\"10.0.0.1\", \"spine2.example:6030\", \"[2001:db8::1]:57400\"]",
                "targets = [\"10.0.0.1\", \"10.0.0.1:9339\"]",
                "listed twice",
            ),
            (
                "username = \"renga\"",
                "username = \"renga\"\ntimeout_seconds = 0",
                "timeout_seconds",
            ),
            (
                "username = \"renga\"",
                "username = \"renga\"\ncommunity_file = '/c'",
                "unknown field",
            ),
        ] {
            let error = parse(&TLS.replace(needle, replacement)).unwrap_err();
            assert!(error.contains(message), "{error}");
        }

        let twice = format!("{TLS}\n{TLS}");
        assert!(parse(&twice).unwrap_err().contains("used twice"));
    }
}
