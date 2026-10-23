//! `query.sql@1`: an operator-written osquery `SELECT`, the one query whose
//! text comes from the request. Sensitive. Matches `Renga.Jobs.Queries.Sql`.
//!
//! The agent does not look for table names in the SQL. Some osquery tables
//! read arbitrary files, make network requests, or copy files off the host,
//! and those are excluded by osquery itself through its `disable_tables`
//! flag. Before each run the agent reads the daemon's flags and refuses
//! unless every table in [`DENIED_TABLES`] is disabled. osquery disables a
//! table named in both `enable_tables` and `disable_tables`, so the second is
//! enough.
//!
//! osquery's own SQLite database is writable, and osquery runs every
//! statement in the text it is given, so the agent also keeps the query to
//! one read:
//!
//! * it splits the text at semicolons outside quotes and comments, and
//!   refuses more than one statement before osquery sees any of it;
//! * it refuses SQLite's parameter syntax (`?`, `:a`, `@a`, `$a`, `#a`)
//!   outside quotes and comments. Nothing binds parameters here, and
//!   SQLite's `$a(...)` form may hold a quote the splitter would otherwise
//!   take as opening a string, hiding a second statement inside it;
//! * it accepts only a `SELECT`, or a `WITH` that reads, refusing anything
//!   else, such as a `PRAGMA` (which can change the connection while it is
//!   merely prepared), before osquery sees it;
//! * it asks SQLite to `EXPLAIN` that statement and refuses a program that
//!   opens a write transaction, writes a virtual table, or calls osquery's
//!   `sleep()`, which would hold the daemon long after the agent stops
//!   waiting;
//! * it requires `carver_disable_function`, since osquery's `carve()` copies
//!   files off the host even with the `carves` table disabled.
//!
//! osquery returns a statement's rows as one reply. The agent reads at most
//! 16 MiB of it and fails beyond that; what it reports is cut to Renga's
//! bounds and says so with `truncated`. Bounding the daemon's own memory is
//! osquery's watchdog's job, not something its extensions API offers.
//!
//! Without osquery there is nothing to answer with, so the query fails.

use super::{clip, parameters, Bounded, Query, Sensitivity, RESULT_BUDGET_BYTES};
use crate::{cancellation::Cancellation, jobs::JobFailure, osquery};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeSet;

/// Tables that read files (`file`, `yara`, `augeas`), make network requests
/// to an address the query names (`curl`, `curl_certificate`, and
/// `ycloud_instance_metadata`, whose `metadata_endpoint` constraint becomes
/// the URL it fetches), or copy files off the host (`carves`).
pub const DENIED_TABLES: [&str; 7] = [
    "augeas",
    "carves",
    "curl",
    "curl_certificate",
    "file",
    "ycloud_instance_metadata",
    "yara",
];

const MAX_SQL: usize = 4096;
const MAX_COLUMNS: usize = 256;
const MAX_COLUMN_NAME: usize = 128;
const MAX_ROWS: usize = 10_000;
const MAX_CELL: usize = 1024;
/// `{"columns":[],"rows":[],"truncated":false}` and change.
const ENVELOPE_BYTES: usize = 64;

pub struct Sql;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {
    #[serde(default)]
    sql: String,
}

impl Query for Sql {
    fn name(&self) -> &'static str {
        "query.sql"
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Sensitive
    }

    fn answer(&self, raw: &Value, _cancellation: &Cancellation) -> Result<Value, JobFailure> {
        sql(raw)?;
        Err(super::failed("osquery is not available on this host"))
    }

    fn uses_osquery(&self) -> bool {
        true
    }

    fn answer_with_osquery(
        &self,
        osquery: &mut osquery::Client,
        raw: &Value,
    ) -> Result<Option<Value>, JobFailure> {
        let sql = sql(raw)?;
        let Ok(options) = osquery.options() else {
            return Ok(None);
        };
        refuse_unless_denied_tables_disabled(&options)?;
        refuse_unless_carving_disabled(&options)?;
        let program = osquery
            .query(&format!("EXPLAIN {sql}"))
            .map_err(osquery_failure)?;
        refuse_unsafe_program(&program)?;
        let columns = osquery.query_columns(&sql).map_err(osquery_failure)?;
        let rows = osquery.query(&sql).map_err(osquery_failure)?;
        Ok(Some(table(columns, rows)))
    }
}

