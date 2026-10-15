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
use socket2::{Domain, Protocol, SockAddr, Socket, Type};
use std::{
    fmt,
    io::{self, Read, Write},
    net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, OnceLock,
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
use url::Host;

const SOCKET_PATH: &str = "/api/v1/agent/socket/websocket";
/// Phoenix's channel heartbeat; the server drops a socket silent for 60s.
const HEARTBEAT: Duration = Duration::from_secs(30);
/// No frame for this long, heartbeat replies included, means the connection
/// is gone even if TCP has not noticed.
const SILENCE_LIMIT: Duration = Duration::from_secs(75);
/// How long one read waits, so the loop can heartbeat and notice shutdown.
const POLL: Duration = Duration::from_millis(250);
const CONNECT_STAGGER: Duration = Duration::from_millis(250);
const CONNECT_POLL: Duration = Duration::from_millis(10);
const FIRST_RETRY: Duration = Duration::from_secs(1);
const MAX_RETRY: Duration = Duration::from_secs(300);
const JOIN_REF: &str = "1";

#[derive(Clone, Copy)]
struct Timing {
    heartbeat: Duration,
    silence_limit: Duration,
    poll: Duration,
}

const TIMING: Timing = Timing {
    heartbeat: HEARTBEAT,
    silence_limit: SILENCE_LIMIT,
    poll: POLL,
};

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
            Err(_failure) if cancelled() => return,
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
    listen_with_timing(endpoint, notices, cancelled, TIMING)
}

fn listen_with_timing(
    endpoint: &NoticeEndpoint,
    notices: &Notices,
    cancelled: &dyn Fn() -> bool,
    timing: Timing,
) -> Result<(), ListenError> {
    let topic = format!("installation:{}", endpoint.installation_id);
    let mut socket = connect(endpoint, cancelled)?;
    socket
        .get_mut()
        .set_deadline(Some(Instant::now() + endpoint.timeout));
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
    let mut next_ref = 2_u64;
    let mut next_heartbeat = Instant::now() + timing.heartbeat;
    let mut last_heard = Instant::now();
    loop {
        if cancelled() {
            socket
                .get_mut()
                .set_deadline(Some(Instant::now() + timing.poll));
            let _ = socket.close(None);
            let _ = socket.flush();
            return Ok(());
        }
        let now = Instant::now();
        if now.duration_since(last_heard) > timing.silence_limit {
            return Err(ListenError::new("socket went silent").after_join());
        }
        if now >= next_heartbeat {
            send(&mut socket, &next_ref.to_string(), "phoenix", "heartbeat")
                .map_err(ListenError::after_join)?;
            next_ref += 1;
            next_heartbeat = now + timing.heartbeat;
        }
        socket
            .get_mut()
            .set_deadline(Some(Instant::now() + timing.poll));
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
    socket: &mut WebSocket<Stream<'_>>,
    topic: &str,
    timeout: Duration,
    cancelled: &dyn Fn() -> bool,
) -> Result<Value, ListenError> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline && !cancelled() {
        socket
            .get_mut()
            .set_deadline(Some(deadline.min(Instant::now() + POLL)));
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
    socket: &mut WebSocket<Stream<'_>>,
    reference: &str,
    topic: &str,
    event: &str,
) -> Result<(), ListenError> {
    socket.get_mut().set_deadline(Some(Instant::now() + POLL));
    let join_ref = (event == "phx_join").then_some(JOIN_REF);
    let frame = json!([join_ref, reference, topic, event, {}]).to_string();
    socket.send(Message::text(frame))?;
    Ok(())
}

fn connect<'a>(
    endpoint: &NoticeEndpoint,
    cancelled: &'a dyn Fn() -> bool,
) -> Result<WebSocket<Stream<'a>>, ListenError> {
    let base = &endpoint.base_url;
    let host = base
        .host()
        .ok_or_else(|| ListenError::new("server URL has no host"))?;
    let port = base
        .port_or_known_default()
        .ok_or_else(|| ListenError::new("server URL has no port"))?;
    let deadline = Instant::now() + endpoint.timeout;
    let addresses = resolve(host.clone(), port, deadline, cancelled)?;
    let tcp = InterruptibleTcp::new(connect_tcp(&addresses, deadline, cancelled)?, cancelled);
    let mut tcp = tcp;
    tcp.set_deadline(Some(deadline));
    let secure = base.scheme() == "https";
    let stream = if secure {
        let name = server_name(host.clone())?;
        let connection = ClientConnection::new(Arc::clone(&endpoint.tls), name)
            .map_err(|error| ListenError::new(format!("cannot start TLS: {error}")))?;
        Stream::Tls(Box::new(StreamOwned::new(connection, tcp)))
    } else {
        Stream::Plain(tcp)
    };

    let scheme = if secure { "wss" } else { "ws" };
    let host = base.host_str().expect("host was checked above");
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
    finish_handshake(
        tungstenite::client::client(request, stream),
        deadline,
        cancelled,
    )
}

