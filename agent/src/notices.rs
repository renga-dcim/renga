//! Optional job notices over Renga's agent socket (RFD 9, "Phoenix Channels
//! notification").
//!
//! The listener holds a WebSocket open, joins this installation's channel and
//! raises a flag when Renga says jobs are waiting. It never receives a job:
//! the agent still leases over HTTPS. When the socket is down, refused or
//! blocked by a proxy, the agent behaves exactly as it would without it, with
//! the check-in hint and the once-per-interval lease attempt.

use crate::{cancellation::Cancellation, transport::NoticeEndpoint};
use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine};
use rustls::{pki_types::ServerName, ClientConnection, StreamOwned};
use serde_json::{json, Value};
use std::{
    fmt,
    io::{self, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use tracing::{debug, info, warn};
use tungstenite::{
    client::IntoClientRequest,
    http::{header::SEC_WEBSOCKET_PROTOCOL, HeaderValue},
    Message, WebSocket,
};

const SOCKET_PATH: &str = "/api/v1/agent/socket/websocket";
/// Phoenix's channel heartbeat; the server drops a socket silent for 60s.
const HEARTBEAT: Duration = Duration::from_secs(30);
/// No frame for this long, heartbeat replies included, means the connection
/// is gone even if TCP has not noticed.
const SILENCE_LIMIT: Duration = Duration::from_secs(75);
/// How long one read waits, so the loop can heartbeat and notice shutdown.
const POLL: Duration = Duration::from_millis(250);
const FIRST_RETRY: Duration = Duration::from_secs(1);
const MAX_RETRY: Duration = Duration::from_secs(300);
const JOIN_REF: &str = "1";

/// Set when Renga says jobs are waiting, until the agent starts a lease pass.
#[derive(Clone, Default)]
pub struct Notices(Arc<AtomicBool>);

impl Notices {
    /// Whether a notice arrived since the last call, clearing it.
    pub fn take(&self) -> bool {
        self.0.swap(false, Ordering::SeqCst)
    }

    fn raise(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// The background thread that keeps the socket open, reconnecting with
/// backoff for as long as the agent runs.
pub struct Listener {
    stop: Cancellation,
    handle: thread::JoinHandle<()>,
}

impl Listener {
    pub fn spawn(endpoint: NoticeEndpoint, notices: Notices, stopped: Cancellation) -> Self {
        Self::spawn_with_retry(endpoint, notices, stopped, FIRST_RETRY)
    }

    fn spawn_with_retry(
        endpoint: NoticeEndpoint,
        notices: Notices,
        stopped: Cancellation,
        first_retry: Duration,
    ) -> Self {
        let stop = Cancellation::default();
        let own_stop = stop.clone();
        let handle = thread::spawn(move || {
            let cancelled = || own_stop.cancelled() || stopped.cancelled();
            run(&endpoint, &notices, &cancelled, first_retry);
        });
        Self { stop, handle }
    }

    /// Closes the socket and waits for the thread, for a reload or shutdown.
    pub fn stop(self) {
        self.stop.cancel();
        let _ = self.handle.join();
    }
}

fn run(
    endpoint: &NoticeEndpoint,
    notices: &Notices,
    cancelled: &dyn Fn() -> bool,
    first_retry: Duration,
) {
    let mut retry = first_retry;
    let mut quiet = false;
    while !cancelled() {
        match listen(endpoint, notices, cancelled) {
            Ok(()) => return,
            Err(failure) => {
                if failure.joined {
                    retry = first_retry;
                    quiet = false;
                }
                // One warning per outage; repeats while it lasts stay at debug.
                if quiet {
                    debug!(error = %failure, "job notice socket unavailable");
                } else {
                    warn!(error = %failure, "job notice socket unavailable; leasing on check-ins until it returns");
                    quiet = true;
                }
            }
        }
        sleep_unless(cancelled, jittered(retry));
        retry = (retry * 2).min(MAX_RETRY);
    }
}

#[derive(Debug)]
struct ListenError {
    message: String,
    /// Whether the channel was joined before this failure, so the outage is new.
    joined: bool,
}

impl ListenError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            joined: false,
        }
    }

    fn after_join(self) -> Self {
        Self {
            joined: true,
            ..self
        }
    }
}

impl fmt::Display for ListenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<tungstenite::Error> for ListenError {
    fn from(error: tungstenite::Error) -> Self {
        match error {
            tungstenite::Error::Http(response) => {
                Self::new(format!("socket refused with HTTP {}", response.status()))
            }
            other => Self::new(other.to_string()),
        }
    }
}

/// One connection: open, join, then wait for notices until it fails or the
/// agent stops. Returns `Ok` only when stopped.
fn listen(
    endpoint: &NoticeEndpoint,
    notices: &Notices,
    cancelled: &dyn Fn() -> bool,
) -> Result<(), ListenError> {
    let topic = format!("installation:{}", endpoint.installation_id);
    let mut socket = connect(endpoint)?;
    send(&mut socket, JOIN_REF, &topic, "phx_join")?;
    let reply = await_join(&mut socket, &topic, endpoint.timeout, cancelled)?;
    if reply["status"] != "ok" {
        let reason = reply["response"]["reason"].as_str().unwrap_or("unknown");
        return Err(ListenError::new(format!("channel join refused: {reason}")));
    }
    info!("job notice socket connected");
    // Jobs queued while the agent was away are reported in the join reply.
    if reply["response"]["jobs_waiting"] == true {
        notices.raise();
    }
    socket.get_mut().set_read_timeout(Some(POLL))?;

    let mut next_ref = 2_u64;
    let mut next_heartbeat = Instant::now() + HEARTBEAT;
    let mut last_heard = Instant::now();
    loop {
        if cancelled() {
            let _ = socket.close(None);
            let _ = socket.flush();
            return Ok(());
        }
        let now = Instant::now();
        if now.duration_since(last_heard) > SILENCE_LIMIT {
            return Err(ListenError::new("socket went silent").after_join());
        }
        if now >= next_heartbeat {
            send(&mut socket, &next_ref.to_string(), "phoenix", "heartbeat")
                .map_err(ListenError::after_join)?;
            next_ref += 1;
            next_heartbeat = now + HEARTBEAT;
        }
        match socket.read() {
            Ok(message) => {
                last_heard = Instant::now();
                if let Message::Text(text) = message {
                    let frame = Frame::parse(text.as_str());
                    if frame.topic == topic {
                        match frame.event.as_str() {
                            "jobs_waiting" => notices.raise(),
                            "phx_error" | "phx_close" => {
                                return Err(ListenError::new("channel closed by Renga").after_join())
                            }
                            _ => {}
                        }
                    }
                }
            }
            Err(tungstenite::Error::Io(error)) if timed_out(&error) => {
                // Answer any ping read meanwhile.
                match socket.flush() {
                    Err(tungstenite::Error::Io(error)) if timed_out(&error) => {}
                    other => other.map_err(|e| ListenError::from(e).after_join())?,
                }
            }
            Err(error) => return Err(ListenError::from(error).after_join()),
        }
    }
}

fn await_join(
    socket: &mut WebSocket<Stream>,
    topic: &str,
    timeout: Duration,
    cancelled: &dyn Fn() -> bool,
) -> Result<Value, ListenError> {
    let deadline = Instant::now() + timeout;
    socket.get_mut().set_read_timeout(Some(POLL))?;
    while Instant::now() < deadline && !cancelled() {
        match socket.read() {
            Ok(Message::Text(text)) => {
                let frame = Frame::parse(text.as_str());
                if frame.topic == topic
                    && frame.event == "phx_reply"
                    && frame.reference.as_deref() == Some(JOIN_REF)
                {
                    return Ok(frame.payload);
                }
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(error)) if timed_out(&error) => {}
            Err(error) => return Err(error.into()),
        }
    }
    Err(ListenError::new("no reply to the channel join"))
}

/// A Phoenix V2 message: `[join_ref, ref, topic, event, payload]`.
struct Frame {
    reference: Option<String>,
    topic: String,
    event: String,
    payload: Value,
}

impl Frame {
    fn parse(text: &str) -> Self {
        let value: Value = serde_json::from_str(text).unwrap_or(Value::Null);
        let field = |index: usize| value.get(index).and_then(Value::as_str).map(String::from);
        Self {
            reference: field(1),
            topic: field(2).unwrap_or_default(),
            event: field(3).unwrap_or_default(),
            payload: value.get(4).cloned().unwrap_or(Value::Null),
        }
    }
}

fn send(
    socket: &mut WebSocket<Stream>,
    reference: &str,
    topic: &str,
    event: &str,
) -> Result<(), ListenError> {
    let join_ref = (event == "phx_join").then_some(JOIN_REF);
    let frame = json!([join_ref, reference, topic, event, {}]).to_string();
    socket.send(Message::text(frame))?;
    Ok(())
}

fn connect(endpoint: &NoticeEndpoint) -> Result<WebSocket<Stream>, ListenError> {
    let base = &endpoint.base_url;
    let host = base
        .host_str()
        .ok_or_else(|| ListenError::new("server URL has no host"))?;
    let port = base
        .port_or_known_default()
        .ok_or_else(|| ListenError::new("server URL has no port"))?;
    let tcp = connect_tcp(host, port, endpoint.timeout)?;
    tcp.set_read_timeout(Some(endpoint.timeout))?;
    tcp.set_write_timeout(Some(endpoint.timeout))?;
    let secure = base.scheme() == "https";
    let stream = if secure {
        let name = ServerName::try_from(host.to_string())
            .map_err(|_| ListenError::new("server host is not a valid TLS name"))?;
        let connection = ClientConnection::new(Arc::clone(&endpoint.tls), name)
            .map_err(|error| ListenError::new(format!("cannot start TLS: {error}")))?;
        Stream::Tls(Box::new(StreamOwned::new(connection, tcp)))
    } else {
        Stream::Plain(tcp)
    };

    let scheme = if secure { "wss" } else { "ws" };
    let authority = match base.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
    };
    let url = format!("{scheme}://{authority}{SOCKET_PATH}?vsn=2.0.0");
    let mut request = url.into_client_request()?;
    // Phoenix reads the token from the subprotocol list, so it never appears
    // in a URL or an access log. It answers with the plain `phoenix` entry.
    let mut protocols = HeaderValue::from_str(&format!(
        "phoenix, base64url.bearer.phx.{}",
        STANDARD_NO_PAD.encode(&endpoint.intake_api_key)
    ))
    .map_err(|_| ListenError::new("invalid intake API key"))?;
    protocols.set_sensitive(true);
    let headers = request.headers_mut();
    headers.insert(SEC_WEBSOCKET_PROTOCOL, protocols);
    headers.insert(
        "x-renga-installation-id",
        HeaderValue::from_str(&endpoint.installation_id)
            .map_err(|_| ListenError::new("invalid installation ID"))?,
    );
    headers.insert(
        "user-agent",
        HeaderValue::from_static(concat!("renga-agent/", env!("CARGO_PKG_VERSION"))),
    );
    let (socket, _response) =
        tungstenite::client::client(request, stream).map_err(|error| match error {
            tungstenite::HandshakeError::Failure(error) => ListenError::from(error),
            tungstenite::HandshakeError::Interrupted(_) => {
                ListenError::new("socket handshake timed out")
            }
        })?;
    Ok(socket)
}

