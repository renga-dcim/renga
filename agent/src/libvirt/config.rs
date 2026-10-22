//! `[collectors.libvirt]` configuration (RFD 11, "Deployment").

use crate::snmp::config::{valid_collector_id, COLLECTOR_ID_MAX};
use serde::Deserialize;
use std::time::Duration;

const ID_DEFAULT: &str = "libvirt";
const URI_DEFAULT: &str = "qemu:///system";
const INTERVAL_DEFAULT: u64 = 300;
const INTERVAL_MIN: u64 = 60;
const TIMEOUT_DEFAULT: u64 = 10;
const TIMEOUT_MAX: u64 = 60;
// Must match `Renga.Inventory.AgentPayload`.
const URI_MAX: usize = 255;

/// The libvirt module. Its `id` is the collector stream identity, and its URI names the
/// hypervisor the reports are authoritative for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibvirtCollector {
    pub id: String,
    pub uri: String,
    pub interval: Duration,
    /// Limit for each `virsh` call.
    pub timeout: Duration,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RawLibvirtCollector {
    id: Option<String>,
    uri: Option<String>,
    interval_seconds: Option<u64>,
    timeout_seconds: Option<u64>,
}

/// Validates `[collectors.libvirt]`.
pub(crate) fn from_raw(
    raw: Option<RawLibvirtCollector>,
) -> Result<Option<LibvirtCollector>, String> {
    raw.map(collector)
        .transpose()
        .map_err(|error| format!("collectors.libvirt: {error}"))
}

fn collector(raw: RawLibvirtCollector) -> Result<LibvirtCollector, String> {
    let id = raw.id.unwrap_or_else(|| ID_DEFAULT.into());
    if !valid_collector_id(&id) {
        return Err(format!(
            "id must be 1-{COLLECTOR_ID_MAX} letters, digits, '.', '_', or '-', starting and ending with a letter or digit"
        ));
    }
    let uri = raw.uri.unwrap_or_else(|| URI_DEFAULT.into());
    if uri.trim().is_empty() || uri.trim() != uri || uri.len() > URI_MAX {
        return Err(format!(
            "uri must be 1-{URI_MAX} characters without surrounding whitespace"
        ));
    }
    if uri.starts_with('-') {
        return Err("uri must not start with '-'".into());
    }
    if carries_secret(&uri) {
        return Err(
            "uri must not carry a password or secret; keep credentials in libvirt's own \
             authentication files"
                .into(),
        );
    }
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
    Ok(LibvirtCollector {
        id,
        uri,
        interval: Duration::from_secs(interval),
        timeout: Duration::from_secs(timeout),
    })
}

/// The URI names the hypervisor in every report and log line, so it must hold no secret: no
/// password in its user part and no query parameter named like one. libvirt reads credentials
/// from its auth configuration, SSH keys, and certificate paths instead.
fn carries_secret(uri: &str) -> bool {
    let (before_query, query) = uri.split_once('?').unwrap_or((uri, ""));
    let authority = before_query
        .split_once("://")
        .map_or("", |(_, rest)| rest.split('/').next().unwrap_or(""));
    let password = authority
        .rsplit_once('@')
        .is_some_and(|(userinfo, _)| userinfo.contains(':'));
    let secret_parameter = query.split('&').any(|parameter| {
        let name = parameter
            .split('=')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        ["pass", "secret", "token"]
            .iter()
            .any(|word| name.contains(word))
    });
    password || secret_parameter
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(toml: &str) -> Result<Option<LibvirtCollector>, String> {
        #[derive(Deserialize)]
        struct Wrapper {
            libvirt: Option<RawLibvirtCollector>,
        }
        let wrapper: Wrapper = toml::from_str(toml).map_err(|error| error.to_string())?;
        from_raw(wrapper.libvirt)
    }

    #[test]
    fn defaults_to_the_local_system_hypervisor_every_five_minutes() {
        let collector = parse("[libvirt]\n").unwrap().unwrap();
        assert_eq!(collector.id, "libvirt");
        assert_eq!(collector.uri, "qemu:///system");
        assert!(!carries_secret(
            "qemu+ssh://renga@hv1.example:2222/system?keyfile=/etc/renga/id_ed25519"
        ));
        assert_eq!(collector.interval, Duration::from_secs(300));
        assert_eq!(parse("").unwrap(), None);
    }

    #[test]
    fn rejects_invalid_settings() {
        for (toml, message) in [
            ("[libvirt]\nid='-x'\n", "id must be"),
            ("[libvirt]\nuri=''\n", "uri must be"),
            ("[libvirt]\nuri='--connect'\n", "must not start with '-'"),
            (
                "[libvirt]\nuri='qemu+ssh://renga:hunter2@hv1/system'\n",
                "must not carry a password",
            ),
            (
                "[libvirt]\nuri='qemu+tcp://hv1/system?auth_token=x'\n",
                "must not carry a password",
            ),
            ("[libvirt]\ninterval_seconds=10\n", "at least 60"),
            ("[libvirt]\ntimeout_seconds=0\n", "between 1 and 60"),
        ] {
            let error = parse(toml).unwrap_err();
            assert!(error.contains(message), "{toml}: {error}");
            assert!(error.starts_with("collectors.libvirt: "), "{error}");
        }
        assert!(parse("[libvirt]\npassword='x'\n").is_err());
    }
}
