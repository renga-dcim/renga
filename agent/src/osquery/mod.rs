//! The osquery backend (RFD 12, "osquery backend"): a client for a locally
//! managed `osqueryd`'s extensions socket, and the backend status each
//! check-in reports.
//!
//! The agent never starts or configures osquery. The operator runs
//! `osqueryd` and makes its extensions socket reachable by the agent's
//! account; osquery keeps its own privileges and the agent's sandbox does not
//! change. The socket speaks Thrift, and the agent calls only the extension
//! manager's `ping`, `query`, and `options` methods.

pub mod thrift;

use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf, time::Duration};

/// Where `osqueryd` puts its extensions socket by default on Linux and macOS.
pub const SOCKET_DEFAULT: &str = "/var/osquery/osquery.em";
/// How long a status probe waits on the socket.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// The `[osquery]` configuration section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OsqueryConfig {
    /// `false` stops the agent from probing or using osquery, so its status
    /// is not reported at all.
    pub enabled: bool,
    pub socket: PathBuf,
}

impl Default for OsqueryConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            socket: PathBuf::from(SOCKET_DEFAULT),
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RawOsquery {
    enabled: Option<bool>,
    socket: Option<PathBuf>,
}

/// Validates `[osquery]`.
pub(crate) fn from_raw(raw: Option<RawOsquery>) -> Result<OsqueryConfig, String> {
    let raw = raw.unwrap_or_default();
    let socket = raw.socket.unwrap_or_else(|| PathBuf::from(SOCKET_DEFAULT));
    if !socket.is_absolute() {
        return Err("osquery.socket must be an absolute path".into());
    }
    Ok(OsqueryConfig {
        enabled: raw.enabled.unwrap_or(true),
        socket,
    })
}

/// Whether this host's osquery can answer, as a check-in reports it. Must
/// match `Renga.Inventory.AgentPayload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum BackendStatus {
    /// The daemon answered; `version` is its own, when it said.
    Available {
        #[serde(skip_serializing_if = "Option::is_none")]
        version: Option<String>,
    },
    /// The socket exists but the agent's account may not connect to it.
    NotPermitted,
    /// No daemon listens at the configured socket.
    NotPresent,
}

/// Why a call to osquery failed.
#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    /// The reply was not what the extension manager sends.
    Protocol(String),
    /// osquery answered with a non-zero status, such as an SQL error.
    Status {
        code: i32,
        message: String,
    },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(error) => write!(f, "osquery socket: {error}"),
            Error::Protocol(message) => write!(f, "osquery protocol: {message}"),
            Error::Status { code, message } => write!(f, "osquery error {code}: {message}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Io(error)
    }
}

/// A row of a query result: column name to osquery's string value.
pub type Row = BTreeMap<String, String>;

#[cfg(unix)]
pub use client::{probe, Client};

#[cfg(not(unix))]
pub fn probe(_config: &OsqueryConfig) -> Option<BackendStatus> {
    None
}

#[cfg(unix)]
mod client {
    use super::{thrift, thrift::Value, BackendStatus, Error, OsqueryConfig, Row, PROBE_TIMEOUT};
    use std::{
        io::{BufReader, BufWriter, ErrorKind},
        os::unix::net::UnixStream,
        path::Path,
        time::Duration,
    };
    use tracing::warn;

    /// A connection to osquery's extension manager.
    pub struct Client {
        reader: BufReader<UnixStream>,
        writer: BufWriter<UnixStream>,
        seqid: i32,
    }

    impl Client {
        /// Connects, waiting at most `timeout` for each read or write.
        pub fn connect(socket: &Path, timeout: Duration) -> Result<Self, Error> {
            let stream = UnixStream::connect(socket)?;
            stream.set_read_timeout(Some(timeout))?;
            stream.set_write_timeout(Some(timeout))?;
            Ok(Self {
                reader: BufReader::new(stream.try_clone()?),
                writer: BufWriter::new(stream),
                seqid: 0,
            })
        }

        /// Checks that the extension manager answers.
        pub fn ping(&mut self) -> Result<(), Error> {
            let result = self.call("ping", vec![])?;
            check_status(result.field(0))
        }

        /// Runs one SQL statement and returns its rows.
        pub fn query(&mut self, sql: &str) -> Result<Vec<Row>, Error> {
            let result = self.call("query", vec![(1, Value::string(sql))])?;
            let response = result
                .field(0)
                .ok_or_else(|| Error::Protocol("query returned no response".into()))?;
            check_status(response.field(1))?;
            let rows = match response.field(2) {
                Some(rows) => rows
                    .as_list()
                    .ok_or_else(|| Error::Protocol("query rows are not a list".into()))?,
                None => &[],
            };
            rows.iter().map(row).collect()
        }