fn connect_tcp(host: &str, port: u16, timeout: Duration) -> Result<TcpStream, ListenError> {
    let mut last = None;
    for address in (host, port).to_socket_addrs()? {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(stream) => return Ok(stream),
            Err(error) => last = Some(error),
        }
    }
    Err(match last {
        Some(error) => error.into(),
        None => ListenError::new("server host did not resolve"),
    })
}

impl From<io::Error> for ListenError {
    fn from(error: io::Error) -> Self {
        Self::new(error.to_string())
    }
}

fn timed_out(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    )
}

/// Spreads reconnects over the second half of the interval, so agents cut off
/// together do not all return in the same instant.
fn jittered(interval: Duration) -> Duration {
    let half = interval / 2;
    let spread = half.as_millis().max(1);
    half + Duration::from_millis((uuid::Uuid::new_v4().as_u128() % spread) as u64)
}

fn sleep_unless(cancelled: &dyn Fn() -> bool, duration: Duration) {
    let deadline = Instant::now() + duration;
    while !cancelled() {
        let now = Instant::now();
        if now >= deadline {
            return;
        }
        thread::sleep((deadline - now).min(Duration::from_millis(50)));
    }
}

/// A plain or TLS connection, so the socket can use the HTTP client's
/// pinned roots and provider.
pub enum Stream {
    Plain(TcpStream),
    Tls(Box<StreamOwned<ClientConnection, TcpStream>>),
}

