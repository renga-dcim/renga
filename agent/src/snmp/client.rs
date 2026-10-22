//! Reads one switch over SNMP into `Answers`.

use super::{
    config::{AuthProtocol, Credentials, PrivacyProtocol, Target},
    mibs::{Answers, Oid, SnmpValue, COLUMNS, SCALARS},
};
use snmp2::{v3, Oid as WireOid, SyncSession, Value};
use std::{
    fmt, fs,
    net::ToSocketAddrs,
    path::Path,
    time::{Duration, Instant},
};

/// A large chassis answers well under this many variables; a device answering more is cut off
/// rather than allowed to grow the report without bound.
const MAX_VARIABLES: usize = 200_000;
/// Bounds memory too, since each variable can carry a long string.
const MAX_ANSWER_BYTES: usize = 32 * 1024 * 1024;
const BULK_REPETITIONS: u32 = 25;
/// Credential files hold one short secret.
const MAX_SECRET_BYTES: u64 = 4_096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PollError(pub String);

impl fmt::Display for PollError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// What the poller needs from an SNMP session, so tests can answer from recordings.
pub trait Session {
    fn get(&mut self, oids: &[&[u32]]) -> Result<Vec<(Oid, SnmpValue)>, PollError>;
    /// The next variables after `oid`, at most `count` of them.
    fn next(&mut self, oid: &[u32], count: u32) -> Result<Vec<(Oid, SnmpValue)>, PollError>;
}

/// Reads every scalar and walks every column before `deadline`.
pub fn poll(session: &mut dyn Session, deadline: Instant) -> Result<Answers, PollError> {
    let mut answers = Answers::default();
    for (oid, value) in session.get(SCALARS)? {
        answers.insert(oid, value);
    }
    let mut total = 0;
    let mut bytes = 0;
    for column in COLUMNS {
        let mut cursor = column.to_vec();
        'walk: loop {
            if Instant::now() >= deadline {
                return Err(PollError("polling took longer than its deadline".into()));
            }
            let batch = session.next(&cursor, BULK_REPETITIONS)?;
            if batch.is_empty() {
                break;
            }
            for (oid, value) in batch {
                // Past the column, past the MIB, or not advancing: the walk is done.
                if !oid.starts_with(column) || value == SnmpValue::Missing || oid <= cursor {
                    break 'walk;
                }
                total += 1;
                bytes += oid.len() * 4 + value_bytes(&value);
                if total > MAX_VARIABLES {
                    return Err(PollError(format!(
                        "the device answered more than {MAX_VARIABLES} variables"
                    )));
                }
                if bytes > MAX_ANSWER_BYTES {
                    return Err(PollError(format!(
                        "the device answered more than {MAX_ANSWER_BYTES} bytes"
                    )));
                }
                cursor.clone_from(&oid);
                answers.insert(oid, value);
            }
        }
    }
    Ok(answers)
}

fn value_bytes(value: &SnmpValue) -> usize {
    match value {
        SnmpValue::Octets(bytes) => bytes.len(),
        SnmpValue::ObjectId(oid) => oid.len() * 4,
        _ => 8,
    }
}

/// An `snmp2` session to one target.
pub struct WireSession {
    session: SyncSession,
    bulk: bool,
}

