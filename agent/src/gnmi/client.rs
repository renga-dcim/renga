//! One gNMI connection to one target: `Capabilities` to choose an encoding, then a `Get` per
//! path. Everything else in the module is blocking, so the connection drives its own
//! single-threaded runtime on the polling thread.

use super::{
    config::{GnmiCollector, Transport},
    proto::{
        CapabilityRequest, CapabilityResponse, DataType, Encoding, GetRequest, GetResponse,
        Notification, Path,
    },
};
use crate::snmp::config::Target;
use http::uri::PathAndQuery;
use std::{error::Error, fs, time::Duration};
use tonic::{
    client::Grpc,
    metadata::{Ascii, MetadataValue},
    transport::{Certificate, Channel, ClientTlsConfig, Endpoint, Identity},
    Code, Status,
};
use tonic_prost::ProstCodec;

/// A ceiling on one answer, far above a large chassis's interface tree, so a target cannot
/// exhaust the agent's memory.
const MAX_ANSWER_BYTES: usize = 32 * 1024 * 1024;
/// The origin naming the OpenConfig models, which targets with native models of their own
/// (such as SR Linux) require to answer in OpenConfig.
const ORIGIN: &str = "openconfig";

/// A connected target; tests answer from recordings instead.
pub trait Session {
    /// Every notification the target answers for `path`.
    fn get(&mut self, path: &str) -> Result<Vec<Notification>, GetError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GetError {
    /// The target does not implement the path or its model; the rest may still be read.
    Unsupported(String),
    /// The target could not be read.
    Failed(String),
}

/// Tokio waits forever for started blocking work when a runtime is dropped. Its DNS resolver
/// uses that pool, so a timed-out lookup must not hold the switch fan-out open during teardown.
struct Runtime(Option<tokio::runtime::Runtime>);

impl Runtime {
    fn new() -> Result<Self, String> {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map(|runtime| Self(Some(runtime)))
            .map_err(|error| format!("cannot start the gNMI runtime: {error}"))
    }

    fn block_on<F: std::future::Future>(&self, future: F) -> F::Output {
        self.0
            .as_ref()
            .expect("runtime is present")
            .block_on(future)
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(runtime) = self.0.take() {
            runtime.shutdown_background();
        }
    }
}

pub struct WireSession {
    runtime: Runtime,
    grpc: Grpc<Channel>,
    credentials: Option<(MetadataValue<Ascii>, MetadataValue<Ascii>)>,
    encoding: Encoding,
    timeout: Duration,
}

impl WireSession {
    /// Connects to `target` and agrees on an encoding. Secrets and certificates are read from
    /// their files on every connection, so rotating them needs no restart.
    pub fn open(target: &Target, collector: &GnmiCollector) -> Result<Self, String> {
        let runtime = Runtime::new()?;
        let credentials = collector
            .credentials
            .as_ref()
            .map(|credentials| {
                let password = fs::read_to_string(&credentials.password_file).map_err(|error| {
                    format!(
                        "cannot read {}: {error}",
                        credentials.password_file.display()
                    )
                })?;
                let password = password.trim_end_matches(['\r', '\n']);
                Ok::<_, String>((
                    metadata(&credentials.username, "username")?,
                    metadata(password, "the password")?,
                ))
            })
            .transpose()?;
        let endpoint = endpoint(target, collector)?;
        let channel = runtime
            .block_on(async { tokio::time::timeout(collector.timeout, endpoint.connect()).await })
            .map_err(|_| "cannot connect: timed out".to_owned())?
            .map_err(|error| format!("cannot connect: {}", chain(&error)))?;
        let mut session = Self {
            runtime,
            grpc: Grpc::new(channel).max_decoding_message_size(MAX_ANSWER_BYTES),
            credentials,
            encoding: Encoding::JsonIetf,
            timeout: collector.timeout,
        };
        let capabilities: CapabilityResponse = session
            .call("/gnmi.gNMI/Capabilities", CapabilityRequest {})
            .map_err(|status| describe(&status))?;
        session.encoding = encoding(&capabilities.supported_encodings)?;
        Ok(session)
    }