        /// The daemon's flags, by name, with their current values.
        pub fn options(&mut self) -> Result<Row, Error> {
            let result = self.call("options", vec![])?;
            let options = result
                .field(0)
                .and_then(Value::as_map)
                .ok_or_else(|| Error::Protocol("options returned no map".into()))?;
            options
                .iter()
                .map(|(name, info)| {
                    let name = name.as_str();
                    let value = info.field(1).and_then(Value::as_str);
                    name.zip(value)
                        .ok_or_else(|| Error::Protocol("malformed option".into()))
                })
                .collect()
        }

        fn call(&mut self, method: &str, args: Vec<(i16, Value)>) -> Result<Value, Error> {
            self.seqid = self.seqid.wrapping_add(1);
            thrift::write_message(&mut self.writer, thrift::CALL, method, self.seqid, &args)?;
            let (header, body) = thrift::read_message(&mut self.reader)?;
            if header.kind == thrift::EXCEPTION {
                let message = body.field(1).and_then(Value::as_str).unwrap_or_default();
                return Err(Error::Protocol(format!("{method} raised: {message}")));
            }
            if header.kind != thrift::REPLY || header.name != method || header.seqid != self.seqid {
                return Err(Error::Protocol(format!("unexpected reply to {method}")));
            }
            Ok(body)
        }
    }

    fn check_status(status: Option<&Value>) -> Result<(), Error> {
        let status = status.ok_or_else(|| Error::Protocol("reply has no status".into()))?;
        match status.field(1).and_then(Value::as_i32) {
            Some(0) => Ok(()),
            Some(code) => Err(Error::Status {
                code,
                message: status.field(2).and_then(Value::as_str).unwrap_or_default(),
            }),
            None => Err(Error::Protocol("status has no code".into())),
        }
    }

    fn row(value: &Value) -> Result<Row, Error> {
        let entries = value
            .as_map()
            .ok_or_else(|| Error::Protocol("a row is not a map".into()))?;
        entries
            .iter()
            .map(|(column, cell)| {
                column
                    .as_str()
                    .zip(cell.as_str())
                    .ok_or_else(|| Error::Protocol("a row holds a non-string".into()))
            })
            .collect()
    }

    /// The backend's status, or `None` when `[osquery]` is disabled. A
    /// daemon that refuses or garbles a ping counts as not present.
    pub fn probe(config: &OsqueryConfig) -> Option<BackendStatus> {
        if !config.enabled {
            return None;
        }
        let mut client = match Client::connect(&config.socket, PROBE_TIMEOUT) {
            Ok(client) => client,
            Err(Error::Io(error)) if error.kind() == ErrorKind::PermissionDenied => {
                return Some(BackendStatus::NotPermitted)
            }
            Err(_absent) => return Some(BackendStatus::NotPresent),
        };
        if let Err(error) = client.ping() {
            warn!(%error, socket = %config.socket.display(), "osquery did not answer a ping");
            return Some(BackendStatus::NotPresent);
        }
        let version = client
            .query("SELECT version FROM osquery_info")
            .ok()
            .and_then(|rows| rows.into_iter().next())
            .and_then(|mut row| row.remove("version"))
            .filter(|version| !version.is_empty() && version.len() <= 64);
        Some(BackendStatus::Available { version })
    }
}

#[cfg(all(test, unix))]
pub(crate) mod fake {
    //! A stand-in `osqueryd` extensions socket for tests.

    use super::thrift::{self, Value};
    use std::{
        io::{BufReader, BufWriter},
        os::unix::net::UnixListener,
        path::PathBuf,
        thread,
    };

    pub const MAP: u8 = 13;
    pub const STRING: u8 = 11;
    pub const STRUCT: u8 = 12;

    /// `ExtensionStatus{code, message}`.
    pub fn status(code: i32, message: &str) -> Value {
        Value::Struct(vec![(1, Value::I32(code)), (2, Value::string(message))])
    }

    /// `ExtensionResponse{status, rows}`.
    pub fn response(code: i32, message: &str, rows: &[&[(&str, &str)]]) -> Value {
        let rows = rows
            .iter()
            .map(|row| {
                Value::Map(
                    STRING,
                    STRING,
                    row.iter()
                        .map(|(k, v)| (Value::string(k), Value::string(v)))
                        .collect(),
                )
            })
            .collect();
        Value::Struct(vec![
            (1, status(code, message)),
            (2, Value::List(MAP, rows)),
        ])
    }

    /// `InternalOptionList` with each flag's current value.
    pub fn options(flags: &[(&str, &str)]) -> Value {
        Value::Map(
            STRING,
            STRUCT,
            flags
                .iter()
                .map(|(name, value)| {
                    (
                        Value::string(name),
                        Value::Struct(vec![(1, Value::string(value))]),
                    )
                })
                .collect(),
        )
    }