impl Stream {
    fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        match self {
            Stream::Plain(stream) => stream.set_read_timeout(timeout),
            Stream::Tls(stream) => stream.sock.set_read_timeout(timeout),
        }
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(stream) => stream.read(buf),
            Stream::Tls(stream) => stream.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(stream) => stream.write(buf),
            Stream::Tls(stream) => stream.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Stream::Plain(stream) => stream.flush(),
            Stream::Tls(stream) => stream.flush(),
        }
    }
}

#[cfg(test)]
// The fake server's handshake callback must return tungstenite's own error type.
#[allow(clippy::result_large_err)]
mod tests {
    use super::*;
    use std::{net::TcpListener, sync::mpsc};
    use tungstenite::handshake::server::{Request, Response};

    const TOKEN: &str = "renga_intake_test+/key";
    const INSTALLATION: &str = "67e55044-10b1-426f-9247-bb680e5fe0c8";

    fn endpoint(origin: &str) -> NoticeEndpoint {
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();
        NoticeEndpoint {
            base_url: origin.parse().unwrap(),
            intake_api_key: TOKEN.into(),
            installation_id: INSTALLATION.into(),
            tls: Arc::new(tls),
            timeout: Duration::from_secs(5),
        }
    }

    /// What one fake Phoenix connection saw and how it answers the join.
    struct Seen {
        protocols: String,
        installation: String,
        path: String,
        join: Value,
    }