    fn call<M1, M2>(&mut self, method: &'static str, message: M1) -> Result<M2, Status>
    where
        M1: prost::Message + Send + Sync + 'static,
        M2: prost::Message + Default + Send + Sync + 'static,
    {
        let mut request = tonic::Request::new(message);
        request.set_timeout(self.timeout);
        if let Some((username, password)) = &self.credentials {
            let metadata = request.metadata_mut();
            metadata.insert("username", username.clone());
            metadata.insert("password", password.clone());
        }
        let grpc = &mut self.grpc;
        let timeout = self.timeout;
        self.runtime
            .block_on(async move {
                tokio::time::timeout(timeout, async move {
                    grpc.ready()
                        .await
                        .map_err(|error| Status::unavailable(chain(&error)))?;
                    grpc.unary(
                        request,
                        PathAndQuery::from_static(method),
                        ProstCodec::<M1, M2>::default(),
                    )
                    .await
                })
                .await
                .map_err(|_| Status::deadline_exceeded("gNMI request timed out"))?
            })
            .map(tonic::Response::into_inner)
    }
}

impl Session for WireSession {
    fn get(&mut self, path: &str) -> Result<Vec<Notification>, GetError> {
        let request = GetRequest {
            path: vec![Path {
                origin: ORIGIN.into(),
                ..Path::from_names(path)
            }],
            r#type: DataType::All as i32,
            encoding: self.encoding as i32,
            ..Default::default()
        };
        self.call::<_, GetResponse>("/gnmi.gNMI/Get", request)
            .map(|response| response.notification)
            .map_err(|status| match status.code() {
                Code::Unimplemented | Code::NotFound | Code::InvalidArgument => {
                    GetError::Unsupported(describe(&status))
                }
                _ => GetError::Failed(describe(&status)),
            })
    }
}

fn endpoint(target: &Target, collector: &GnmiCollector) -> Result<Endpoint, String> {
    let host = if target.host.contains(':') {
        format!("[{}]", target.host)
    } else {
        target.host.clone()
    };
    let scheme = match collector.transport {
        Transport::Tls { .. } => "https",
        Transport::Plaintext => "http",
    };
    let endpoint = Endpoint::from_shared(format!("{scheme}://{host}:{}", target.port))
        .map_err(|error| format!("{:?} is not a usable address: {error}", target.address))?
        .connect_timeout(collector.timeout)
        .timeout(collector.timeout);
    let Transport::Tls {
        ca_file,
        client_identity,
        server_name,
    } = &collector.transport
    else {
        return Ok(endpoint);
    };
    let read = |path: &std::path::Path| {
        fs::read(path).map_err(|error| format!("cannot read {}: {error}", path.display()))
    };
    let mut tls = ClientTlsConfig::new()
        .domain_name(server_name.clone().unwrap_or_else(|| target.host.clone()))
        .timeout(collector.timeout);
    tls = match ca_file {
        Some(ca_file) => tls.ca_certificate(Certificate::from_pem(read(ca_file)?)),
        None => tls.with_webpki_roots(),
    };
    if let Some(identity) = client_identity {
        tls = tls.identity(Identity::from_pem(
            read(&identity.cert_file)?,
            read(&identity.key_file)?,
        ));
    }
    endpoint
        .tls_config(tls)
        .map_err(|error| format!("cannot set up TLS: {}", chain(&error)))
}

/// JSON_IETF when the target offers it, since it names each value's model; otherwise JSON.
fn encoding(supported: &[i32]) -> Result<Encoding, String> {
    let offers = |encoding: Encoding| supported.contains(&(encoding as i32));
    if supported.is_empty() || offers(Encoding::JsonIetf) {
        Ok(Encoding::JsonIetf)
    } else if offers(Encoding::Json) {
        Ok(Encoding::Json)
    } else {
        Err("the target supports neither JSON_IETF nor JSON encoding".into())
    }
}

fn metadata(value: &str, name: &str) -> Result<MetadataValue<Ascii>, String> {
    MetadataValue::try_from(value).map_err(|_| format!("{name} must be printable ASCII"))
}

fn describe(status: &Status) -> String {
    format!("{:?}: {}", status.code(), status.message())
}

/// An error with its causes, which transport errors keep out of their own message. A cause
/// that only repeats what is already said is left out.
fn chain(error: &dyn Error) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        let cause_text = cause.to_string();
        if !text.contains(&cause_text) {
            text.push_str(": ");
            text.push_str(&cause_text);
        }
        source = cause.source();
    }
    text
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{
        cancellation::Cancellation,
        gnmi::{
            config::{Credentials, GnmiCollector},
            openconfig,
        },
    };
    use std::{
        collections::BTreeMap,
        convert::Infallible,
        future::Future,
        pin::Pin,
        sync::{
            atomic::{AtomicBool, Ordering},
            mpsc, Arc, Mutex,
        },
        task::{Context, Poll},
        thread,
        time::{Duration, Instant},
    };
    use tokio_stream::wrappers::{ReceiverStream, TcpListenerStream};
    use tonic::server::NamedService;

