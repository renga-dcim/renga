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
        assert_eq!(collector.interval, Duration::from_secs(300));
        assert_eq!(parse("").unwrap(), None);
    }

    #[test]
    fn rejects_invalid_settings() {
        for (toml, message) in [
            ("[libvirt]\nid='-x'\n", "id must be"),
            ("[libvirt]\nuri=''\n", "uri must be"),
            ("[libvirt]\nuri='--connect'\n", "must not start with '-'"),
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
