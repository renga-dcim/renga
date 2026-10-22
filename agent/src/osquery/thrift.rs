//! Just enough of Apache Thrift's binary protocol to call osquery's extension
//! manager: strict message headers, structs, strings, integers, lists, and
//! maps, over an unframed (buffered) transport.
//!
//! Reads are bounded: a reply may not exceed [`MAX_REPLY_BYTES`], nest deeper
//! than [`MAX_DEPTH`], or declare more than [`MAX_ELEMENTS`] container
//! entries, so a misbehaving peer cannot make the agent allocate without limit.

use std::io::{self, Read, Write};

const VERSION_1: u32 = 0x8001_0000;
const VERSION_MASK: u32 = 0xffff_0000;

pub const CALL: u8 = 1;
pub const REPLY: u8 = 2;
pub const EXCEPTION: u8 = 3;

const STOP: u8 = 0;
const BOOL: u8 = 2;
const BYTE: u8 = 3;
const DOUBLE: u8 = 4;
const I16: u8 = 6;
const I32: u8 = 8;
const I64: u8 = 10;
const STRING: u8 = 11;
const STRUCT: u8 = 12;
const MAP: u8 = 13;
const SET: u8 = 14;
const LIST: u8 = 15;

/// The most bytes one reply may take.
pub const MAX_REPLY_BYTES: u64 = 16 * 1024 * 1024;
/// The deepest nesting a reply may use.
pub const MAX_DEPTH: usize = 16;
/// The most entries one list, set, or map may declare.
pub const MAX_ELEMENTS: usize = 1 << 20;

/// A decoded Thrift value. Strings stay bytes until a caller asks for text.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    Byte(i8),
    I16(i16),
    I32(i32),
    I64(i64),
    Double(f64),
    String(Vec<u8>),
    Struct(Vec<(i16, Value)>),
    Map(u8, u8, Vec<(Value, Value)>),
    List(u8, Vec<Value>),
}

impl Value {
    fn type_id(&self) -> u8 {
        match self {
            Value::Bool(_) => BOOL,
            Value::Byte(_) => BYTE,
            Value::I16(_) => I16,
            Value::I32(_) => I32,
            Value::I64(_) => I64,
            Value::Double(_) => DOUBLE,
            Value::String(_) => STRING,
            Value::Struct(_) => STRUCT,
            Value::Map(..) => MAP,
            Value::List(..) => LIST,
        }
    }

