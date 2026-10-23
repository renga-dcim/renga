//! The agent's home deployment (RFD 23): the origin its authenticated requests go to.
//!
//! `renga_url` may name a deployment, which answers with itself, or a resolver, which answers
//! with the deployment that owns the intake key's deployment identifier. The answer is kept in
//! the state directory so later starts need no resolution; deleting it forces one.

use crate::{
    cancellation::Cancellation,
    config::Config,
    transport::{self, FailureKind, TransportError},
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{fmt, fs, io::Write, path::Path};
use url::Url;

const HOME_FILE: &str = "home.json";
const INTAKE_KEY_PREFIX: &str = "renga_intake_";
/// Base64url of the 32 random bytes that end every intake key.
const SECRET_LENGTH: usize = 43;

/// A resolved home and what it was resolved from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Home {
    /// The address asked, so changing `renga_url` resolves again.
    pub renga_url: String,
    /// The deployment identifier asked for, so a rotated key resolves again.
    pub deployment: String,
    pub home: Url,
    pub resolved_at: DateTime<Utc>,
}

impl Home {
    /// Whether this home was resolved for `config`'s address and deployment identifier and is
    /// still an origin `config` may send requests to.
    pub fn answers(&self, config: &Config) -> bool {
        self.renga_url == config.renga_url
            && self.deployment == deployment_id(&config.intake_api_key).unwrap_or_default()
            && transport::origin_url(self.home.as_str(), config.allow_insecure_http, "home URL")
                .is_ok()
    }
}

#[derive(Debug)]
pub struct HomeError {
    message: String,
    kind: FailureKind,
}

impl HomeError {
    fn state(message: String) -> Self {
        Self {
            message,
            kind: FailureKind::Permanent,
        }
    }

    /// Whether asking again later may succeed.
    pub fn transient(&self) -> bool {
        self.kind == FailureKind::Transient
    }
}

impl fmt::Display for HomeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for HomeError {}

impl From<TransportError> for HomeError {
    fn from(error: TransportError) -> Self {
        Self {
            message: format!("cannot resolve home: {error}"),
            kind: error.kind(),
        }
    }
}

/// The deployment identifier an intake key carries between its prefix and its secret, or
/// `None` for a key issued before identifiers existed. The secret is base64url and may itself
/// contain `_`, so the identifier is found by the secret's fixed length.
pub fn deployment_id(intake_api_key: &str) -> Option<&str> {
    let rest = intake_api_key.strip_prefix(INTAKE_KEY_PREFIX)?;
    let separator = rest.len().checked_sub(SECRET_LENGTH + 1)?;
    // A malformed key may put a multi-byte character across the offset; slicing there must
    // not panic, since a panic message would print the key.
    let (identifier, secret) = rest.split_at_checked(separator)?;
    (secret.starts_with('_') && valid_deployment_id(identifier)).then_some(identifier)
}

/// The form Renga accepts for a deployment identifier.
fn valid_deployment_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=16).contains(&bytes.len())
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
        && bytes.first() != Some(&b'-')
        && bytes.last() != Some(&b'-')
}

/// Returns the persisted home when it still answers this configuration, and otherwise asks
/// `renga_url` and persists the answer.
pub fn resolve(
    config: &Config,
    state_directory: &Path,
    cancellation: &Cancellation,
) -> Result<Home, HomeError> {
    if let Some(home) = persisted(config, state_directory)? {
        return Ok(home);
    }
    let home = fetch(config, cancellation)?;
    persist(state_directory, &home)?;
    Ok(home)
}

/// The persisted home, when there is one and it answers `config`.
pub fn persisted(config: &Config, state_directory: &Path) -> Result<Option<Home>, HomeError> {
    Ok(load(state_directory)?.filter(|home| home.answers(config)))
}

/// Asks `renga_url` where the home is without persisting the answer, so a caller can check that
/// it can use the answer before it replaces the persisted home.
pub fn fetch(config: &Config, cancellation: &Cancellation) -> Result<Home, HomeError> {
    let deployment = deployment_id(&config.intake_api_key).unwrap_or_default();
    Ok(Home {
        renga_url: config.renga_url.clone(),
        deployment: deployment.into(),
        home: transport::fetch_home(config, deployment, cancellation)?,
        resolved_at: Utc::now(),
    })
}