/// The request's one statement, without a trailing semicolon.
fn sql(raw: &Value) -> Result<String, JobFailure> {
    let params: Parameters = parameters(raw)?;
    if params.sql.chars().count() > MAX_SQL {
        return Err(super::failed(&format!(
            "invalid parameters: sql must be at most {MAX_SQL} characters"
        )));
    }
    let statement = single_statement(&params.sql)?.trim();
    if statement.is_empty() {
        return Err(super::failed("invalid parameters: sql must not be blank"));
    }
    if !matches!(
        first_keyword(statement).to_ascii_uppercase().as_str(),
        "SELECT" | "WITH"
    ) {
        return Err(super::failed(
            "refused by the agent's policy: sql must be a SELECT",
        ));
    }
    Ok(statement.to_owned())
}

/// The statement's first word, after any leading comments.
fn first_keyword(statement: &str) -> &str {
    let bytes = statement.as_bytes();
    let mut i = 0;
    loop {
        match bytes.get(i..i + 2) {
            Some(b"--") => i = closing(bytes, i + 2, b"\n"),
            Some(b"/*") => i = closing(bytes, i + 2, b"*/"),
            _ if bytes.get(i).is_some_and(u8::is_ascii_whitespace) => i += 1,
            _ => break,
        }
    }
    let rest = &statement[i..];
    let end = rest
        .find(|c: char| !c.is_ascii_alphabetic())
        .unwrap_or(rest.len());
    &rest[..end]
}

/// The text before the first semicolon that is outside a string, quoted
/// name, or comment. Anything after it other than whitespace, comments, and
/// more semicolons is a second statement, which osquery would also run.
fn single_statement(sql: &str) -> Result<&str, JobFailure> {
    let bytes = sql.as_bytes();
    let mut end = None;
    let mut i = 0;
    while i < bytes.len() {
        // Where the next token starts, and whether it may follow the end.
        let (next, ignorable) = match bytes[i] {
            b'-' if bytes.get(i + 1) == Some(&b'-') => (closing(bytes, i + 2, b"\n"), true),
            b'/' if bytes.get(i + 1) == Some(&b'*') => (closing(bytes, i + 2, b"*/"), true),
            quote @ (b'\'' | b'"' | b'`') => (closing(bytes, i + 1, &[quote]), false),
            b'[' => (closing(bytes, i + 1, b"]"), false),
            b';' => {
                end.get_or_insert(i);
                (i + 1, true)
            }
            b'?' | b':' | b'@' | b'$' | b'#' => {
                return Err(super::failed(
                    "invalid parameters: sql must not use parameters ($, :, @, #, or ?) \
                     outside quotes",
                ))
            }
            byte => (i + 1, byte.is_ascii_whitespace()),
        };
        if end.is_some() && !ignorable {
            return Err(super::failed(
                "invalid parameters: sql must be one statement",
            ));
        }
        i = next;
    }
    Ok(&sql[..end.unwrap_or(sql.len())])
}

/// The index just past `terminator` at or after `from`, or the end of the
/// text when it is missing (SQLite then reports the error itself).
fn closing(bytes: &[u8], from: usize, terminator: &[u8]) -> usize {
    bytes[from.min(bytes.len())..]
        .windows(terminator.len())
        .position(|window| window == terminator)
        .map_or(bytes.len(), |at| from + at + terminator.len())
}

/// Refuses a compiled program that writes: SQLite opens a write transaction
/// (`Transaction` with a non-zero P2) for every change to a table, view,
/// index, or trigger, and writes virtual tables with `VUpdate`. Also refuses
/// one that calls `sleep()`: the daemon runs a query to the end whether or
/// not anyone waits, and its watchdog limits CPU and memory, not time.
fn refuse_unsafe_program(program: &[osquery::Row]) -> Result<(), JobFailure> {
    let writes = program.iter().any(|op| {
        let opcode = op.get("opcode").map_or("", String::as_str);
        let p2 = op.get("p2").map_or("0", String::as_str);
        matches!(opcode, "VUpdate" | "VCreate" | "VDestroy")
            || (opcode == "Transaction" && p2 != "0")
    });
    if writes {
        return Err(super::failed(
            "refused by the agent's policy: sql must only read",
        ));
    }
    if program.iter().any(|op| calls(op, "sleep")) {
        return Err(super::failed(
            "refused by the agent's policy: sql must not call sleep()",
        ));
    }
    Ok(())
}

