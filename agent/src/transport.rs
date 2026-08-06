//! Blocking HTTP transport and bounded retry policy.

use crate::{
    cancellation::Cancellation,
    config::Config,
    payload::{CheckIn, Observation, MAX_OBSERVATION_BYTES},
};
use reqwest::{
    blocking::{Client, Response},
    header::{HeaderValue, AUTHORIZATION},
    redirect::Policy,
    StatusCode, Url,
};
use serde::Serialize;
use std::{fmt, thread, time::Duration};

const MAX_ERROR_BODY: usize = 512;
const CHECKIN_PATH: &str = "/api/v1/agent/checkins";
const OBSERVATION_PATH: &str = "/api/v1/observations";
const BACKOFF_SLICE: Duration = Duration::from_millis(25);

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

pub struct HttpClient {
    client: Client,
    checkin_url: Url,
    observation_url: Url,
    authorization: HeaderValue,
    attempts: u32,
    cancellation: Cancellation,
}
impl HttpClient {
    pub fn new(config: &Config, cancellation: Cancellation) -> Result<Self, TransportError> {
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
        let checkin_url = endpoint_url(&base_url, CHECKIN_PATH)?;
        let observation_url = endpoint_url(&base_url, OBSERVATION_PATH)?;
        let mut authorization = HeaderValue::from_str(&format!("Bearer {}", config.token))
            .map_err(|_| TransportError::new("invalid bearer token".into(), false))?;
        authorization.set_sensitive(true);
        let client = Client::builder()
            .timeout(config.request_timeout)
            .redirect(Policy::none())
            .build()
            .map_err(|e| TransportError::new(format!("cannot build HTTP client: {e}"), false))?;
        Ok(Self {
            client,
            checkin_url,
            observation_url,
            authorization,
            attempts: config.max_retry_attempts,
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
            || {
                let response = self
                    .client
                    .post(self.observation_url.clone())
                    .header(AUTHORIZATION, self.authorization.clone())
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(body.clone())
                    .send()
                    .map_err(request_error)?;
                response_result(response)
            },
            thread::sleep,
            &self.cancellation,
        )
    }
    fn post<T: Serialize>(&self, url: Url, value: &T) -> Result<(), TransportError> {
        retry(
            self.attempts,
            || {
                let response = self
                    .client
                    .post(url.clone())
                    .header(AUTHORIZATION, self.authorization.clone())
                    .json(value)
                    .send()
                    .map_err(request_error)?;
                response_result(response)
            },
            thread::sleep,
            &self.cancellation,
        )
    }
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

fn response_result(response: Response) -> Result<(), TransportError> {
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    let excerpt: String = response
        .text()
        .unwrap_or_default()
        .chars()
        .take(MAX_ERROR_BODY)
        .collect();
    let transient = status == StatusCode::REQUEST_TIMEOUT
        || status == StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error();
    Err(TransportError::new(
        format!("server returned {status}; response excerpt: {excerpt:?}"),
        transient,
    ))
}

fn retry<T>(
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
            token: token.into(),
            installation_id: uuid::Uuid::nil(),
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
    fn already_cancelled_makes_no_attempt() {
        let cancellation = Cancellation::default();
        cancellation.cancel();
        let mut calls = 0;
        let failure = retry::<()>(
            3,
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
