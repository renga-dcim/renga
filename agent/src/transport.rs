//! Blocking HTTP transport and bounded retry policy.

use crate::{
    cancellation::Cancellation,
    config::{Config, DELIVERY_BUDGET},
    installation_key::InstallationKey,
    payload::{
        AgentHome, CheckIn, CheckInAck, JobClaim, JobOffer, JobReport, LeaseRequest, LeaseResponse,
        LeasedJob, Observation, ReportAck, MAX_OBSERVATION_BYTES,
    },
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use reqwest::{
    blocking::{Client, Response},
    header::{HeaderValue, AUTHORIZATION},
    redirect::Policy,
    StatusCode, Url,
};
use serde::{de::DeserializeOwned, Serialize};
use std::{
    fmt,
    io::Read,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::Duration,
};
use tracing::warn;

const MAX_ERROR_BODY: usize = 512;
const CHECKIN_PATH: &str = "/api/v1/agent/checkins";
const OBSERVATION_PATH: &str = "/api/v1/observations";
const JOB_LEASE_PATH: &str = "/api/v1/agent/jobs/lease";
const HOME_PATH: &str = "/api/v1/agent/home";
const INSTALLATION_ID_HEADER: &str = "x-renga-installation-id";
const BACKOFF_SLICE: Duration = Duration::from_millis(25);
/// Ten leased jobs with their parameters fit well inside this; anything
/// larger is not a response this agent understands.
const MAX_RESPONSE_BODY: u64 = 1024 * 1024;

/// How a failed delivery should be treated by whoever holds the payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureKind {
    /// The network or server may recover: timeouts, connection failures, 408, 429, and 5xx.
    Transient,
    /// The server will never accept this exact payload: it is malformed, too large, or its
    /// observation ID was already used for a different payload. Retrying it cannot succeed.
    PayloadRejected,
    /// Everything else, such as revoked credentials, enrollment conflicts, redirects, or local
    /// setup errors. The payload itself may be fine once an operator fixes the cause.
    Permanent,
}

#[derive(Debug, Clone)]
pub struct TransportError {
    message: String,
    kind: FailureKind,
    status: Option<StatusCode>,
    moved: bool,
}

impl TransportError {
    pub(crate) fn new(message: String, kind: FailureKind) -> Self {
        Self {
            message,
            kind,
            status: None,
            moved: false,
        }
    }

    pub(crate) fn with_status(self, status: StatusCode) -> Self {
        Self {
            status: Some(status),
            ..self
        }
    }

    /// The HTTP status of a response the server sent, if it sent one.
    pub fn status(&self) -> Option<StatusCode> {
        self.status
    }

    fn cancelled() -> Self {
        Self::new("HTTP delivery cancelled".into(), FailureKind::Permanent)
    }

    pub fn kind(&self) -> FailureKind {
        self.kind
    }

    /// Whether the home said this agent's organization now lives on another deployment.
    pub fn is_moved(&self) -> bool {
        self.moved
    }

    fn transient(&self) -> bool {
        self.kind == FailureKind::Transient
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
    base_url: Url,
    checkin_url: Url,
    observation_url: Url,
    lease_url: Url,
    authorization: HeaderValue,
    installation_id: HeaderValue,
    installation: uuid::Uuid,
    installation_key: Option<Arc<InstallationKey>>,
    notices: NoticeEndpoint,
    attempts: u32,
    request_timeout: Duration,
    cancellation: Cancellation,
    /// Raised by any clone that hears `410 moved`, so the daemon resolves the home again.
    moved: Arc<AtomicBool>,
}

impl HttpClient {
    /// A client that sends every request to the configured `renga_url` itself.
    pub fn new(config: &Config, cancellation: Cancellation) -> Result<Self, TransportError> {
        let base_url = origin_url(
            &config.renga_url,
            config.allow_insecure_http,
            "Renga server URL",
        )?;
        Self::for_home(config, &base_url, cancellation)
    }

