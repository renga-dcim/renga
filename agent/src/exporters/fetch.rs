//! The narrow HTTP fetch a local exporter scrape is allowed (RFD 10, "Local Prometheus
//! exporters").
//!
//! Every scrape resolves the endpoint itself, refuses a non-loopback address unless the operator
//! allowed remote connections, pins the connection to the addresses it checked, and then checks
//! the peer the request actually reached. Proxies are never used, since a proxy would make the
//! peer check meaningless, and redirects are never followed. The Renga intake key is never sent;
//! a remote endpoint may present a bearer token read from its own local file.

use reqwest::{
    blocking::Client,
    header::{HeaderValue, AUTHORIZATION},
    redirect::Policy,
};
use std::{
    fs,
    io::Read,
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    path::PathBuf,
    time::Duration,
};
use url::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub url: Url,
    pub allow_remote: bool,
    pub bearer_token_file: Option<PathBuf>,
    pub timeout: Duration,
    pub max_bytes: usize,
}

/// Why a scrape failed. Either way it never becomes a zero reading.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchError {
    /// The exporter refused the agent's credentials.
    NotPermitted(String),
    /// Anything else: resolution, policy, connection, status, size, or encoding.
    Failed(String),
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotPermitted(message) | Self::Failed(message) => f.write_str(message),
        }
    }
}

impl From<String> for FetchError {
    fn from(message: String) -> Self {
        Self::Failed(message)
    }
}

impl From<&str> for FetchError {
    fn from(message: &str) -> Self {
        Self::Failed(message.into())
    }
}

/// Fetches the endpoint's body as text, or says why the scrape failed.
pub fn fetch(endpoint: &Endpoint) -> Result<String, FetchError> {
    let host = endpoint
        .url
        .host_str()
        .ok_or("the exporter URL has no host")?
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_owned();
    let port = endpoint
        .url
        .port_or_known_default()
        .ok_or("the exporter URL has no port")?;
    let addresses: Vec<SocketAddr> = match host.parse::<IpAddr>() {
        Ok(ip) => vec![SocketAddr::new(ip, port)],
        Err(_) => (host.as_str(), port)
            .to_socket_addrs()
            .map_err(|error| format!("cannot resolve {host}: {error}"))?
            .collect(),
    };
    if addresses.is_empty() {
        return Err(format!("{host} resolves to no address").into());
    }
    check_destination(&addresses, endpoint.allow_remote)?;

    let tls = crate::transport::pinned_tls().map_err(|error| error.to_string())?;
    let client = Client::builder()
        .tls_backend_preconfigured(tls)
        .no_proxy()
        .redirect(Policy::none())
        .connect_timeout(endpoint.timeout)
        .timeout(endpoint.timeout)
        .resolve_to_addrs(&host, &addresses)
        .build()
        .map_err(|error| format!("cannot build the exporter client: {error}"))?;
    let mut request = client
        .get(endpoint.url.clone())
        .header("Accept", "text/plain");
    if let Some(path) = &endpoint.bearer_token_file {
        let token = fs::read_to_string(path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        let mut value = HeaderValue::from_str(&format!("Bearer {}", token.trim()))
            .map_err(|_| format!("{} does not hold a usable token", path.display()))?;
        value.set_sensitive(true);
        request = request.header(AUTHORIZATION, value);
    }
    let response = request
        .send()
        .map_err(|error| format!("cannot scrape {}: {error}", endpoint.url))?;
    let peer = response
        .remote_addr()
        .ok_or("the exporter connection has no peer address")?;
    if !addresses.contains(&peer) {
        return Err(format!("connected to {peer}, which was not resolved").into());
    }
    check_destination(&[peer], endpoint.allow_remote)?;
    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err(FetchError::NotPermitted(format!(
            "{} answered {status}",
            endpoint.url
        )));
    }
    if !status.is_success() {
        return Err(format!("{} answered {status}", endpoint.url).into());
    }

    let mut body = Vec::new();
    response
        .take(endpoint.max_bytes as u64 + 1)
        .read_to_end(&mut body)
        .map_err(|error| format!("cannot read {}: {error}", endpoint.url))?;
    if body.len() > endpoint.max_bytes {
        return Err(format!("response exceeds {} bytes", endpoint.max_bytes).into());
    }
    String::from_utf8(body).map_err(|_| "response is not UTF-8".into())
}

