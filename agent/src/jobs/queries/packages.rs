//! `query.packages@1`: installed packages and their versions. Sensitive.
//! Matches `Renga.Jobs.Queries.Packages`.
//!
//! dpkg, apk, and pacman keep plain-text databases the agent parses itself.
//! RPM's database needs `rpm`, run with a fixed query format; the `name`
//! filter is applied to its output and never passed to it. A host's package
//! list is usually longer than one result holds, so `truncated` says when the
//! list was cut and `name` narrows it.

use super::{clip, failed, parameters, run_program, Bounded, Query, Sensitivity};
use crate::{cancellation::Cancellation, jobs::JobFailure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs::{self, File},
    io::Read,
    path::Path,
    process::Command,
    time::Duration,
};

const MAX_PACKAGES: usize = 4096;
const MAX_DATABASE_BYTES: u64 = 64 * 1024 * 1024;
const RPM_TIMEOUT: Duration = Duration::from_secs(45);
const RPM_QUERY: &[&str] = &["-qa", "--qf", "%{NAME}\t%{EVR}\t%{ARCH}\n"];

pub struct Packages;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {
    name: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct Package {
    pub name: String,
    pub version: String,
    pub architecture: Option<String>,
    pub manager: &'static str,
}

impl Query for Packages {
    fn name(&self) -> &'static str {
        "query.packages"
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::Sensitive
    }

    fn timeout(&self) -> Duration {
        Duration::from_secs(60)
    }

    fn answer(&self, raw: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
        let params: Parameters = parameters(raw)?;
        if params
            .name
            .as_ref()
            .is_some_and(|n| n.chars().count() > 128)
        {
            return Err(failed(
                "invalid parameters: name must be at most 128 characters",
            ));
        }
        let packages = read_packages(Path::new("/"), cancellation)?;
        Ok(answer(packages, params.name.as_deref()))
    }
}

fn answer(mut packages: Vec<Package>, name: Option<&str>) -> Value {
    let needle = name.map(str::to_lowercase).filter(|n| !n.is_empty());
    packages.retain(|p| {
        needle
            .as_ref()
            .is_none_or(|needle| p.name.to_lowercase().contains(needle))
    });
    packages.sort();
    packages.dedup();
    let mut list = Bounded::new(MAX_PACKAGES);
    for package in packages {
        if !list.push(package) {
            break;
        }
    }
    let (packages, truncated) = list.into_parts();
    serde_json::json!({ "packages": packages, "truncated": truncated })
}

/// Reads every package database present under `root`. A host normally has
/// one; a container image may carry more.
fn read_packages(root: &Path, cancellation: &Cancellation) -> Result<Vec<Package>, JobFailure> {
    let mut packages = Vec::new();
    let mut found = false;
    if let Some(text) = read_bounded(&root.join("var/lib/dpkg/status"))? {
        found = true;
        packages.extend(parse_dpkg(&text));
    }
    if let Some(text) = read_bounded(&root.join("lib/apk/db/installed"))? {
        found = true;
        packages.extend(parse_apk(&text));
    }
    let pacman = root.join("var/lib/pacman/local");
    if pacman.is_dir() {
        found = true;
        for entry in fs::read_dir(&pacman).into_iter().flatten().flatten() {
            if cancellation.cancelled() {
                return Err(JobFailure::Cancelled);
            }
            if let Some(text) = read_bounded(&entry.path().join("desc"))? {
                packages.extend(parse_pacman_desc(&text));
            }
        }
    }
    if root.join("var/lib/rpm").is_dir() || root.join("usr/lib/sysimage/rpm").is_dir() {
        found = true;
        packages.extend(rpm(cancellation)?);
    }
    if cancellation.cancelled() {
        return Err(JobFailure::Cancelled);
    }
    if !found {
        return Err(failed(
            "no supported package database (dpkg, rpm, apk, pacman)",
        ));
    }
    Ok(packages)
}

