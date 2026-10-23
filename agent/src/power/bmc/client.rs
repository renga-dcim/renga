//! The narrow HTTPS client a BMC poll is allowed (RFD 10, "Collectors and BMCs").
//!
//! Every request goes to the target itself over HTTPS: proxies are never used, redirects are
//! never followed, and only Redfish service paths are requested, so a link a BMC serves cannot
//! send the module's credentials anywhere else. Bodies are bounded, and the whole target shares
//! one deadline.

use super::config::{BmcCollector, BmcTarget};
use crate::power::collector::TargetError;
use reqwest::{blocking::Client, redirect::Policy, StatusCode};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{verify_tls12_signature, verify_tls13_signature, WebPkiSupportedAlgorithms},
    pki_types::{pem::PemObject, CertificateDer, ServerName, UnixTime},
    DigitallySignedStruct, SignatureScheme,
};
use serde_json::Value;
use std::{
    fs,
    io::Read,
    sync::Arc,
    time::{Duration, Instant},
};

/// Redfish resources are small; a collection of thousands of members still fits.
const MAX_BODY_BYTES: usize = 2 * 1024 * 1024;

/// A Redfish service, one resource at a time. Tests serve recorded resources.
pub trait Redfish {
    fn get(&mut self, path: &str) -> Result<Value, TargetError>;
}

/// A connection to one target's Redfish service.
pub struct WireRedfish {
    client: Client,
    origin: String,
    username: String,
    password: String,
    timeout: Duration,
    deadline: Instant,
}

impl WireRedfish {
    /// Prepares requests to `target` that must all finish by `deadline`.
    pub fn open(
        collector: &BmcCollector,
        target: &BmcTarget,
        deadline: Instant,
    ) -> Result<Self, TargetError> {
        let password = fs::read_to_string(&collector.password_file).map_err(|error| {
            TargetError::NotPermitted(format!(
                "cannot read {}: {error}",
                collector.password_file.display()
            ))
        })?;
        let tls = tls(collector, target).map_err(TargetError::Unreachable)?;
        let client = Client::builder()
            .tls_backend_preconfigured(tls)
            .no_proxy()
            .redirect(Policy::none())
            .connect_timeout(collector.timeout)
            .build()
            .map_err(|error| {
                TargetError::Unreachable(format!("cannot build the BMC client: {error}"))
            })?;
        let host = &target.target.host;
        let origin = if host.contains(':') {
            format!("https://[{host}]:{}", target.target.port)
        } else {
            format!("https://{host}:{}", target.target.port)
        };
        Ok(Self {
            client,
            origin,
            username: collector.username.clone(),
            password: password.trim_end_matches(['\r', '\n']).to_owned(),
            timeout: collector.timeout,
            deadline,
        })
    }
}

impl Redfish for WireRedfish {
    fn get(&mut self, path: &str) -> Result<Value, TargetError> {
        if !service_path(path) {
            return Err(TargetError::Unsupported(format!(
                "the BMC links to {path:?}, which is not a Redfish service path"
            )));
        }
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(TargetError::Unreachable(
                "the BMC did not answer within the poll's time budget".into(),
            ));
        }
        let url = format!("{}{path}", self.origin);
        let response = self
            .client
            .get(&url)
            .basic_auth(&self.username, Some(&self.password))
            .header("Accept", "application/json")
            .header("OData-Version", "4.0")
            .timeout(self.timeout.min(remaining))
            .send()
            .map_err(|error| {
                TargetError::Unreachable(format!("cannot read {url}: {}", chain(&error)))
            })?;
        let status = response.status();
        if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
            return Err(TargetError::NotPermitted(format!(
                "{url} answered {status}"
            )));
        }
        if status.is_client_error() {
            return Err(TargetError::Unsupported(format!("{url} answered {status}")));
        }
        if !status.is_success() {
            return Err(TargetError::Unreachable(format!("{url} answered {status}")));
        }
        let mut body = Vec::new();
        response
            .take(MAX_BODY_BYTES as u64 + 1)
            .read_to_end(&mut body)
            .map_err(|error| TargetError::Unreachable(format!("cannot read {url}: {error}")))?;
        if body.len() > MAX_BODY_BYTES {
            return Err(TargetError::Unsupported(format!(
                "{url} is larger than {MAX_BODY_BYTES} bytes"
            )));
        }
        serde_json::from_slice(&body)
            .map_err(|error| TargetError::Unsupported(format!("{url} is not JSON: {error}")))
    }
}