fn check_destination(addresses: &[SocketAddr], allow_remote: bool) -> Result<(), String> {
    match addresses.iter().find(|address| !address.ip().is_loopback()) {
        Some(address) if !allow_remote => Err(format!(
            "{address} is not a loopback address; set allow_remote = true to scrape it"
        )),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        thread,
    };

    /// Serves one response and returns the request head it received.
    fn serve(response: String) -> (Url, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = Url::parse(&format!(
            "http://{}/metrics",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut head = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" || line.is_empty() {
                    break;
                }
                head.push_str(&line);
            }
            reader.get_mut().write_all(response.as_bytes()).unwrap();
            head
        });
        (url, server)
    }

    fn ok(body: &str) -> String {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    fn endpoint(url: Url) -> Endpoint {
        Endpoint {
            url,
            allow_remote: false,
            bearer_token_file: None,
            timeout: Duration::from_secs(5),
            max_bytes: 1_000,
        }
    }

    #[test]
    fn fetches_a_loopback_exporter_without_credentials() {
        let (url, server) = serve(ok("ipmi_dcmi_power_consumption_watts 312\n"));

        assert_eq!(
            fetch(&endpoint(url)).unwrap(),
            "ipmi_dcmi_power_consumption_watts 312\n"
        );
        let head = server.join().unwrap().to_ascii_lowercase();
        assert!(!head.contains("authorization"), "{head}");
    }

    #[test]
    fn a_remote_endpoint_needs_explicit_permission() {
        let remote = Url::parse("http://192.0.2.10:9100/metrics").unwrap();
        let error = fetch(&endpoint(remote)).unwrap_err().to_string();
        assert!(error.contains("allow_remote"), "{error}");

        assert!(check_destination(&["192.0.2.10:9100".parse().unwrap()], true).is_ok());
        assert!(check_destination(&["[::1]:9100".parse().unwrap()], false).is_ok());
    }

    #[test]
    fn redirects_are_not_followed() {
        let (url, server) = serve(
            "HTTP/1.1 302 Found\r\nLocation: http://192.0.2.10/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .into(),
        );
        let error = fetch(&endpoint(url)).unwrap_err().to_string();
        server.join().unwrap();
        assert!(error.contains("302"), "{error}");
    }

    #[test]
    fn an_oversized_response_fails_the_scrape() {
        let (url, server) = serve(ok(&"x".repeat(1_001)));
        let error = fetch(&endpoint(url)).unwrap_err().to_string();
        server.join().unwrap();
        assert!(error.contains("exceeds"), "{error}");
    }

    #[test]
    fn a_refused_credential_is_not_permitted() {
        let (url, server) = serve(
            "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
        );
        let error = fetch(&endpoint(url)).unwrap_err();
        server.join().unwrap();
        assert!(matches!(error, FetchError::NotPermitted(_)), "{error:?}");
    }

    #[test]
    fn a_configured_token_file_is_sent_as_a_bearer_token() {
        let path = std::env::temp_dir().join(format!("renga-token-{}", uuid::Uuid::new_v4()));
        fs::write(&path, "exporter-secret\n").unwrap();
        let (url, server) = serve(ok(""));

        let mut endpoint = endpoint(url);
        endpoint.bearer_token_file = Some(path.clone());
        fetch(&endpoint).unwrap();
        fs::remove_file(path).unwrap();

        assert!(server
            .join()
            .unwrap()
            .to_ascii_lowercase()
            .contains("authorization: bearer exporter-secret"));
    }

    #[test]
    fn an_unreachable_exporter_fails_the_scrape() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let url = Url::parse(&format!("http://{address}/metrics")).unwrap();
        assert!(fetch(&endpoint(url)).is_err());
    }
}