    /// A target answering from the recorded switch.
    pub(crate) struct Recorded {
        answers: BTreeMap<&'static str, Result<Vec<Notification>, GetError>>,
    }

    impl Recorded {
        pub(crate) fn switch() -> Self {
            Self {
                answers: openconfig::tests::recorded()
                    .into_iter()
                    .map(|(path, notification)| (path, Ok(vec![notification])))
                    .collect(),
            }
        }

        /// The target lacks the model behind `path`.
        pub(crate) fn without(mut self, path: &'static str) -> Self {
            self.answers.insert(
                path,
                Err(GetError::Unsupported("Unimplemented: no such model".into())),
            );
            self
        }

        /// The target fails while answering `path`.
        pub(crate) fn failing(mut self, path: &'static str) -> Self {
            self.answers.insert(
                path,
                Err(GetError::Failed("Unavailable: connection reset".into())),
            );
            self
        }
    }

    impl Session for Recorded {
        fn get(&mut self, path: &str) -> Result<Vec<Notification>, GetError> {
            self.answers
                .get(path)
                .cloned()
                .unwrap_or_else(|| Err(GetError::Unsupported(format!("NotFound: {path}"))))
        }
    }

    #[derive(Clone, Copy)]
    enum GetReply {
        Normal,
        StallBody,
        StallTrailers,
    }

    /// A gNMI target on a local port that answers from the recorded switch, minus LLDP, and
    /// keeps every Get request it receives. Tests may stop a Get after its headers or message.
    #[derive(Clone)]
    struct FakeTarget {
        password: &'static str,
        requests: Arc<Mutex<Vec<GetRequest>>>,
        get_reply: GetReply,
    }

    impl NamedService for FakeTarget {
        const NAME: &'static str = "gnmi.gNMI";
    }

    impl FakeTarget {
        fn authorize<T>(&self, request: &tonic::Request<T>) -> Result<(), Status> {
            let metadata = request.metadata();
            let given = |key| metadata.get(key).and_then(|value| value.to_str().ok());
            if given("username") == Some("renga") && given("password") == Some(self.password) {
                Ok(())
            } else {
                Err(Status::unauthenticated("bad credentials"))
            }
        }

        fn get(&self, request: GetRequest) -> Result<GetResponse, Status> {
            self.requests.lock().unwrap().push(request.clone());
            let path: Vec<_> = request.path[0]
                .elem
                .iter()
                .map(|elem| elem.name.as_str())
                .collect();
            let path = path.join("/");
            if path == openconfig::LLDP {
                return Err(Status::unimplemented("LLDP is not modelled"));
            }
            let notification = openconfig::tests::recorded()
                .into_iter()
                .find(|(recorded, _)| *recorded == path)
                .map(|(_, notification)| notification)
                .ok_or_else(|| Status::not_found(path))?;
            Ok(GetResponse {
                notification: vec![notification],
            })
        }

        /// Serves on a new thread over TLS as `localhost`; returns its port.
        fn serve(self, cert_pem: String, key_pem: String) -> u16 {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            listener.set_nonblocking(true).unwrap();
            thread::spawn(move || {
                tokio::runtime::Runtime::new()
                    .unwrap()
                    .block_on(async move {
                        let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                        tonic::transport::Server::builder()
                            .tls_config(
                                tonic::transport::ServerTlsConfig::new()
                                    .identity(Identity::from_pem(cert_pem, key_pem)),
                            )
                            .unwrap()
                            .add_service(self)
                            .serve_with_incoming(TcpListenerStream::new(listener))
                            .await
                            .unwrap();
                    });
            });
            port
        }
    }

    impl tower::Service<http::Request<tonic::body::Body>> for FakeTarget {
        type Response = http::Response<tonic::body::Body>;
        type Error = Infallible;
        type Future = Pin<Box<dyn Future<Output = Result<Self::Response, Infallible>> + Send>>;

        fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Infallible>> {
            Poll::Ready(Ok(()))
        }