fn server_name(host: Host<&str>) -> Result<ServerName<'static>, ListenError> {
    match host {
        Host::Domain(name) => ServerName::try_from(name.to_string())
            .map_err(|_| ListenError::new("server host is not a valid TLS name")),
        Host::Ipv4(address) => Ok(ServerName::IpAddress(IpAddr::V4(address).into())),
        Host::Ipv6(address) => Ok(ServerName::IpAddress(IpAddr::V6(address).into())),
    }
}

type Resolution = (String, u16, mpsc::Sender<io::Result<Vec<SocketAddr>>>);

/// Name resolution has no cancellable std API, so one process-wide worker
/// contains a stuck system resolver without accumulating detached listeners.
fn resolver() -> &'static mpsc::SyncSender<Resolution> {
    static RESOLVER: OnceLock<mpsc::SyncSender<Resolution>> = OnceLock::new();
    RESOLVER.get_or_init(|| {
        let (requests, work) = mpsc::sync_channel::<Resolution>(1);
        thread::Builder::new()
            .name("renga-notice-dns".into())
            .spawn(move || {
                while let Ok((host, port, reply)) = work.recv() {
                    let result = (host.as_str(), port)
                        .to_socket_addrs()
                        .map(|addresses| addresses.collect());
                    let _ = reply.send(result);
                }
            })
            .expect("cannot start notice DNS worker");
        requests
    })
}

fn resolve(
    host: Host<&str>,
    port: u16,
    deadline: Instant,
    cancelled: &dyn Fn() -> bool,
) -> Result<Vec<SocketAddr>, ListenError> {
    match host {
        Host::Ipv4(address) => Ok(vec![SocketAddr::new(IpAddr::V4(address), port)]),
        Host::Ipv6(address) => Ok(vec![SocketAddr::new(IpAddr::V6(address), port)]),
        Host::Domain(host) => {
            let (reply, result) = mpsc::channel();
            resolver()
                .try_send((host.to_string(), port, reply))
                .map_err(|error| match error {
                    mpsc::TrySendError::Full(_) => {
                        ListenError::new("server name resolver is still busy")
                    }
                    mpsc::TrySendError::Disconnected(_) => {
                        ListenError::new("server name resolver stopped")
                    }
                })?;
            loop {
                remaining(deadline, cancelled)?;
                match result.recv_timeout(wait_slice(deadline)) {
                    Ok(Ok(addresses)) if addresses.is_empty() => {
                        return Err(ListenError::new("server host did not resolve"));
                    }
                    Ok(Ok(addresses)) => return Ok(addresses),
                    Ok(Err(error)) => return Err(error.into()),
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        return Err(ListenError::new("server name resolver stopped"));
                    }
                }
            }
        }
    }
}

fn connect_tcp(
    addresses: &[SocketAddr],
    deadline: Instant,
    cancelled: &dyn Fn() -> bool,
) -> Result<TcpStream, ListenError> {
    if addresses.is_empty() {
        return Err(ListenError::new("server host did not resolve"));
    }
    let mut last = None;
    let mut next_address = 0;
    let mut next_start = Instant::now();
    let mut pending = Vec::new();
    loop {
        remaining(deadline, cancelled)?;
        let now = Instant::now();
        if next_address < addresses.len() && now >= next_start {
            match start_connection(addresses[next_address]) {
                Ok(socket) => pending.push(socket),
                Err(error) => last = Some(error),
            }
            next_address += 1;
            next_start = if pending.is_empty() {
                now
            } else {
                now + CONNECT_STAGGER
            };
        }

        let mut index = 0;
        while index < pending.len() {
            match connection_ready(&pending[index]) {
                Ok(true) => {
                    let socket = pending.swap_remove(index);
                    socket.set_nonblocking(false)?;
                    return Ok(socket.into());
                }
                Ok(false) => index += 1,
                Err(error) => {
                    pending.swap_remove(index);
                    last = Some(error);
                    if pending.is_empty() {
                        next_start = Instant::now();
                    }
                }
            }
        }

        if pending.is_empty() && next_address == addresses.len() {
            return Err(last
                .map(ListenError::from)
                .unwrap_or_else(|| ListenError::new("server host did not resolve")));
        }
        let mut wait = wait_slice(deadline).min(CONNECT_POLL);
        if next_address < addresses.len() {
            wait = wait.min(next_start.saturating_duration_since(Instant::now()));
        }
        thread::sleep(wait);
    }
}

