//! Canonical serialization shared with `Renga.Enrollment.Canonical`.
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signer, SigningKey};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub enum Canonical {
    Bytes(Vec<u8>),
    Int(i64),
    Map(BTreeMap<&'static str, Canonical>),
}
pub fn encode(v: &Canonical) -> Vec<u8> {
    let mut o = vec![];
    render(v, &mut o);
    o
}
fn render(v: &Canonical, o: &mut Vec<u8>) {
    match v {
        Canonical::Bytes(s) => {
            o.extend(format!("s{}:", s.len()).bytes());
            o.extend(s)
        }
        Canonical::Int(i) => o.extend(format!("i{i};").bytes()),
        Canonical::Map(m) => {
            o.extend(format!("m{}:", m.len()).bytes());
            for (k, v) in m {
                render(&Canonical::Bytes(k.as_bytes().into()), o);
                render(v, o)
            }
        }
    }
}
pub fn json_canonical(v: &Value) -> Vec<u8> {
    fn r(v: &Value, o: &mut Vec<u8>) {
        match v {
            Value::Null => o.extend(b"n"),
            Value::Bool(true) => o.extend(b"t"),
            Value::Bool(false) => o.extend(b"f"),
            Value::String(s) => {
                o.extend(format!("s{}:", s.len()).bytes());
                o.extend(s.as_bytes())
            }
            Value::Number(n) => o.extend(
                if n.is_i64() || n.is_u64() {
                    format!("i{n};")
                } else {
                    format!("d{n};")
                }
                .bytes(),
            ),
            Value::Array(a) => {
                o.extend(format!("l{}:", a.len()).bytes());
                for x in a {
                    r(x, o)
                }
            }
            Value::Object(m) => {
                o.extend(format!("m{}:", m.len()).bytes());
                let mut p: Vec<_> = m.iter().collect();
                p.sort_by_key(|x| x.0);
                for (k, v) in p {
                    r(&Value::String(k.clone()), o);
                    r(v, o)
                }
            }
        }
    }
    let mut o = vec![];
    r(v, &mut o);
    o
}
fn b(v: impl AsRef<[u8]>) -> Canonical {
    Canonical::Bytes(v.as_ref().into())
}
pub fn proof(
    key: &SigningKey,
    id: &str,
    nonce: &[u8],
    installation: uuid::Uuid,
    evidence: &Value,
    requested: &Value,
    metadata: &Value,
) -> String {
    let digest = |v: &Value| Sha256::digest(json_canonical(v)).to_vec();
    let m = BTreeMap::from([
        ("action", b("collector:enroll")),
        ("challenge_id", b(id)),
        ("domain", b("renga/enrollment/proof")),
        ("evidence_sha256", b(digest(evidence))),
        ("installation_id", b(installation.to_string())),
        (
            "key_thumbprint",
            b(Sha256::digest(key.verifying_key().as_bytes())),
        ),
        ("metadata_sha256", b(digest(metadata))),
        ("nonce", b(nonce)),
        ("requested_capabilities_sha256", b(digest(requested))),
        ("version", Canonical::Int(1)),
    ]);
    URL_SAFE_NO_PAD.encode(key.sign(&encode(&Canonical::Map(m))).to_bytes())
}
pub fn runtime_transcript(
    credential: &str,
    installation: uuid::Uuid,
    target: &str,
    timestamp: i64,
    nonce: &str,
    body: &[u8],
) -> Vec<u8> {
    let m = BTreeMap::from([
        (
            "body_sha256",
            b(URL_SAFE_NO_PAD.encode(Sha256::digest(body))),
        ),
        ("content_type", b("application/json")),
        ("credential_id", b(credential)),
        ("domain", b("renga/agent-credential/request")),
        ("installation_id", b(installation.to_string())),
        ("method", b("POST")),
        ("nonce", b(nonce)),
        ("request_target", b(target)),
        ("timestamp", Canonical::Int(timestamp)),
        ("version", Canonical::Int(1)),
    ]);
    encode(&Canonical::Map(m))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn canonical_vector_matches_elixir_contract() {
        let value = serde_json::json!({"z":[true,null],"a":"é"});
        assert_eq!(json_canonical(&value), b"m2:s1:as2:\xC3\xA9s1:zl2:tn");
    }
}
