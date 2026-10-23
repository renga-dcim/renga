//! Folds what a target answered to Get into one JSON tree.
//!
//! Targets choose how to split an answer: one update holding the whole requested subtree, one
//! per list entry under a keyed path, or one per leaf. Whatever the split, merging every update
//! at its full path gives the same tree, which the OpenConfig mapper then reads. YANG module
//! prefixes on member names (`openconfig-interfaces:interfaces`) are dropped, since the mapper
//! reads one model and JSON (unlike JSON_IETF) never carries them.

use super::proto::{typed_value::Value as Typed, Notification, Path, TypedValue};
use serde_json::{Map, Number, Value};
use std::collections::BTreeMap;

struct Elem {
    name: String,
    keys: BTreeMap<String, String>,
}

/// Merges every update in `notifications` into `tree`. Deletes are ignored: a Get answer
/// describes current state, so it carries none.
pub fn merge(tree: &mut Value, notifications: &[Notification]) -> Result<(), String> {
    for notification in notifications {
        for update in &notification.update {
            let Some(value) = update.val.as_ref() else {
                continue;
            };
            let mut value = json(value)?;
            let elems: Vec<Elem> = elems(notification.prefix.as_ref())
                .chain(elems(update.path.as_ref()))
                .collect();
            // Some targets wrap a container's content in the container's own name again.
            if let Some(last) = elems.last().filter(|elem| elem.keys.is_empty()) {
                if let Value::Object(object) = &mut value {
                    if object.len() == 1 && object.contains_key(&last.name) {
                        value = object.remove(&last.name).expect("checked above");
                    }
                }
            }
            insert(tree, &elems, value);
        }
    }
    Ok(())
}

fn elems(path: Option<&Path>) -> impl Iterator<Item = Elem> + '_ {
    path.into_iter()
        .flat_map(|path| &path.elem)
        .map(|elem| Elem {
            name: unprefixed(&elem.name).to_owned(),
            keys: elem
                .key
                .iter()
                .map(|(key, value)| (unprefixed(key).to_owned(), value.clone()))
                .collect(),
        })
}

fn json(value: &TypedValue) -> Result<Value, String> {
    Ok(match &value.value {
        Some(Typed::JsonVal(bytes) | Typed::JsonIetfVal(bytes)) => {
            let mut value: Value = serde_json::from_slice(bytes)
                .map_err(|error| format!("the target sent invalid JSON: {error}"))?;
            strip_prefixes(&mut value);
            value
        }
        Some(Typed::StringVal(text) | Typed::AsciiVal(text)) => Value::String(text.clone()),
        Some(Typed::IntVal(number)) => Value::from(*number),
        Some(Typed::UintVal(number)) => Value::from(*number),
        Some(Typed::BoolVal(flag)) => Value::Bool(*flag),
        Some(Typed::FloatVal(number)) => float(f64::from(*number)),
        Some(Typed::DoubleVal(number)) => float(*number),
        Some(Typed::LeaflistVal(array)) => {
            Value::Array(array.element.iter().map(json).collect::<Result<_, _>>()?)
        }
        // Opaque bytes say nothing the mapper reads.
        Some(Typed::BytesVal(_)) | None => Value::Null,
    })
}

fn float(number: f64) -> Value {
    Number::from_f64(number).map_or(Value::Null, Value::Number)
}

fn strip_prefixes(value: &mut Value) {
    match value {
        Value::Object(object) => {
            *object = std::mem::take(object)
                .into_iter()
                .map(|(key, mut value)| {
                    strip_prefixes(&mut value);
                    (unprefixed(&key).to_owned(), value)
                })
                .collect();
        }
        Value::Array(values) => values.iter_mut().for_each(strip_prefixes),
        _ => {}
    }
}

fn unprefixed(name: &str) -> &str {
    name.rsplit_once(':').map_or(name, |(_, name)| name)
}

fn insert(node: &mut Value, elems: &[Elem], value: Value) {
    let Some((elem, rest)) = elems.split_first() else {
        merge_value(node, value);
        return;
    };
    if !node.is_object() {
        *node = Value::Object(Map::new());
    }
    let child = node
        .as_object_mut()
        .expect("made an object above")
        .entry(elem.name.clone())
        .or_insert(Value::Null);
    if elem.keys.is_empty() {
        insert(child, rest, value);
        return;
    }
    // A keyed element addresses one entry of a list, held as an array of objects that carry
    // their keys the way JSON-encoded lists do.
    if !child.is_array() {
        *child = Value::Array(Vec::new());
    }
    let entries = child.as_array_mut().expect("made an array above");
    let index = match entries
        .iter()
        .position(|entry| keys_match(entry, &elem.keys))
    {
        Some(index) => index,
        None => {
            entries.push(Value::Object(
                elem.keys
                    .iter()
                    .map(|(key, value)| (key.clone(), Value::String(value.clone())))
                    .collect(),
            ));
            entries.len() - 1
        }
    };
    insert(&mut entries[index], rest, value);
}

