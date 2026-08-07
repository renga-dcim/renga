//! Configuration loading without transport-specific policy.

use serde::Deserialize;
use std::{
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

/// Validated runtime configuration. The token is intentionally redacted from Debug.
#[derive(Clone)]
pub struct Config {
    pub config_path: PathBuf,
    pub renga_url: String,
    pub allow_insecure_http: bool,
    pub token: String,
    pub installation_id: uuid::Uuid,
    pub inventory_interval: Duration,
    pub checkin_interval: Duration,
    pub config_refresh_interval: Duration,
    pub request_timeout: Duration,
    pub max_retry_attempts: u32,
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("config_path", &self.config_path)
            .field("renga_url", &self.renga_url)
            .field("allow_insecure_http", &self.allow_insecure_http)
            .field("token", &"[REDACTED]")
            .field("installation_id", &self.installation_id)
            .field("inventory_interval", &self.inventory_interval)
            .field("checkin_interval", &self.checkin_interval)
            .field("config_refresh_interval", &self.config_refresh_interval)
            .field("request_timeout", &self.request_timeout)
            .field("max_retry_attempts", &self.max_retry_attempts)
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
    token: Option<String>,
    installation_id: Option<String>,
    inventory_interval_seconds: Option<u64>,
    checkin_interval_seconds: Option<u64>,
    config_refresh_interval_seconds: Option<u64>,
    request_timeout_seconds: Option<u64>,
    max_retry_attempts: Option<u32>,
}

impl Config {
    /// Loads TOML and then applies `RENGA_*` overrides. Durations are in seconds.
    /// Defaults: inventory 1h, check-in 1m, refresh 5m, timeout 20s, retries 5.
    pub fn load(path: impl AsRef<Path>) -> Result<Self, ConfigError> {
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
        string_env!("RENGA_TOKEN", token);
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
        Self::from_raw(path.to_path_buf(), raw)
    }

    fn from_raw(config_path: PathBuf, raw: RawConfig) -> Result<Self, ConfigError> {
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
        let installation = required(raw.installation_id, "installation_id")?;
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
        Ok(Self {
            config_path,
            renga_url,
            allow_insecure_http,
            token: required(raw.token, "token")?,
            installation_id: uuid::Uuid::parse_str(&installation)
                .map_err(|_| ConfigError("installation_id must be a UUID".into()))?,
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
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    static ENV_LOCK: Mutex<()> = Mutex::new(());
    fn raw() -> RawConfig {
        RawConfig {
            renga_url: Some("https://renga.test".into()),
            token: Some("secret".into()),
            installation_id: Some("67e55044-10b1-426f-9247-bb680e5fe0c8".into()),
            ..Default::default()
        }
    }
    #[test]
    fn defaults_are_sane_and_secret_is_redacted() {
        let mut input = raw();
        input.renga_url = Some("https://renga.test///".into());
        let c = Config::from_raw("x".into(), input).unwrap();
        assert_eq!(c.inventory_interval, Duration::from_secs(3600));
        assert_eq!(c.renga_url, "https://renga.test");
        assert!(!format!("{c:?}").contains("secret"));
    }
    #[test]
    fn parses_toml_and_rejects_invalid_values() {
        let r: RawConfig =
            toml::from_str("renga_url='https://renga.test'\ntoken='y'\ninstallation_id='bad'\n")
                .unwrap();
        assert!(Config::from_raw("x".into(), r)
            .unwrap_err()
            .to_string()
            .contains("UUID"));
        let mut r = raw();
        r.request_timeout_seconds = Some(0);
        assert!(Config::from_raw("x".into(), r).is_err());
    }

    #[test]
    fn bounds_transport_timeout_and_attempt_configuration() {
        let mut timeout = raw();
        timeout.request_timeout_seconds = Some(TIMEOUT_MAX + 1);
        assert!(Config::from_raw("x".into(), timeout)
            .unwrap_err()
            .to_string()
            .contains("must not exceed 20"));

        let mut attempts = raw();
        attempts.max_retry_attempts = Some(RETRIES_MAX + 1);
        assert!(Config::from_raw("x".into(), attempts)
            .unwrap_err()
            .to_string()
            .contains("between 1 and 5"));
    }
    #[test]
    fn environment_wins_over_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        fs::write(&path,"renga_url='file'\ntoken='file-token'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\n").unwrap();
        env::set_var("RENGA_URL", "https://environment.test");
        let c = Config::load(&path).unwrap();
        env::remove_var("RENGA_URL");
        fs::remove_file(path).unwrap();
        assert_eq!(c.renga_url, "https://environment.test");
    }

    #[test]
    fn checkin_interval_accepts_sixty_seconds_and_rejects_sixty_one_from_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        let config = |seconds| {
            format!(
                "renga_url='https://renga.test'\ntoken='file-token'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\ncheckin_interval_seconds={seconds}\n"
            )
        };

        fs::write(&path, config(60)).unwrap();
        assert_eq!(
            Config::load(&path).unwrap().checkin_interval,
            Duration::from_secs(60)
        );

        fs::write(&path, config(61)).unwrap();
        let error = Config::load(&path).unwrap_err();
        assert!(error.to_string().contains("must not exceed 60"));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn checkin_interval_rejects_oversized_environment_override_on_reload_path() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        fs::write(&path,"renga_url='https://renga.test'\ntoken='file-token'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\ncheckin_interval_seconds=60\n").unwrap();
        env::set_var("RENGA_CHECKIN_INTERVAL_SECONDS", "61");

        let error = Config::load(&path).unwrap_err();

        env::remove_var("RENGA_CHECKIN_INTERVAL_SECONDS");
        fs::remove_file(path).unwrap();
        assert!(error.to_string().contains("must not exceed 60"));
    }

    #[test]
    fn requires_https_unless_insecure_http_is_explicitly_enabled() {
        assert!(Config::from_raw("x".into(), raw()).is_ok());

        let mut input = raw();
        input.renga_url = Some("http://localhost:4000".into());
        assert!(Config::from_raw("x".into(), input).is_err());

        let mut input = raw();
        input.renga_url = Some("http://localhost:4000".into());
        input.allow_insecure_http = Some(true);
        assert!(Config::from_raw("x".into(), input).is_ok());
    }

    #[test]
    fn insecure_http_environment_override_is_strict_and_wins_over_toml() {
        let _guard = ENV_LOCK.lock().unwrap();
        let path = env::temp_dir().join(format!("renga-config-{}.toml", uuid::Uuid::new_v4()));
        fs::write(&path, "renga_url='http://localhost:4000'\nallow_insecure_http=false\ntoken='file-token'\ninstallation_id='67e55044-10b1-426f-9247-bb680e5fe0c8'\n").unwrap();

        env::set_var("RENGA_ALLOW_INSECURE_HTTP", "true");
        let config = Config::load(&path).unwrap();
        assert!(config.allow_insecure_http);

        env::set_var("RENGA_ALLOW_INSECURE_HTTP", "TRUE");
        let error = Config::load(&path).unwrap_err();
        assert!(error.to_string().contains("exactly true or false"));

        env::remove_var("RENGA_ALLOW_INSECURE_HTTP");
        fs::remove_file(path).unwrap();
    }
}