/// Forgets the persisted home after it said the organization moved (RFD 23), so no later run
/// sends requests there without first asking `renga_url` again.
pub fn discard(state_directory: &Path) -> Result<(), HomeError> {
    match fs::remove_file(state_directory.join(HOME_FILE)) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(HomeError::state(
            format!("cannot discard persisted home: {error}"),
        )),
        _ => Ok(()),
    }
}

/// A missing or unreadable home is resolved again rather than treated as an error.
fn load(state_directory: &Path) -> Result<Option<Home>, HomeError> {
    let path = state_directory.join(HOME_FILE);
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(HomeError::state(format!(
                "cannot inspect persisted home {}: {error}",
                path.display()
            )))
        }
        Ok(metadata) if !metadata.file_type().is_file() => {
            return Err(HomeError::state(format!(
                "persisted home {} is not a regular file",
                path.display()
            )))
        }
        Ok(_) => {}
    }
    let bytes = fs::read(&path).map_err(|error| {
        HomeError::state(format!(
            "cannot read persisted home {}: {error}",
            path.display()
        ))
    })?;
    Ok(serde_json::from_slice(&bytes).ok())
}

/// Replaces the persisted home atomically.
pub fn persist(state_directory: &Path, home: &Home) -> Result<(), HomeError> {
    fs::create_dir_all(state_directory).map_err(|error| {
        HomeError::state(format!(
            "cannot create state directory {}: {error}",
            state_directory.display()
        ))
    })?;
    let temporary = state_directory.join(format!(".home-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&serde_json::to_vec(home)?)?;
        file.sync_all()?;
        fs::rename(&temporary, state_directory.join(HOME_FILE))?;
        #[cfg(unix)]
        fs::File::open(state_directory)?.sync_all()?;
        Ok::<_, std::io::Error>(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|error| HomeError::state(format!("cannot persist home: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::BTreeMap,
        io::{BufRead, BufReader},
        net::TcpListener,
        path::PathBuf,
        thread,
        time::Duration,
    };

    const SECRET: &str = "abc_def-ghi_jkl-mno_pqr-stu_vwx-yz0_123-456";

    fn state_directory() -> PathBuf {
        std::env::temp_dir().join(format!("renga-home-{}", uuid::Uuid::new_v4()))
    }

    fn config(renga_url: &str, intake_api_key: &str) -> Config {
        Config {
            config_path: PathBuf::from("agent.toml"),
            renga_url: renga_url.into(),
            allow_insecure_http: true,
            intake_api_key: intake_api_key.into(),
            installation_id: uuid::Uuid::nil(),
            inventory_interval: Duration::from_secs(300),
            checkin_interval: Duration::from_secs(60),
            config_refresh_interval: Duration::from_secs(300),
            request_timeout: Duration::from_secs(5),
            max_retry_attempts: 1,
            labels: BTreeMap::new(),
            jobs: Default::default(),
            snmp: Vec::new(),
            gnmi: Vec::new(),
            libvirt: None,
            exporters: Vec::new(),
        }
    }

    /// Answers one home request per entry and returns each request line and its headers.
    fn home_server(answers: Vec<(u16, String)>) -> (String, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let handle = thread::spawn(move || {
            answers
                .into_iter()
                .map(|(status, body)| {
                    let (stream, _) = listener.accept().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut request = String::new();
                    loop {
                        let mut line = String::new();
                        reader.read_line(&mut line).unwrap();
                        if line == "\r\n" || line.is_empty() {
                            break;
                        }
                        request.push_str(&line);
                    }
                    write!(
                        reader.get_mut(),
                        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .unwrap();
                    request
                })
                .collect()
        });
        (origin, handle)
    }

    fn home_body(home: &str) -> String {
        serde_json::json!({ "home": home }).to_string()
    }

    #[test]
    fn reads_the_deployment_identifier_by_the_secret_length() {
        assert_eq!(
            deployment_id(&format!("renga_intake_eu-1_{SECRET}")),
            Some("eu-1")
        );
        assert_eq!(deployment_id(&format!("renga_intake_{SECRET}")), None);
        assert_eq!(deployment_id(&format!("renga_intake_Bad_{SECRET}")), None);
        assert_eq!(deployment_id(&format!("renga_intake_-x_{SECRET}")), None);
        assert_eq!(deployment_id(&format!("renga_intake_eu-1x{SECRET}")), None);
        assert_eq!(deployment_id("renga_intake_short"), None);
        // The fixed-length offset lands inside the multi-byte character.
        assert_eq!(
            deployment_id(&format!("renga_intake_é{}", "a".repeat(SECRET_LENGTH))),
            None
        );
        assert_eq!(deployment_id(&format!("other_eu-1_{SECRET}")), None);
    }

    #[test]
    fn resolves_once_without_a_credential_and_persists_the_home() {
        let (origin, server) = home_server(vec![(200, home_body("http://home.test:4000"))]);
        let state = state_directory();
        let config = config(&origin, &format!("renga_intake_eu-1_{SECRET}"));

        let home = resolve(&config, &state, &Cancellation::default()).unwrap();
        let again = resolve(&config, &state, &Cancellation::default()).unwrap();

        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].starts_with("GET /api/v1/agent/home?deployment=eu-1 HTTP/1.1"));
        assert!(!requests[0].to_ascii_lowercase().contains("authorization"));
        assert!(!requests[0].contains(SECRET));
        assert_eq!(home.home.as_str(), "http://home.test:4000/");
        assert_eq!(home.deployment, "eu-1");
        assert_eq!(again, home);
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn a_key_without_an_identifier_asks_with_an_empty_deployment() {
        let (origin, server) = home_server(vec![(200, home_body("http://home.test"))]);
        let state = state_directory();

        resolve(
            &config(&origin, &format!("renga_intake_{SECRET}")),
            &state,
            &Cancellation::default(),
        )
        .unwrap();

        assert!(server.join().unwrap()[0].starts_with("GET /api/v1/agent/home?deployment= "));
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn resolves_again_when_the_address_or_key_changes_or_the_home_is_deleted() {
        let (origin, server) = home_server(vec![
            (200, home_body("http://one.test")),
            (200, home_body("http://two.test")),
            (200, home_body("http://three.test")),
            (200, home_body("http://four.test")),
            (200, home_body("http://five.test")),
        ]);
        let state = state_directory();
        let first = config(&origin, &format!("renga_intake_eu-1_{SECRET}"));
        let rotated = config(&origin, &format!("renga_intake_us-1_{SECRET}"));
        let mut readdressed = rotated.clone();
        readdressed.renga_url = format!("{origin}/");
        let cancellation = Cancellation::default();

        let homes = [
            resolve(&first, &state, &cancellation).unwrap(),
            resolve(&rotated, &state, &cancellation).unwrap(),
            resolve(&readdressed, &state, &cancellation).unwrap(),
            {
                fs::remove_file(state.join(HOME_FILE)).unwrap();
                resolve(&readdressed, &state, &cancellation).unwrap()
            },
            {
                let home = fetch(&readdressed, &cancellation).unwrap();
                persist(&state, &home).unwrap();
                home
            },
        ];

        assert_eq!(server.join().unwrap().len(), 5);
        assert_eq!(
            homes.map(|home| home.home.host_str().unwrap().to_owned()),
            [
                "one.test",
                "two.test",
                "three.test",
                "four.test",
                "five.test"
            ]
        );
        assert_eq!(
            resolve(&readdressed, &state, &cancellation)
                .unwrap()
                .home
                .host_str(),
            Some("five.test")
        );
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn fetching_never_touches_the_persisted_home() {
        let (origin, server) = home_server(vec![
            (200, home_body("http://home.test")),
            (503, "{}".into()),
            (200, home_body("http://elsewhere.test")),
        ]);
        let state = state_directory();
        let config = config(&origin, &format!("renga_intake_{SECRET}"));
        let cancellation = Cancellation::default();

        let home = resolve(&config, &state, &cancellation).unwrap();
        let error = fetch(&config, &cancellation).unwrap_err();
        let answer = fetch(&config, &cancellation).unwrap();

        server.join().unwrap();
        assert!(error.transient());
        assert_eq!(answer.home.host_str(), Some("elsewhere.test"));
        assert_eq!(load(&state).unwrap(), Some(home));
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn a_discarded_home_is_resolved_again() {
        let (origin, server) = home_server(vec![
            (200, home_body("http://one.test")),
            (200, home_body("http://two.test")),
        ]);
        let state = state_directory();
        let config = config(&origin, &format!("renga_intake_{SECRET}"));
        let cancellation = Cancellation::default();

        resolve(&config, &state, &cancellation).unwrap();
        discard(&state).unwrap();
        discard(&state).unwrap();
        assert_eq!(persisted(&config, &state).unwrap(), None);
        let home = resolve(&config, &state, &cancellation).unwrap();

        assert_eq!(server.join().unwrap().len(), 2);
        assert_eq!(home.home.host_str(), Some("two.test"));
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn an_unreadable_persisted_home_is_resolved_again() {
        let (origin, server) = home_server(vec![(200, home_body("http://home.test"))]);
        let state = state_directory();
        fs::create_dir_all(&state).unwrap();
        fs::write(state.join(HOME_FILE), "not json").unwrap();

        let home = resolve(
            &config(&origin, &format!("renga_intake_{SECRET}")),
            &state,
            &Cancellation::default(),
        )
        .unwrap();

        assert_eq!(server.join().unwrap().len(), 1);
        assert_eq!(home.home.host_str(), Some("home.test"));
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn refuses_a_plaintext_home_unless_insecure_http_is_allowed() {
        // The resolver itself is reached over plaintext only because the test needs a stub.
        let (origin, server) = home_server(vec![(200, home_body("http://home.test"))]);
        let state = state_directory();
        let config = config(&origin, &format!("renga_intake_{SECRET}"));
        let persisted = Home {
            renga_url: config.renga_url.clone(),
            deployment: String::new(),
            home: Url::parse("http://home.test").unwrap(),
            resolved_at: Utc::now(),
        };
        let mut strict = config.clone();
        strict.allow_insecure_http = false;

        assert!(persisted.answers(&config));
        assert!(!persisted.answers(&strict));
        resolve(&config, &state, &Cancellation::default()).unwrap();
        server.join().unwrap();
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn refuses_a_home_that_is_not_an_origin_and_persists_nothing() {
        for home in ["http://home.test/renga", "ftp://home.test", "not a url"] {
            let (origin, server) = home_server(vec![(200, home_body(home))]);
            let state = state_directory();

            let error = resolve(
                &config(&origin, &format!("renga_intake_{SECRET}")),
                &state,
                &Cancellation::default(),
            )
            .unwrap_err();

            server.join().unwrap();
            assert!(!error.transient(), "{home}: {error}");
            assert!(!state.join(HOME_FILE).exists());
            let _ = fs::remove_dir_all(state);
        }
    }

    #[test]
    fn a_resolver_that_knows_no_deployment_is_a_permanent_failure() {
        let (origin, server) = home_server(vec![(404, r#"{"error":"not_found"}"#.into())]);
        let state = state_directory();

        let error = resolve(
            &config(&origin, &format!("renga_intake_zz_{SECRET}")),
            &state,
            &Cancellation::default(),
        )
        .unwrap_err();

        server.join().unwrap();
        assert!(!error.transient());
        assert!(error.to_string().contains("404"));
        let _ = fs::remove_dir_all(state);
    }

    #[test]
    fn an_unreachable_resolver_is_transient() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let state = state_directory();

        let error = resolve(
            &config(&origin, &format!("renga_intake_{SECRET}")),
            &state,
            &Cancellation::default(),
        )
        .unwrap_err();

        assert!(error.transient(), "{error}");
        let _ = fs::remove_dir_all(state);
    }
}