        fn call(&mut self, request: http::Request<tonic::body::Body>) -> Self::Future {
            let target = self.clone();
            Box::pin(async move {
                Ok(match request.uri().path() {
                    "/gnmi.gNMI/Capabilities" => {
                        let service =
                            tower::service_fn(move |request: tonic::Request<CapabilityRequest>| {
                                let result = target.authorize(&request).map(|()| {
                                    tonic::Response::new(CapabilityResponse {
                                        supported_encodings: vec![
                                            Encoding::Json as i32,
                                            Encoding::JsonIetf as i32,
                                        ],
                                        g_nmi_version: "0.10.0".into(),
                                    })
                                });
                                async move { result }
                            });
                        tonic::server::Grpc::new(
                            ProstCodec::<CapabilityResponse, CapabilityRequest>::default(),
                        )
                        .unary(service, request)
                        .await
                    }
                    "/gnmi.gNMI/Get" => {
                        if matches!(target.get_reply, GetReply::Normal) {
                            let service =
                                tower::service_fn(move |request: tonic::Request<GetRequest>| {
                                    let result = target
                                        .authorize(&request)
                                        .and_then(|()| target.get(request.into_inner()))
                                        .map(tonic::Response::new);
                                    async move { result }
                                });
                            tonic::server::Grpc::new(
                                ProstCodec::<GetResponse, GetRequest>::default(),
                            )
                            .unary(service, request)
                            .await
                        } else {
                            let service =
                                tower::service_fn(move |request: tonic::Request<GetRequest>| {
                                    let result = target
                                        .authorize(&request)
                                        .and_then(|()| target.get(request.into_inner()));
                                    let reply = target.get_reply;
                                    async move {
                                        let response = result?;
                                        let (sender, receiver) = tokio::sync::mpsc::channel(1);
                                        if matches!(reply, GetReply::StallTrailers) {
                                            sender.send(Ok(response)).await.unwrap();
                                        }
                                        tokio::spawn(async move {
                                            std::future::pending::<()>().await;
                                            drop(sender);
                                        });
                                        Ok(tonic::Response::new(ReceiverStream::new(receiver)))
                                    }
                                });
                            tonic::server::Grpc::new(
                                ProstCodec::<GetResponse, GetRequest>::default(),
                            )
                            .server_streaming(service, request)
                            .await
                        }
                    }
                    _ => Status::unimplemented("not gNMI").into_http(),
                })
            })
        }
    }