    /// Accepts `connections` sockets in turn. Each answers the join with
    /// `reply`, then runs `after` with the open socket.
    fn phoenix(
        connections: usize,
        reply: Value,
        after: impl Fn(&mut WebSocket<TcpStream>) + Send + 'static,
    ) -> (String, mpsc::Receiver<Seen>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (seen, received) = mpsc::channel();
        thread::spawn(move || {
            for _ in 0..connections {
                let (stream, _) = listener.accept().unwrap();
                let mut headers = (String::new(), String::new(), String::new());
                let mut socket =
                    tungstenite::accept_hdr(stream, |request: &Request, mut response: Response| {
                        let header = |name| {
                            request
                                .headers()
                                .get(name)
                                .map(|value: &HeaderValue| value.to_str().unwrap().to_string())
                                .unwrap_or_default()
                        };
                        headers = (
                            header("sec-websocket-protocol"),
                            header("x-renga-installation-id"),
                            request.uri().to_string(),
                        );
                        response
                            .headers_mut()
                            .insert(SEC_WEBSOCKET_PROTOCOL, HeaderValue::from_static("phoenix"));
                        Ok(response)
                    })
                    .unwrap();
                let join: Value =
                    serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
                let topic = join[2].clone();
                socket
                    .send(Message::text(
                        json!([JOIN_REF, JOIN_REF, topic, "phx_reply", reply]).to_string(),
                    ))
                    .unwrap();
                seen.send(Seen {
                    protocols: headers.0,
                    installation: headers.1,
                    path: headers.2,
                    join,
                })
                .unwrap();
                after(&mut socket);
            }
        });
        (origin, received)
    }

    fn joined(waiting: bool) -> Value {
        json!({"status": "ok", "response": {"jobs_waiting": waiting}})
    }