    /// A struct's field by id.
    pub fn field(&self, id: i16) -> Option<&Value> {
        match self {
            Value::Struct(fields) => fields
                .iter()
                .find(|(field, _)| *field == id)
                .map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_i32(&self) -> Option<i32> {
        match self {
            Value::I32(value) => Some(*value),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<String> {
        match self {
            Value::String(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&[Value]> {
        match self {
            Value::List(_, items) => Some(items),
            _ => None,
        }
    }

    pub fn as_map(&self) -> Option<&[(Value, Value)]> {
        match self {
            Value::Map(_, _, entries) => Some(entries),
            _ => None,
        }
    }

    pub fn string(text: &str) -> Self {
        Value::String(text.as_bytes().to_vec())
    }
}

/// A message header: its type, method name, and sequence id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub kind: u8,
    pub name: String,
    pub seqid: i32,
}

/// Writes a strict message: header, then `body` as the argument or result struct.
pub fn write_message(
    out: &mut impl Write,
    kind: u8,
    name: &str,
    seqid: i32,
    body: &[(i16, Value)],
) -> io::Result<()> {
    out.write_all(&(VERSION_1 | kind as u32).to_be_bytes())?;
    write_bytes(out, name.as_bytes())?;
    out.write_all(&seqid.to_be_bytes())?;
    write_struct(out, body)?;
    out.flush()
}

fn write_struct(out: &mut impl Write, fields: &[(i16, Value)]) -> io::Result<()> {
    for (id, value) in fields {
        out.write_all(&[value.type_id()])?;
        out.write_all(&id.to_be_bytes())?;
        write_value(out, value)?;
    }
    out.write_all(&[STOP])
}

fn write_value(out: &mut impl Write, value: &Value) -> io::Result<()> {
    match value {
        Value::Bool(value) => out.write_all(&[*value as u8]),
        Value::Byte(value) => out.write_all(&value.to_be_bytes()),
        Value::I16(value) => out.write_all(&value.to_be_bytes()),
        Value::I32(value) => out.write_all(&value.to_be_bytes()),
        Value::I64(value) => out.write_all(&value.to_be_bytes()),
        Value::Double(value) => out.write_all(&value.to_bits().to_be_bytes()),
        Value::String(bytes) => write_bytes(out, bytes),
        Value::Struct(fields) => write_struct(out, fields),
        Value::Map(key, value, entries) => {
            out.write_all(&[*key, *value])?;
            out.write_all(&(entries.len() as i32).to_be_bytes())?;
            for (k, v) in entries {
                write_value(out, k)?;
                write_value(out, v)?;
            }
            Ok(())
        }
        Value::List(element, items) => {
            out.write_all(&[*element])?;
            out.write_all(&(items.len() as i32).to_be_bytes())?;
            items.iter().try_for_each(|item| write_value(out, item))
        }
    }
}

fn write_bytes(out: &mut impl Write, bytes: &[u8]) -> io::Result<()> {
    out.write_all(&(bytes.len() as i32).to_be_bytes())?;
    out.write_all(bytes)
}

/// Reads a strict message header and the struct after it.
pub fn read_message(input: &mut impl Read) -> io::Result<(Header, Value)> {
    let mut input = input.take(MAX_REPLY_BYTES);
    let word = read_i32(&mut input)? as u32;
    if word & VERSION_MASK != VERSION_1 {
        return Err(invalid("not a strict Thrift binary message"));
    }
    let kind = (word & 0xff) as u8;
    let name = String::from_utf8(read_bytes(&mut input)?)
        .map_err(|_| invalid("method name is not UTF-8"))?;
    let seqid = read_i32(&mut input)?;
    let body = read_value(&mut input, STRUCT, 0)?;
    Ok((Header { kind, name, seqid }, body))
}

fn read_value(input: &mut impl Read, kind: u8, depth: usize) -> io::Result<Value> {
    if depth > MAX_DEPTH {
        return Err(invalid("reply nests too deeply"));
    }
    Ok(match kind {
        BOOL => Value::Bool(read_array::<1>(input)?[0] != 0),
        BYTE => Value::Byte(i8::from_be_bytes(read_array(input)?)),
        I16 => Value::I16(i16::from_be_bytes(read_array(input)?)),
        I32 => Value::I32(read_i32(input)?),
        I64 => Value::I64(i64::from_be_bytes(read_array(input)?)),
        DOUBLE => Value::Double(f64::from_bits(u64::from_be_bytes(read_array(input)?))),
        STRING => Value::String(read_bytes(input)?),
        STRUCT => {
            let mut fields = Vec::new();
            loop {
                let [field_kind] = read_array(input)?;
                if field_kind == STOP {
                    break;
                }
                let id = i16::from_be_bytes(read_array(input)?);
                fields.push((id, read_value(input, field_kind, depth + 1)?));
            }
            Value::Struct(fields)
        }
        MAP => {
            let [key, value] = read_array(input)?;
            let size = read_size(input)?;
            let mut entries = Vec::with_capacity(size.min(1024));
            for _ in 0..size {
                let k = read_value(input, key, depth + 1)?;
                let v = read_value(input, value, depth + 1)?;
                entries.push((k, v));
            }
            Value::Map(key, value, entries)
        }
        LIST | SET => {
            let [element] = read_array(input)?;
            let size = read_size(input)?;
            let mut items = Vec::with_capacity(size.min(1024));
            for _ in 0..size {
                items.push(read_value(input, element, depth + 1)?);
            }
            Value::List(element, items)
        }
        other => return Err(invalid(&format!("unknown Thrift type {other}"))),
    })
}

fn read_size(input: &mut impl Read) -> io::Result<usize> {
    let size = read_i32(input)?;
    usize::try_from(size)
        .ok()
        .filter(|size| *size <= MAX_ELEMENTS)
        .ok_or_else(|| invalid("container size out of range"))
}

fn read_bytes(input: &mut impl Read) -> io::Result<Vec<u8>> {
    let len = read_i32(input)?;
    let len = u64::try_from(len).map_err(|_| invalid("negative string length"))?;
    if len > MAX_REPLY_BYTES {
        return Err(invalid("string longer than a reply may be"));
    }
    let mut bytes = Vec::new();
    (&mut *input).take(len).read_to_end(&mut bytes)?;
    if bytes.len() as u64 != len {
        return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
    }
    Ok(bytes)
}

fn read_i32(input: &mut impl Read) -> io::Result<i32> {
    Ok(i32::from_be_bytes(read_array(input)?))
}

fn read_array<const N: usize>(input: &mut impl Read) -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    input.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(body: Vec<(i16, Value)>) -> (Header, Value) {
        let mut bytes = Vec::new();
        write_message(&mut bytes, REPLY, "query", 7, &body).unwrap();
        read_message(&mut bytes.as_slice()).unwrap()
    }

    #[test]
    fn round_trips_every_type_it_writes() {
        let rows = Value::List(
            MAP,
            vec![Value::Map(
                STRING,
                STRING,
                vec![(Value::string("name"), Value::string("osqueryd"))],
            )],
        );
        let body = vec![
            (1, Value::Bool(true)),
            (2, Value::Byte(-3)),
            (3, Value::I16(-300)),
            (4, Value::I32(70_000)),
            (5, Value::I64(1 << 40)),
            (6, Value::Double(0.5)),
            (7, Value::string("text")),
            (8, Value::Struct(vec![(1, rows)])),
        ];

        let (header, value) = round_trip(body.clone());

        assert_eq!(
            header,
            Header {
                kind: REPLY,
                name: "query".into(),
                seqid: 7
            }
        );
        assert_eq!(value, Value::Struct(body));
    }

    #[test]
    fn refuses_non_strict_and_oversized_replies() {
        let unversioned = [0, 0, 0, 5, b'q', b'u', b'e', b'r', b'y'];
        assert!(read_message(&mut unversioned.as_slice()).is_err());

        let mut huge_list = Vec::new();
        huge_list.extend_from_slice(&(VERSION_1 | REPLY as u32).to_be_bytes());
        write_bytes(&mut huge_list, b"query").unwrap();
        huge_list.extend_from_slice(&1i32.to_be_bytes());
        huge_list.extend_from_slice(&[LIST, 0, 0, LIST]);
        huge_list.extend_from_slice(&i32::MAX.to_be_bytes());
        let error = read_message(&mut huge_list.as_slice()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);

        let mut long_string = Vec::new();
        long_string.extend_from_slice(&(VERSION_1 | REPLY as u32).to_be_bytes());
        long_string.extend_from_slice(&i32::MAX.to_be_bytes());
        assert!(read_message(&mut long_string.as_slice()).is_err());
    }

    #[test]
    fn refuses_deep_nesting() {
        let mut value = Value::Struct(vec![]);
        for _ in 0..=MAX_DEPTH {
            value = Value::Struct(vec![(1, value)]);
        }
        let mut bytes = Vec::new();
        write_message(&mut bytes, REPLY, "query", 1, &[(0, value)]).unwrap();
        assert!(read_message(&mut bytes.as_slice()).is_err());
    }
}