    /// A client that sends every request to `home`, the deployment `renga_url` resolved to.
    pub fn for_home(
        config: &Config,
        home: &Url,
        cancellation: Cancellation,
    ) -> Result<Self, TransportError> {
        let base_url = origin_url(home.as_str(), config.allow_insecure_http, "home URL")?;
        let checkin_url = endpoint_url(&base_url, CHECKIN_PATH)?;
        let observation_url = endpoint_url(&base_url, OBSERVATION_PATH)?;
        let lease_url = endpoint_url(&base_url, JOB_LEASE_PATH)?;
        let mut authorization = HeaderValue::from_str(&format!("Bearer {}", config.intake_api_key))
            .map_err(|_| {
                TransportError::new("invalid intake API key".into(), FailureKind::Permanent)
            })?;
        authorization.set_sensitive(true);
        let installation_id =
            HeaderValue::from_str(&config.installation_id.to_string()).map_err(|_| {
                TransportError::new("invalid installation ID".into(), FailureKind::Permanent)
            })?;
        let tls = pinned_tls()?;
        // The notice socket shares the same pinned TLS settings and credentials.
        let notices = NoticeEndpoint {
            base_url: base_url.clone(),
            intake_api_key: config.intake_api_key.clone(),
            installation_id: config.installation_id.to_string(),
            tls: Arc::new(tls.clone()),
            timeout: config.request_timeout,
        };
        Ok(Self {
            client: build_client(tls, config.request_timeout)?,
            base_url,
            checkin_url,
            observation_url,
            lease_url,
            authorization,
            installation_id,
            installation: config.installation_id,
            installation_key: None,
            notices,
            attempts: config.max_retry_attempts,
            request_timeout: config.request_timeout,
            cancellation,
            moved: Arc::default(),
        })
    }
    /// Signs claims of privileged job offers with `key` (RFD 13). Without
    /// one, the client leases only `observe` jobs.
    pub fn with_installation_key(self, key: Arc<InstallationKey>) -> Self {
        Self {
            installation_key: Some(key),
            ..self
        }
    }

    /// The origin every request goes to.
    pub fn home(&self) -> &Url {
        &self.base_url
    }

    /// Whether a request heard `410 moved` since the last call, clearing the flag.
    pub fn take_moved(&self) -> bool {
        self.moved.swap(false, Ordering::SeqCst)
    }

    /// Shares `previous`'s move signal, for a client that replaces it without changing the home,
    /// so a worker still holding the previous client can report a move. A client for a new home
    /// keeps its own signal, so the old home's answers are ignored.
    pub fn sharing_moved_signal(mut self, previous: &HttpClient) -> Self {
        if self.base_url == previous.base_url {
            self.moved = Arc::clone(&previous.moved);
        }
        self
    }

    fn noting_moved<T>(&self, result: Result<T, TransportError>) -> Result<T, TransportError> {
        if result.as_ref().is_err_and(TransportError::is_moved) {
            self.moved.store(true, Ordering::SeqCst);
        }
        result
    }

    /// Where and how to open the job notice socket (see `crate::notices`).
    pub fn notice_endpoint(&self) -> NoticeEndpoint {
        self.notices.clone()
    }

    /// Posts a check-in. A body the agent cannot read still means the
    /// check-in was accepted, so it yields an empty acknowledgement.
    pub fn post_checkin(&self, value: &CheckIn) -> Result<CheckInAck, TransportError> {
        let body = self.post_reading(self.checkin_url.clone(), value)?;
        Ok(serde_json::from_slice(&body).unwrap_or_default())
    }

    /// Leases up to `limit` queued jobs for the given `name@version` keys,
    /// claiming each privileged job Renga offers with the installation key.
    pub fn lease_jobs(
        &self,
        capabilities: &[String],
        limit: u32,
    ) -> Result<Vec<LeasedJob>, TransportError> {
        let request = LeaseRequest {
            capabilities,
            limit,
        };
        let response: LeaseResponse = self.post_json(self.lease_url.clone(), &request)?;
        let mut jobs = response.jobs;
        for offer in &response.offers {
            match self.claim_offer(offer) {
                Ok(job) => jobs.push(job),
                // A lapsed offer is offered again, and a job whose resource was
                // rebound has failed in Renga, so the other offers still lease.
                Err(error) => {
                    warn!(job_id = %offer.job_id, error = %error, "cannot claim job offer");
                }
            }
        }
        Ok(jobs)
    }

    /// Signs and posts the claim that leases an offered privileged job.
    fn claim_offer(&self, offer: &JobOffer) -> Result<LeasedJob, TransportError> {
        let key = self.installation_key.as_ref().ok_or_else(|| {
            TransportError::new(
                "no installation key to claim a privileged job".into(),
                FailureKind::Permanent,
            )
        })?;
        let url = endpoint_url(
            &self.base_url,
            &format!("/api/v1/agent/jobs/{}/claims", offer.job_id),
        )?;
        let claim = JobClaim {
            lease_token: &offer.lease_token,
            nonce: &offer.nonce,
            signature: URL_SAFE_NO_PAD.encode(key.sign(&offer.message(self.installation))),
        };
        self.post_json(url, &claim)
    }

    /// Posts one numbered report on a leased job. Retries resend the same
    /// sequence, which Renga records once.
    pub fn post_job_report(
        &self,
        job_id: uuid::Uuid,
        report: &JobReport<'_>,
    ) -> Result<ReportAck, TransportError> {
        let url = endpoint_url(
            &self.base_url,
            &format!("/api/v1/agent/jobs/{job_id}/events"),
        )?;
        self.post_json(url, report)
    }
    pub fn post_observation(&self, value: &Observation) -> Result<(), TransportError> {
        self.post_encoded_observation(&encode_observation(value)?)
    }