    fn eventually(condition: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if condition() {
                return true;
            }
            thread::sleep(Duration::from_millis(10));
        }
        false
    }

    fn push(socket: &mut WebSocket<TcpStream>, event: &str) {
        let topic = format!("installation:{INSTALLATION}");
        socket
            .send(Message::text(
                json!([null, null, topic, event, {}]).to_string(),
            ))
            .unwrap();
    }

    /// Keeps the server end open until the client hangs up.
    fn hold(socket: &mut WebSocket<TcpStream>) {
        while socket.read().is_ok() {}
    }

    #[test]
    fn authenticates_like_the_https_api_and_joins_its_installation() {
        let (origin, seen) = phoenix(1, joined(false), hold);
        let listener = Listener::spawn(
            endpoint(&origin),
            Notices::default(),
            Cancellation::default(),
        );

        let seen = seen.recv_timeout(Duration::from_secs(5)).unwrap();
        let encoded = STANDARD_NO_PAD.encode(TOKEN);
        assert_eq!(
            seen.protocols,
            format!("phoenix, base64url.bearer.phx.{encoded}")
        );
        assert_eq!(seen.installation, INSTALLATION);
        assert_eq!(seen.path, "/api/v1/agent/socket/websocket?vsn=2.0.0");
        assert!(!seen.path.contains("renga_intake"));
        assert_eq!(
            seen.join,
            json!([
                "1",
                "1",
                format!("installation:{INSTALLATION}"),
                "phx_join",
                {}
            ])
        );
        listener.stop();
    }

    #[test]
    fn a_pushed_notice_raises_the_flag_once() {
        let (origin, _seen) = phoenix(1, joined(false), |socket| {
            push(socket, "jobs_waiting");
            hold(socket);
        });
        let notices = Notices::default();
        let listener = Listener::spawn(endpoint(&origin), notices.clone(), Cancellation::default());

        assert!(eventually(|| notices.take()));
        assert!(!notices.take());
        listener.stop();
    }

    #[test]
    fn jobs_already_waiting_at_join_raise_the_flag() {
        let (origin, _seen) = phoenix(1, joined(true), hold);
        let notices = Notices::default();
        let listener = Listener::spawn(endpoint(&origin), notices.clone(), Cancellation::default());

        assert!(eventually(|| notices.take()));
        listener.stop();
    }

    #[test]
    fn ignores_other_topics_and_events() {
        let (origin, _seen) = phoenix(1, joined(false), |socket| {
            socket
                .send(Message::text(
                    json!([null, null, "installation:other", "jobs_waiting", {}]).to_string(),
                ))
                .unwrap();
            push(socket, "something_else");
            hold(socket);
        });
        let notices = Notices::default();
        let listener = Listener::spawn(endpoint(&origin), notices.clone(), Cancellation::default());

        thread::sleep(Duration::from_millis(300));
        assert!(!notices.take());
        listener.stop();
    }

    #[test]
    fn reconnects_after_a_refused_join_or_a_closed_channel() {
        let refused = json!({"status": "error", "response": {"reason": "agent_not_registered"}});
        let (origin, seen) = phoenix(3, refused, |socket| push(socket, "phx_close"));
        let listener = Listener::spawn_with_retry(
            endpoint(&origin),
            Notices::default(),
            Cancellation::default(),
            Duration::from_millis(20),
        );

        for _ in 0..3 {
            seen.recv_timeout(Duration::from_secs(5)).unwrap();
        }
        listener.stop();
    }

    #[test]
    fn stops_promptly_while_waiting_to_reconnect() {
        let listener = Listener::spawn(
            endpoint("http://127.0.0.1:9"),
            Notices::default(),
            Cancellation::default(),
        );
        thread::sleep(Duration::from_millis(100));

        let started = Instant::now();
        listener.stop();
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn agent_shutdown_closes_an_open_socket() {
        let (origin, seen) = phoenix(1, joined(false), hold);
        let stopped = Cancellation::default();
        let listener = Listener::spawn(endpoint(&origin), Notices::default(), stopped.clone());
        seen.recv_timeout(Duration::from_secs(5)).unwrap();

        stopped.cancel();
        let started = Instant::now();
        listener.stop();
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn the_endpoint_never_prints_the_key() {
        let printed = format!("{:?}", endpoint("http://127.0.0.1:9"));
        assert!(!printed.contains(TOKEN));
    }
}
