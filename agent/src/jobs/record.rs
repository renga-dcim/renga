//! A bounded, durable record of the jobs this agent started and how they
//! ended (RFD 9, "Agent execution").
//!
//! The agent writes a job's ID before running it and its outcome once it
//! ends, so a job delivered again (after a lost final report or a re-lease)
//! is answered from the record instead of run twice. Renga stays the source
//! of truth; this only guards against duplicates.

use super::RetryClass;
use crate::payload::ReportType;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fmt, fs,
    io::{self, Write},
    path::{Path, PathBuf},
};
use tracing::warn;
use uuid::Uuid;

const RECORD_FILE: &str = "jobs.json";
const TEMPORARY_PREFIX: &str = ".jobs.json.";
/// Bounds the file the agent rewrites on every change. Unresolved records are
/// protected through the retry horizon; acknowledged outcomes make room first.
const MAX_RECORDS: usize = 128;
const RETENTION: chrono::TimeDelta = chrono::TimeDelta::days(8);

#[derive(Debug)]
pub struct RecordError(String);

impl fmt::Display for RecordError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RecordError {}

fn io_error(action: &str, path: &Path, error: io::Error) -> RecordError {
    RecordError(format!("cannot {action} {}: {error}", path.display()))
}

/// The terminal report a job ended with, re-sent verbatim on redelivery.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Outcome {
    #[serde(rename = "type")]
    pub kind: ReportType,
    pub payload: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobRecord {
    pub job_id: Uuid,
    pub capability: String,
    pub retry_class: RetryClass,
    pub started_at: DateTime<Utc>,
    /// `None` while running, or when the agent stopped mid-run.
    pub outcome: Option<Outcome>,
    /// True only after Renga acknowledged the terminal report. Older record
    /// files predate this field and must remain protected until age retention.
    #[serde(default)]
    pub confirmed: bool,
}

pub struct JobRecords {
    directory: PathBuf,
    records: Vec<JobRecord>,
}