/// A path within the Redfish service, with nothing that could leave it.
fn service_path(path: &str) -> bool {
    (path == "/redfish/v1" || path.starts_with("/redfish/v1/"))
        && path.len() <= 512
        && path.bytes().all(|byte| byte.is_ascii_graphic())
        && !path.contains(['?', '#', '\\', '%'])
        && !path.contains("//")
        && !path
            .split('/')
            .any(|segment| segment == "." || segment == "..")
}

fn chain(error: &dyn std::error::Error) -> String {
    let mut message = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        message.push_str(": ");
        message.push_str(&cause.to_string());
        source = cause.source();
    }
    message
}

/// The target's pin, else the module's CA file, else the public web roots.
fn tls(collector: &BmcCollector, target: &BmcTarget) -> Result<rustls::ClientConfig, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let builder = rustls::ClientConfig::builder_with_provider(Arc::clone(&provider))
        .with_safe_default_protocol_versions()
        .map_err(|error| format!("cannot configure TLS protocol versions: {error}"))?;
    if let Some(digest) = target.pin {
        return Ok(builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(Pinned {
                digest,
                algorithms: provider.signature_verification_algorithms,
            }))
            .with_no_client_auth());
    }
    let Some(path) = &collector.ca_file else {
        return crate::transport::pinned_tls().map_err(|error| error.to_string());
    };
    let unreadable =
        |error: &dyn std::fmt::Display| format!("cannot read {}: {error}", path.display());
    let mut roots = rustls::RootCertStore::empty();
    for certificate in CertificateDer::pem_file_iter(path).map_err(|error| unreadable(&error))? {
        roots
            .add(certificate.map_err(|error| unreadable(&error))?)
            .map_err(|error| unreadable(&error))?;
    }
    if roots.is_empty() {
        return Err(format!("{} holds no certificate", path.display()));
    }
    Ok(builder.with_root_certificates(roots).with_no_client_auth())
}

/// Trusts exactly the certificate whose SHA-256 digest was pinned, whatever it names or whoever
/// signed it, and still checks that the BMC holds its key.
#[derive(Debug)]
struct Pinned {
    digest: [u8; 32],
    algorithms: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let digest = ring::digest::digest(&ring::digest::SHA256, end_entity.as_ref());
        if digest.as_ref() == self.digest {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "the BMC's certificate does not match its pin".into(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snmp::config::Target;
    use rcgen::{generate_simple_self_signed, CertifiedKey};
    use rustls::{
        pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer},
        ServerConfig, ServerConnection, StreamOwned,
    };
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        path::PathBuf,
        thread,
    };
    use uuid::Uuid;

    struct Bmc {
        address: String,
        certificate: CertificateDer<'static>,
        server: thread::JoinHandle<Option<String>>,
    }

