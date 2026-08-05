//! Blocking HTTP transport and bounded retry policy.

use crate::{
    config::Config,
    payload::{CheckIn, Observation},
};
use reqwest::{
    blocking::{Client, Response},
    StatusCode,
};
use serde::Serialize;
use std::{fmt, thread, time::Duration};

const MAX_ERROR_BODY: usize = 512;
const CHECKIN_PATH: &str = "/api/v1/agent/checkins";
const OBSERVATION_PATH: &str = "/api/v1/observations";

#[derive(Debug, Clone)]
pub struct TransportError {
    message: String,
    transient: bool,
}
impl TransportError {
    fn new(message: String, transient: bool) -> Self {
        Self { message, transient }
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
    base_url: String,
    token: String,
    attempts: u32,
}
impl HttpClient {
    pub fn new(config: &Config) -> Result<Self, TransportError> {
        let client = Client::builder()
            .timeout(config.request_timeout)
            .build()
            .map_err(|e| TransportError::new(format!("cannot build HTTP client: {e}"), false))?;
        Ok(Self {
            client,
            base_url: config.renga_url.clone(),
            token: config.token.clone(),
            attempts: config.max_retry_attempts,
        })
    }
    pub fn post_checkin(&self, value: &CheckIn) -> Result<(), TransportError> {
        self.post(CHECKIN_PATH, value)
    }
    pub fn post_observation(&self, value: &Observation) -> Result<(), TransportError> {
        self.post(OBSERVATION_PATH, value)
    }
    fn post<T: Serialize>(&self, path: &str, value: &T) -> Result<(), TransportError> {
        retry(
            self.attempts,
            || {
                let response = self
                    .client
                    .post(format!("{}{path}", self.base_url))
                    .bearer_auth(&self.token)
                    .json(value)
                    .send()
                    .map_err(|e| {
                        TransportError::new(
                            format!("HTTP request failed: {e}"),
                            e.is_timeout() || e.is_connect() || e.is_request(),
                        )
                    })?;
                response_result(response)
            },
            thread::sleep,
        )
    }
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
) -> Result<T, TransportError> {
    let mut delay = Duration::from_millis(250);
    for attempt in 1..=attempts {
        match operation() {
            Ok(value) => return Ok(value),
            Err(error) if !error.transient || attempt == attempts => return Err(error),
            Err(_) => {
                sleep(delay);
                delay = (delay * 2).min(Duration::from_secs(8));
            }
        }
    }
    unreachable!("configuration guarantees at least one attempt")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn error(transient: bool) -> TransportError {
        TransportError::new("failure".into(), transient)
    }

    #[test]
    fn uses_the_server_api_routes() {
        assert_eq!(CHECKIN_PATH, "/api/v1/agent/checkins");
        assert_eq!(OBSERVATION_PATH, "/api/v1/observations");
    }

    #[test]
    fn succeeds_after_transients() {
        let mut calls = 0;
        let mut sleeps = vec![];
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
        );
        assert_eq!(result.unwrap(), 7);
        assert_eq!(
            sleeps,
            vec![Duration::from_millis(250), Duration::from_millis(500)]
        );
    }
    #[test]
    fn stops_on_permanent_response() {
        let mut calls = 0;
        assert!(retry::<()>(
            5,
            || {
                calls += 1;
                Err(error(false))
            },
            |_| {}
        )
        .is_err());
        assert_eq!(calls, 1);
    }
    #[test]
    fn exhausts_total_attempts() {
        let mut calls = 0;
        assert!(retry::<()>(
            3,
            || {
                calls += 1;
                Err(error(true))
            },
            |_| {}
        )
        .is_err());
        assert_eq!(calls, 3);
    }
}