    /// Posts an observation exactly as encoded, so a queued payload replays byte for byte and
    /// the server can recognize a repeat by its observation ID.
    pub fn post_encoded_observation(&self, body: &[u8]) -> Result<(), TransportError> {
        self.post_encoded_observation_while(body, || self.cancellation.cancelled())
    }

    /// Posts an observation while both the daemon and the operation that produced it remain
    /// active. Jobs use this so cancellation also interrupts retry backoff.
    pub fn post_encoded_observation_with_cancellation(
        &self,
        body: &[u8],
        cancellation: &Cancellation,
    ) -> Result<(), TransportError> {
        self.post_encoded_observation_while(body, || {
            self.cancellation.cancelled() || cancellation.cancelled()
        })
    }

    fn post_encoded_observation_while(
        &self,
        body: &[u8],
        cancelled: impl Fn() -> bool,
    ) -> Result<(), TransportError> {
        self.noting_moved(retry(
            self.attempts,
            self.request_timeout,
            || {
                let response = self
                    .client
                    .post(self.observation_url.clone())
                    .header(AUTHORIZATION, self.authorization.clone())
                    .header(INSTALLATION_ID_HEADER, self.installation_id.clone())
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(body.to_vec())
                    .send()
                    .map_err(request_error)?;
                response_result(response)
            },
            thread::sleep,
            cancelled,
        ))
    }
    fn post_json<T: Serialize, R: DeserializeOwned>(
        &self,
        url: Url,
        value: &T,
    ) -> Result<R, TransportError> {
        let body = self.post_reading(url, value)?;
        serde_json::from_slice(&body).map_err(|error| {
            TransportError::new(
                format!("cannot parse server response: {error}"),
                FailureKind::Permanent,
            )
        })
    }

    /// Posts JSON and returns the successful response's body.
    fn post_reading<T: Serialize>(&self, url: Url, value: &T) -> Result<Vec<u8>, TransportError> {
        self.noting_moved(retry(
            self.attempts,
            self.request_timeout,
            || {
                let response = self
                    .client
                    .post(url.clone())
                    .header(AUTHORIZATION, self.authorization.clone())
                    .header(INSTALLATION_ID_HEADER, self.installation_id.clone())
                    .json(value)
                    .send()
                    .map_err(request_error)?;
                response_body(response)
            },
            thread::sleep,
            || self.cancellation.cancelled(),
        ))
    }
}

/// The server origin, credentials and TLS settings the notice socket uses.
#[derive(Clone)]
pub struct NoticeEndpoint {
    pub base_url: Url,
    pub intake_api_key: String,
    pub installation_id: String,
    pub tls: Arc<rustls::ClientConfig>,
    /// Bounds connecting and the opening handshake.
    pub timeout: Duration,
}

impl fmt::Debug for NoticeEndpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NoticeEndpoint")
            .field("base_url", &self.base_url.as_str())
            .field("intake_api_key", &"[REDACTED]")
            .field("installation_id", &self.installation_id)
            .finish()
    }
}

/// Encodes an observation for delivery, refusing one the API could never parse.
pub fn encode_observation(value: &Observation) -> Result<Vec<u8>, TransportError> {
    let body = serde_json::to_vec(value).map_err(|_| {
        TransportError::new(
            "cannot serialize observation payload".into(),
            FailureKind::PayloadRejected,
        )
    })?;
    if body.len() > MAX_OBSERVATION_BYTES {
        return Err(TransportError::new(
            format!(
                "encoded observation exceeds {MAX_OBSERVATION_BYTES}-byte limit (encoded size: {} bytes)",
                body.len()
            ),
            FailureKind::PayloadRejected,
        ));
    }
    Ok(body)
}

/// Asks `renga_url` where this agent's home deployment is (RFD 23). The request carries no
/// credential, so the intake key never reaches an address that is only a resolver.
pub fn fetch_home(
    config: &Config,
    deployment: &str,
    cancellation: &Cancellation,
) -> Result<Url, TransportError> {
    let base_url = origin_url(
        &config.renga_url,
        config.allow_insecure_http,
        "Renga server URL",
    )?;
    let mut url = endpoint_url(&base_url, HOME_PATH)?;
    url.query_pairs_mut().append_pair("deployment", deployment);
    let client = build_client(pinned_tls()?, config.request_timeout)?;
    let body = retry(
        config.max_retry_attempts,
        config.request_timeout,
        || {
            let response = client.get(url.clone()).send().map_err(request_error)?;
            response_body(response)
        },
        thread::sleep,
        || cancellation.cancelled(),
    )?;
    let response: AgentHome = serde_json::from_slice(&body).map_err(|error| {
        TransportError::new(
            format!("cannot parse home response: {error}"),
            FailureKind::Permanent,
        )
    })?;
    origin_url(&response.home, config.allow_insecure_http, "home URL")
}