fn start_connection(address: SocketAddr) -> io::Result<Socket> {
    let socket = Socket::new(
        Domain::for_address(address),
        Type::STREAM,
        Some(Protocol::TCP),
    )?;
    socket.set_nonblocking(true)?;
    match socket.connect(&SockAddr::from(address)) {
        Ok(()) => Ok(socket),
        Err(error) if connection_in_progress(&error) => Ok(socket),
        Err(error) => Err(error),
    }
}

fn connection_ready(socket: &Socket) -> io::Result<bool> {
    if let Some(error) = socket.take_error()? {
        return Err(error);
    }
    Ok(socket.peer_addr().is_ok())
}

fn connection_in_progress(error: &io::Error) -> bool {
    if error.kind() == io::ErrorKind::WouldBlock {
        return true;
    }
    #[cfg(unix)]
    return error.raw_os_error() == Some(libc::EINPROGRESS);
    #[cfg(not(unix))]
    false
}

fn finish_handshake<'a>(
    first: Result<
        (
            WebSocket<Stream<'a>>,
            tungstenite::handshake::client::Response,
        ),
        tungstenite::HandshakeError<tungstenite::handshake::client::ClientHandshake<Stream<'a>>>,
    >,
    deadline: Instant,
    cancelled: &'a dyn Fn() -> bool,
) -> Result<WebSocket<Stream<'a>>, ListenError> {
    let mut handshake = match first {
        Ok((socket, _response)) => return Ok(socket),
        Err(tungstenite::HandshakeError::Failure(error)) => return Err(error.into()),
        Err(tungstenite::HandshakeError::Interrupted(handshake)) => handshake,
    };
    loop {
        remaining(deadline, cancelled)?;
        match handshake.handshake() {
            Ok((socket, _response)) => return Ok(socket),
            Err(tungstenite::HandshakeError::Failure(error)) => return Err(error.into()),
            Err(tungstenite::HandshakeError::Interrupted(next)) => handshake = next,
        }
    }
}

fn remaining(deadline: Instant, cancelled: &dyn Fn() -> bool) -> Result<(), ListenError> {
    if cancelled() {
        Err(ListenError::new("socket connection cancelled"))
    } else if Instant::now() >= deadline {
        Err(ListenError::new("socket connection timed out"))
    } else {
        Ok(())
    }
}

fn wait_slice(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now()).min(POLL)
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

/// Applies cancellation and one high-level operation deadline beneath TLS, so
/// partial wire progress cannot hold Rustls or Tungstenite in an inner loop.
pub struct InterruptibleTcp<'a> {
    stream: TcpStream,
    cancelled: &'a dyn Fn() -> bool,
    deadline: Option<Instant>,
}

impl<'a> InterruptibleTcp<'a> {
    fn new(stream: TcpStream, cancelled: &'a dyn Fn() -> bool) -> Self {
        Self {
            stream,
            cancelled,
            deadline: None,
        }
    }

    fn set_deadline(&mut self, deadline: Option<Instant>) {
        self.deadline = deadline;
    }

    fn timeout(&self) -> io::Result<Duration> {
        if (self.cancelled)() {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "socket operation cancelled",
            ));
        }
        let remaining = self
            .deadline
            .map(|deadline| deadline.saturating_duration_since(Instant::now()))
            .unwrap_or(POLL)
            .min(POLL);
        if remaining.is_zero() {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "socket operation timed out",
            ))
        } else {
            Ok(remaining)
        }
    }
}

impl Read for InterruptibleTcp<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.stream.set_read_timeout(Some(self.timeout()?))?;
        self.stream.read(buf)
    }
}

impl Write for InterruptibleTcp<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.stream.set_write_timeout(Some(self.timeout()?))?;
        self.stream.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stream.set_write_timeout(Some(self.timeout()?))?;
        self.stream.flush()
    }
}