/// Whether an `EXPLAIN` row calls the SQL function `name`. Function and
/// aggregate opcodes show it in P4 as `name(arguments)`; a string literal
/// that merely reads like a call is another opcode.
fn calls(op: &osquery::Row, name: &str) -> bool {
    let opcode = op.get("opcode").map_or("", String::as_str);
    let p4 = op.get("p4").map_or("", String::as_str);
    (opcode.contains("Func") || opcode.starts_with("Agg"))
        && p4
            .split('(')
            .next()
            .is_some_and(|called| called.trim().eq_ignore_ascii_case(name))
}

/// The bytes osquery trims from each `disable_tables` entry: its Boost trim
/// classifies single bytes in the C locale. Trimming anything more, such as
/// a Unicode space, would accept a name osquery does not disable.
const FLAG_SPACE: [char; 6] = [' ', '\t', '\n', '\x0b', '\x0c', '\r'];

fn refuse_unless_denied_tables_disabled(options: &osquery::Row) -> Result<(), JobFailure> {
    let disabled: BTreeSet<&str> = options
        .get("disable_tables")
        .map(|tables| {
            tables
                .split(',')
                .map(|table| table.trim_matches(FLAG_SPACE))
                .collect()
        })
        .unwrap_or_default();
    let missing: Vec<&str> = DENIED_TABLES
        .into_iter()
        .filter(|table| !disabled.contains(table))
        .collect();
    if missing.is_empty() {
        return Ok(());
    }
    Err(super::failed(&format!(
        "refused by the agent's policy: osquery must run with --disable_tables covering {}",
        missing.join(", ")
    )))
}

/// `carve()` asks the daemon to copy files off the host whatever
/// `disable_tables` says; only this flag turns it off. A daemon that does
/// not report the flag is refused.
fn refuse_unless_carving_disabled(options: &osquery::Row) -> Result<(), JobFailure> {
    match options.get("carver_disable_function").map(String::as_str) {
        Some("true") => Ok(()),
        _ => Err(super::failed(
            "refused by the agent's policy: osquery must run with --carver_disable_function",
        )),
    }
}

/// osquery's own message, such as a syntax error or an unknown table, is
/// about the operator's SQL and safe to show them.
fn osquery_failure(error: osquery::Error) -> JobFailure {
    match error {
        osquery::Error::Status { message, .. } => {
            super::failed(&format!("osquery: {}", clip(&message, 256)))
        }
        _other => super::failed(
            "osquery did not answer, or its answer was larger than the agent reads (16 MiB); \
             narrow the query, for example with LIMIT",
        ),
    }
}

