//! Configuration loading without transport-specific policy.

use crate::{
    exporters::{self, Exporter, RawExporter},
    gnmi::config::{self as gnmi_config, GnmiCollector, RawGnmiCollector},
    identity,
    jobs::{JobPolicy, Selector},
    libvirt::config::{self as libvirt_config, LibvirtCollector, RawLibvirtCollector},
    power::pdu::POWER_INTERVALS,
    snmp::config::{self as snmp_config, RawSnmpCollector, SnmpCollector},
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    env, fmt, fs,
    path::{Path, PathBuf},
    time::Duration,
};

const INVENTORY_DEFAULT: u64 = 3_600;
const CHECKIN_DEFAULT: u64 = 60;
// The server lease is 90s; reserve the fixed delivery budget below for renewal.
const CHECKIN_MAX: u64 = 60;
const REFRESH_DEFAULT: u64 = 300;
const TIMEOUT_DEFAULT: u64 = 20;
const RETRIES_DEFAULT: u32 = 5;
const TIMEOUT_MAX: u64 = 20;
const RETRIES_MAX: u32 = 5;
pub const DELIVERY_BUDGET: Duration = Duration::from_secs(25);
// Must match `Renga.Inventory.AgentPayload` so the server never rejects a
// report for labels the agent accepted.
const LABELS_MAX: usize = 32;
const LABEL_KEY_MAX: usize = 63;
const LABEL_VALUE_MAX: usize = 255;
// Must match the lease endpoint's limit on advertised capabilities.
const JOBS_ENABLED_MAX: usize = 64;

/// Validated runtime configuration. The token is intentionally redacted from Debug.
#[derive(Clone)]
pub struct Config {
    pub config_path: PathBuf,
    pub renga_url: String,
    pub allow_insecure_http: bool,
    pub intake_api_key: String,
    pub installation_id: uuid::Uuid,
    pub inventory_interval: Duration,
    pub checkin_interval: Duration,
    pub config_refresh_interval: Duration,
    pub request_timeout: Duration,
    pub max_retry_attempts: u32,
    /// Operator-chosen key/value labels sent with every observation, so
    /// Renga's triage rules can match them (for example `team = "storage"`).
    pub labels: BTreeMap<String, String>,
    /// Which compiled-in job capabilities the operator lets Renga request.
    pub jobs: JobPolicy,
    /// SNMP switch poller modules (RFD 11), each its own collector stream.
    pub snmp: Vec<SnmpCollector>,
    /// gNMI/OpenConfig switch poller modules, reporting like the SNMP ones.
    pub gnmi: Vec<GnmiCollector>,
    pub libvirt: Option<LibvirtCollector>,
    /// SNMP PDU power modules (RFD 10), each its own `power_poller` collector stream.
    pub power: Vec<SnmpCollector>,
    /// Local Prometheus exporters to read power from (RFD 10).
    pub exporters: Vec<Exporter>,
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("config_path", &self.config_path)
            .field("renga_url", &self.renga_url)
            .field("allow_insecure_http", &self.allow_insecure_http)
            .field("intake_api_key", &"[REDACTED]")
            .field("installation_id", &self.installation_id)
            .field("inventory_interval", &self.inventory_interval)
            .field("checkin_interval", &self.checkin_interval)
            .field("config_refresh_interval", &self.config_refresh_interval)
            .field("request_timeout", &self.request_timeout)
            .field("max_retry_attempts", &self.max_retry_attempts)
            .field("labels", &self.labels)
            .field("jobs", &self.jobs)
            .field("snmp", &self.snmp)
            .field("gnmi", &self.gnmi)
            .field("libvirt", &self.libvirt)
            .field("power", &self.power)
            .field("exporters", &self.exporters)
            .finish()
    }
}

