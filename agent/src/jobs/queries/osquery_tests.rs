//! Named queries answered from osquery's tables, against a stand-in daemon.

use super::*;
use crate::osquery::{fake, thrift::Value as Thrift};
use serde_json::json;
use std::path::PathBuf;

/// One stand-in table: rows as column-value pairs.
type Table = Vec<Vec<(&'static str, &'static str)>>;

/// A capability for `query` whose osquery answers each SQL statement with
/// `rows`, or with an error when the statement has none.
fn with_daemon(
    query: impl Query + 'static,
    rows: Vec<(&'static str, Table)>,
) -> (QueryCapability, std::thread::JoinHandle<Vec<String>>) {
    let (socket, server) = fake::serve(move |method, args| {
        let sql = args.field(1).and_then(Thrift::as_str).unwrap_or_default();
        assert_eq!(method, "query");
        match rows.iter().find(|(prefix, _)| sql.contains(prefix)) {
            Some((_, rows)) => {
                let rows: Vec<&[(&str, &str)]> = rows.iter().map(Vec::as_slice).collect();
                fake::response(0, "OK", &rows)
            }
            None => fake::response(1, "no such table", &[]),
        }
    });
    let osquery = OsqueryConfig {
        enabled: true,
        socket,
    };
    (QueryCapability::new(query, osquery), server)
}

fn run(capability: &QueryCapability, parameters: serde_json::Value) -> serde_json::Value {
    capability
        .run(&parameters, &Cancellation::default())
        .unwrap()
}

#[test]
fn listening_sockets_come_from_listening_ports() {
    let (capability, server) = with_daemon(
        listening_sockets::ListeningSockets,
        vec![(
            "FROM listening_ports",
            vec![
                vec![
                    ("protocol", "6"),
                    ("address", "0.0.0.0"),
                    ("port", "22"),
                    ("pid", "812"),
                    ("name", "sshd"),
                ],
                vec![
                    ("protocol", "17"),
                    ("address", "::"),
                    ("port", "53"),
                    ("pid", "-1"),
                    ("name", ""),
                ],
                vec![
                    ("protocol", "6"),
                    ("address", "127.0.0.1"),
                    ("port", "0"),
                    ("pid", "9"),
                    ("name", "x"),
                ],
                vec![
                    ("protocol", "132"),
                    ("address", "0.0.0.0"),
                    ("port", "9"),
                    ("pid", "1"),
                    ("name", "sctp"),
                ],
            ],
        )],
    );

    let value = run(&capability, json!({}));
    contract::assert_conforms("query.listening_sockets@1", "result", &value);
    assert_eq!(
        value,
        json!({
            "sockets": [
                {"protocol": "tcp", "address": "127.0.0.1", "port": 0, "process": "x", "pid": 9},
                {"protocol": "tcp", "address": "0.0.0.0", "port": 22, "process": "sshd", "pid": 812},
                {"protocol": "udp", "address": "::", "port": 53, "process": null, "pid": null}
            ],
            "truncated": false
        })
    );
    assert_eq!(server.join().unwrap(), ["query"]);
}

#[test]
fn services_come_from_systemd_units() {
    let (capability, server) = with_daemon(
        services::Services,
        vec![(
            "FROM systemd_units",
            vec![
                vec![
                    ("id", "ssh.service"),
                    ("description", "OpenBSD Secure Shell server"),
                    ("load_state", "loaded"),
                    ("active_state", "active"),
                    ("sub_state", "running"),
                    ("unit_file_state", "enabled"),
                ],
                vec![
                    ("id", "broken.service"),
                    ("description", ""),
                    ("load_state", "loaded"),
                    ("active_state", "failed"),
                    ("sub_state", "failed"),
                    ("unit_file_state", ""),
                ],
            ],
        )],
    );

    let value = run(&capability, json!({"failed_only": true}));
    contract::assert_conforms("query.services@1", "result", &value);
    assert_eq!(
        value["units"],
        json!([{
            "name": "broken.service",
            "description": null,
            "load_state": "loaded",
            "active_state": "failed",
            "sub_state": "failed",
            "enabled_state": null
        }])
    );
    server.join().unwrap();
}

#[test]
fn disk_usage_comes_from_mounts() {
    let (capability, server) = with_daemon(
        disk_usage::DiskUsage,
        vec![(
            "FROM mounts",
            vec![
                vec![
                    ("path", "/"),
                    ("device", "/dev/sda1"),
                    ("type", "ext4"),
                    ("blocks_size", "4096"),
                    ("blocks", "1000"),
                    ("blocks_free", "400"),
                    ("blocks_available", "350"),
                    ("inodes", "64"),
                    ("inodes_free", "60"),
                ],
                vec![
                    ("path", "/proc"),
                    ("device", "proc"),
                    ("type", "proc"),
                    ("blocks_size", "4096"),
                    ("blocks", "0"),
                    ("blocks_free", "0"),
                    ("blocks_available", "0"),
                    ("inodes", "0"),
                    ("inodes_free", "0"),
                ],
            ],
        )],
    );

    let value = run(&capability, json!({}));
    contract::assert_conforms("query.disk_usage@1", "result", &value);
    assert_eq!(
        value["filesystems"],
        json!([{
            "mount_point": "/",
            "device": "/dev/sda1",
            "fs_type": "ext4",
            "size_bytes": 4_096_000,
            "used_bytes": 2_457_600,
            "available_bytes": 1_433_600,
            "inodes_total": 64,
            "inodes_used": 4
        }])
    );
    server.join().unwrap();
}

#[test]
fn packages_come_from_deb_and_rpm_tables() {
    let (capability, server) = with_daemon(
        packages::Packages,
        vec![
            (
                "FROM deb_packages",
                vec![vec![
                    ("name", "openssl"),
                    ("version", "3.0.2-0ubuntu1"),
                    ("arch", "amd64"),
                ]],
            ),
            (
                "FROM rpm_packages",
                vec![
                    vec![
                        ("name", "bash"),
                        ("version", "5.1.8"),
                        ("release", "9.el9"),
                        ("epoch", "0"),
                        ("arch", "x86_64"),
                    ],
                    vec![
                        ("name", "openssh"),
                        ("version", "8.7p1"),
                        ("release", "38.el9"),
                        ("epoch", "1"),
                        ("arch", "x86_64"),
                    ],
                ],
            ),
        ],
    );

    let value = run(&capability, json!({"name": "OPEN"}));
    contract::assert_conforms("query.packages@1", "result", &value);
    assert_eq!(
        value["packages"],
        json!([
            {"name": "openssh", "version": "1:8.7p1-38.el9", "architecture": "x86_64", "manager": "rpm"},
            {"name": "openssl", "version": "3.0.2-0ubuntu1", "architecture": "amd64", "manager": "dpkg"}
        ])
    );
    assert_eq!(server.join().unwrap(), ["query", "query"]);
}

#[test]
fn rpm_versions_keep_an_explicit_epoch_even_zero() {
    let (capability, server) = with_daemon(
        packages::Packages,
        vec![
            ("FROM deb_packages", Vec::new()),
            (
                "FROM rpm_packages",
                vec![
                    vec![
                        ("name", "a"),
                        ("version", "1"),
                        ("release", "2"),
                        ("epoch", ""),
                    ],
                    vec![
                        ("name", "b"),
                        ("version", "1"),
                        ("release", "2"),
                        ("epoch", "0"),
                    ],
                    vec![
                        ("name", "c"),
                        ("version", "1"),
                        ("release", "2"),
                        ("epoch", "3"),
                    ],
                ],
            ),
        ],
    );
    let versions: Vec<_> = run(&capability, json!({}))["packages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["version"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(versions, ["1-2", "0:1-2", "3:1-2"]);
    server.join().unwrap();
}

#[cfg(target_os = "linux")]
#[test]
fn a_failed_package_table_reads_natively_instead_of_answering_half() {
    // dpkg answers, rpm fails: the answer must not be dpkg's packages alone.
    let (capability, server) = with_daemon(
        packages::Packages,
        vec![(
            "FROM deb_packages",
            vec![vec![("name", "only-from-osquery"), ("version", "1")]],
        )],
    );
    let answer = capability.run(&json!({}), &Cancellation::default());
    assert!(!answer.is_ok_and(|v| v.to_string().contains("only-from-osquery")));
    assert_eq!(server.join().unwrap(), ["query", "query"]);

    // dpkg fails first: rpm is not asked on that connection.
    let (capability, server) = with_daemon(packages::Packages, vec![]);
    let _ = capability.run(&json!({}), &Cancellation::default());
    assert_eq!(server.join().unwrap(), ["query"]);
}

#[test]
fn a_matching_filter_with_no_hits_still_answers_from_osquery() {
    let (capability, server) = with_daemon(
        packages::Packages,
        vec![
            (
                "FROM deb_packages",
                vec![vec![("name", "openssl"), ("version", "3")]],
            ),
            ("FROM rpm_packages", Vec::new()),
        ],
    );
    assert_eq!(
        run(&capability, json!({"name": "nothing-like-this"})),
        json!({"packages": [], "truncated": false})
    );
    server.join().unwrap();
}

/// A query that asks osquery and counts its native readings.
struct Counting {
    timeout: std::time::Duration,
    native: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl Query for Counting {
    fn name(&self) -> &'static str {
        "query.counting"
    }
    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Inventory
    }
    fn timeout(&self) -> std::time::Duration {
        self.timeout
    }
    fn answer(
        &self,
        _: &serde_json::Value,
        _: &Cancellation,
    ) -> Result<serde_json::Value, JobFailure> {
        self.native
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(json!({"native": true}))
    }
    fn uses_osquery(&self) -> bool {
        true
    }
    fn answer_with_osquery(
        &self,
        osquery: &mut osquery::Client,
        _: &serde_json::Value,
    ) -> Result<Option<serde_json::Value>, JobFailure> {
        Ok(osquery_rows(osquery, "SELECT 1").map(|_| json!({"native": false})))
    }
}

#[test]
fn a_stalled_daemon_leaves_the_native_reading_its_time() {
    let dir = std::env::temp_dir().join(format!("renga-osquery-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("osquery.em");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    // Accepts and never answers.
    let _hold = std::thread::spawn(move || {
        let held = listener.accept();
        std::thread::sleep(std::time::Duration::from_secs(5));
        drop(held)
    });
    let native = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let capability = QueryCapability::new(
        Counting {
            timeout: std::time::Duration::from_millis(1000),
            native: native.clone(),
        },
        OsqueryConfig {
            enabled: true,
            socket,
        },
    );
    let started = std::time::Instant::now();
    assert_eq!(run(&capability, json!({})), json!({"native": true}));
    // osquery had a fifth of the query's second, not the whole of it.
    assert!(started.elapsed() < std::time::Duration::from_millis(600));
    assert_eq!(native.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[test]
fn a_job_cancelled_during_osquery_does_not_read_natively_too() {
    let dir = std::env::temp_dir().join(format!("renga-osquery-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("osquery.em");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let _hold = std::thread::spawn(move || {
        let held = listener.accept();
        std::thread::sleep(std::time::Duration::from_secs(5));
        drop(held)
    });
    let native = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let capability = QueryCapability::new(
        Counting {
            timeout: std::time::Duration::from_millis(1000),
            native: native.clone(),
        },
        OsqueryConfig {
            enabled: true,
            socket,
        },
    );
    let stopped = Cancellation::default();
    let trigger = stopped.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(50));
        trigger.cancel();
    });
    assert!(matches!(
        capability.run(&json!({}), &stopped),
        Err(JobFailure::Cancelled)
    ));
    assert_eq!(native.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[cfg(target_os = "linux")]
#[test]
fn no_systemd_units_from_osquery_reads_natively() {
    let (capability, server) =
        with_daemon(services::Services, vec![("FROM systemd_units", Vec::new())]);
    let answer = capability.run(&json!({}), &Cancellation::default());
    assert_ne!(answer.ok(), Some(json!({"units": [], "truncated": false})));
    assert_eq!(server.join().unwrap(), ["query"]);
}

#[test]
fn invalid_parameters_are_refused_before_asking_osquery() {
    let (capability, _server) = with_daemon(listening_sockets::ListeningSockets, vec![]);
    assert!(capability
        .run(&json!({"port": 0}), &Cancellation::default())
        .is_err());
}

#[cfg(target_os = "linux")]
#[test]
fn an_osquery_error_falls_back_to_the_native_reading() {
    let (capability, server) = with_daemon(disk_usage::DiskUsage, vec![]);
    let value = run(&capability, json!({}));
    contract::assert_conforms("query.disk_usage@1", "result", &value);
    assert_eq!(server.join().unwrap(), ["query"]);
}

#[cfg(target_os = "linux")]
#[test]
fn a_missing_or_disabled_daemon_reads_natively() {
    let missing = OsqueryConfig {
        enabled: true,
        socket: PathBuf::from(format!("/nonexistent/{}.em", uuid::Uuid::new_v4())),
    };
    let capability = QueryCapability::new(disk_usage::DiskUsage, missing);
    contract::assert_conforms("query.disk_usage@1", "result", &run(&capability, json!({})));

    let disabled = OsqueryConfig {
        enabled: false,
        ..Default::default()
    };
    let capability = QueryCapability::new(disk_usage::DiskUsage, disabled);
    contract::assert_conforms("query.disk_usage@1", "result", &run(&capability, json!({})));
}

/// A daemon for `query.sql@1` whose `disable_tables` is `disabled`.
fn sql_daemon(disabled: &'static str) -> (QueryCapability, std::thread::JoinHandle<Vec<String>>) {
    let (socket, server) = fake::serve(move |method, args| {
        let sql = args.field(1).and_then(Thrift::as_str).unwrap_or_default();
        match (method, sql.as_str()) {
            ("options", _) => fake::options(&[("disable_tables", disabled)]),
            ("getQueryColumns", "SELECT pid, name FROM processes") => {
                fake::response(0, "OK", &[&[("pid", "BIGINT")], &[("name", "TEXT")]])
            }
            ("query", "EXPLAIN SELECT pid, name FROM processes") => fake::response(
                0,
                "OK",
                &[
                    &[("opcode", "VOpen"), ("p2", "0")],
                    &[("opcode", "Transaction"), ("p2", "0")],
                ],
            ),
            ("query", "EXPLAIN CREATE TABLE t (a)") => fake::response(
                0,
                "OK",
                &[
                    &[("opcode", "CreateBtree"), ("p2", "2")],
                    &[("opcode", "Transaction"), ("p2", "1")],
                ],
            ),
            ("query", "SELECT pid, name FROM processes") => fake::response(
                0,
                "OK",
                &[
                    &[("name", "sshd"), ("pid", "812")],
                    &[("name", "init"), ("pid", "1")],
                ],
            ),
            (_, sql) => fake::response(1, &format!("no such table: {sql}"), &[]),
        }
    });
    let osquery = OsqueryConfig {
        enabled: true,
        socket,
    };
    (QueryCapability::new(sql::Sql, osquery), server)
}

const ALL_DENIED: &str = "curl,curl_certificate,carves,yara,file,augeas";

#[test]
fn ad_hoc_sql_answers_a_table_in_column_order() {
    let (capability, server) = sql_daemon(ALL_DENIED);
    let value = run(
        &capability,
        json!({"sql": "SELECT pid, name FROM processes"}),
    );
    assert_eq!(
        value,
        json!({
            "columns": ["pid", "name"],
            "rows": [["812", "sshd"], ["1", "init"]],
            "truncated": false
        })
    );
    contract::assert_conforms("query.sql@1", "result", &value);
    drop(capability);
    assert_eq!(
        server.join().unwrap(),
        ["options", "query", "getQueryColumns", "query"]
    );
}

#[test]
fn ad_hoc_sql_is_refused_unless_every_denied_table_is_disabled() {
    let (capability, server) = sql_daemon("curl,carves");
    let failure = capability
        .run(
            &json!({"sql": "SELECT pid, name FROM processes"}),
            &Cancellation::default(),
        )
        .unwrap_err();
    match failure {
        JobFailure::Failed(reason) => {
            assert!(
                reason.starts_with("refused by the agent's policy"),
                "{reason}"
            );
            assert!(
                reason.contains("augeas, curl_certificate, file, yara"),
                "{reason}"
            );
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
    drop(capability);
    // Nothing ran: the flags were read and the statement never sent.
    assert_eq!(server.join().unwrap(), ["options"]);
}

#[test]
fn ad_hoc_sql_reports_osquery_s_error() {
    let (capability, _server) = sql_daemon(ALL_DENIED);
    match capability.run(
        &json!({"sql": "SELECT * FROM file"}),
        &Cancellation::default(),
    ) {
        Err(JobFailure::Failed(reason)) => {
            assert_eq!(reason, "osquery: no such table: EXPLAIN SELECT * FROM file")
        }
        other => panic!("expected osquery's error, got {other:?}"),
    }
}

#[test]
fn ad_hoc_sql_needs_osquery() {
    let missing = OsqueryConfig {
        enabled: true,
        socket: PathBuf::from("/nonexistent/osquery.em"),
    };
    let capability = QueryCapability::new(sql::Sql, missing);
    match capability.run(&json!({"sql": "SELECT 1"}), &Cancellation::default()) {
        Err(JobFailure::Failed(reason)) => assert!(reason.contains("not available"), "{reason}"),
        other => panic!("expected a failure, got {other:?}"),
    }
}

fn refusal(capability: &QueryCapability, sql: &str) -> String {
    match capability.run(&json!({ "sql": sql }), &Cancellation::default()) {
        Err(JobFailure::Failed(reason)) => reason,
        other => panic!("expected a refusal, got {other:?}"),
    }
}

#[test]
fn ad_hoc_sql_must_be_one_statement() {
    let (capability, server) = sql_daemon(ALL_DENIED);
    let reason = refusal(&capability, "SELECT 1; CREATE TABLE t (a)");
    assert!(reason.contains("one statement"), "{reason}");
    drop(capability);
    // osquery runs every statement it is given, so it saw none of them.
    assert!(server.join().unwrap().is_empty());
}

#[test]
fn ad_hoc_sql_must_only_read() {
    let (capability, server) = sql_daemon(ALL_DENIED);
    let reason = refusal(&capability, "CREATE TABLE t (a)");
    assert!(reason.contains("must only read"), "{reason}");
    drop(capability);
    // The write was explained, never run.
    assert_eq!(server.join().unwrap(), ["options", "query"]);
}