fn read_bounded(path: &Path) -> Result<Option<String>, JobFailure> {
    let Ok(file) = File::open(path) else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.take(MAX_DATABASE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| failed("could not read the package database"))?;
    if bytes.len() as u64 > MAX_DATABASE_BYTES {
        return Err(failed("the package database is too large to read"));
    }
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

fn package(
    name: &str,
    version: &str,
    architecture: Option<&str>,
    manager: &'static str,
) -> Package {
    Package {
        name: clip(name, 256),
        version: clip(version, 256),
        architecture: architecture.filter(|a| !a.is_empty()).map(|a| clip(a, 32)),
        manager,
    }
}

/// dpkg's status file: RFC 822-style stanzas; only installed packages count.
pub fn parse_dpkg(text: &str) -> Vec<Package> {
    text.split("\n\n")
        .filter_map(|stanza| {
            let field = |key: &str| {
                stanza
                    .lines()
                    .find_map(|line| line.strip_prefix(key)?.strip_prefix(':'))
                    .map(str::trim)
            };
            if !field("Status")?.ends_with(" installed") {
                return None;
            }
            Some(package(
                field("Package")?,
                field("Version")?,
                field("Architecture"),
                "dpkg",
            ))
        })
        .collect()
}

/// apk's installed database: stanzas of one-letter keys.
pub fn parse_apk(text: &str) -> Vec<Package> {
    text.split("\n\n")
        .filter_map(|stanza| {
            let field = |key: &str| stanza.lines().find_map(|line| line.strip_prefix(key));
            Some(package(field("P:")?, field("V:")?, field("A:"), "apk"))
        })
        .collect()
}

/// One pacman `desc` file: `%NAME%` headings, each followed by its value.
pub fn parse_pacman_desc(text: &str) -> Option<Package> {
    let field = |key: &str| {
        let mut lines = text.lines();
        lines.find(|line| *line == key)?;
        lines.next().map(str::trim)
    };
    Some(package(
        field("%NAME%")?,
        field("%VERSION%")?,
        field("%ARCH%"),
        "pacman",
    ))
}

fn rpm(cancellation: &Cancellation) -> Result<Vec<Package>, JobFailure> {
    let output = run_program(
        Command::new("rpm").args(RPM_QUERY),
        cancellation,
        RPM_TIMEOUT,
        "the RPM packages",
    )?;
    if !output.status.success() {
        return Err(failed("could not query the RPM database"));
    }
    Ok(parse_rpm(&String::from_utf8_lossy(&output.stdout)))
}

/// `rpm -qa --qf '%{NAME}\t%{EVR}\t%{ARCH}\n'` output.
pub fn parse_rpm(text: &str) -> Vec<Package> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split('\t');
            let (name, version) = (fields.next()?, fields.next()?);
            let architecture = fields.next().filter(|a| *a != "(none)");
            Some(package(name, version, architecture, "rpm"))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const DPKG: &str = "Package: openssl\nStatus: install ok installed\nPriority: optional\nArchitecture: amd64\nVersion: 3.0.13-0ubuntu3\n\nPackage: removed\nStatus: deinstall ok config-files\nVersion: 1\n\nPackage: libssl3t64\nStatus: install ok installed\nArchitecture: amd64\nVersion: 3.0.13-0ubuntu3\nDescription: Secure Sockets Layer\n toolkit\n";

    #[test]
    fn parses_each_database() {
        assert_eq!(
            parse_dpkg(DPKG),
            [
                package("openssl", "3.0.13-0ubuntu3", Some("amd64"), "dpkg"),
                package("libssl3t64", "3.0.13-0ubuntu3", Some("amd64"), "dpkg"),
            ]
        );
        assert_eq!(
            parse_apk(
                "C:Q1abc=\nP:musl\nV:1.2.5-r0\nA:x86_64\n\nP:busybox\nV:1.36.1-r29\nA:x86_64\n"
            ),
            [
                package("musl", "1.2.5-r0", Some("x86_64"), "apk"),
                package("busybox", "1.36.1-r29", Some("x86_64"), "apk"),
            ]
        );
        assert_eq!(
            parse_pacman_desc("%NAME%\nopenssl\n\n%VERSION%\n3.3.2-1\n\n%ARCH%\nx86_64\n"),
            Some(package("openssl", "3.3.2-1", Some("x86_64"), "pacman"))
        );
        assert_eq!(
            parse_rpm("openssl\t1:3.0.7-27.el9\tx86_64\ngpg-pubkey\tabc-123\t(none)\n"),
            [
                package("openssl", "1:3.0.7-27.el9", Some("x86_64"), "rpm"),
                package("gpg-pubkey", "abc-123", None, "rpm"),
            ]
        );
    }

    #[test]
    fn filters_by_name_after_reading() {
        let value = answer(parse_dpkg(DPKG), Some("SSL"));
        assert_eq!(value["packages"].as_array().unwrap().len(), 2);
        super::super::contract::assert_conforms("query.packages@1", "result", &value);
        let value = answer(parse_dpkg(DPKG), Some("openssl"));
        assert_eq!(
            value,
            json!({"packages": [{"name": "openssl", "version": "3.0.13-0ubuntu3",
                                 "architecture": "amd64", "manager": "dpkg"}],
                   "truncated": false})
        );
    }

    #[test]
    fn reads_a_root_with_a_dpkg_database() {
        let root = std::env::temp_dir().join(format!("renga-packages-{}", std::process::id()));
        fs::create_dir_all(root.join("var/lib/dpkg")).unwrap();
        fs::write(root.join("var/lib/dpkg/status"), DPKG).unwrap();
        let packages = read_packages(&root, &Cancellation::default()).unwrap();
        fs::remove_dir_all(&root).unwrap();
        assert_eq!(packages.len(), 2);

        let empty = std::env::temp_dir().join(format!("renga-no-packages-{}", std::process::id()));
        fs::create_dir_all(&empty).unwrap();
        assert!(read_packages(&empty, &Cancellation::default()).is_err());
        fs::remove_dir_all(&empty).unwrap();
    }

    #[test]
    fn the_name_never_reaches_rpm() {
        assert!(!RPM_QUERY.iter().any(|arg| arg.contains("{name}")));
        assert!(Packages
            .answer(&json!({"name": "a".repeat(129)}), &Cancellation::default())
            .is_err());
        assert!(Packages
            .answer(&json!({"query": "x"}), &Cancellation::default())
            .is_err());
    }
}