#[derive(Debug)]
pub struct ConfigError(String);
impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ConfigError {}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    renga_url: Option<String>,
    allow_insecure_http: Option<bool>,
    intake_api_key: Option<String>,
    installation_id: Option<String>,
    inventory_interval_seconds: Option<u64>,
    checkin_interval_seconds: Option<u64>,
    config_refresh_interval_seconds: Option<u64>,
    request_timeout_seconds: Option<u64>,
    max_retry_attempts: Option<u32>,
    labels: Option<BTreeMap<String, String>>,
    jobs: Option<RawJobs>,
    collectors: Option<RawCollectors>,
    exporters: Option<Vec<RawExporter>>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCollectors {
    snmp: Option<Vec<RawSnmpCollector>>,
    gnmi: Option<Vec<RawGnmiCollector>>,
    libvirt: Option<RawLibvirtCollector>,
    power: Option<Vec<RawSnmpCollector>>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawJobs {
    enabled: Option<Vec<String>>,
}

impl Config {
    /// Loads TOML and then applies `RENGA_*` overrides. Durations are in seconds.
    /// Defaults: inventory 1h, check-in 1m, refresh 5m, timeout 20s, retries 5.
    pub fn load(
        path: impl AsRef<Path>,
        state_directory: impl AsRef<Path>,
    ) -> Result<Self, ConfigError> {
        let path = path.as_ref();
        let mut raw: RawConfig = match fs::read_to_string(path) {
            // TOML diagnostics can echo source lines, including the token.
            Ok(text) => toml::from_str(&text)
                .map_err(|_| ConfigError(format!("invalid config TOML in {}", path.display())))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => RawConfig::default(),
            Err(e) => {
                return Err(ConfigError(format!(
                    "cannot read config {}: {e}",
                    path.display()
                )))
            }
        };
        macro_rules! string_env {
            ($key:literal, $field:ident) => {
                if let Ok(v) = env::var($key) {
                    raw.$field = Some(v);
                }
            };
        }
        macro_rules! number_env {
            ($key:literal, $field:ident, $ty:ty) => {
                if let Ok(v) = env::var($key) {
                    raw.$field = Some(v.parse::<$ty>().map_err(|_| {
                        ConfigError(format!("{} must be a positive integer", $key))
                    })?);
                }
            };
        }
        string_env!("RENGA_URL", renga_url);
        string_env!("RENGA_INTAKE_API_KEY", intake_api_key);
        string_env!("RENGA_INSTALLATION_ID", installation_id);
        if let Ok(value) = env::var("RENGA_ALLOW_INSECURE_HTTP") {
            raw.allow_insecure_http = Some(match value.as_str() {
                "true" => true,
                "false" => false,
                _ => {
                    return Err(ConfigError(
                        "RENGA_ALLOW_INSECURE_HTTP must be exactly true or false".into(),
                    ))
                }
            });
        }
        number_env!(
            "RENGA_INVENTORY_INTERVAL_SECONDS",
            inventory_interval_seconds,
            u64
        );
        number_env!(
            "RENGA_CHECKIN_INTERVAL_SECONDS",
            checkin_interval_seconds,
            u64
        );
        number_env!(
            "RENGA_CONFIG_REFRESH_INTERVAL_SECONDS",
            config_refresh_interval_seconds,
            u64
        );
        number_env!(
            "RENGA_REQUEST_TIMEOUT_SECONDS",
            request_timeout_seconds,
            u64
        );
        number_env!("RENGA_MAX_RETRY_ATTEMPTS", max_retry_attempts, u32);
        Self::from_raw(path.to_path_buf(), state_directory.as_ref(), raw)
    }

    fn from_raw(
        config_path: PathBuf,
        state_directory: &Path,
        raw: RawConfig,
    ) -> Result<Self, ConfigError> {
        fn required(value: Option<String>, name: &str) -> Result<String, ConfigError> {
            value
                .filter(|v| !v.trim().is_empty())
                .ok_or_else(|| ConfigError(format!("{name} is required")))
        }
        fn duration(value: Option<u64>, default: u64, name: &str) -> Result<Duration, ConfigError> {
            let seconds = value.unwrap_or(default);
            if seconds == 0 {
                Err(ConfigError(format!("{name} must be greater than zero")))
            } else {
                Ok(Duration::from_secs(seconds))
            }
        }
        fn checkin_duration(value: Option<u64>) -> Result<Duration, ConfigError> {
            let duration = duration(value, CHECKIN_DEFAULT, "checkin_interval_seconds")?;
            if duration.as_secs() > CHECKIN_MAX {
                Err(ConfigError(format!(
                    "checkin_interval_seconds must not exceed {CHECKIN_MAX}"
                )))
            } else {
                Ok(duration)
            }
        }
        let installation_id =
            identity::load_or_create(state_directory, raw.installation_id.as_deref())
                .map_err(|error| ConfigError(error.to_string()))?;
        let renga_url = required(raw.renga_url, "renga_url")?
            .trim_end_matches('/')
            .to_owned();
        let allow_insecure_http = raw.allow_insecure_http.unwrap_or(false);
        if !(renga_url.starts_with("https://")
            || allow_insecure_http && renga_url.starts_with("http://"))
        {
            return Err(ConfigError(
                "renga_url must use HTTPS (HTTP requires allow_insecure_http = true)".into(),
            ));
        }
        let max_retry_attempts = raw.max_retry_attempts.unwrap_or(RETRIES_DEFAULT);
        if !(1..=RETRIES_MAX).contains(&max_retry_attempts) {
            return Err(ConfigError(format!(
                "max_retry_attempts must be between 1 and {RETRIES_MAX}"
            )));
        }
        let request_timeout = duration(
            raw.request_timeout_seconds,
            TIMEOUT_DEFAULT,
            "request_timeout_seconds",
        )?;
        if request_timeout.as_secs() > TIMEOUT_MAX {
            return Err(ConfigError(format!(
                "request_timeout_seconds must not exceed {TIMEOUT_MAX}"
            )));
        }
        let labels = validate_labels(raw.labels.unwrap_or_default())?;
        let jobs = job_policy(raw.jobs.unwrap_or_default())?;
        let collectors = raw.collectors.unwrap_or_default();
        let snmp =
            snmp_config::from_raw(collectors.snmp.unwrap_or_default()).map_err(ConfigError)?;
        let gnmi =
            gnmi_config::from_raw(collectors.gnmi.unwrap_or_default()).map_err(ConfigError)?;
        // Each module is its own stream, so two modules cannot share an ID.
        if let Some(collector) = gnmi
            .iter()
            .find(|collector| snmp.iter().any(|snmp| snmp.id == collector.id))
        {
            return Err(ConfigError(format!(
                "collectors.gnmi: id {:?} is already used by an SNMP module",
                collector.id
            )));
        }
        let libvirt = libvirt_config::from_raw(collectors.libvirt).map_err(ConfigError)?;
        if let Some(libvirt) = &libvirt {
            // A stream's kind never changes, so one ID cannot name both a poller and a hypervisor.
            if snmp.iter().any(|collector| collector.id == libvirt.id) {
                return Err(ConfigError(format!(
                    "collectors.libvirt: id {:?} is already used by an SNMP module",
                    libvirt.id
                )));
            }
            if gnmi.iter().any(|collector| collector.id == libvirt.id) {
                return Err(ConfigError(format!(
                    "collectors.libvirt: id {:?} is already used by a gNMI module",
                    libvirt.id
                )));
            }
        }
        let power = snmp_config::from_raw_section(
            collectors.power.unwrap_or_default(),
            "collectors.power",
            POWER_INTERVALS,
        )
        .map_err(ConfigError)?;
        if let Some(collector) = power.iter().find(|collector| {
            snmp.iter().any(|other| other.id == collector.id)
                || libvirt
                    .as_ref()
                    .is_some_and(|other| other.id == collector.id)
        }) {
            return Err(ConfigError(format!(
                "collectors.power: id {:?} is already used by another collector module",
                collector.id
            )));
        }
        Ok(Self {
            config_path,
            renga_url,
            allow_insecure_http,
            intake_api_key: required(raw.intake_api_key, "intake_api_key")?,
            installation_id,
            inventory_interval: duration(
                raw.inventory_interval_seconds,
                INVENTORY_DEFAULT,
                "inventory_interval_seconds",
            )?,
            checkin_interval: checkin_duration(raw.checkin_interval_seconds)?,
            config_refresh_interval: duration(
                raw.config_refresh_interval_seconds,
                REFRESH_DEFAULT,
                "config_refresh_interval_seconds",
            )?,
            request_timeout,
            max_retry_attempts,
            labels,
            jobs,
            snmp,
            gnmi,
            libvirt,
            power,
            exporters: exporters::from_raw(raw.exporters.unwrap_or_default())
                .map_err(ConfigError)?,
        })
    }
}

fn validate_labels(
    labels: BTreeMap<String, String>,
) -> Result<BTreeMap<String, String>, ConfigError> {
    if labels.len() > LABELS_MAX {
        return Err(ConfigError(format!(
            "labels must have at most {LABELS_MAX} entries"
        )));
    }
    for (key, value) in &labels {
        if !valid_label_key(key) {
            return Err(ConfigError(format!(
                "label key {key:?} must be 1-{LABEL_KEY_MAX} letters, digits, '.', '_', '-', or '/', starting and ending with a letter or digit"
            )));
        }
        if value.chars().count() > LABEL_VALUE_MAX {
            return Err(ConfigError(format!(
                "label {key:?} must be at most {LABEL_VALUE_MAX} characters"
            )));
        }
    }
    Ok(labels)
}

/// Unknown capability names are accepted, so a configuration shared across
/// agent versions does not stop older agents; they simply enable nothing.
fn job_policy(raw: RawJobs) -> Result<JobPolicy, ConfigError> {
    let Some(entries) = raw.enabled else {
        return Ok(JobPolicy::default());
    };
    if entries.len() > JOBS_ENABLED_MAX {
        return Err(ConfigError(format!(
            "jobs.enabled must have at most {JOBS_ENABLED_MAX} entries"
        )));
    }
    let selectors = entries
        .iter()
        .map(|entry| {
            Selector::parse(entry).ok_or_else(|| {
                ConfigError(format!(
                    "jobs.enabled entry {entry:?} must be a capability name such as \"inventory.collect\" or a name@version key such as \"inventory.collect@1\""
                ))
            })
        })
        .collect::<Result<_, _>>()?;
    Ok(JobPolicy {
        enabled: Some(selectors),
    })
}

fn valid_label_key(key: &str) -> bool {
    let bytes = key.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= LABEL_KEY_MAX
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'/'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn state_directory() -> PathBuf {
        env::temp_dir().join(format!("renga-config-state-{}", uuid::Uuid::new_v4()))
    }

    fn from_raw(raw: RawConfig) -> Result<Config, ConfigError> {
        Config::from_raw("x".into(), &state_directory(), raw)
    }

    fn raw() -> RawConfig {
        RawConfig {
            renga_url: Some("https://renga.test".into()),
            intake_api_key: Some("secret".into()),
            installation_id: Some("67e55044-10b1-426f-9247-bb680e5fe0c8".into()),
            ..Default::default()
        }
    }
    #[test]
    fn labels_are_optional_and_validated() {
        assert!(from_raw(raw()).unwrap().labels.is_empty());

        let r: RawConfig = toml::from_str(
            "renga_url='https://renga.test'\nintake_api_key='y'\n[labels]\nteam='storage'\n\"rack.row\"='B'\n",
        )
        .unwrap();
        let mut r = r;
        r.installation_id = raw().installation_id;
        let labels = from_raw(r).unwrap().labels;
        assert_eq!(labels.get("team").map(String::as_str), Some("storage"));
        assert_eq!(labels.get("rack.row").map(String::as_str), Some("B"));

        for key in ["", "-team", "team-", "has space", &"k".repeat(64)] {
            let mut r = raw();
            r.labels = Some(BTreeMap::from([(key.to_string(), "v".to_string())]));
            assert!(from_raw(r).is_err(), "{key:?} should be rejected");
        }

        let mut r = raw();
        r.labels = Some(BTreeMap::from([("team".to_string(), "v".repeat(256))]));
        assert!(from_raw(r).is_err());

        let mut r = raw();
        r.labels = Some(
            (0..33)
                .map(|i| (format!("k{i}"), "v".to_string()))
                .collect(),
        );
        assert!(from_raw(r).is_err());
    }
    #[test]
    fn jobs_policy_defaults_to_unset_and_validates_entries() {
        assert_eq!(from_raw(raw()).unwrap().jobs, JobPolicy::default());

        let mut r: RawConfig = toml::from_str(
            "renga_url='https://renga.test'\nintake_api_key='y'\n[jobs]\nenabled=['inventory.collect', 'service.restart@2']\n",
        )
        .unwrap();
        r.installation_id = raw().installation_id;
        let jobs = from_raw(r).unwrap().jobs;
        assert_eq!(
            jobs.enabled.unwrap(),
            [
                Selector::parse("inventory.collect").unwrap(),
                Selector::parse("service.restart@2").unwrap()
            ]
        );

        let mut r: RawConfig = toml::from_str("[jobs]\nenabled=[]\n").unwrap();
        r.renga_url = raw().renga_url;
        r.intake_api_key = raw().intake_api_key;
        r.installation_id = raw().installation_id;
        assert_eq!(from_raw(r).unwrap().jobs.enabled, Some(vec![]));

        for entry in [
            "host.inventory@0",
            "inventory",
            "rm -rf /",
            "inventory.collect@x",
        ] {
            let mut r = raw();
            r.jobs = Some(RawJobs {
                enabled: Some(vec![entry.into()]),
            });
            assert!(from_raw(r).is_err(), "{entry:?} should be rejected");
        }

        let mut r = raw();
        r.jobs = Some(RawJobs {
            enabled: Some(vec!["inventory.collect".into(); 65]),
        });
        assert!(from_raw(r).is_err());

        assert!(toml::from_str::<RawConfig>("[jobs]\ndisabled=['inventory.collect']\n").is_err());
    }
    #[test]
    fn defaults_are_sane_and_secret_is_redacted() {
        let mut input = raw();
        input.renga_url = Some("https://renga.test///".into());
        let c = from_raw(input).unwrap();
        assert_eq!(c.inventory_interval, Duration::from_secs(3600));
        assert_eq!(c.renga_url, "https://renga.test");
        assert!(!format!("{c:?}").contains("secret"));
    }
    #[test]
    fn parses_toml_and_rejects_invalid_values() {
        let r: RawConfig = toml::from_str(
            "renga_url='https://renga.test'\nintake_api_key='y'\ninstallation_id='bad'\n",
        )
        .unwrap();
        assert!(from_raw(r).unwrap_err().to_string().contains("UUID"));
        let mut r = raw();
        r.request_timeout_seconds = Some(0);
        assert!(from_raw(r).is_err());
    }

    #[test]
    fn bounds_transport_timeout_and_attempt_configuration() {
        let mut timeout = raw();
        timeout.request_timeout_seconds = Some(TIMEOUT_MAX + 1);
        assert!(from_raw(timeout)
            .unwrap_err()
            .to_string()
            .contains("must not exceed 20"));

        let mut attempts = raw();
        attempts.max_retry_attempts = Some(RETRIES_MAX + 1);
        assert!(from_raw(attempts)
            .unwrap_err()
            .to_string()
            .contains("between 1 and 5"));
    }
    #[test]
    fn environment_wins_over_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        fs::write(&path,"renga_url='file'\nintake_api_key='file-key'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\n").unwrap();
        env::set_var("RENGA_URL", "https://environment.test");
        let c = Config::load(&path, &state).unwrap();
        env::remove_var("RENGA_URL");
        fs::remove_file(path).unwrap();
        assert_eq!(c.renga_url, "https://environment.test");
    }

    #[test]
    fn reads_exporters_from_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        let base = "renga_url='https://renga.test'\nintake_api_key='file-key'\n";
        fs::write(
            &path,
            format!(
                "{base}[[exporters]]\nurl='http://127.0.0.1:9100/metrics'\n\
                 [[exporters]]\nurl='http://127.0.0.1:9290/metrics'\ninterval_seconds=30\n"
            ),
        )
        .unwrap();
        let config = Config::load(&path, &state).unwrap();
        assert_eq!(config.exporters.len(), 2);
        assert_eq!(config.exporters[1].interval, Duration::from_secs(30));

        fs::write(
            &path,
            format!("{base}[[exporters]]\nurl='http://127.0.0.1:9100/metrics'\npassword='x'\n"),
        )
        .unwrap();
        assert!(Config::load(&path, &state).is_err());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn reads_snmp_collector_modules_from_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        fs::write(
            &path,
            "renga_url='https://renga.test'\nintake_api_key='file-key'\n\
             [[collectors.snmp]]\nid='core'\ntargets=['10.0.0.1']\nusername='renga'\n\
             auth_password_file='/etc/renga/snmp-auth'\nprivacy_password_file='/etc/renga/snmp-priv'\n",
        )
        .unwrap();
        let config = Config::load(&path, &state).unwrap();
        assert_eq!(config.snmp.len(), 1);
        assert_eq!(config.snmp[0].id, "core");

        fs::write(
            &path,
            "renga_url='https://renga.test'\nintake_api_key='file-key'\n[[collectors.snmp]]\nid='core'\n",
        )
        .unwrap();
        let error = Config::load(&path, &state).unwrap_err().to_string();
        fs::remove_file(path).unwrap();
        assert!(error.contains("collectors.snmp[0]: targets"), "{error}");
    }

    #[test]
    fn reads_pdu_power_modules_from_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        let module = |section: &str, id: &str| {
            format!(
                "[[collectors.{section}]]\nid='{id}'\ntargets=['10.0.0.5']\nusername='renga'\n\
                 auth_password_file='/etc/renga/snmp-auth'\n\
                 privacy_password_file='/etc/renga/snmp-priv'\n"
            )
        };
        let base = "renga_url='https://renga.test'\nintake_api_key='file-key'\n";

        fs::write(&path, format!("{base}{}", module("power", "rack-pdus"))).unwrap();
        let config = Config::load(&path, &state).unwrap();
        assert_eq!(config.power.len(), 1);
        assert_eq!(config.power[0].id, "rack-pdus");
        // Readings go stale in minutes, so PDUs are polled every minute by default.
        assert_eq!(config.power[0].interval, Duration::from_secs(60));

        fs::write(
            &path,
            format!(
                "{base}{}interval_seconds=10\n",
                module("power", "rack-pdus")
            ),
        )
        .unwrap();
        let error = Config::load(&path, &state).unwrap_err().to_string();
        assert!(
            error.contains("collectors.power[0]: interval_seconds must be at least 30"),
            "{error}"
        );

        // One ID is one stream, and a stream's kind never changes.
        fs::write(
            &path,
            format!(
                "{base}{}{}",
                module("snmp", "core"),
                module("power", "core")
            ),
        )
        .unwrap();
        let error = Config::load(&path, &state).unwrap_err().to_string();
        fs::remove_file(path).unwrap();
        assert!(
            error.contains("already used by another collector module"),
            "{error}"
        );
    }

    #[test]
    fn reads_the_libvirt_module_and_keeps_stream_ids_distinct() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        let base = "renga_url='https://renga.test'\nintake_api_key='file-key'\n";
        fs::write(&path, format!("{base}[collectors.libvirt]\n")).unwrap();
        let config = Config::load(&path, &state).unwrap();
        assert_eq!(config.libvirt.unwrap().uri, "qemu:///system");

        fs::write(
            &path,
            format!(
                "{base}[[collectors.snmp]]\nid='libvirt'\ntargets=['10.0.0.1']\nusername='renga'\n\
                 auth_password_file='/a'\nprivacy_password_file='/p'\n[collectors.libvirt]\n"
            ),
        )
        .unwrap();
        let error = Config::load(&path, &state).unwrap_err().to_string();
        fs::remove_file(path).unwrap();
        assert!(error.contains("already used by an SNMP module"), "{error}");
    }

    #[test]
    fn reads_gnmi_collector_modules_and_keeps_stream_ids_distinct() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        let base = "renga_url='https://renga.test'\nintake_api_key='file-key'\n";
        let gnmi = "[[collectors.gnmi]]\nid='spines'\ntargets=['10.0.0.1']\n\
                    username='renga'\npassword_file='/etc/renga/gnmi-password'\n";
        fs::write(&path, format!("{base}{gnmi}")).unwrap();
        let config = Config::load(&path, &state).unwrap();
        assert_eq!(config.gnmi.len(), 1);
        assert_eq!(config.gnmi[0].targets[0].port, 9339);

        fs::write(
            &path,
            format!(
                "{base}{gnmi}[[collectors.snmp]]\nid='spines'\ntargets=['10.0.0.1']\n\
                 username='renga'\nauth_password_file='/a'\nprivacy_password_file='/p'\n"
            ),
        )
        .unwrap();
        let error = Config::load(&path, &state).unwrap_err().to_string();
        assert!(error.contains("already used by an SNMP module"), "{error}");

        fs::write(
            &path,
            format!("{base}{gnmi}[collectors.libvirt]\nid='spines'\n"),
        )
        .unwrap();
        let error = Config::load(&path, &state).unwrap_err().to_string();
        fs::remove_file(path).unwrap();
        assert!(error.contains("already used by a gNMI module"), "{error}");
    }

    #[test]
    fn checkin_interval_accepts_sixty_seconds_and_rejects_sixty_one_from_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        let config = |seconds| {
            format!(
                "renga_url='https://renga.test'\nintake_api_key='file-key'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\ncheckin_interval_seconds={seconds}\n"
            )
        };

        fs::write(&path, config(60)).unwrap();
        assert_eq!(
            Config::load(&path, &state).unwrap().checkin_interval,
            Duration::from_secs(60)
        );

        fs::write(&path, config(61)).unwrap();
        let error = Config::load(&path, &state).unwrap_err();
        assert!(error.to_string().contains("must not exceed 60"));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn checkin_interval_rejects_oversized_environment_override_on_reload_path() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        fs::write(&path,"renga_url='https://renga.test'\nintake_api_key='file-key'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\ncheckin_interval_seconds=60\n").unwrap();
        env::set_var("RENGA_CHECKIN_INTERVAL_SECONDS", "61");

        let error = Config::load(&path, &state).unwrap_err();

        env::remove_var("RENGA_CHECKIN_INTERVAL_SECONDS");
        fs::remove_file(path).unwrap();
        assert!(error.to_string().contains("must not exceed 60"));
    }

    #[test]
    fn requires_https_unless_insecure_http_is_explicitly_enabled() {
        assert!(from_raw(raw()).is_ok());

        let mut input = raw();
        input.renga_url = Some("http://localhost:4000".into());
        assert!(from_raw(input).is_err());

        let mut input = raw();
        input.renga_url = Some("http://localhost:4000".into());
        input.allow_insecure_http = Some(true);
        assert!(from_raw(input).is_ok());
    }

    #[test]
    fn insecure_http_environment_override_is_strict_and_wins_over_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let state = state_directory();
        fs::write(&path, "renga_url='http://localhost:4000'\nallow_insecure_http=false\nintake_api_key='file-key'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\n").unwrap();

        env::set_var("RENGA_ALLOW_INSECURE_HTTP", "true");
        let config = Config::load(&path, &state).unwrap();
        assert!(config.allow_insecure_http);

        env::set_var("RENGA_ALLOW_INSECURE_HTTP", "TRUE");
        let error = Config::load(&path, &state).unwrap_err();
        assert!(error.to_string().contains("exactly true or false"));

        env::remove_var("RENGA_ALLOW_INSECURE_HTTP");
        fs::remove_file(path).unwrap();
    }
}