/// Parses an HTTP(S) origin. The agent API is rooted at the origin, so rejecting base paths
/// avoids silently discarding an operator-supplied path when joining absolute API routes.
pub(crate) fn origin_url(
    value: &str,
    allow_insecure_http: bool,
    name: &str,
) -> Result<Url, TransportError> {
    let has_explicit_authority = value
        .split_once("://")
        .is_some_and(|(_, authority)| !authority.is_empty() && !authority.starts_with('/'));
    let url = Url::parse(value)
        .map_err(|_| TransportError::new(format!("invalid {name}"), FailureKind::Permanent))?;
    if url.scheme() == "http" && !allow_insecure_http {
        return Err(TransportError::new(
            format!("{name} must use HTTPS unless insecure HTTP is explicitly enabled"),
            FailureKind::Permanent,
        ));
    }
    if !has_explicit_authority
        || !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err(TransportError::new(
            format!(
                "{name} must be an HTTP(S) origin without credentials, path, query, or fragment"
            ),
            FailureKind::Permanent,
        ));
    }
    Ok(url)
}

/// Pins both the provider and roots so static installations neither depend on a host CA store
/// nor inherit a process-global Rustls provider selected by another library.
fn pinned_tls() -> Result<rustls::ClientConfig, TransportError> {
    Ok(rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|error| {
        TransportError::new(
            format!("cannot configure TLS protocol versions: {error}"),
            FailureKind::Permanent,
        )
    })?
    .with_root_certificates(rustls::RootCertStore::from_iter(
        webpki_roots::TLS_SERVER_ROOTS.iter().cloned(),
    ))
    .with_no_client_auth())
}

fn build_client(tls: rustls::ClientConfig, timeout: Duration) -> Result<Client, TransportError> {
    Client::builder()
        .tls_backend_preconfigured(tls)
        .timeout(timeout)
        .redirect(Policy::none())
        .build()
        .map_err(|e| {
            TransportError::new(
                format!("cannot build HTTP client: {e}"),
                FailureKind::Permanent,
            )
        })
}

fn request_error(error: reqwest::Error) -> TransportError {
    let kind = if error.is_timeout() || error.is_connect() || error.is_request() {
        FailureKind::Transient
    } else {
        FailureKind::Permanent
    };
    TransportError::new(format!("HTTP request failed: {error}"), kind)
}

fn endpoint_url(base_url: &Url, path: &str) -> Result<Url, TransportError> {
    base_url.join(path).map_err(|_| {
        TransportError::new(
            "cannot construct Renga API endpoint URL".into(),
            FailureKind::Permanent,
        )
    })
}

fn response_result(mut response: Response) -> Result<(), TransportError> {
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    Err(status_error(status, &mut response))
}

fn response_body(mut response: Response) -> Result<Vec<u8>, TransportError> {
    let status = response.status();
    if !status.is_success() {
        return Err(status_error(status, &mut response));
    }
    read_bounded(&mut response, MAX_RESPONSE_BODY)
}

fn read_bounded(reader: &mut impl Read, limit: u64) -> Result<Vec<u8>, TransportError> {
    let mut bytes = Vec::new();
    reader
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            TransportError::new(
                format!("cannot read server response: {error}"),
                FailureKind::Transient,
            )
        })?;
    if bytes.len() as u64 > limit {
        return Err(TransportError::new(
            format!("server response exceeds {limit} bytes"),
            FailureKind::Permanent,
        ));
    }
    Ok(bytes)
}

fn status_error(status: StatusCode, response: &mut Response) -> TransportError {
    let excerpt = bounded_error_excerpt(response);
    TransportError {
        moved: moved(status, &excerpt),
        ..TransportError::new(
            format!("server returned {status}; response excerpt: {excerpt:?}"),
            failure_kind(status, &excerpt),
        )
        .with_status(status)
    }
}

/// `410 moved` names an organization that now lives on another deployment (RFD 23). Any other
/// `410` is not an answer the agent knows how to act on.
fn moved(status: StatusCode, excerpt: &str) -> bool {
    status == StatusCode::GONE
        && serde_json::from_str::<serde_json::Value>(excerpt)
            .is_ok_and(|body| body.get("error").and_then(|value| value.as_str()) == Some("moved"))
}

fn failure_kind(status: StatusCode, excerpt: &str) -> FailureKind {
    match status {
        StatusCode::REQUEST_TIMEOUT | StatusCode::TOO_MANY_REQUESTS => FailureKind::Transient,
        // The payload is fine; it waits for the agent to find its new home.
        StatusCode::GONE if moved(status, excerpt) => FailureKind::Transient,
        status if status.is_server_error() => FailureKind::Transient,
        StatusCode::BAD_REQUEST
        | StatusCode::PAYLOAD_TOO_LARGE
        | StatusCode::UNPROCESSABLE_ENTITY => FailureKind::PayloadRejected,
        // A conflict is about the payload only when its observation ID was reused; an
        // enrollment conflict belongs to the installation and leaves the payload deliverable.
        StatusCode::CONFLICT if rejects_path(excerpt, "observation_id") => {
            FailureKind::PayloadRejected
        }
        _ => FailureKind::Permanent,
    }
}