/// A plain or TLS connection, so the socket can use the HTTP client's
/// pinned roots and provider.
pub enum Stream<'a> {
    Plain(InterruptibleTcp<'a>),
    Tls(Box<StreamOwned<ClientConnection, InterruptibleTcp<'a>>>),
}

impl Stream<'_> {
    fn set_deadline(&mut self, deadline: Option<Instant>) {
        match self {
            Stream::Plain(stream) => stream.set_deadline(deadline),
            Stream::Tls(stream) => stream.sock.set_deadline(deadline),
        }
    }
}

impl Read for Stream<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(stream) => stream.read(buf),
            Stream::Tls(stream) => stream.read(buf),
        }
    }
}

impl Write for Stream<'_> {
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
    use std::{
        net::TcpListener,
        sync::{atomic::AtomicUsize, mpsc, Mutex},
    };
    use tungstenite::handshake::server::{Request, Response};

    const TOKEN: &str = "renga_intake_test+/key";
    const INSTALLATION: &str = "67e55044-10b1-426f-9247-bb680e5fe0c8";

    struct Capture(Arc<Mutex<Vec<u8>>>);

    impl Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().write(bytes)
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

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

    fn saturated_listener() -> (Socket, Vec<Socket>, SocketAddr) {
        let listener = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).unwrap();
        listener
            .bind(&SockAddr::from(
                "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            ))
            .unwrap();
        listener.listen(1).unwrap();
        let address = listener.local_addr().unwrap().as_socket().unwrap();
        let mut fillers = Vec::new();
        loop {
            let candidate = start_connection(address).unwrap();
            let settle = Instant::now() + Duration::from_millis(100);
            let mut ready = false;
            while Instant::now() < settle {
                if connection_ready(&candidate).unwrap() {
                    ready = true;
                    break;
                }
                thread::sleep(Duration::from_millis(5));
            }
            fillers.push(candidate);
            if !ready {
                return (listener, fillers, address);
            }
            assert!(fillers.len() < 16, "loopback listen queue did not saturate");
        }
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
    fn reconnects_after_a_refused_join() {
        let refused = json!({"status": "error", "response": {"reason": "agent_not_registered"}});
        let (origin, seen) = phoenix(3, refused, hold);
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
    fn reconnects_after_a_joined_channel_closes() {
        let (origin, seen) = phoenix(2, joined(false), |socket| push(socket, "phx_close"));
        let listener = Listener::spawn_with_retry(
            endpoint(&origin),
            Notices::default(),
            Cancellation::default(),
            Duration::from_millis(20),
        );

        for _ in 0..2 {
            seen.recv_timeout(Duration::from_secs(5)).unwrap();
        }
        listener.stop();
    }

    #[test]
    fn heartbeats_and_reconnects_when_a_joined_socket_goes_silent() {
        let (heartbeat, received) = mpsc::channel();
        let (origin, _seen) = phoenix(1, joined(false), move |socket| {
            let frame: Value =
                serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
            heartbeat.send(frame).unwrap();
            hold(socket);
        });
        let error = listen_with_timing(
            &endpoint(&origin),
            &Notices::default(),
            &|| false,
            Timing {
                heartbeat: Duration::from_millis(20),
                silence_limit: Duration::from_millis(80),
                poll: Duration::from_millis(10),
            },
        )
        .unwrap_err();

        assert!(error.joined);
        assert_eq!(error.message, "socket went silent");
        let heartbeat = received.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(heartbeat[2], "phoenix");
        assert_eq!(heartbeat[3], "heartbeat");
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
    fn stopping_does_not_wait_for_a_stalled_upgrade_or_tls_handshake() {
        for scheme in ["http", "https"] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let origin = format!("{scheme}://{}", listener.local_addr().unwrap());
            let accepted = thread::spawn(move || {
                let (_stream, _) = listener.accept().unwrap();
                thread::sleep(Duration::from_secs(2));
            });
            let listener = Listener::spawn(
                endpoint(&origin),
                Notices::default(),
                Cancellation::default(),
            );
            thread::sleep(Duration::from_millis(100));

            let started = Instant::now();
            listener.stop();
            assert!(
                started.elapsed() < Duration::from_secs(1),
                "stalled {scheme} handshake blocked listener stop"
            );
            accepted.join().unwrap();
        }
    }

    #[test]
    fn stopping_interrupts_slowly_progressing_upgrade_and_tls_reads() {
        for (scheme, response) in [
            (
                "http",
                b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n".as_slice(),
            ),
            ("https", &[22, 3, 3, 0, 100, 1, 0, 0, 96]),
        ] {
            let server = TcpListener::bind("127.0.0.1:0").unwrap();
            let origin = format!("{scheme}://{}", server.local_addr().unwrap());
            let (progress, observed) = mpsc::channel();
            let server = thread::spawn(move || {
                let (mut stream, _) = server.accept().unwrap();
                let mut incoming = [0; 1024];
                let _ = stream.read(&mut incoming);
                for (index, byte) in response.iter().enumerate() {
                    if stream.write_all(&[*byte]).is_err() {
                        break;
                    }
                    let _ = stream.flush();
                    if index == 0 {
                        progress.send(()).unwrap();
                    }
                    thread::sleep(Duration::from_millis(25));
                }
            });
            let listener = Listener::spawn(
                endpoint(&origin),
                Notices::default(),
                Cancellation::default(),
            );
            observed.recv_timeout(Duration::from_secs(1)).unwrap();
            thread::sleep(Duration::from_millis(75));

            let started = Instant::now();
            listener.stop();
            assert!(
                started.elapsed() < Duration::from_secs(1),
                "slowly progressing {scheme} handshake blocked listener stop"
            );
            server.join().unwrap();
        }
    }

    #[test]
    fn refused_addresses_return_without_spinning_until_the_deadline() {
        let listeners: Vec<_> = (0..3)
            .map(|_| TcpListener::bind("127.0.0.1:0").unwrap())
            .collect();
        let addresses: Vec<_> = listeners
            .iter()
            .map(|listener| listener.local_addr().unwrap())
            .collect();
        drop(listeners);
        let started = Instant::now();
        let deadline = started + Duration::from_secs(5);

        assert!(connect_tcp(&addresses, deadline, &|| false).is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn a_refused_address_falls_through_to_the_next_address() {
        let refused = TcpListener::bind("127.0.0.1:0").unwrap();
        let refused_address = refused.local_addr().unwrap();
        drop(refused);
        let accepting = TcpListener::bind("127.0.0.1:0").unwrap();
        let accepting_address = accepting.local_addr().unwrap();
        let accepted = thread::spawn(move || accepting.accept().unwrap());

        let stream = connect_tcp(
            &[refused_address, accepting_address],
            Instant::now() + Duration::from_secs(2),
            &|| false,
        )
        .unwrap();

        assert_eq!(stream.peer_addr().unwrap(), accepting_address);
        drop(stream);
        accepted.join().unwrap();
    }

    #[test]
    fn a_pending_first_address_does_not_block_a_reachable_second_address() {
        let (_saturated, _fillers, pending_address) = saturated_listener();
        let accepting = TcpListener::bind("127.0.0.1:0").unwrap();
        let accepting_address = accepting.local_addr().unwrap();
        let accepted = thread::spawn(move || accepting.accept().unwrap());
        let started = Instant::now();

        let stream = connect_tcp(
            &[pending_address, accepting_address],
            started + Duration::from_secs(2),
            &|| false,
        )
        .unwrap();

        assert!(started.elapsed() >= CONNECT_STAGGER);
        assert_eq!(stream.peer_addr().unwrap(), accepting_address);
        drop(stream);
        accepted.join().unwrap();
    }

    #[test]
    fn a_pending_connection_can_complete_after_more_than_one_poll_slice() {
        let (listener, fillers, address) = saturated_listener();
        let accepted = thread::spawn(move || {
            thread::sleep(POLL + Duration::from_millis(100));
            let mut connections = Vec::new();
            for _ in 0..=fillers.len() {
                connections.push(listener.accept().unwrap().0);
            }
            drop(fillers);
            connections
        });
        let started = Instant::now();

        let stream = connect_tcp(&[address], started + Duration::from_secs(2), &|| false).unwrap();

        assert!(started.elapsed() > POLL);
        drop(stream);
        drop(accepted.join().unwrap());
    }

    #[test]
    fn one_pending_address_polls_at_a_bounded_rate_after_the_last_stagger() {
        let (_listener, _fillers, address) = saturated_listener();
        let polls = AtomicUsize::new(0);
        let started = Instant::now();

        assert!(connect_tcp(
            &[address],
            started + CONNECT_STAGGER + Duration::from_millis(100),
            &|| {
                polls.fetch_add(1, Ordering::SeqCst);
                false
            },
        )
        .is_err());

        assert!(started.elapsed() >= CONNECT_STAGGER);
        assert!(polls.load(Ordering::SeqCst) < 100);
    }

    #[test]
    fn connects_to_a_wss_ipv6_literal() {
        use rcgen::{generate_simple_self_signed, CertifiedKey};
        use rustls::{
            pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer},
            ServerConfig, ServerConnection,
        };

        let CertifiedKey { cert, signing_key } =
            generate_simple_self_signed(vec!["::1".into()]).unwrap();
        let certificate = cert.der().clone();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let server_config = ServerConfig::builder_with_provider(Arc::clone(&provider))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.clone()],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(signing_key.serialize_der())),
            )
            .unwrap();
        let mut roots = rustls::RootCertStore::empty();
        roots.add(certificate).unwrap();
        let client_config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();

        let server = TcpListener::bind("[::1]:0").unwrap();
        let origin = format!("https://[::1]:{}", server.local_addr().unwrap().port());
        let (joined_tx, received) = mpsc::channel();
        let server = thread::spawn(move || {
            let (tcp, _) = server.accept().unwrap();
            let tls =
                StreamOwned::new(ServerConnection::new(Arc::new(server_config)).unwrap(), tcp);
            let mut socket =
                tungstenite::accept_hdr(tls, |_request: &Request, mut response: Response| {
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
                    json!([JOIN_REF, JOIN_REF, topic, "phx_reply", joined(false)]).to_string(),
                ))
                .unwrap();
            joined_tx.send(()).unwrap();
            while socket.read().is_ok() {}
        });
        let mut endpoint = endpoint(&origin);
        endpoint.tls = Arc::new(client_config);
        let listener = Listener::spawn(endpoint, Notices::default(), Cancellation::default());

        received.recv_timeout(Duration::from_secs(5)).unwrap();
        listener.stop();
        server.join().unwrap();
    }

    #[test]
    fn cancellation_replaces_an_established_wss_partial_tls_record() {
        use rcgen::{generate_simple_self_signed, CertifiedKey};
        use rustls::{
            pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer},
            ServerConfig, ServerConnection,
        };

        let CertifiedKey { cert, signing_key } =
            generate_simple_self_signed(vec!["127.0.0.1".into()]).unwrap();
        let certificate = cert.der().clone();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let server_config = Arc::new(
            ServerConfig::builder_with_provider(Arc::clone(&provider))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![certificate.clone()],
                    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(signing_key.serialize_der())),
                )
                .unwrap(),
        );
        let mut roots = rustls::RootCertStore::empty();
        roots.add(certificate).unwrap();
        let client_config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();

        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("https://{}", server.local_addr().unwrap());
        let (progress, observed) = mpsc::channel();
        let (replacement_protocol, received_protocol) = mpsc::channel();
        let server = thread::spawn(move || {
            let (tcp, _) = server.accept().unwrap();
            let tls = StreamOwned::new(
                ServerConnection::new(Arc::clone(&server_config)).unwrap(),
                tcp,
            );
            let mut socket =
                tungstenite::accept_hdr(tls, |_request: &Request, mut response: Response| {
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
                    json!([JOIN_REF, JOIN_REF, topic, "phx_reply", joined(false)]).to_string(),
                ))
                .unwrap();
            let record = [23, 3, 3, 0, 100]
                .into_iter()
                .chain(std::iter::repeat_n(0, 100));
            for (index, byte) in record.enumerate() {
                if socket.get_mut().sock.write_all(&[byte]).is_err() {
                    break;
                }
                let _ = socket.get_mut().sock.flush();
                if index == 0 {
                    progress.send(()).unwrap();
                }
                thread::sleep(Duration::from_millis(25));
            }

            let (tcp, _) = server.accept().unwrap();
            let tls = StreamOwned::new(ServerConnection::new(server_config).unwrap(), tcp);
            let mut seen_protocol = String::new();
            let mut socket =
                tungstenite::accept_hdr(tls, |request: &Request, mut response: Response| {
                    seen_protocol = request
                        .headers()
                        .get(SEC_WEBSOCKET_PROTOCOL)
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .to_string();
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
                    json!([JOIN_REF, JOIN_REF, topic, "phx_reply", joined(false)]).to_string(),
                ))
                .unwrap();
            replacement_protocol.send(seen_protocol).unwrap();
            while socket.read().is_ok() {}
        });
        let mut endpoint = endpoint(&origin);
        endpoint.tls = Arc::new(client_config);
        let listener = Listener::spawn(
            endpoint.clone(),
            Notices::default(),
            Cancellation::default(),
        );
        observed.recv_timeout(Duration::from_secs(2)).unwrap();
        thread::sleep(Duration::from_millis(75));
        let (finished, result) = mpsc::channel();
        let stopper = thread::spawn(move || {
            listener.stop();
            finished.send(()).unwrap();
        });

        result
            .recv_timeout(Duration::from_secs(1))
            .expect("established WSS cancellation must leave the Rustls read loop");
        stopper.join().unwrap();

        endpoint.intake_api_key = "replacement-token".into();
        let replacement = Listener::spawn(endpoint, Notices::default(), Cancellation::default());
        let protocol = received_protocol
            .recv_timeout(Duration::from_secs(2))
            .expect("replacement WSS listener did not connect");
        assert!(protocol.contains(&STANDARD_NO_PAD.encode("replacement-token")));
        replacement.stop();
        server.join().unwrap();
    }

    #[test]
    fn partial_handshakes_expire_without_cancellation() {
        for (scheme, response) in [
            (
                "http",
                b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n".as_slice(),
            ),
            ("https", &[22, 3, 3, 0, 100, 1, 0, 0, 96]),
        ] {
            let server = TcpListener::bind("127.0.0.1:0").unwrap();
            let origin = format!("{scheme}://{}", server.local_addr().unwrap());
            let server = thread::spawn(move || {
                let (mut stream, _) = server.accept().unwrap();
                let mut incoming = [0; 1024];
                let _ = stream.read(&mut incoming);
                for byte in response.iter().cycle() {
                    if stream.write_all(&[*byte]).is_err() {
                        break;
                    }
                    let _ = stream.flush();
                    thread::sleep(Duration::from_millis(25));
                }
            });
            let mut endpoint = endpoint(&origin);
            endpoint.timeout = Duration::from_millis(100);
            let cancelled = Cancellation::default();
            let worker_cancelled = cancelled.clone();
            let (finished, result) = mpsc::channel();
            let worker = thread::spawn(move || {
                let started = Instant::now();
                let error = match connect(&endpoint, &|| worker_cancelled.cancelled()) {
                    Ok(_) => panic!("partial handshake unexpectedly completed"),
                    Err(error) => error,
                };
                finished.send((started.elapsed(), error.message)).unwrap();
            });

            let (elapsed, message) =
                result
                    .recv_timeout(Duration::from_secs(1))
                    .unwrap_or_else(|_| {
                        cancelled.cancel();
                        panic!("slowly progressing {scheme} handshake ignored its deadline")
                    });
            assert!(elapsed >= Duration::from_millis(80));
            assert!(message.contains("timed out"));
            worker.join().unwrap();
            server.join().unwrap();
        }
    }

    #[test]
    fn trace_logging_never_records_the_handshake_credential() {
        let _ = tracing_log::LogTracer::init();
        let output = Arc::new(Mutex::new(Vec::new()));
        let writer_output = Arc::clone(&output);
        let subscriber = crate::logging::subscriber(
            move || Capture(Arc::clone(&writer_output)),
            tracing_subscriber::EnvFilter::new("trace"),
        );
        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", server.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (stream, _) = server.accept().unwrap();
            let mut socket =
                tungstenite::accept_hdr(stream, |_request: &Request, mut response: Response| {
                    response
                        .headers_mut()
                        .insert(SEC_WEBSOCKET_PROTOCOL, HeaderValue::from_static("phoenix"));
                    Ok(response)
                })
                .unwrap();
            while socket.read().is_ok() {}
        });

        tracing::subscriber::with_default(subscriber, || {
            tracing::trace!("redaction-test-marker");
            let socket = connect(&endpoint(&origin), &|| false).unwrap();
            drop(socket);
        });
        server.join().unwrap();

        let output = String::from_utf8(output.lock().unwrap().clone()).unwrap();
        assert!(output.contains("redaction-test-marker"));
        assert!(!output.contains(TOKEN));
        assert!(!output.contains(&STANDARD_NO_PAD.encode(TOKEN)));
    }

    #[test]
    fn the_endpoint_never_prints_the_key() {
        let printed = format!("{:?}", endpoint("http://127.0.0.1:9"));
        assert!(!printed.contains(TOKEN));
    }
}