impl WireSession {
    /// Reads the credential files and opens a session. Nothing secret is kept after this.
    pub fn open(
        target: &Target,
        credentials: &Credentials,
        timeout: Duration,
    ) -> Result<Self, PollError> {
        let address = (target.host.as_str(), target.port)
            .to_socket_addrs()
            .map_err(|error| PollError(format!("cannot resolve {}: {error}", target.host)))?
            .next()
            .ok_or_else(|| PollError(format!("cannot resolve {}", target.host)))?;
        let session = match credentials {
            Credentials::V2c { community_file } => {
                let community = read_secret(community_file)?;
                SyncSession::new_v2c(address, &community, Some(timeout), 0)
                    .map_err(|error| PollError(format!("cannot open a socket: {error}")))?
            }
            Credentials::V3 {
                username,
                auth_protocol,
                auth_password_file,
                privacy_protocol,
                privacy_password_file,
            } => {
                let security =
                    v3::Security::new(username.as_bytes(), &read_secret(auth_password_file)?)
                        .with_auth_protocol(wire_auth(*auth_protocol))
                        .with_auth(v3::Auth::AuthPriv {
                            cipher: wire_cipher(*privacy_protocol),
                            privacy_password: read_secret(privacy_password_file)?,
                        })
                        .with_key_extension_method(v3::KeyExtension::Blumenthal);
                let mut session = SyncSession::new_v3(address, Some(timeout), 0, security)
                    .map_err(|error| PollError(format!("cannot open a socket: {error}")))?;
                session.init().map_err(wire_error)?;
                session
            }
        };
        Ok(Self {
            session,
            bulk: true,
        })
    }
}

impl Session for WireSession {
    fn get(&mut self, oids: &[&[u32]]) -> Result<Vec<(Oid, SnmpValue)>, PollError> {
        let wire: Vec<WireOid> = oids
            .iter()
            .map(|oid| wire_oid(oid))
            .collect::<Result<_, _>>()?;
        let refs: Vec<&WireOid> = wire.iter().collect();
        let pdu = self.session.get_many(&refs).map_err(wire_error)?;
        check_status(pdu.error_status)?;
        pdu.varbinds
            .map(|(oid, value)| Ok((from_wire_oid(&oid)?, from_wire_value(&value))))
            .collect()
    }

    fn next(&mut self, oid: &[u32], count: u32) -> Result<Vec<(Oid, SnmpValue)>, PollError> {
        let wire = wire_oid(oid)?;
        let pdu = if self.bulk {
            self.session.getbulk(&[&wire], 0, count)
        } else {
            self.session.getnext(&wire)
        }
        .map_err(wire_error)?;
        check_status(pdu.error_status)?;
        pdu.varbinds
            .map(|(oid, value)| Ok((from_wire_oid(&oid)?, from_wire_value(&value))))
            .collect()
    }
}

fn check_status(status: u32) -> Result<(), PollError> {
    match status {
        0 => Ok(()),
        // noSuchName from a v1-style agent: the rest of the walk is empty.
        2 => Ok(()),
        status => Err(PollError(format!(
            "the device answered with error status {status}"
        ))),
    }
}

fn read_secret(path: &Path) -> Result<Vec<u8>, PollError> {
    let metadata = fs::metadata(path)
        .map_err(|error| PollError(format!("cannot read {}: {error}", path.display())))?;
    if metadata.len() > MAX_SECRET_BYTES {
        return Err(PollError(format!("{} is too large", path.display())));
    }
    let bytes = fs::read(path)
        .map_err(|error| PollError(format!("cannot read {}: {error}", path.display())))?;
    let secret = bytes.trim_ascii_end();
    if secret.is_empty() {
        return Err(PollError(format!("{} is empty", path.display())));
    }
    Ok(secret.to_vec())
}

fn wire_auth(protocol: AuthProtocol) -> v3::AuthProtocol {
    match protocol {
        AuthProtocol::Md5 => v3::AuthProtocol::Md5,
        AuthProtocol::Sha => v3::AuthProtocol::Sha1,
        AuthProtocol::Sha224 => v3::AuthProtocol::Sha224,
        AuthProtocol::Sha256 => v3::AuthProtocol::Sha256,
        AuthProtocol::Sha384 => v3::AuthProtocol::Sha384,
        AuthProtocol::Sha512 => v3::AuthProtocol::Sha512,
    }
}

fn wire_cipher(protocol: PrivacyProtocol) -> v3::Cipher {
    match protocol {
        PrivacyProtocol::Des => v3::Cipher::Des,
        PrivacyProtocol::Aes128 => v3::Cipher::Aes128,
        PrivacyProtocol::Aes192 => v3::Cipher::Aes192,
        PrivacyProtocol::Aes256 => v3::Cipher::Aes256,
    }
}