    /// Serves one HTTPS response with a fresh self-signed certificate for `127.0.0.1` and returns
    /// the request head it received, if the handshake succeeded.
    fn serve(status: &'static str, body: &'static str) -> Bmc {
        let CertifiedKey { cert, signing_key } =
            generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let certificate = cert.der().clone();
        let config =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![certificate.clone()],
                    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(signing_key.serialize_der())),
                )
                .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let server = thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            let tls = StreamOwned::new(ServerConnection::new(Arc::new(config)).unwrap(), tcp);
            let mut reader = BufReader::new(tls);
            let mut head = String::new();
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    return None;
                }
                if line == "\r\n" || line.is_empty() {
                    break;
                }
                head.push_str(&line);
            }
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
                 Connection: close\r\n\r\n{body}",
                body.len()
            );
            reader.get_mut().write_all(response.as_bytes()).unwrap();
            reader.get_mut().flush().unwrap();
            Some(head)
        });
        Bmc {
            address,
            certificate,
            server,
        }
    }

    fn password_file() -> PathBuf {
        let path = std::env::temp_dir().join(format!("renga-bmc-{}", Uuid::new_v4()));
        fs::write(&path, "s3cret\n").unwrap();
        path
    }

    fn collector(address: &str, pin: Option<[u8; 32]>) -> (BmcCollector, BmcTarget) {
        let target = BmcTarget {
            target: Target::parse_with_default_port(address, 443).unwrap(),
            pin,
        };
        let collector = BmcCollector {
            id: "rack-bmcs".into(),
            targets: vec![target.clone()],
            username: "renga".into(),
            password_file: password_file(),
            ca_file: None,
            interval: Duration::from_secs(60),
            timeout: Duration::from_secs(5),
            max_concurrent_targets: 1,
        };
        (collector, target)
    }

    fn digest(certificate: &CertificateDer<'_>) -> [u8; 32] {
        ring::digest::digest(&ring::digest::SHA256, certificate.as_ref())
            .as_ref()
            .try_into()
            .unwrap()
    }

    fn get(collector: &BmcCollector, target: &BmcTarget) -> Result<Value, TargetError> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let result = WireRedfish::open(collector, target, deadline)?.get("/redfish/v1/Systems");
        fs::remove_file(&collector.password_file).unwrap();
        result
    }

    #[test]
    fn reads_a_pinned_bmc_with_basic_auth() {
        let bmc = serve("200 OK", r#"{"Members@odata.count": 0, "Members": []}"#);
        let (collector, target) = collector(&bmc.address, Some(digest(&bmc.certificate)));

        let systems = get(&collector, &target).unwrap();

        assert_eq!(systems["Members@odata.count"], 0);
        let head = bmc.server.join().unwrap().unwrap();
        assert!(
            head.starts_with("GET /redfish/v1/Systems HTTP/1.1\r\n"),
            "{head}"
        );
        // renga:s3cret, without the password file's trailing newline.
        assert!(
            head.to_ascii_lowercase()
                .contains("authorization: basic cmvuz2e6cznjcmv0\r\n"),
            "{head}"
        );
    }

    #[test]
    fn refuses_a_bmc_whose_certificate_is_not_the_pinned_one() {
        let bmc = serve("200 OK", "{}");
        let (collector, target) = collector(&bmc.address, Some([0; 32]));

        let error = get(&collector, &target).unwrap_err();

        assert!(matches!(error, TargetError::Unreachable(_)), "{error:?}");
        assert!(
            error.message().contains("does not match its pin"),
            "{error:?}"
        );
        assert_eq!(bmc.server.join().unwrap(), None, "no request was sent");
    }

    #[test]
    fn trusts_a_bmc_signed_by_the_ca_file() {
        let bmc = serve("200 OK", "{}");
        let (mut collector, target) = collector(&bmc.address, None);
        let ca_file = std::env::temp_dir().join(format!("renga-bmc-ca-{}.pem", Uuid::new_v4()));
        let pem = format!(
            "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n",
            base64::Engine::encode(
                &base64::engine::general_purpose::STANDARD,
                bmc.certificate.as_ref()
            )
        );
        fs::write(&ca_file, pem).unwrap();
        collector.ca_file = Some(ca_file.clone());

        let result = get(&collector, &target);
        fs::remove_file(ca_file).unwrap();

        assert_eq!(result.unwrap(), serde_json::json!({}));
        bmc.server.join().unwrap().unwrap();
    }

    #[test]
    fn tells_refused_credentials_from_a_service_without_redfish() {
        for (status, expected) in [
            ("401 Unauthorized", "not_permitted"),
            ("404 Not Found", "unsupported"),
        ] {
            let bmc = serve(status, "{}");
            let (collector, target) = collector(&bmc.address, Some(digest(&bmc.certificate)));
            let error = get(&collector, &target).unwrap_err();
            let kind = match error {
                TargetError::NotPermitted(_) => "not_permitted",
                TargetError::Unsupported(_) => "unsupported",
                TargetError::Unreachable(_) => "unreachable",
            };
            assert_eq!(kind, expected, "{status}");
            bmc.server.join().unwrap();
        }
    }

    #[test]
    fn requests_only_redfish_service_paths() {
        for path in ["/redfish/v1", "/redfish/v1/Chassis/System.Embedded.1/Power"] {
            assert!(service_path(path), "{path}");
        }
        for path in [
            "https://elsewhere.example/redfish/v1",
            "//elsewhere.example/redfish/v1",
            "/redfish/v1/../../login",
            "/redfish/v1/Systems?$expand=*",
            "/redfish/v1/Systems/%2e%2e",
            "/redfish/v10",
            "/redfish/v1/ Systems",
        ] {
            assert!(!service_path(path), "{path}");
        }
    }
}