fn rejects_path(excerpt: &str, path: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(excerpt)
        .ok()
        .and_then(|body| body.get("errors")?.as_array().cloned())
        .is_some_and(|errors| {
            errors
                .iter()
                .any(|error| error.get("path").and_then(|value| value.as_str()) == Some(path))
        })
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
    cancelled: impl Fn() -> bool,
) -> Result<T, TransportError> {
    let started = std::time::Instant::now();
    let mut delay = Duration::from_millis(250);
    for attempt in 1..=attempts {
        if cancelled() {
            return Err(TransportError::cancelled());
        }
        match operation() {
            Ok(value) => return Ok(value),
            // Asking the same home again cannot succeed once it said the organization moved.
            Err(error) if !error.transient() || error.is_moved() || attempt == attempts => {
                return Err(error)
            }
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
                    if cancelled() {
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
        env, fs,
        io::{Read, Write},
        net::TcpListener,
        path::PathBuf,
        process::Command,
    };

    fn config(renga_url: &str, intake_api_key: &str) -> Config {
        Config {
            config_path: PathBuf::from("agent.toml"),
            renga_url: renga_url.into(),
            allow_insecure_http: false,
            intake_api_key: intake_api_key.into(),
            installation_id: uuid::Uuid::nil(),
            inventory_interval: Duration::from_secs(300),
            checkin_interval: Duration::from_secs(60),
            config_refresh_interval: Duration::from_secs(300),
            request_timeout: Duration::from_secs(30),
            max_retry_attempts: 1,
            labels: BTreeMap::new(),
            jobs: Default::default(),
            snmp: Vec::new(),
        }
    }

    fn error(transient: bool) -> TransportError {
        let kind = if transient {
            FailureKind::Transient
        } else {
            FailureKind::Permanent
        };
        TransportError::new("failure".into(), kind)
    }

    #[test]
    fn error_excerpt_never_reads_beyond_its_byte_limit() {
        let mut body = std::io::Cursor::new(vec![b'x'; MAX_ERROR_BODY * 4]);

        let excerpt = bounded_error_excerpt(&mut body);

        assert_eq!(excerpt.len(), MAX_ERROR_BODY);
        assert_eq!(body.position(), MAX_ERROR_BODY as u64);
    }

    #[test]
    fn classifies_failures_by_who_can_fix_them() {
        let reused_id = r#"{"status":"rejected","errors":[{"path":"observation_id","message":"has already been used for a different payload"}]}"#;
        let enrolled = r#"{"status":"rejected","errors":[{"path":"installation_id","message":"collector credential is already enrolled by another installation"}]}"#;

        for (status, excerpt, kind) in [
            (StatusCode::SERVICE_UNAVAILABLE, "", FailureKind::Transient),
            (StatusCode::TOO_MANY_REQUESTS, "", FailureKind::Transient),
            (StatusCode::REQUEST_TIMEOUT, "", FailureKind::Transient),
            (
                StatusCode::UNPROCESSABLE_ENTITY,
                "",
                FailureKind::PayloadRejected,
            ),
            (StatusCode::BAD_REQUEST, "", FailureKind::PayloadRejected),
            (
                StatusCode::PAYLOAD_TOO_LARGE,
                "",
                FailureKind::PayloadRejected,
            ),
            (
                StatusCode::CONFLICT,
                reused_id,
                FailureKind::PayloadRejected,
            ),
            (StatusCode::CONFLICT, enrolled, FailureKind::Permanent),
            (StatusCode::CONFLICT, "not json", FailureKind::Permanent),
            (StatusCode::UNAUTHORIZED, "", FailureKind::Permanent),
            (StatusCode::FORBIDDEN, "", FailureKind::Permanent),
            (StatusCode::NOT_FOUND, "", FailureKind::Permanent),
            (
                StatusCode::GONE,
                r#"{"error":"moved"}"#,
                FailureKind::Transient,
            ),
            (StatusCode::GONE, "", FailureKind::Permanent),
        ] {
            assert_eq!(failure_kind(status, excerpt), kind, "{status} {excerpt}");
        }
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
            labels: BTreeMap::new(),
        })
    }

    #[test]
    fn uses_the_server_api_routes() {
        assert_eq!(CHECKIN_PATH, "/api/v1/agent/checkins");
        assert_eq!(OBSERVATION_PATH, "/api/v1/observations");
        assert_eq!(JOB_LEASE_PATH, "/api/v1/agent/jobs/lease");
    }

    #[test]
    fn response_bodies_are_bounded() {
        let mut fits = std::io::Cursor::new(vec![b'x'; 8]);
        assert_eq!(read_bounded(&mut fits, 8).unwrap().len(), 8);

        let mut oversized = std::io::Cursor::new(vec![b'x'; 9]);
        let error = read_bounded(&mut oversized, 8).unwrap_err();
        assert_eq!(error.kind(), FailureKind::Permanent);
    }

    /// Answers one request with `status` and `body`, returning the request.
    fn answer_once(status: u16, body: &'static str) -> (String, thread::JoinHandle<String>) {
        let (origin, server) = answer_each(vec![(status, body)]);
        (
            origin,
            thread::spawn(move || server.join().unwrap().remove(0)),
        )
    }

    /// Answers one connection per response, in order, and returns the requests.
    fn answer_each(
        responses: Vec<(u16, &'static str)>,
    ) -> (String, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            responses
                .into_iter()
                .map(|(status, body)| {
                    let (mut stream, _) = listener.accept().unwrap();
                    let mut request = Vec::new();
                    let mut buffer = [0; 4096];
                    loop {
                        let read = stream.read(&mut buffer).unwrap();
                        request.extend_from_slice(&buffer[..read]);
                        let text = String::from_utf8_lossy(&request);
                        if let Some((head, rest)) = text.split_once("\r\n\r\n") {
                            let length = head
                                .lines()
                                .find_map(|line| {
                                    let (name, value) = line.split_once(':')?;
                                    name.eq_ignore_ascii_case("content-length")
                                        .then(|| value.trim().parse::<usize>().unwrap())
                                })
                                .unwrap_or(0);
                            if rest.len() >= length {
                                break;
                            }
                        }
                    }
                    write!(
                        stream,
                        "HTTP/1.1 {status} Status\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .unwrap();
                    String::from_utf8(request).unwrap()
                })
                .collect()
        });
        (origin, server)
    }

    fn insecure_client(origin: &str) -> HttpClient {
        let mut config = config(origin, "token");
        config.allow_insecure_http = true;
        config.request_timeout = Duration::from_secs(5);
        HttpClient::new(&config, Cancellation::default()).unwrap()
    }

    #[test]
    fn moved_stops_retrying_keeps_the_payload_and_raises_the_shared_flag() {
        let (origin, server) = answer_once(410, r#"{"error":"moved"}"#);
        let mut config = config(&origin, "token");
        config.allow_insecure_http = true;
        config.max_retry_attempts = 3;
        let client = HttpClient::new(&config, Cancellation::default()).unwrap();
        let clone = client.clone();

        // The stub answers once, so a retry would fail to connect instead.
        let error = clone.post_checkin(&CheckIn::new(vec![], None)).unwrap_err();

        server.join().unwrap();
        assert!(error.is_moved());
        assert_eq!(error.kind(), FailureKind::Transient);
        assert!(client.take_moved());
        assert!(!client.take_moved());
    }

    #[test]
    fn a_replacement_for_the_same_home_hears_the_previous_clients_moves() {
        let (origin, server) = answer_once(410, r#"{"error":"moved"}"#);
        let previous = insecure_client(&origin);
        let worker = previous.clone();
        let same_home = insecure_client(&origin).sharing_moved_signal(&previous);
        let new_home =
            insecure_client("http://elsewhere.invalid:1").sharing_moved_signal(&previous);

        // A worker started before the replacement hears the move.
        worker
            .post_checkin(&CheckIn::new(vec![], None))
            .unwrap_err();

        server.join().unwrap();
        assert!(!new_home.take_moved());
        assert!(same_home.take_moved());
    }

    #[test]
    fn a_gone_without_moved_is_not_a_move() {
        let (origin, server) = answer_once(410, r#"{"error":"gone"}"#);
        let client = insecure_client(&origin);

        let error = client
            .post_checkin(&CheckIn::new(vec![], None))
            .unwrap_err();

        server.join().unwrap();
        assert!(!error.is_moved());
        assert_eq!(error.kind(), FailureKind::Permanent);
        assert!(!client.take_moved());
    }

    #[test]
    fn checkin_returns_the_jobs_waiting_hint_and_tolerates_older_servers() {
        let (origin, server) = answer_once(202, r#"{"status":"accepted","jobs_waiting":true}"#);
        let ack = insecure_client(&origin)
            .post_checkin(&CheckIn::new(vec!["inventory.collect@1".into()], None))
            .unwrap();
        assert_eq!(ack.jobs_waiting, Some(true));
        assert!(server.join().unwrap().contains("inventory.collect@1"));

        let (origin, server) = answer_once(202, "");
        let ack = insecure_client(&origin)
            .post_checkin(&CheckIn::new(vec![], None))
            .unwrap();
        assert_eq!(ack.jobs_waiting, None);
        server.join().unwrap();
    }

    #[test]
    fn leases_jobs_and_posts_reports_to_the_job_routes() {
        let (origin, server) = answer_once(
            200,
            r#"{"jobs":[{"id":"67e55044-10b1-426f-9247-bb680e5fe0c8","capability":"inventory.collect@1","parameters":{},"attempt":1,"lease_token":"t","lease_expires_at":"2026-10-14T12:00:00Z","not_after":null,"timeout_ms":1000,"output_limit_bytes":65536}]}"#,
        );
        let jobs = insecure_client(&origin)
            .lease_jobs(&["inventory.collect@1".into()], 1)
            .unwrap();
        assert_eq!(jobs.len(), 1);
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /api/v1/agent/jobs/lease "));
        assert!(request.contains(r#"{"capabilities":["inventory.collect@1"],"limit":1}"#));

        let payload = json!({});
        let report = JobReport {
            lease_token: "t",
            sequence: 1,
            kind: crate::payload::ReportType::Started,
            payload: &payload,
        };
        let (origin, server) = answer_once(200, r#"{"status":"accepted","cancel_requested":true}"#);
        let ack = insecure_client(&origin)
            .post_job_report(jobs[0].id, &report)
            .unwrap();
        assert!(ack.cancel_requested);
        assert!(server
            .join()
            .unwrap()
            .starts_with("POST /api/v1/agent/jobs/67e55044-10b1-426f-9247-bb680e5fe0c8/events "));

        // A conflict tells the worker to stop reporting on the job.
        let (origin, server) = answer_once(
            409,
            r#"{"status":"rejected","errors":[{"path":"lease_token","message":"does not hold the job's lease"}]}"#,
        );
        let error = insecure_client(&origin)
            .post_job_report(jobs[0].id, &report)
            .unwrap_err();
        assert_eq!(error.status(), Some(StatusCode::CONFLICT));
        server.join().unwrap();
    }

    #[test]
    fn claims_privileged_offers_with_the_installation_key() {
        const OFFER: &str = r#"{"job_id":"67e55044-10b1-426f-9247-bb680e5fe0c8","capability":"service.restart@1","lease_token":"t","nonce":"n","resource_id":"1f0e9b2a-3c4d-4e5f-8a9b-0c1d2e3f4a5b","binding_version":2,"expires_at":"2026-10-14T12:00:00Z"}"#;
        let lease = format!(r#"{{"jobs":[],"offers":[{OFFER}]}}"#).leak();
        let (origin, server) = answer_each(vec![
            (200, lease),
            (
                200,
                r#"{"id":"67e55044-10b1-426f-9247-bb680e5fe0c8","capability":"service.restart@1","parameters":{"service":"sshd"},"attempt":1,"lease_token":"t","lease_expires_at":"2026-10-14T12:00:00Z","not_after":null,"timeout_ms":1000,"output_limit_bytes":65536}"#,
            ),
        ]);
        let state = std::env::temp_dir().join(format!("renga-key-{}", uuid::Uuid::new_v4()));
        let key = Arc::new(InstallationKey::load_or_create(&state).unwrap());
        let jobs = insecure_client(&origin)
            .with_installation_key(Arc::clone(&key))
            .lease_jobs(&["service.restart@1".into()], 1)
            .unwrap();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].parameters["service"], "sshd");

        let requests = server.join().unwrap();
        let claim = &requests[1];
        assert!(claim
            .starts_with("POST /api/v1/agent/jobs/67e55044-10b1-426f-9247-bb680e5fe0c8/claims "));
        let body: serde_json::Value =
            serde_json::from_str(claim.split_once("\r\n\r\n").unwrap().1).unwrap();
        let offer: JobOffer = serde_json::from_str(OFFER).unwrap();
        let signature = URL_SAFE_NO_PAD
            .decode(body["signature"].as_str().unwrap())
            .unwrap();
        ring::signature::UnparsedPublicKey::new(
            &ring::signature::ED25519,
            URL_SAFE_NO_PAD.decode(key.public_key()).unwrap(),
        )
        .verify(&offer.message(uuid::Uuid::nil()), &signature)
        .unwrap();
        assert_eq!(body["lease_token"], "t");
        assert_eq!(body["nonce"], "n");
    }

    #[test]
    fn skips_offers_it_cannot_claim() {
        let (origin, server) = answer_each(vec![
            (
                200,
                r#"{"jobs":[],"offers":[{"job_id":"67e55044-10b1-426f-9247-bb680e5fe0c8","capability":"service.restart@1","lease_token":"t","nonce":"n","resource_id":"1f0e9b2a-3c4d-4e5f-8a9b-0c1d2e3f4a5b","binding_version":2,"expires_at":"2026-10-14T12:00:00Z"}]}"#,
            ),
            (
                409,
                r#"{"status":"rejected","errors":[{"path":"id","message":"the resource was bound elsewhere"}]}"#,
            ),
        ]);
        let state = std::env::temp_dir().join(format!("renga-key-{}", uuid::Uuid::new_v4()));
        let key = Arc::new(InstallationKey::load_or_create(&state).unwrap());
        let jobs = insecure_client(&origin)
            .with_installation_key(key)
            .lease_jobs(&["service.restart@1".into()], 1)
            .unwrap();
        assert!(jobs.is_empty());
        assert_eq!(server.join().unwrap().len(), 2);
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

    #[cfg(target_os = "linux")]
    #[test]
    fn constructs_https_client_without_a_host_ca_store() {
        const CHILD: &str = "RENGA_EMPTY_CA_STORE_TEST_CHILD";

        if env::var_os(CHILD).is_some() {
            assert!(!webpki_roots::TLS_SERVER_ROOTS.is_empty());
            HttpClient::new(
                &config("https://renga.test", "valid-token"),
                Cancellation::default(),
            )
            .unwrap();
            return;
        }

        let root = env::temp_dir().join(format!("renga-empty-ca-{}", uuid::Uuid::new_v4()));
        let directory = root.join("certs");
        let file = root.join("ca.pem");
        fs::create_dir_all(&directory).unwrap();
        fs::write(&file, []).unwrap();

        let status = Command::new(env::current_exe().unwrap())
            .args([
                "--exact",
                "transport::tests::constructs_https_client_without_a_host_ca_store",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .env("SSL_CERT_FILE", &file)
            .env("SSL_CERT_DIR", &directory)
            .status()
            .unwrap();

        fs::remove_dir_all(root).unwrap();
        assert!(status.success());
    }

    #[test]
    fn rejects_server_certificate_outside_embedded_roots() {
        use rcgen::{generate_simple_self_signed, CertifiedKey};
        use rustls::{pki_types::PrivatePkcs8KeyDer, ServerConfig, ServerConnection, StreamOwned};
        let CertifiedKey { cert, signing_key } =
            generate_simple_self_signed(["localhost".to_string()]).unwrap();
        let server_config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![cert.der().clone()],
                PrivatePkcs8KeyDer::from(signing_key.serialize_der()).into(),
            )
            .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let connection = ServerConnection::new(Arc::new(server_config)).unwrap();
            let mut stream = StreamOwned::new(connection, stream);
            let mut request = [0; 1];
            assert!(stream.read(&mut request).is_err());
        });

        let client = HttpClient::new(
            &config(
                &format!("https://localhost:{}", address.port()),
                "valid-token",
            ),
            Cancellation::default(),
        )
        .unwrap();
        let error = client
            .client
            .get(client.checkin_url.clone())
            .send()
            .unwrap_err();

        assert!(format!("{error:?}").contains("UnknownIssuer"));
        server.join().unwrap();
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

        assert_eq!(error.kind(), FailureKind::PayloadRejected);
        assert!(error.to_string().contains("exceeds 256000-byte limit"));
        assert!(matches!(
            listener.accept(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
        ));
    }

    #[test]
    fn cancelled_observation_operation_makes_no_network_attempt() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let mut config = config(
            &format!("http://{}", listener.local_addr().unwrap()),
            "valid-token",
        );
        config.allow_insecure_http = true;
        let client = HttpClient::new(&config, Cancellation::default()).unwrap();
        let operation = Cancellation::default();
        operation.cancel();

        let error = client
            .post_encoded_observation_with_cancellation(b"{}", &operation)
            .unwrap_err();

        assert!(error.is_cancelled());
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
            .post_reading(client.checkin_url.clone(), &serde_json::json!({}))
            .unwrap_err();

        assert!(error.to_string().contains("302 Found"));
        assert_eq!(
            error.kind(),
            FailureKind::Permanent,
            "redirects must not be retried"
        );
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
            || cancellation.cancelled(),
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
            || cancellation.cancelled()
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
            || cancellation.cancelled()
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
            || cancellation.cancelled()
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
            || cancellation.cancelled(),
        )
        .unwrap_err();
        assert_eq!(calls, 0);
        assert!(failure.is_cancelled());
        assert_eq!(failure.to_string(), "HTTP delivery cancelled");
    }

    #[test]
    fn cancellation_during_backoff_prevents_the_next_attempt() {
        let daemon = Cancellation::default();
        let operation = Cancellation::default();
        let from_sleep = operation.clone();
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
            || daemon.cancelled() || operation.cancelled(),
        )
        .unwrap_err();
        assert_eq!(calls, 1);
        assert_eq!(sleeps, 1);
        assert!(!daemon.cancelled());
        assert!(failure.is_cancelled());
    }

    #[test]
    fn operation_deadline_during_backoff_prevents_the_next_attempt() {
        let operation =
            Cancellation::with_deadline(std::time::Instant::now() + Duration::from_millis(10));
        let mut calls = 0;

        let failure = retry::<()>(
            3,
            Duration::ZERO,
            || {
                calls += 1;
                Err(error(true))
            },
            thread::sleep,
            || operation.cancelled(),
        )
        .unwrap_err();

        assert_eq!(calls, 1);
        assert!(failure.is_cancelled());
    }
}
