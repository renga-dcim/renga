//! Blocking HTTP transport and bounded retry policy.

use crate::{
    cancellation::Cancellation,
    config::{Auth, Config, DELIVERY_BUDGET},
    enrollment::{proof, runtime_transcript},
    payload::{CheckIn, Observation, MAX_OBSERVATION_BYTES},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signer, SigningKey};
use rand::{rngs::OsRng, RngCore};
use reqwest::{
    blocking::{Client, Response},
    header::{HeaderValue, AUTHORIZATION},
    redirect::Policy,
    StatusCode, Url,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{fmt, io::Read, thread, time::Duration};

const MAX_ERROR_BODY: usize = 512;
const CHECKIN_PATH: &str = "/api/v1/agent/checkins";
const OBSERVATION_PATH: &str = "/api/v1/observations";
const KEY_CHECKIN_PATH: &str = "/api/v1/key/agent/checkins";
const KEY_OBSERVATION_PATH: &str = "/api/v1/key/observations";
const INSTALLATION_ID_HEADER: &str = "x-renga-installation-id";
const BACKOFF_SLICE: Duration = Duration::from_millis(25);
const MAX_PROTOCOL_BODY: usize = 16 * 1024;

#[derive(Debug, Clone)]
pub struct TransportError {
    message: String,
    transient: bool,
}

impl TransportError {
    fn new(message: String, transient: bool) -> Self {
        Self { message, transient }
    }

    fn cancelled() -> Self {
        Self::new("HTTP delivery cancelled".into(), false)
    }

    pub fn is_cancelled(&self) -> bool {
        self.message == "HTTP delivery cancelled"
    }
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for TransportError {}

#[derive(Clone)]
pub struct HttpClient {
    client: Client,
    checkin_url: Url,
    observation_url: Url,
    authorization: HeaderValue,
    signing: Option<SigningKey>,
    installation_id: HeaderValue,
    attempts: u32,
    request_timeout: Duration,
    cancellation: Cancellation,
}

impl HttpClient {
    pub fn new(config: &Config, cancellation: Cancellation) -> Result<Self, TransportError> {
        Self::new_with_enrollment_sleep(config, cancellation, thread::sleep)
    }

    fn new_with_enrollment_sleep(
        config: &Config,
        cancellation: Cancellation,
        enrollment_sleep: impl FnMut(Duration),
    ) -> Result<Self, TransportError> {
        let has_explicit_authority = config
            .renga_url
            .split_once("://")
            .is_some_and(|(_, authority)| !authority.is_empty() && !authority.starts_with('/'));
        let base_url = Url::parse(&config.renga_url)
            .map_err(|_| TransportError::new("invalid Renga server URL".into(), false))?;
        if base_url.scheme() == "http" && !config.allow_insecure_http {
            return Err(TransportError::new(
                "Renga server URL must use HTTPS unless insecure HTTP is explicitly enabled".into(),
                false,
            ));
        }
        // The agent API is rooted at the origin. Rejecting base paths avoids silently
        // discarding an operator-supplied path when joining absolute API routes.
        if !has_explicit_authority
            || !matches!(base_url.scheme(), "http" | "https")
            || base_url.host_str().is_none()
            || !base_url.username().is_empty()
            || base_url.password().is_some()
            || base_url.query().is_some()
            || base_url.fragment().is_some()
            || base_url.path() != "/"
        {
            return Err(TransportError::new(
                "Renga server URL must be an HTTP(S) origin without credentials, path, query, or fragment"
                    .into(),
                false,
            ));
        }
        let client = Client::builder()
            .timeout(config.request_timeout)
            .redirect(Policy::none())
            .build()
            .map_err(|e| TransportError::new(format!("cannot build HTTP client: {e}"), false))?;
        let (checkin_path, observation_path, authorization, installation, signing) =
            match &config.auth {
                Auth::LegacyToken {
                    token,
                    installation_id,
                } => (
                    CHECKIN_PATH,
                    OBSERVATION_PATH,
                    format!("Bearer {token}"),
                    *installation_id,
                    None,
                ),
                Auth::Enrolled {
                    organization,
                    profile,
                    oidc_token_file,
                    state_path,
                } => {
                    let (store, mut state) =
                        crate::state::Store::open(state_path).map_err(|_| {
                            TransportError::new("cannot open enrollment state".into(), false)
                        })?;
                    if state.credential_id.is_none() {
                        enroll(
                            &client,
                            &base_url,
                            organization,
                            profile,
                            oidc_token_file,
                            &store,
                            &mut state,
                            config.max_retry_attempts,
                            enrollment_sleep,
                            &cancellation,
                        )?;
                    }
                    if state.credential_expires_at.is_some_and(|expiry| {
                        expiry < chrono::Utc::now() + chrono::Duration::hours(12)
                    }) {
                        renew(
                            &client,
                            &base_url,
                            &store,
                            &mut state,
                            config.max_retry_attempts,
                            config.request_timeout,
                            &cancellation,
                        )?;
                    }
                    let credential = state.credential_id.clone().ok_or_else(|| {
                        TransportError::new("enrollment did not issue a credential".into(), false)
                    })?;
                    (
                        KEY_CHECKIN_PATH,
                        KEY_OBSERVATION_PATH,
                        format!("RengaKey {credential}"),
                        state.installation_id,
                        Some(state.signing_key()),
                    )
                }
            };
        let checkin_url = endpoint_url(&base_url, checkin_path)?;
        let observation_url = endpoint_url(&base_url, observation_path)?;
        let mut authorization = HeaderValue::from_str(&authorization)
            .map_err(|_| TransportError::new("invalid authorization credential".into(), false))?;
        authorization.set_sensitive(true);
        let installation_id = HeaderValue::from_str(&installation.to_string())
            .map_err(|_| TransportError::new("invalid installation ID".into(), false))?;
        Ok(Self {
            client,
            checkin_url,
            observation_url,
            authorization,
            signing,
            installation_id,
            attempts: config.max_retry_attempts,
            request_timeout: config.request_timeout,
            cancellation,
        })
    }
    pub fn post_checkin(&self, value: &CheckIn) -> Result<(), TransportError> {
        self.post(self.checkin_url.clone(), value)
    }
    pub fn post_observation(&self, value: &Observation) -> Result<(), TransportError> {
        let body = serde_json::to_vec(value).map_err(|_| {
            TransportError::new("cannot serialize observation payload".into(), false)
        })?;
        if body.len() > MAX_OBSERVATION_BYTES {
            return Err(TransportError::new(
                format!(
                    "encoded observation exceeds {MAX_OBSERVATION_BYTES}-byte limit (encoded size: {} bytes)",
                    body.len()
                ),
                false,
            ));
        }
        self.post_encoded_observation(body)
    }

    fn post_encoded_observation(&self, body: Vec<u8>) -> Result<(), TransportError> {
        retry(
            self.attempts,
            self.request_timeout,
            || {
                let response = self
                    .request(self.observation_url.clone(), body.clone())?
                    .send()
                    .map_err(request_error)?;
                response_result(response)
            },
            thread::sleep,
            &self.cancellation,
        )
    }
    fn post<T: Serialize>(&self, url: Url, value: &T) -> Result<(), TransportError> {
        let body = serde_json::to_vec(value)
            .map_err(|_| TransportError::new("cannot serialize request payload".into(), false))?;
        retry(
            self.attempts,
            self.request_timeout,
            || {
                let response = self
                    .request(url.clone(), body.clone())?
                    .send()
                    .map_err(request_error)?;
                response_result(response)
            },
            thread::sleep,
            &self.cancellation,
        )
    }
    fn request(
        &self,
        url: Url,
        body: Vec<u8>,
    ) -> Result<reqwest::blocking::RequestBuilder, TransportError> {
        let mut r = self
            .client
            .post(url.clone())
            .header(AUTHORIZATION, self.authorization.clone())
            .header(INSTALLATION_ID_HEADER, self.installation_id.clone())
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body.clone());
        if let Some(key) = &self.signing {
            let mut nonce = [0u8; 32];
            OsRng.fill_bytes(&mut nonce);
            let n = URL_SAFE_NO_PAD.encode(nonce);
            let ts = chrono::Utc::now().timestamp();
            let installation = uuid::Uuid::parse_str(self.installation_id.to_str().unwrap())
                .map_err(|_| TransportError::new("invalid installation ID".into(), false))?;
            let credential = self
                .authorization
                .to_str()
                .map_err(|_| TransportError::new("invalid credential".into(), false))?
                .strip_prefix("RengaKey ")
                .unwrap();
            let sig = URL_SAFE_NO_PAD.encode(
                key.sign(&runtime_transcript(
                    credential,
                    installation,
                    &request_target(&url),
                    ts,
                    &n,
                    &body,
                ))
                .to_bytes(),
            );
            r = r
                .header("x-renga-timestamp", ts)
                .header("x-renga-nonce", n)
                .header("x-renga-signature", sig);
        }
        Ok(r)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChallengeProof {
    version: String,
    algorithm: String,
    canonicalization: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChallengeResponse {
    challenge_id: String,
    nonce: String,
    expires_at: chrono::DateTime<chrono::Utc>,
    proof: ChallengeProof,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AcceptedResponse {
    status: String,
    source_id: String,
    agent_id: String,
    credential_id: String,
    credential_expires_at: chrono::DateTime<chrono::Utc>,
    assignments: serde_json::Value,
    grants: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RenewalResponse {
    credential_id: String,
    expires_at: chrono::DateTime<chrono::Utc>,
}

// Enrollment keeps the transport, durable store, retry policy, and cancellation
// boundary explicit; grouping them would obscure which inputs are security-sensitive.
#[allow(clippy::too_many_arguments)]
fn enroll(
    client: &Client,
    base: &Url,
    organization: &str,
    profile: &str,
    token_file: &std::path::Path,
    store: &crate::state::Store,
    state: &mut crate::state::State,
    attempts: u32,
    sleep: impl FnMut(Duration),
    cancellation: &Cancellation,
) -> Result<(), TransportError> {
    let key = state.signing_key();
    let response = client.post(endpoint_url(base,"/api/v1/enrollment/challenges")?)
        .json(&serde_json::json!({"organization":organization,"profile":profile,"installation_id":state.installation_id,"public_key":URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes())}))
        .send().map_err(request_error)?;
    let challenge: ChallengeResponse = protocol_response(response)?;
    let challenge_uuid = uuid::Uuid::parse_str(&challenge.challenge_id)
        .map_err(|_| invalid_protocol("enrollment challenge"))?;
    if challenge_uuid.to_string() != challenge.challenge_id
        || challenge.expires_at <= chrono::Utc::now()
        || challenge.proof.version != "renga-enrollment-proof-v1"
        || challenge.proof.algorithm != "Ed25519"
        || challenge.proof.canonicalization != "renga-canonical-v1"
    {
        return Err(invalid_protocol("enrollment challenge"));
    }
    let nonce = canonical_bytes(&challenge.nonce, 32)
        .ok_or_else(|| invalid_protocol("enrollment challenge"))?;
    let token = std::fs::read_to_string(token_file)
        .map_err(|_| TransportError::new("cannot read OIDC token file".into(), false))?;
    let evidence = serde_json::json!({"kind":"oidc","token":token.trim()});
    let requested = serde_json::json!([]);
    let metadata = serde_json::json!({"agent_version":env!("CARGO_PKG_VERSION")});
    let signature = proof(
        &key,
        &challenge.challenge_id,
        &nonce,
        state.installation_id,
        &evidence,
        &requested,
        &metadata,
    );
    let attempt_body = serde_json::to_vec(&serde_json::json!({"challenge_id":challenge.challenge_id,"nonce":challenge.nonce,"evidence":evidence,"requested_capabilities":requested,"metadata":metadata,"proof":signature}))
        .map_err(|_| invalid_protocol("enrollment attempt"))?;
    let accepted: AcceptedResponse = retry_unbudgeted(
        attempts,
        || {
            let response = client
                .post(endpoint_url(base, "/api/v1/enrollment/attempts")?)
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(attempt_body.clone())
                .send()
                .map_err(request_error)?;
            protocol_response(response)
        },
        sleep,
        cancellation,
    )?;
    if accepted.status != "accepted"
        || !crate::state::canonical_credential(&accepted.credential_id)
        || accepted.credential_expires_at <= chrono::Utc::now()
    {
        return Err(invalid_protocol("enrollment acceptance"));
    }
    let _ = (
        &accepted.source_id,
        &accepted.agent_id,
        &accepted.assignments,
        &accepted.grants,
    );
    let mut next = state.clone();
    next.credential_id = Some(accepted.credential_id);
    next.credential_expires_at = Some(accepted.credential_expires_at);
    store
        .save(&next)
        .map_err(|_| TransportError::new("cannot persist enrollment state".into(), false))?;
    *state = next;
    Ok(())
}

fn renew(
    client: &Client,
    base: &Url,
    store: &crate::state::Store,
    state: &mut crate::state::State,
    attempts: u32,
    timeout: Duration,
    cancellation: &Cancellation,
) -> Result<(), TransportError> {
    let target = "/api/v1/key/agent/credentials/renew";
    let body = b"{}";
    let credential = state
        .credential_id
        .as_deref()
        .ok_or_else(|| TransportError::new("missing credential".into(), false))?;
    let old_expiry = state
        .credential_expires_at
        .ok_or_else(|| invalid_protocol("enrollment state"))?;
    let result: RenewalResponse = retry(
        attempts,
        timeout,
        || {
            let mut raw = [0u8; 32];
            OsRng.fill_bytes(&mut raw);
            let nonce = URL_SAFE_NO_PAD.encode(raw);
            let timestamp = chrono::Utc::now().timestamp();
            let signature = URL_SAFE_NO_PAD.encode(
                state
                    .signing_key()
                    .sign(&runtime_transcript(
                        credential,
                        state.installation_id,
                        target,
                        timestamp,
                        &nonce,
                        body,
                    ))
                    .to_bytes(),
            );
            let response = client
                .post(endpoint_url(base, target)?)
                .header(AUTHORIZATION, format!("RengaKey {credential}"))
                .header(INSTALLATION_ID_HEADER, state.installation_id.to_string())
                .header("content-type", "application/json")
                .header("x-renga-timestamp", timestamp)
                .header("x-renga-nonce", nonce)
                .header("x-renga-signature", signature)
                .body(body.as_slice())
                .send()
                .map_err(request_error)?;
            protocol_response(response)
        },
        thread::sleep,
        cancellation,
    )?;
    if result.credential_id != credential
        || !crate::state::canonical_credential(&result.credential_id)
        || result.expires_at <= chrono::Utc::now()
        || result.expires_at < old_expiry
    {
        return Err(invalid_protocol("credential renewal"));
    }
    let mut next = state.clone();
    next.credential_expires_at = Some(result.expires_at);
    store
        .save(&next)
        .map_err(|_| TransportError::new("cannot persist renewed credential".into(), false))?;
    *state = next;
    Ok(())
}

fn request_target(url: &Url) -> String {
    url.query().map_or_else(
        || url.path().to_owned(),
        |query| format!("{}?{query}", url.path()),
    )
}

fn canonical_bytes(value: &str, size: usize) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode(value)
        .ok()
        .filter(|bytes| bytes.len() == size && URL_SAFE_NO_PAD.encode(bytes) == value)
}

fn invalid_protocol(kind: &str) -> TransportError {
    TransportError::new(format!("invalid {kind} response"), false)
}

fn protocol_response<T: DeserializeOwned>(response: Response) -> Result<T, TransportError> {
    if !response.status().is_success() {
        response_result(response)?;
        unreachable!()
    }
    let mut bytes = Vec::new();
    response
        .take((MAX_PROTOCOL_BODY + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| TransportError::new("incomplete protocol response".into(), true))?;
    if bytes.len() > MAX_PROTOCOL_BODY {
        return Err(invalid_protocol("oversized protocol"));
    }
    serde_json::from_slice(&bytes).map_err(|error| {
        if error.is_eof() {
            TransportError::new("incomplete protocol response".into(), true)
        } else {
            invalid_protocol("protocol")
        }
    })
}

fn request_error(error: reqwest::Error) -> TransportError {
    TransportError::new(
        format!("HTTP request failed: {error}"),
        error.is_timeout() || error.is_connect() || error.is_request(),
    )
}

fn endpoint_url(base_url: &Url, path: &str) -> Result<Url, TransportError> {
    base_url
        .join(path)
        .map_err(|_| TransportError::new("cannot construct Renga API endpoint URL".into(), false))
}

fn response_result(mut response: Response) -> Result<(), TransportError> {
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    let excerpt = bounded_error_excerpt(&mut response);
    let transient = status == StatusCode::REQUEST_TIMEOUT
        || status == StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error();
    Err(TransportError::new(
        format!("server returned {status}; response excerpt: {excerpt:?}"),
        transient,
    ))
}

fn bounded_error_excerpt(reader: &mut impl Read) -> String {
    let mut bytes = Vec::with_capacity(MAX_ERROR_BODY);
    let _ = reader.take(MAX_ERROR_BODY as u64).read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).into_owned()
}

fn retry<T>(
    attempts: u32,
    request_timeout: Duration,
    mut operation: impl FnMut() -> Result<T, TransportError>,
    mut sleep: impl FnMut(Duration),
    cancellation: &Cancellation,
) -> Result<T, TransportError> {
    let started = std::time::Instant::now();
    let mut delay = Duration::from_millis(250);
    for attempt in 1..=attempts {
        if cancellation.cancelled() {
            return Err(TransportError::cancelled());
        }
        match operation() {
            Ok(value) => return Ok(value),
            Err(error) if !error.transient || attempt == attempts => return Err(error),
            Err(error) => {
                // Do not start an attempt whose configured timeout cannot fit inside the fixed
                // delivery budget; check-in interval plus this budget must remain below lease TTL.
                if started
                    .elapsed()
                    .saturating_add(delay)
                    .saturating_add(request_timeout)
                    > DELIVERY_BUDGET
                {
                    return Err(error);
                }
                let mut remaining = delay;
                while !remaining.is_zero() {
                    if cancellation.cancelled() {
                        return Err(TransportError::cancelled());
                    }
                    let slice = remaining.min(BACKOFF_SLICE);
                    sleep(slice);
                    remaining -= slice;
                }
                delay = (delay * 2).min(Duration::from_secs(8));
            }
        }
    }
    unreachable!("configuration guarantees at least one attempt")
}

fn retry_unbudgeted<T>(
    attempts: u32,
    mut operation: impl FnMut() -> Result<T, TransportError>,
    mut sleep: impl FnMut(Duration),
    cancellation: &Cancellation,
) -> Result<T, TransportError> {
    let mut delay = Duration::from_millis(250);
    for attempt in 1..=attempts {
        if cancellation.cancelled() {
            return Err(TransportError::cancelled());
        }
        match operation() {
            Ok(value) => return Ok(value),
            Err(error) if !error.transient || attempt == attempts => return Err(error),
            Err(_) => {
                let mut remaining = delay;
                while !remaining.is_zero() {
                    if cancellation.cancelled() {
                        return Err(TransportError::cancelled());
                    }
                    let slice = remaining.min(BACKOFF_SLICE);
                    sleep(slice);
                    remaining -= slice;
                }
                delay = (delay * 2).min(Duration::from_secs(8));
            }
        }
    }
    unreachable!("configuration guarantees at least one attempt")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::payload::{Component, Identifiers, ResourceKind, ServerResource};
    use serde_json::json;
    use std::{
        collections::BTreeMap,
        io::{Read, Write},
        net::TcpListener,
        path::PathBuf,
    };

    fn config(renga_url: &str, token: &str) -> Config {
        Config {
            config_path: PathBuf::from("agent.toml"),
            renga_url: renga_url.into(),
            allow_insecure_http: false,
            auth: Auth::LegacyToken {
                token: token.into(),
                installation_id: uuid::Uuid::nil(),
            },
            inventory_interval: Duration::from_secs(300),
            checkin_interval: Duration::from_secs(60),
            config_refresh_interval: Duration::from_secs(300),
            request_timeout: Duration::from_secs(30),
            max_retry_attempts: 1,
        }
    }

    fn error(transient: bool) -> TransportError {
        TransportError::new("failure".into(), transient)
    }

    fn read_request(stream: &mut impl Read) -> Vec<u8> {
        let mut request = Vec::new();
        let mut byte = [0];
        while !request.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
        }
        let headers = String::from_utf8_lossy(&request);
        let content_length = headers
            .lines()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length: ")
                    .map(str::parse::<usize>)
            })
            .unwrap()
            .unwrap();
        let mut body = vec![0; content_length];
        stream.read_exact(&mut body).unwrap();
        body
    }

    #[test]
    fn enrolled_startup_retries_an_incomplete_acceptance_with_identical_body() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let credential = URL_SAFE_NO_PAD.encode([9_u8; 32]);
        let expected_credential = credential.clone();
        let challenge = serde_json::to_vec(&json!({
            "challenge_id": uuid::Uuid::new_v4().to_string(),
            "nonce": URL_SAFE_NO_PAD.encode([4_u8; 32]),
            "expires_at": chrono::Utc::now() + chrono::Duration::hours(1),
            "proof": {
                "version": "renga-enrollment-proof-v1",
                "algorithm": "Ed25519",
                "canonicalization": "renga-canonical-v1"
            }
        }))
        .unwrap();
        let accepted = serde_json::to_vec(&json!({
            "status": "accepted",
            "source_id": uuid::Uuid::new_v4().to_string(),
            "agent_id": uuid::Uuid::new_v4().to_string(),
            "credential_id": credential,
            "credential_expires_at": chrono::Utc::now() + chrono::Duration::days(2),
            "assignments": [],
            "grants": []
        }))
        .unwrap();
        let server = std::thread::spawn(move || {
            let mut attempt_bodies = Vec::new();
            for request_number in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let body = read_request(&mut stream);
                let response = match request_number {
                    0 => challenge.as_slice(),
                    1 => {
                        attempt_bodies.push(body);
                        &accepted[..accepted.len() / 2]
                    }
                    _ => {
                        attempt_bodies.push(body);
                        accepted.as_slice()
                    }
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    response.len()
                )
                .unwrap();
                stream.write_all(response).unwrap();
            }
            attempt_bodies
        });

        let root = std::env::temp_dir().join(format!("renga-enrollment-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let token_path = root.join("oidc-token");
        let state_path = root.join("state");
        std::fs::write(&token_path, "test-oidc-token\n").unwrap();
        let mut enrolled = config(&format!("http://{address}"), "unused");
        enrolled.allow_insecure_http = true;
        enrolled.max_retry_attempts = 2;
        enrolled.auth = Auth::Enrolled {
            organization: "test-org".into(),
            profile: "default".into(),
            oidc_token_file: token_path,
            state_path: state_path.clone(),
        };

        let client =
            HttpClient::new_with_enrollment_sleep(&enrolled, Cancellation::default(), |_| {})
                .unwrap();
        assert_eq!(
            client.authorization.to_str().unwrap(),
            format!("RengaKey {expected_credential}")
        );
        let attempts = server.join().unwrap();
        assert_eq!(attempts.len(), 2);
        assert_eq!(attempts[0], attempts[1]);
        let (_, state) = crate::state::Store::open(&state_path).unwrap();
        assert_eq!(
            state.credential_id.as_deref(),
            Some(expected_credential.as_str())
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn error_excerpt_never_reads_beyond_its_byte_limit() {
        let mut body = std::io::Cursor::new(vec![b'x'; MAX_ERROR_BODY * 4]);

        let excerpt = bounded_error_excerpt(&mut body);

        assert_eq!(excerpt.len(), MAX_ERROR_BODY);
        assert_eq!(body.position(), MAX_ERROR_BODY as u64);
    }

    fn oversized_observation() -> Observation {
        Observation::new(ServerResource {
            kind: ResourceKind::Server,
            identifiers: Identifiers {
                hostname: "host".into(),
                ..Default::default()
            },
            attributes: None,
            interfaces: None,
            components: vec![Component {
                kind: "generated_regression".into(),
                attributes: BTreeMap::from([(
                    "content".into(),
                    json!("x".repeat(MAX_OBSERVATION_BYTES)),
                )]),
            }],
        })
    }

    #[test]
    fn uses_the_server_api_routes() {
        assert_eq!(CHECKIN_PATH, "/api/v1/agent/checkins");
        assert_eq!(OBSERVATION_PATH, "/api/v1/observations");
    }

    #[test]
    fn signed_request_target_includes_query_verbatim() {
        let url =
            Url::parse("https://renga.test/api/v1/key/observations?cursor=a%2Fb&n=1").unwrap();
        assert_eq!(
            request_target(&url),
            "/api/v1/key/observations?cursor=a%2Fb&n=1"
        );
    }

    #[test]
    fn validates_and_builds_exact_endpoint_urls_and_authorization() {
        for base in ["https://renga.test", "https://renga.test/"] {
            let client =
                HttpClient::new(&config(base, "valid-token"), Cancellation::default()).unwrap();
            assert_eq!(
                client.checkin_url.as_str(),
                "https://renga.test/api/v1/agent/checkins"
            );
            assert_eq!(
                client.observation_url.as_str(),
                "https://renga.test/api/v1/observations"
            );
            assert_eq!(client.authorization.to_str().unwrap(), "Bearer valid-token");
            assert_eq!(
                client.installation_id.to_str().unwrap(),
                uuid::Uuid::nil().to_string()
            );
        }
    }

    #[test]
    fn rejects_plaintext_http_by_default() {
        let result = HttpClient::new(
            &config("http://renga.test", "valid-token"),
            Cancellation::default(),
        );
        assert!(result.is_err(), "accepted a plaintext HTTP origin");
    }

    #[test]
    fn rejects_encoded_observation_over_phoenix_limit_before_network_attempt() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let mut config = config(
            &format!("http://{}", listener.local_addr().unwrap()),
            "valid-token",
        );
        config.allow_insecure_http = true;
        let client = HttpClient::new(&config, Cancellation::default()).unwrap();
        let observation = oversized_observation();
        assert!(serde_json::to_vec(&observation).unwrap().len() > MAX_OBSERVATION_BYTES);

        let error = client.post_observation(&observation).unwrap_err();

        assert!(!error.transient);
        assert!(error.to_string().contains("exceeds 256000-byte limit"));
        assert!(matches!(
            listener.accept(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
        ));
    }

    #[test]
    fn does_not_follow_redirects_and_treats_them_as_permanent() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for stream in listener.incoming().take(1) {
                let mut stream = stream.unwrap();
                let mut request = [0; 4096];
                let _ = stream.read(&mut request).unwrap();
                write!(
                    stream,
                    "HTTP/1.1 302 Found\r\nLocation: http://{address}/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
                .unwrap();
            }
        });

        let mut config = config(&format!("http://{address}"), "valid-token");
        config.allow_insecure_http = true;
        let client = HttpClient::new(&config, Cancellation::default()).unwrap();
        let error = client
            .post(client.checkin_url.clone(), &serde_json::json!({}))
            .unwrap_err();

        assert!(error.to_string().contains("302 Found"));
        assert!(!error.transient, "redirects must not be retried");
        server.join().unwrap();
    }

    #[test]
    fn rejects_malformed_or_unsafe_server_urls_at_construction() {
        for url in [
            "http://",
            "http:///missing-host",
            "ftp://renga.test",
            "https://user:pass@renga.test",
            "https://renga.test?query=yes",
            "https://renga.test/#fragment",
            "https://renga.test/base",
        ] {
            assert!(
                HttpClient::new(&config(url, "valid-token"), Cancellation::default()).is_err(),
                "accepted {url}"
            );
        }
    }

    #[test]
    fn rejects_invalid_bearer_header_without_exposing_token() {
        let token = "secret\nInjected: value";
        let error = match HttpClient::new(
            &config("https://renga.test", token),
            Cancellation::default(),
        ) {
            Ok(_) => panic!("accepted invalid bearer token"),
            Err(error) => error,
        };
        assert!(!error.to_string().contains(token));
        assert!(!format!("{error:?}").contains(token));
    }

    #[test]
    fn succeeds_after_transients() {
        let mut calls = 0;
        let mut sleeps = vec![];
        let cancellation = Cancellation::default();
        let result = retry(
            3,
            Duration::ZERO,
            || {
                calls += 1;
                if calls < 3 {
                    Err(error(true))
                } else {
                    Ok(7)
                }
            },
            |d| sleeps.push(d),
            &cancellation,
        );
        assert_eq!(result.unwrap(), 7);
        assert_eq!(sleeps, vec![Duration::from_millis(25); 30]);
    }
    #[test]
    fn stops_on_permanent_response() {
        let mut calls = 0;
        let cancellation = Cancellation::default();
        assert!(retry::<()>(
            5,
            Duration::ZERO,
            || {
                calls += 1;
                Err(error(false))
            },
            |_| {},
            &cancellation
        )
        .is_err());
        assert_eq!(calls, 1);
    }
    #[test]
    fn exhausts_total_attempts() {
        let mut calls = 0;
        let cancellation = Cancellation::default();
        assert!(retry::<()>(
            3,
            Duration::ZERO,
            || {
                calls += 1;
                Err(error(true))
            },
            |_| {},
            &cancellation
        )
        .is_err());
        assert_eq!(calls, 3);
    }

    #[test]
    fn retry_does_not_start_an_attempt_that_cannot_fit_delivery_budget() {
        let mut calls = 0;
        let cancellation = Cancellation::default();

        assert!(retry::<()>(
            5,
            DELIVERY_BUDGET,
            || {
                calls += 1;
                Err(error(true))
            },
            |_| {},
            &cancellation
        )
        .is_err());
        assert_eq!(calls, 1);
    }

    #[test]
    fn already_cancelled_makes_no_attempt() {
        let cancellation = Cancellation::default();
        cancellation.cancel();
        let mut calls = 0;
        let failure = retry::<()>(
            3,
            Duration::ZERO,
            || {
                calls += 1;
                Ok(())
            },
            |_| panic!("cancelled delivery must not back off"),
            &cancellation,
        )
        .unwrap_err();
        assert_eq!(calls, 0);
        assert!(failure.is_cancelled());
        assert_eq!(failure.to_string(), "HTTP delivery cancelled");
    }

    #[test]
    fn cancellation_during_backoff_prevents_the_next_attempt() {
        let cancellation = Cancellation::default();
        let from_sleep = cancellation.clone();
        let mut calls = 0;
        let mut sleeps = 0;
        let failure = retry::<()>(
            3,
            Duration::ZERO,
            || {
                calls += 1;
                Err(error(true))
            },
            |_| {
                sleeps += 1;
                from_sleep.cancel();
            },
            &cancellation,
        )
        .unwrap_err();
        assert_eq!(calls, 1);
        assert_eq!(sleeps, 1);
        assert!(failure.is_cancelled());
    }
}