/// Errors from the library never carry credentials, only what failed.
fn wire_error(error: snmp2::Error) -> PollError {
    match error {
        snmp2::Error::Receive | snmp2::Error::Send => {
            PollError("no answer before the timeout".into())
        }
        snmp2::Error::AuthFailure(kind) => PollError(format!("authentication failed: {kind:?}")),
        other => PollError(format!("SNMP error: {other:?}")),
    }
}

fn wire_oid(oid: &[u32]) -> Result<WireOid<'static>, PollError> {
    let components: Vec<u64> = oid.iter().map(|part| u64::from(*part)).collect();
    WireOid::from(&components).map_err(|_| PollError(format!("invalid OID {oid:?}")))
}

fn from_wire_oid(oid: &WireOid) -> Result<Oid, PollError> {
    oid.iter()
        .and_then(|parts| parts.map(|part| u32::try_from(part).ok()).collect())
        .ok_or_else(|| PollError("the device answered an OID out of range".into()))
}

fn from_wire_value(value: &Value) -> SnmpValue {
    match value {
        Value::Integer(value) => SnmpValue::Integer(*value),
        Value::OctetString(bytes) | Value::Opaque(bytes) => SnmpValue::Octets(bytes.to_vec()),
        Value::ObjectIdentifier(oid) => {
            from_wire_oid(oid).map_or(SnmpValue::Other, SnmpValue::ObjectId)
        }
        Value::IpAddress(address) => SnmpValue::IpAddress(*address),
        Value::Counter32(value) | Value::Unsigned32(value) | Value::Timeticks(value) => {
            SnmpValue::Unsigned(u64::from(*value))
        }
        Value::Counter64(value) => SnmpValue::Unsigned(*value),
        Value::NoSuchObject | Value::NoSuchInstance | Value::EndOfMibView => SnmpValue::Missing,
        _ => SnmpValue::Other,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::snmp::mibs::{self, IF_NAME};

    /// Answers from recorded variables the way an agent walks them.
    pub(crate) struct Recorded {
        pub answers: Vec<(Oid, SnmpValue)>,
        pub requests: usize,
    }

    impl Recorded {
        pub(crate) fn new(answers: &Answers) -> Self {
            Self {
                answers: answers
                    .iter()
                    .map(|(oid, value)| (oid.clone(), value.clone()))
                    .collect(),
                requests: 0,
            }
        }
    }

    impl Session for Recorded {
        fn get(&mut self, oids: &[&[u32]]) -> Result<Vec<(Oid, SnmpValue)>, PollError> {
            self.requests += 1;
            Ok(oids
                .iter()
                .map(|oid| {
                    let value = self
                        .answers
                        .iter()
                        .find(|(recorded, _)| recorded == oid)
                        .map_or(SnmpValue::Missing, |(_, value)| value.clone());
                    (oid.to_vec(), value)
                })
                .collect())
        }

        fn next(&mut self, oid: &[u32], count: u32) -> Result<Vec<(Oid, SnmpValue)>, PollError> {
            self.requests += 1;
            let mut batch: Vec<_> = self
                .answers
                .iter()
                .filter(|(recorded, _)| recorded.as_slice() > oid)
                .take(count as usize)
                .cloned()
                .collect();
            if batch.len() < count as usize {
                batch.push((vec![1, 3, 6, 1, 99], SnmpValue::Missing));
            }
            Ok(batch)
        }
    }

    #[test]
    fn walks_every_column_into_answers() {
        let recorded = mibs::tests::answers();
        let mut session = Recorded::new(&recorded);
        let answers = poll(&mut session, Instant::now() + Duration::from_secs(5)).unwrap();

        let (resource, _) = mibs::switch("10.0.0.1", &answers, 60).unwrap();
        assert_eq!(resource.interfaces.as_ref().unwrap().len(), 4);
        assert!(answers.iter().any(|(oid, _)| oid.starts_with(IF_NAME)));
    }

    #[test]
    fn stops_a_device_that_answers_too_much() {
        let mut answers = mibs::tests::answers();
        for index in 0..600 {
            let mut oid = IF_NAME.to_vec();
            oid.push(10_000 + index);
            answers.insert(oid, SnmpValue::Octets(vec![b'x'; 60_000]));
        }
        let mut session = Recorded::new(&answers);
        let error = poll(&mut session, Instant::now() + Duration::from_secs(5)).unwrap_err();
        assert!(error.0.contains("bytes"), "{error}");
    }

    #[test]
    fn stops_at_the_deadline() {
        let mut session = Recorded::new(&mibs::tests::answers());
        let error = poll(&mut session, Instant::now()).unwrap_err();
        assert!(error.0.contains("deadline"));
    }

    #[test]
    fn credential_files_are_trimmed_and_bounded() {
        let directory = std::env::temp_dir().join(format!("renga-snmp-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        let secret = directory.join("secret");
        fs::write(&secret, "s3cret\n").unwrap();
        assert_eq!(read_secret(&secret).unwrap(), b"s3cret");
        fs::write(&secret, "\n").unwrap();
        assert!(read_secret(&secret).unwrap_err().0.contains("empty"));
        fs::write(&secret, vec![b'x'; 5_000]).unwrap();
        assert!(read_secret(&secret).unwrap_err().0.contains("too large"));
        let missing = read_secret(&directory.join("missing")).unwrap_err();
        assert!(missing.0.contains("cannot read"));
        fs::remove_dir_all(directory).unwrap();
    }

    /// Polls a real agent when `RENGA_SNMPD_TEST` names one, as `host:port`, with an SNMPv3
    /// user `renga` (SHA-256, AES-128) whose passwords are in the files `RENGA_SNMPD_AUTH` and
    /// `RENGA_SNMPD_PRIV`. Skipped otherwise.
    #[test]
    fn polls_a_real_agent_over_snmpv3() {
        let (Ok(address), Ok(auth), Ok(privacy)) = (
            std::env::var("RENGA_SNMPD_TEST"),
            std::env::var("RENGA_SNMPD_AUTH"),
            std::env::var("RENGA_SNMPD_PRIV"),
        ) else {
            return;
        };
        let target = Target::parse(&address).unwrap();
        let credentials = Credentials::V3 {
            username: "renga".into(),
            auth_protocol: AuthProtocol::Sha256,
            auth_password_file: auth.into(),
            privacy_protocol: PrivacyProtocol::Aes128,
            privacy_password_file: privacy.into(),
        };
        let mut session = WireSession::open(&target, &credentials, Duration::from_secs(2)).unwrap();
        let answers = poll(&mut session, Instant::now() + Duration::from_secs(30)).unwrap();

        assert!(answers
            .iter()
            .any(|(oid, value)| oid.as_slice() == mibs::SYS_NAME
                && matches!(value, SnmpValue::Octets(_))));
        assert!(answers
            .iter()
            .any(|(oid, _)| oid.starts_with(mibs::IF_DESCR)));

        let wrong = Credentials::V3 {
            username: "renga".into(),
            auth_protocol: AuthProtocol::Sha256,
            auth_password_file: std::env::var("RENGA_SNMPD_PRIV").unwrap().into(),
            privacy_protocol: PrivacyProtocol::Aes128,
            privacy_password_file: std::env::var("RENGA_SNMPD_PRIV").unwrap().into(),
        };
        let refused = WireSession::open(&target, &wrong, Duration::from_secs(1))
            .and_then(|mut session| poll(&mut session, Instant::now() + Duration::from_secs(5)));
        assert!(refused.is_err());
    }

    #[test]
    fn converts_oids_both_ways() {
        let wire = wire_oid(&[1, 3, 6, 1, 2, 1, 1, 5, 0]).unwrap();
        assert_eq!(
            from_wire_oid(&wire).unwrap(),
            vec![1, 3, 6, 1, 2, 1, 1, 5, 0]
        );
    }
}