/// Rows as values in column order, cut to Renga's bounds. A clipped name or
/// value, or a dropped column or row, sets `truncated`.
fn table(columns: Vec<String>, rows: Vec<osquery::Row>) -> Value {
    let mut truncated = columns.len() > MAX_COLUMNS;
    let names: Vec<&String> = columns.iter().take(MAX_COLUMNS).collect();
    let mut clipped = |value: &str, max: usize| {
        truncated |= value.chars().count() > max;
        clip(value, max)
    };
    // The header takes at most half the budget, column by column, so rows
    // always have room. Columns past that are dropped from every row too.
    let mut header: Vec<String> = Vec::new();
    let mut header_bytes = ENVELOPE_BYTES;
    for name in &names {
        let name = clipped(name, MAX_COLUMN_NAME);
        let bytes = serde_json::to_string(&name).map_or(usize::MAX, |s| s.len() + 1);
        if header_bytes.saturating_add(bytes) > RESULT_BUDGET_BYTES / 2 {
            break;
        }
        header_bytes += bytes;
        header.push(name);
    }
    let dropped = header.len() < names.len();
    let names = &names[..header.len()];
    let mut list = Bounded::with_budget(MAX_ROWS, RESULT_BUDGET_BYTES - header_bytes);
    for row in &rows {
        let values: Vec<String> = names
            .iter()
            .map(|name| clipped(row.get(*name).map_or("", String::as_str), MAX_CELL))
            .collect();
        if !list.push(values) {
            break;
        }
    }
    let (rows, cut) = list.into_parts();
    serde_json::json!({ "columns": header, "rows": rows, "truncated": truncated || cut || dropped })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn row(cells: &[(&str, &str)]) -> osquery::Row {
        cells
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn keeps_osquery_s_column_order() {
        let value = table(
            vec!["pid".into(), "name".into()],
            vec![
                row(&[("name", "sshd"), ("pid", "812")]),
                row(&[("pid", "1")]),
            ],
        );
        assert_eq!(
            value,
            json!({
                "columns": ["pid", "name"],
                "rows": [["812", "sshd"], ["1", ""]],
                "truncated": false
            })
        );
        super::super::contract::assert_conforms("query.sql@1", "result", &value);
    }

    #[test]
    fn a_header_too_large_for_the_budget_drops_columns_not_the_result() {
        // 256 names of 128 four-byte characters: far more than the budget.
        let name: String = std::iter::repeat_n('\u{1F600}', MAX_COLUMN_NAME).collect();
        let columns = vec![name; MAX_COLUMNS];
        let rows = vec![row(&[])];
        let value = table(columns, rows);
        assert_eq!(value["truncated"], true);
        let kept = value["columns"].as_array().unwrap().len();
        assert!(kept > 0 && kept < MAX_COLUMNS);
        assert_eq!(value["rows"][0].as_array().unwrap().len(), kept);
        assert!(serde_json::to_vec(&value).unwrap().len() <= RESULT_BUDGET_BYTES);
        super::super::contract::assert_conforms("query.sql@1", "result", &value);
    }

    #[test]
    fn bounds_columns_cells_and_rows() {
        let wide: Vec<String> = (0..MAX_COLUMNS + 1).map(|i| format!("c{i}")).collect();
        let value = table(wide, vec![]);
        assert_eq!(value["columns"].as_array().unwrap().len(), MAX_COLUMNS);
        assert_eq!(value["truncated"], true);

        let long = "x".repeat(MAX_CELL + 1);
        let value = table(vec!["a".into()], vec![row(&[("a", &long)])]);
        assert_eq!(value["rows"][0][0].as_str().unwrap().len(), MAX_CELL);
        assert_eq!(value["truncated"], true);

        let cell = "y".repeat(MAX_CELL);
        let rows: Vec<osquery::Row> = (0..100).map(|_| row(&[("a", &cell)])).collect();
        let value = table(vec!["a".into()], rows);
        let kept = value["rows"].as_array().unwrap().len();
        assert!(kept < 100 && kept > 10, "{kept}");
        assert_eq!(value["truncated"], true);
        assert!(serde_json::to_vec(&value).unwrap().len() <= RESULT_BUDGET_BYTES);
        super::super::contract::assert_conforms("query.sql@1", "result", &value);
    }

    #[test]
    fn requires_every_denied_table_disabled() {
        let all = DENIED_TABLES.join(",");
        assert!(refuse_unless_denied_tables_disabled(&row(&[("disable_tables", &all)])).is_ok());
        let spaced = format!(" {} ,hash", DENIED_TABLES.join(" , "));
        assert!(refuse_unless_denied_tables_disabled(&row(&[("disable_tables", &spaced)])).is_ok());
        // osquery does not trim a Unicode space, so it would not disable these.
        let nbsp = DENIED_TABLES.map(|t| format!("{t}\u{a0}")).join(",");
        assert!(refuse_unless_denied_tables_disabled(&row(&[("disable_tables", &nbsp)])).is_err());

        match refuse_unless_denied_tables_disabled(&row(&[("disable_tables", "curl,file")])) {
            Err(JobFailure::Failed(reason)) => {
                assert!(
                    reason.contains(
                        "augeas, carves, curl_certificate, ycloud_instance_metadata, yara"
                    ),
                    "{reason}"
                )
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
        assert!(refuse_unless_denied_tables_disabled(&row(&[])).is_err());
    }

    #[test]
    fn refuses_blank_long_or_unknown_parameters() {
        assert_eq!(sql(&json!({"sql": "SELECT 1"})).unwrap(), "SELECT 1");
        assert!(sql(&Value::Null).is_err());
        assert!(sql(&json!({"sql": "  "})).is_err());
        assert!(sql(&json!({"sql": "x".repeat(MAX_SQL + 1)})).is_err());
        assert!(sql(&json!({"sql": "SELECT 1", "table": "file"})).is_err());
        super::super::contract::assert_conforms(
            "query.sql@1",
            "parameters",
            &json!({"sql": "SELECT 1"}),
        );
    }

    #[test]
    fn keeps_to_one_statement() {
        fn one(text: &str) -> Option<&str> {
            single_statement(text).ok()
        }
        assert_eq!(one("SELECT 1"), Some("SELECT 1"));
        assert_eq!(one("SELECT 1; "), Some("SELECT 1"));
        assert_eq!(one("SELECT 1;; -- done\n/* really */"), Some("SELECT 1"));
        assert_eq!(one("SELECT ';' AS a"), Some("SELECT ';' AS a"));
        assert_eq!(one("SELECT 'it''s; fine'"), Some("SELECT 'it''s; fine'"));
        assert_eq!(
            one("SELECT \"a;b\", [c;d], `e;f` FROM t"),
            Some("SELECT \"a;b\", [c;d], `e;f` FROM t")
        );
        assert_eq!(
            one("SELECT 1 -- ; DROP TABLE t"),
            Some("SELECT 1 -- ; DROP TABLE t")
        );
        assert_eq!(one("SELECT 1 /* ; */ + 2"), Some("SELECT 1 /* ; */ + 2"));
        assert_eq!(one("SELECT 'é;'"), Some("SELECT 'é;'"));

        assert_eq!(one("SELECT 1; SELECT 2"), None);
        assert_eq!(one("SELECT 1; CREATE TABLE t (a)"), None);
        assert_eq!(one("SELECT 1;'x'"), None);
        assert_eq!(one("SELECT 1; -"), None);
        assert_eq!(sql(&json!({"sql": " ; "})).ok(), None);
        assert_eq!(sql(&json!({"sql": "SELECT 1;\n"})).unwrap(), "SELECT 1");
    }

    fn op(opcode: &str, p2: &str) -> osquery::Row {
        row(&[("opcode", opcode), ("p2", p2)])
    }

    #[test]
    fn refuses_programs_that_write() {
        let read = [op("Init", "7"), op("OpenRead", "3"), op("Transaction", "0")];
        assert!(refuse_unsafe_program(&read).is_ok());
        assert!(refuse_unsafe_program(&[op("Init", "4"), op("ResultRow", "1")]).is_ok());

        let insert = [
            op("OpenWrite", "3"),
            op("Insert", "3"),
            op("Transaction", "1"),
        ];
        assert!(refuse_unsafe_program(&insert).is_err());
        assert!(refuse_unsafe_program(&[op("VUpdate", "0")]).is_err());
    }

    #[test]
    fn refuses_programs_that_call_sleep() {
        let call = |opcode: &str, p4: &str| row(&[("opcode", opcode), ("p2", "0"), ("p4", p4)]);
        for op in [
            call("Function", "sleep(1)"),
            call("PureFunc", "SLEEP(1)"),
            call("Function0", "sleep(1)"),
        ] {
            assert!(refuse_unsafe_program(&[op]).is_err());
        }
        // A string that reads like the call, and other functions, are fine.
        assert!(refuse_unsafe_program(&[call("String8", "sleep(1)")]).is_ok());
        assert!(refuse_unsafe_program(&[call("Function", "sleeper(1)")]).is_ok());
        assert!(refuse_unsafe_program(&[call("Function", "lower(1)")]).is_ok());
    }

    #[test]
    fn without_osquery_it_fails() {
        match Sql.answer(&json!({"sql": "SELECT 1"}), &Cancellation::default()) {
            Err(JobFailure::Failed(reason)) => assert!(reason.contains("not available")),
            other => panic!("expected a failure, got {other:?}"),
        }
    }
}