fn keys_match(entry: &Value, keys: &BTreeMap<String, String>) -> bool {
    keys.iter().all(|(key, expected)| match entry.get(key) {
        Some(Value::String(actual)) => actual == expected,
        Some(Value::Number(actual)) => actual.to_string() == *expected,
        _ => false,
    })
}

fn merge_value(node: &mut Value, value: Value) {
    match (node, value) {
        (Value::Object(existing), Value::Object(incoming)) => {
            for (key, value) in incoming {
                merge_value(existing.entry(key).or_insert(Value::Null), value);
            }
        }
        (Value::Array(existing), Value::Array(incoming)) => existing.extend(incoming),
        (node, value) => *node = value,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::gnmi::proto::{PathElem, Update};
    use serde_json::json;

    /// A path written like `interfaces/interface[name=Ethernet1]/state`.
    pub(crate) fn path(text: &str) -> Path {
        Path {
            elem: text
                .split('/')
                .filter(|part| !part.is_empty())
                .map(|part| match part.split_once('[') {
                    Some((name, keys)) => PathElem {
                        name: name.into(),
                        key: keys
                            .trim_end_matches(']')
                            .split("][")
                            .map(|pair| {
                                let (key, value) = pair.split_once('=').unwrap();
                                (key.into(), value.into())
                            })
                            .collect(),
                    },
                    None => PathElem {
                        name: part.into(),
                        key: BTreeMap::new(),
                    },
                })
                .collect(),
            ..Default::default()
        }
    }

    pub(crate) fn update(at: &str, value: Typed) -> Update {
        Update {
            path: Some(path(at)),
            val: Some(TypedValue { value: Some(value) }),
        }
    }

    pub(crate) fn json_ietf(value: Value) -> Typed {
        Typed::JsonIetfVal(serde_json::to_vec(&value).unwrap())
    }

    fn tree(notifications: &[Notification]) -> Value {
        let mut tree = Value::Null;
        merge(&mut tree, notifications).unwrap();
        tree
    }

    #[test]
    fn builds_the_same_tree_whatever_the_split() {
        let whole = Notification {
            update: vec![update(
                "",
                json_ietf(json!({"openconfig-interfaces:interfaces": {"interface": [
                    {"name": "Ethernet1", "state": {"mtu": 9214, "oper-status": "UP"}}
                ]}})),
            )],
            ..Default::default()
        };
        let per_entry = Notification {
            prefix: Some(path("interfaces")),
            update: vec![update(
                "interface[name=Ethernet1]",
                json_ietf(json!({"state": {"mtu": 9214, "oper-status": "UP"}})),
            )],
            ..Default::default()
        };
        let per_leaf = Notification {
            prefix: Some(path(
                "openconfig-interfaces:interfaces/interface[name=Ethernet1]",
            )),
            update: vec![
                update("state/mtu", Typed::UintVal(9214)),
                update("state/oper-status", Typed::StringVal("UP".into())),
            ],
            ..Default::default()
        };
        let rewrapped = Notification {
            update: vec![update(
                "interfaces",
                json_ietf(json!({"openconfig-interfaces:interfaces": {"interface": [
                    {"name": "Ethernet1", "state": {"mtu": 9214, "oper-status": "UP"}}
                ]}})),
            )],
            ..Default::default()
        };

        let expected = json!({"interfaces": {"interface": [
            {"name": "Ethernet1", "state": {"mtu": 9214, "oper-status": "UP"}}
        ]}});
        for notification in [whole, per_entry, per_leaf, rewrapped] {
            assert_eq!(tree(&[notification]), expected);
        }
    }

    #[test]
    fn matches_numeric_list_keys_and_merges_entries() {
        let tree = tree(&[Notification {
            update: vec![
                update(
                    "interfaces/interface[name=Ethernet1]/subinterfaces",
                    json_ietf(json!({"subinterface": [{"index": 0, "state": {"index": 0}}]})),
                ),
                update(
                    "interfaces/interface[name=Ethernet1]/subinterfaces/subinterface[index=0]/state/enabled",
                    Typed::BoolVal(true),
                ),
            ],
            ..Default::default()
        }]);

        assert_eq!(
            tree["interfaces"]["interface"][0]["subinterfaces"]["subinterface"],
            json!([{"index": 0, "state": {"index": 0, "enabled": true}}])
        );
    }

    #[test]
    fn rejects_invalid_json() {
        let error = merge(
            &mut Value::Null,
            &[Notification {
                update: vec![update("system", Typed::JsonVal(b"{".to_vec()))],
                ..Default::default()
            }],
        )
        .unwrap_err();

        assert!(error.contains("invalid JSON"), "{error}");
    }
}