    /// Serves one connection, answering each call with `answer(method, args)`
    /// until the client hangs up. Returns the socket path.
    pub fn serve(
        answer: impl Fn(&str, &Value) -> Value + Send + 'static,
    ) -> (PathBuf, thread::JoinHandle<Vec<String>>) {
        let dir = std::env::temp_dir().join(format!("renga-osquery-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("osquery.em");
        let listener = UnixListener::bind(&path).unwrap();
        let handle = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut writer = BufWriter::new(stream);
            let mut calls = Vec::new();
            while let Ok((header, args)) = thrift::read_message(&mut reader) {
                let result = answer(&header.name, &args);
                calls.push(header.name.clone());
                thrift::write_message(
                    &mut writer,
                    thrift::REPLY,
                    &header.name,
                    header.seqid,
                    &[(0, result)],
                )
                .unwrap();
            }
            calls
        });
        (path, handle)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::{fake, thrift::Value, *};
    use std::os::unix::fs::PermissionsExt;

    fn answer(method: &str, args: &Value) -> Value {
        match method {
            "ping" => fake::status(0, "OK"),
            "query" => match args.field(1).and_then(Value::as_str).as_deref() {
                Some("SELECT version FROM osquery_info") => {
                    fake::response(0, "OK", &[&[("version", "5.12.1")]])
                }
                Some(_other) => fake::response(1, "no such table: nope", &[]),
                None => fake::response(1, "missing sql", &[]),
            },
            "options" => fake::options(&[("disable_tables", "curl,carves"), ("verbose", "false")]),
            _ => fake::status(1, "unknown"),
        }
    }

    #[test]
    fn calls_ping_query_and_options() {
        let (socket, server) = fake::serve(answer);
        let mut client = Client::connect(&socket, PROBE_TIMEOUT).unwrap();

        client.ping().unwrap();
        let rows = client.query("SELECT version FROM osquery_info").unwrap();
        assert_eq!(rows[0]["version"], "5.12.1");
        match client.query("SELECT * FROM nope") {
            Err(Error::Status { code: 1, message }) => assert!(message.contains("no such table")),
            other => panic!("expected an osquery error, got {other:?}"),
        }
        let options = client.options().unwrap();
        assert_eq!(options["disable_tables"], "curl,carves");

        drop(client);
        assert_eq!(
            server.join().unwrap(),
            ["ping", "query", "query", "options"]
        );
    }

    #[test]
    fn reports_an_answering_daemon_as_available_with_its_version() {
        let (socket, server) = fake::serve(answer);
        let config = OsqueryConfig {
            enabled: true,
            socket,
        };

        assert_eq!(
            probe(&config),
            Some(BackendStatus::Available {
                version: Some("5.12.1".into())
            })
        );
        server.join().unwrap();
    }

    #[test]
    fn reports_a_missing_or_silent_daemon_as_not_present() {
        let missing = OsqueryConfig {
            enabled: true,
            socket: std::env::temp_dir().join(format!("renga-none-{}.em", uuid::Uuid::new_v4())),
        };
        assert_eq!(probe(&missing), Some(BackendStatus::NotPresent));

        let (socket, server) = fake::serve(|_method, _args| fake::status(1, "shutting down"));
        let refusing = OsqueryConfig {
            enabled: true,
            socket,
        };
        assert_eq!(probe(&refusing), Some(BackendStatus::NotPresent));
        server.join().unwrap();
    }

    #[test]
    fn reports_an_unreachable_socket_as_not_permitted() {
        // Root bypasses file permissions, so only an unprivileged run can see this.
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let dir = std::env::temp_dir().join(format!("renga-osquery-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("osquery.em");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o000)).unwrap();
        let config = OsqueryConfig {
            enabled: true,
            socket,
        };

        assert_eq!(probe(&config), Some(BackendStatus::NotPermitted));
    }

    #[test]
    fn is_silent_when_disabled() {
        let config = OsqueryConfig {
            enabled: false,
            socket: SOCKET_DEFAULT.into(),
        };
        assert_eq!(probe(&config), None);
    }

    #[test]
    fn serializes_the_status_renga_expects() {
        let available = BackendStatus::Available {
            version: Some("5.12.1".into()),
        };
        assert_eq!(
            serde_json::to_value(available).unwrap(),
            serde_json::json!({"status": "available", "version": "5.12.1"})
        );
        assert_eq!(
            serde_json::to_value(BackendStatus::NotPermitted).unwrap(),
            serde_json::json!({"status": "not_permitted"})
        );
    }

    #[test]
    fn config_needs_an_absolute_socket() {
        assert_eq!(from_raw(None).unwrap(), OsqueryConfig::default());
        let raw = RawOsquery {
            enabled: Some(false),
            socket: Some("relative.em".into()),
        };
        assert!(from_raw(Some(raw)).is_err());
    }
}