impl JobRecords {
    /// Loads the record from the state directory. An unreadable record is
    /// set aside rather than stopping jobs: it only guards against
    /// duplicates, and Renga still refuses reports from an expired lease.
    pub fn open(state_directory: &Path) -> Result<Self, RecordError> {
        let path = state_directory.join(RECORD_FILE);
        let records = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|error| {
                warn!(path = %path.display(), %error, "ignoring unreadable job record");
                Vec::new()
            }),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(io_error("read job record", &path, error)),
        };
        remove_abandoned_temporaries(state_directory);
        Ok(Self {
            directory: state_directory.to_path_buf(),
            records,
        })
    }

    pub fn get(&self, job_id: Uuid) -> Option<&JobRecord> {
        self.records.iter().find(|record| record.job_id == job_id)
    }

    /// Durably notes that the job is about to run. Must succeed before the
    /// capability runs, or a crash could lead to running it twice unseen.
    pub fn start(
        &mut self,
        job_id: Uuid,
        capability: &str,
        retry_class: RetryClass,
        now: DateTime<Utc>,
    ) -> Result<(), RecordError> {
        self.remove_expired(now);
        let replacing = self.records.iter().any(|record| record.job_id == job_id);
        if !replacing && self.records.len() >= MAX_RECORDS {
            match self.records.iter().position(|record| record.confirmed) {
                Some(index) => {
                    self.records.remove(index);
                }
                None => {
                    return Err(RecordError(format!(
                        "job record is full with {MAX_RECORDS} unresolved jobs"
                    )))
                }
            }
        }
        self.records.retain(|record| record.job_id != job_id);
        self.records.push(JobRecord {
            job_id,
            capability: capability.to_owned(),
            retry_class,
            started_at: now,
            outcome: None,
            confirmed: false,
        });
        self.persist(now)
    }

    /// Notes how the job ended, before the outcome is reported.
    pub fn finish(
        &mut self,
        job_id: Uuid,
        outcome: Outcome,
        now: DateTime<Utc>,
    ) -> Result<(), RecordError> {
        match self
            .records
            .iter_mut()
            .find(|record| record.job_id == job_id)
        {
            Some(record) => {
                record.outcome = Some(outcome);
                record.confirmed = false;
            }
            None => return Err(RecordError(format!("job {job_id} was never started"))),
        }
        self.persist(now)
    }

    /// Marks an outcome as accepted by Renga, making this record eligible for
    /// count-based eviction. Age retention remains the final bound for every
    /// record, including unresolved work whose server-side deadline has passed.
    pub fn confirm(&mut self, job_id: Uuid, now: DateTime<Utc>) -> Result<(), RecordError> {
        match self
            .records
            .iter_mut()
            .find(|record| record.job_id == job_id)
        {
            Some(record) if record.outcome.is_some() => record.confirmed = true,
            Some(_) => return Err(RecordError(format!("job {job_id} has no outcome"))),
            None => return Err(RecordError(format!("job {job_id} was never started"))),
        }
        self.persist(now)
    }

    fn persist(&mut self, now: DateTime<Utc>) -> Result<(), RecordError> {
        self.remove_expired(now);
        while self.records.len() > MAX_RECORDS {
            match self.records.iter().position(|record| record.confirmed) {
                Some(index) => {
                    self.records.remove(index);
                }
                None => {
                    return Err(RecordError(format!(
                        "job record is full with more than {MAX_RECORDS} unresolved jobs"
                    )))
                }
            }
        }

        let body = serde_json::to_vec(&self.records)
            .map_err(|error| RecordError(format!("cannot encode job record: {error}")))?;
        let path = self.directory.join(RECORD_FILE);
        let temporary = self
            .directory
            .join(format!("{TEMPORARY_PREFIX}{}", Uuid::new_v4()));
        let result = (|| {
            let mut file = create_private_file(&temporary)?;
            file.write_all(&body)
                .and_then(|()| file.sync_all())
                .map_err(|error| io_error("write job record", &temporary, error))?;
            fs::rename(&temporary, &path)
                .map_err(|error| io_error("persist job record", &path, error))?;
            sync_directory(&self.directory)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    fn remove_expired(&mut self, now: DateTime<Utc>) {
        self.records
            .retain(|record| now.signed_duration_since(record.started_at) < RETENTION);
    }
}

/// Clears writes a crash interrupted before their rename. Only one agent runs
/// jobs from a state directory, so no other writer owns these.
fn remove_abandoned_temporaries(directory: &Path) {
    let Ok(listing) = fs::read_dir(directory) else {
        return;
    };
    for item in listing.flatten() {
        if item
            .file_name()
            .to_str()
            .is_some_and(|name| name.starts_with(TEMPORARY_PREFIX))
        {
            let _ = fs::remove_file(item.path());
        }
    }
}

fn create_private_file(path: &Path) -> Result<fs::File, RecordError> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map_err(|error| io_error("create job record", path, error))
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), RecordError> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| io_error("sync state directory", path, error))
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<(), RecordError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn state() -> PathBuf {
        let path = std::env::temp_dir().join(format!("renga-jobs-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn succeeded() -> Outcome {
        Outcome {
            kind: ReportType::Succeeded,
            payload: json!({"result": {"observation_id": "x"}}),
        }
    }

    #[test]
    fn outcomes_survive_a_restart() {
        let state = state();
        let now = Utc::now();
        let running = Uuid::new_v4();
        let finished = Uuid::new_v4();

        let mut records = JobRecords::open(&state).unwrap();
        records
            .start(running, "inventory.collect@1", RetryClass::Idempotent, now)
            .unwrap();
        records
            .start(finished, "inventory.collect@1", RetryClass::Idempotent, now)
            .unwrap();
        records.finish(finished, succeeded(), now).unwrap();

        let reopened = JobRecords::open(&state).unwrap();
        assert_eq!(reopened.get(running).unwrap().outcome, None);
        assert_eq!(reopened.get(finished).unwrap().outcome, Some(succeeded()));
        assert!(reopened.get(Uuid::new_v4()).is_none());
        assert_eq!(
            fs::read_dir(&state).unwrap().count(),
            1,
            "no temporary files are left behind"
        );
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn acknowledged_outcomes_make_room_without_evicting_unresolved_work() {
        let state = state();
        let now = Utc::now();
        let mut records = JobRecords::open(&state).unwrap();
        let old = Uuid::new_v4();
        records
            .start(old, "a.b@1", RetryClass::Idempotent, now - RETENTION)
            .unwrap();
        let first = Uuid::new_v4();
        records
            .start(first, "a.b@1", RetryClass::Idempotent, now)
            .unwrap();
        records.finish(first, succeeded(), now).unwrap();
        assert!(records.get(old).is_none(), "expired records are dropped");

        for _ in 0..MAX_RECORDS {
            let id = Uuid::new_v4();
            records
                .start(id, "a.b@1", RetryClass::Idempotent, now)
                .unwrap();
            records.finish(id, succeeded(), now).unwrap();
            records.confirm(id, now).unwrap();
        }
        let reopened = JobRecords::open(&state).unwrap();
        assert_eq!(reopened.records.len(), MAX_RECORDS);
        assert_eq!(
            reopened.get(first).unwrap().outcome,
            Some(succeeded()),
            "the unacknowledged outcome remains available for redelivery"
        );
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn unresolved_records_apply_backpressure_at_capacity() {
        let state = state();
        let now = Utc::now();
        let mut records = JobRecords::open(&state).unwrap();
        let first = Uuid::new_v4();

        records
            .start(first, "a.b@1", RetryClass::Idempotent, now)
            .unwrap();
        records.finish(first, succeeded(), now).unwrap();
        for _ in 1..MAX_RECORDS {
            records
                .start(Uuid::new_v4(), "a.b@1", RetryClass::Idempotent, now)
                .unwrap();
        }

        assert!(records
            .start(Uuid::new_v4(), "a.b@1", RetryClass::Idempotent, now)
            .unwrap_err()
            .to_string()
            .contains("unresolved"));
        assert_eq!(JobRecords::open(&state).unwrap().records.len(), MAX_RECORDS);
        assert_eq!(records.get(first).unwrap().outcome, Some(succeeded()));
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn an_unreadable_record_is_set_aside() {
        let state = state();
        fs::write(state.join(RECORD_FILE), b"not json").unwrap();
        fs::write(state.join(format!("{TEMPORARY_PREFIX}abandoned")), b"[]").unwrap();
        let mut records = JobRecords::open(&state).unwrap();
        assert!(records.records.is_empty());
        assert!(!state.join(format!("{TEMPORARY_PREFIX}abandoned")).exists());
        assert!(records
            .finish(Uuid::new_v4(), succeeded(), Utc::now())
            .is_err());
        fs::remove_dir_all(state).unwrap();
    }
}
