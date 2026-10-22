//! The gNMI messages the poller exchanges (`gnmi.proto` 0.10.0), written out by hand so building
//! the agent needs no `protoc`. Tags must match the published proto. Fields the poller never
//! sends or reads are left out; decoding skips them.

use std::collections::BTreeMap;

#[derive(Clone, PartialEq, prost::Message)]
pub struct CapabilityRequest {}

#[derive(Clone, PartialEq, prost::Message)]
pub struct CapabilityResponse {
    #[prost(enumeration = "Encoding", repeated, tag = "2")]
    pub supported_encodings: Vec<i32>,
    #[prost(string, tag = "3")]
    pub g_nmi_version: String,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct GetRequest {
    #[prost(message, optional, tag = "1")]
    pub prefix: Option<Path>,
    #[prost(message, repeated, tag = "2")]
    pub path: Vec<Path>,
    #[prost(enumeration = "DataType", tag = "3")]
    pub r#type: i32,
    #[prost(enumeration = "Encoding", tag = "5")]
    pub encoding: i32,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct GetResponse {
    #[prost(message, repeated, tag = "1")]
    pub notification: Vec<Notification>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Notification {
    #[prost(int64, tag = "1")]
    pub timestamp: i64,
    #[prost(message, optional, tag = "2")]
    pub prefix: Option<Path>,
    #[prost(message, repeated, tag = "4")]
    pub update: Vec<Update>,
    #[prost(message, repeated, tag = "5")]
    pub delete: Vec<Path>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Update {
    #[prost(message, optional, tag = "1")]
    pub path: Option<Path>,
    #[prost(message, optional, tag = "3")]
    pub val: Option<TypedValue>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct TypedValue {
    #[prost(
        oneof = "typed_value::Value",
        tags = "1, 2, 3, 4, 5, 6, 8, 10, 11, 12, 14"
    )]
    pub value: Option<typed_value::Value>,
}

pub mod typed_value {
    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Value {
        #[prost(string, tag = "1")]
        StringVal(String),
        #[prost(int64, tag = "2")]
        IntVal(i64),
        #[prost(uint64, tag = "3")]
        UintVal(u64),
        #[prost(bool, tag = "4")]
        BoolVal(bool),
        #[prost(bytes, tag = "5")]
        BytesVal(Vec<u8>),
        #[prost(float, tag = "6")]
        FloatVal(f32),
        #[prost(message, tag = "8")]
        LeaflistVal(super::ScalarArray),
        #[prost(bytes, tag = "10")]
        JsonVal(Vec<u8>),
        #[prost(bytes, tag = "11")]
        JsonIetfVal(Vec<u8>),
        #[prost(string, tag = "12")]
        AsciiVal(String),
        #[prost(double, tag = "14")]
        DoubleVal(f64),
    }
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct ScalarArray {
    #[prost(message, repeated, tag = "1")]
    pub element: Vec<TypedValue>,
}

#[derive(Clone, PartialEq, prost::Message)]
pub struct Path {
    #[prost(string, tag = "2")]
    pub origin: String,
    #[prost(message, repeated, tag = "3")]
    pub elem: Vec<PathElem>,
    #[prost(string, tag = "4")]
    pub target: String,
}

#[derive(Clone, PartialEq, Eq, prost::Message)]
pub struct PathElem {
    #[prost(string, tag = "1")]
    pub name: String,
    #[prost(btree_map = "string, string", tag = "2")]
    pub key: BTreeMap<String, String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum Encoding {
    Json = 0,
    Bytes = 1,
    Proto = 2,
    Ascii = 3,
    JsonIetf = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum DataType {
    All = 0,
    Config = 1,
    State = 2,
    Operational = 3,
}

impl Path {
    /// A path from `/`-separated element names, without keys: what the poller requests.
    pub fn from_names(path: &str) -> Self {
        Self {
            elem: path
                .split('/')
                .filter(|name| !name.is_empty())
                .map(|name| PathElem {
                    name: name.to_owned(),
                    key: BTreeMap::new(),
                })
                .collect(),
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;

    #[test]
    fn encodes_a_get_request_with_the_published_tags() {
        let request = GetRequest {
            path: vec![Path::from_names("/system/state")],
            r#type: DataType::State as i32,
            encoding: Encoding::JsonIetf as i32,
            ..Default::default()
        };

        // path (2) { elem (3) { name (1) "system" } elem { name "state" } }, type (3) STATE,
        // encoding (5) JSON_IETF, encoded by hand from the wire format so a wrong tag shows up.
        assert_eq!(
            request.encode_to_vec(),
            [
                0x12, 0x13, 0x1a, 0x08, 0x0a, 0x06, b's', b'y', b's', b't', b'e', b'm', 0x1a, 0x07,
                0x0a, 0x05, b's', b't', b'a', b't', b'e', 0x18, 0x02, 0x28, 0x04,
            ]
        );
    }

    #[test]
    fn decodes_keyed_paths_and_typed_values() {
        let notification = Notification {
            prefix: Some(Path {
                origin: "openconfig".into(),
                ..Path::from_names("interfaces")
            }),
            update: vec![Update {
                path: Some(Path {
                    elem: vec![
                        PathElem {
                            name: "interface".into(),
                            key: [("name".into(), "Ethernet1".into())].into(),
                        },
                        PathElem {
                            name: "state".into(),
                            key: BTreeMap::new(),
                        },
                    ],
                    ..Default::default()
                }),
                val: Some(TypedValue {
                    value: Some(typed_value::Value::JsonIetfVal(br#"{"mtu":9214}"#.to_vec())),
                }),
            }],
            ..Default::default()
        };

        let decoded = Notification::decode(notification.encode_to_vec().as_slice()).unwrap();

        assert_eq!(decoded, notification);
    }
}