    #[test]
    fn reads_a_target_over_tls_with_a_password() {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let target = FakeTarget {
            password: "secret",
            requests: Arc::default(),
            get_reply: GetReply::Normal,
        };
        let port = target
            .clone()
            .serve(cert.pem(), signing_key.serialize_pem());
        let directory = std::env::temp_dir().join(format!("renga-gnmi-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join("ca.pem"), cert.pem()).unwrap();
        fs::write(directory.join("password"), "secret\n").unwrap();
        let mut collector = GnmiCollector {
            id: "spines".into(),
            targets: vec![Target::parse(&format!("127.0.0.1:{port}")).unwrap()],
            credentials: Some(Credentials {
                username: "renga".into(),
                password_file: directory.join("password"),
            }),
            transport: Transport::Tls {
                ca_file: Some(directory.join("ca.pem")),
                client_identity: None,
                server_name: Some("localhost".into()),
            },
            interval: Duration::from_secs(900),
            timeout: Duration::from_secs(5),
            max_concurrent_targets: 1,
        };
        let poll = |collector: &GnmiCollector| {
            crate::gnmi::poll(collector, &Cancellation::default(), |target: &Target| {
                WireSession::open(target, collector)
                    .map(|session| Box::new(session) as Box<dyn Session>)
            })
        };

        let outcomes = poll(&collector);

        let (resource, sections) = outcomes[0].result.as_ref().unwrap();
        assert_eq!(
            resource.identifiers.serial_number.as_deref(),
            Some("JPE12345678")
        );
        assert!(sections.interface_vlans && !sections.interface_neighbors);
        let requests = target.requests.lock().unwrap().clone();
        assert_eq!(requests.len(), openconfig::PATHS.len());
        assert!(requests.iter().all(|request| {
            request.path[0].origin == "openconfig" && request.encoding == Encoding::JsonIetf as i32
        }));

        fs::write(directory.join("password"), "wrong\n").unwrap();
        let outcomes = poll(&collector);
        assert_eq!(
            outcomes[0].result.as_ref().unwrap_err(),
            "Unauthenticated: bad credentials"
        );

        // Verified against the configured CA, the certificate does not name the address.
        collector.transport = Transport::Tls {
            ca_file: Some(directory.join("ca.pem")),
            client_identity: None,
            server_name: None,
        };
        let outcomes = poll(&collector);
        fs::remove_dir_all(directory).unwrap();
        assert_eq!(
            outcomes[0].result.as_ref().unwrap_err(),
            "cannot connect: transport error: invalid peer certificate: certificate not valid \
             for name \"127.0.0.1\"; certificate is only valid for DnsName(\"localhost\")"
        );
    }

    #[test]
    fn bounds_the_whole_rpc_and_keeps_healthy_targets_reporting() {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let directory = std::env::temp_dir().join(format!("renga-gnmi-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join("ca.pem"), cert.pem()).unwrap();
        fs::write(directory.join("password"), "secret\n").unwrap();

        for stalled_reply in [GetReply::StallBody, GetReply::StallTrailers] {
            let healthy_port = FakeTarget {
                password: "secret",
                requests: Arc::default(),
                get_reply: GetReply::Normal,
            }
            .serve(cert.pem(), signing_key.serialize_pem());
            let stalled_port = FakeTarget {
                password: "secret",
                requests: Arc::default(),
                get_reply: stalled_reply,
            }
            .serve(cert.pem(), signing_key.serialize_pem());
            let collector = GnmiCollector {
                id: "spines".into(),
                targets: [healthy_port, stalled_port]
                    .map(|port| Target::parse(&format!("127.0.0.1:{port}")).unwrap())
                    .to_vec(),
                credentials: Some(Credentials {
                    username: "renga".into(),
                    password_file: directory.join("password"),
                }),
                transport: Transport::Tls {
                    ca_file: Some(directory.join("ca.pem")),
                    client_identity: None,
                    server_name: Some("localhost".into()),
                },
                interval: Duration::from_secs(900),
                timeout: Duration::from_millis(100),
                max_concurrent_targets: 2,
            };

            let started = Instant::now();
            let outcomes =
                crate::gnmi::poll(&collector, &Cancellation::default(), |target: &Target| {
                    WireSession::open(target, &collector)
                        .map(|session| Box::new(session) as Box<dyn Session>)
                });

            assert!(outcomes[0].result.is_ok());
            assert_eq!(
                outcomes[1].result.as_ref().unwrap_err(),
                "system/state: DeadlineExceeded: gNMI request timed out"
            );
            assert!(started.elapsed() < Duration::from_secs(1));
        }

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn a_timed_out_blocking_resolver_does_not_withhold_healthy_targets() {
        let collector = GnmiCollector {
            id: "spines".into(),
            targets: ["healthy.example:9339", "stalled.example:9339"]
                .map(|address| Target::parse(address).unwrap())
                .to_vec(),
            credentials: None,
            transport: Transport::Plaintext,
            interval: Duration::from_secs(900),
            timeout: Duration::from_millis(20),
            max_concurrent_targets: 2,
        };
        let (release, blocked) = mpsc::channel();
        let blocked = Arc::new(Mutex::new(Some(blocked)));
        let resolver_started = Arc::new(AtomicBool::new(false));

        let started = Instant::now();
        let outcomes = crate::gnmi::poll(
            &collector,
            &Cancellation::default(),
            |target: &Target| -> Result<Box<dyn Session>, String> {
                if target.host == "healthy.example" {
                    return Ok(Box::new(Recorded::switch()));
                }
                let blocked = blocked.lock().unwrap().take().unwrap();
                let resolver_started = Arc::clone(&resolver_started);
                let blocking_started = Arc::clone(&resolver_started);
                let runtime = Runtime::new().unwrap();
                runtime.block_on(async move {
                    tokio::task::spawn_blocking(move || {
                        blocking_started.store(true, Ordering::Release);
                        let _ = blocked.recv_timeout(Duration::from_secs(2));
                    });
                    while !resolver_started.load(Ordering::Acquire) {
                        tokio::task::yield_now().await;
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                });
                Err("cannot connect: timed out".into())
            },
        );
        release.send(()).unwrap();

        assert!(outcomes[0].result.is_ok());
        assert_eq!(
            outcomes[1].result.as_ref().unwrap_err(),
            "cannot connect: timed out"
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn prefers_json_ietf_and_falls_back_to_json() {
        let json_ietf = Encoding::JsonIetf as i32;
        let json = Encoding::Json as i32;
        let proto = Encoding::Proto as i32;
        assert_eq!(encoding(&[json, json_ietf]), Ok(Encoding::JsonIetf));
        assert_eq!(encoding(&[proto, json]), Ok(Encoding::Json));
        assert_eq!(encoding(&[]), Ok(Encoding::JsonIetf));
        assert!(encoding(&[proto]).is_err());
    }

    #[test]
    fn addresses_ipv6_targets_in_brackets() {
        let collector = GnmiCollector {
            id: "lab".into(),
            targets: Vec::new(),
            credentials: None,
            transport: Transport::Plaintext,
            interval: Duration::from_secs(60),
            timeout: Duration::from_secs(1),
            max_concurrent_targets: 1,
        };
        let target = Target::parse_with_default_port("2001:db8::1", 9339).unwrap();

        let endpoint = endpoint(&target, &collector).unwrap();

        assert_eq!(endpoint.uri().to_string(), "http://[2001:db8::1]:9339/");
    }
}
