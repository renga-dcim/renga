//! Leases jobs and runs them one at a time (RFD 9, "Agent execution").
//!
//! A pass runs on its own thread, so a slow job never delays check-ins or
//! scheduled inventory. Every job is checked against the current policy
//! when it is leased, recorded before it runs, given a fixed timeout, and
//! told to stop when Renga asks to cancel it or the agent shuts down.

use super::{
    record::{JobRecords, Outcome, RecordError},
    Capability, Catalog, JobFailure, JobPolicy, RetryClass,
};
use crate::{
    cancellation::Cancellation,
    payload::{JobReport, LeasedJob, ReportAck, ReportType},
    transport::{HttpClient, TransportError},
};
use chrono::Utc;
use reqwest::StatusCode;
use serde_json::{json, Value};
use std::{
    fmt,
    path::Path,
    sync::{mpsc, Arc, PoisonError, RwLock},
    thread,
    time::{Duration, Instant},
};
use tracing::{info, warn};
use uuid::Uuid;

/// Stops a pass that keeps finding work, so it yields back to the next check-in.
const MAX_JOBS_PER_PASS: usize = 10;
/// Renga's lease lasts 60 seconds and every accepted report extends it.
const HEARTBEAT: Duration = Duration::from_secs(20);
/// How often the worker looks at agent shutdown while a job runs.
const POLL: Duration = Duration::from_millis(250);

/// Identifies the configuration a pass was built from. Reload takes the write
/// lock; capability startup holds a read lock through thread creation, so a
/// successful reload and the start of new work have one unambiguous order.
#[derive(Clone, Default)]
pub struct PolicyGeneration(Arc<RwLock<u64>>);

impl PolicyGeneration {
    pub fn current(&self) -> u64 {
        *self.0.read().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn advance(&self) {
        let mut generation = self.0.write().unwrap_or_else(PoisonError::into_inner);
        *generation += 1;
    }

    fn still_current(&self, expected: u64) -> bool {
        self.current() == expected
    }

    fn if_current<T>(&self, expected: u64, operation: impl FnOnce() -> T) -> Option<T> {
        let generation = self.0.read().unwrap_or_else(PoisonError::into_inner);
        (*generation == expected).then(operation)
    }
}

/// The part of Renga's API the worker uses, so tests can script it.
pub trait JobApi {
    fn lease(&self, capabilities: &[String], limit: u32) -> Result<Vec<LeasedJob>, TransportError>;
    fn report(&self, job_id: Uuid, report: &JobReport<'_>) -> Result<ReportAck, TransportError>;
    fn report_before(
        &self,
        job_id: Uuid,
        report: &JobReport<'_>,
        _deadline: Instant,
    ) -> Result<ReportAck, TransportError> {
        self.report(job_id, report)
    }
}

impl JobApi for HttpClient {
    fn lease(&self, capabilities: &[String], limit: u32) -> Result<Vec<LeasedJob>, TransportError> {
        self.lease_jobs(capabilities, limit)
    }

    fn report(&self, job_id: Uuid, report: &JobReport<'_>) -> Result<ReportAck, TransportError> {
        self.post_job_report(job_id, report)
    }

    fn report_before(
        &self,
        job_id: Uuid,
        report: &JobReport<'_>,
        deadline: Instant,
    ) -> Result<ReportAck, TransportError> {
        self.post_job_report_before(job_id, report, deadline)
    }
}

#[derive(Debug)]
pub enum PassError {
    Record(RecordError),
    Lease(TransportError),
}

impl fmt::Display for PassError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Record(error) => write!(f, "{error}"),
            Self::Lease(error) => write!(f, "cannot lease jobs: {error}"),
        }
    }
}

impl std::error::Error for PassError {}

pub struct Worker<'a, A: JobApi> {
    pub api: &'a A,
    pub catalog: &'a Catalog,
    pub policy: &'a JobPolicy,
    pub state_directory: &'a Path,
    /// Agent shutdown.
    pub stopped: &'a Cancellation,
    pub policy_generation: &'a PolicyGeneration,
    pub expected_generation: u64,
    pub heartbeat: Duration,
}

impl<'a, A: JobApi> Worker<'a, A> {
    pub fn new(
        api: &'a A,
        catalog: &'a Catalog,
        policy: &'a JobPolicy,
        state_directory: &'a Path,
        stopped: &'a Cancellation,
        policy_generation: &'a PolicyGeneration,
        expected_generation: u64,
    ) -> Self {
        Self {
            api,
            catalog,
            policy,
            state_directory,
            stopped,
            policy_generation,
            expected_generation,
            heartbeat: HEARTBEAT,
        }
    }

    /// Leases and runs jobs one at a time until none are waiting. Returns
    /// how many jobs it handled.
    pub fn run_pass(&self) -> Result<usize, PassError> {
        if !self.policy_current() {
            return Ok(0);
        }
        let keys = self.catalog.enabled_keys(self.policy);
        if keys.is_empty() {
            return Ok(0);
        }
        // Without a record the agent could run a redelivered job twice, so it
        // leases nothing until the state directory is usable again.
        let mut records = JobRecords::open(self.state_directory).map_err(PassError::Record)?;
        let mut handled = 0;
        while handled < MAX_JOBS_PER_PASS && !self.stopped.cancelled() && self.policy_current() {
            let jobs = self.api.lease(&keys, 1).map_err(PassError::Lease)?;
            if !self.policy_current() {
                break;
            }
            if jobs.is_empty() {
                break;
            }
            for job in jobs {
                self.handle(job, &mut records);
                handled += 1;
            }
        }
        Ok(handled)
    }

    fn handle(&self, job: LeasedJob, records: &mut JobRecords) {
        if !self.policy_current() {
            return;
        }
        let mut reporter = Reporter::new(self.api, &job);

        let Some(capability) = self.catalog.enabled(&job.capability, self.policy) else {
            // The policy changed after Renga leased against an older advertisement.
            warn!(job_id = %job.id, capability = %job.capability, "refusing job its policy does not enable");
            reporter.send(
                ReportType::Failed,
                &failure("capability is not enabled by the agent's local policy"),
            );
            return;
        };

        if let Some(record) = records.get(job.id) {
            if let Some(outcome) = record.outcome.clone() {
                info!(job_id = %job.id, "job delivered again; re-sending its recorded outcome");
                if reporter.send(outcome.kind, &outcome.payload).is_some() {
                    confirm(records, job.id);
                }
                return;
            }
            if capability.retry_class() == RetryClass::Imperative {
                // It may have acted before the agent stopped; running it again
                // needs a new, freshly authorized job.
                let outcome = Outcome {
                    kind: ReportType::Failed,
                    payload: failure(
                        "the agent stopped while running this job, so it may have partly run",
                    ),
                };
                self.finish(records, &job, &mut reporter, outcome);
                return;
            }
        }

        if let Err(error) = records.start(
            job.id,
            &job.capability,
            capability.retry_class(),
            Utc::now(),
        ) {
            warn!(job_id = %job.id, %error, "cannot record job; refusing to run it");
            reporter.send(
                ReportType::Failed,
                &failure("the agent cannot record jobs in its state directory"),
            );
            return;
        }

        if !self.policy_current() {
            return;
        }
        let Some(ack) = reporter.send(ReportType::Started, &json!({})) else {
            // Without a confirmed lease the job is not run; the record lets a
            // redelivery decide by its retry class.
            return;
        };
        if !self.policy_current() {
            return;
        }
        let cancel_requested = ack.cancel_requested;

        info!(job_id = %job.id, capability = %job.capability, attempt = job.attempt, "running job");
        let outcome = if cancel_requested {
            Some(cancelled())
        } else {
            self.run(&job, capability, &mut reporter)
        };
        match outcome {
            Some(outcome) => self.finish(records, &job, &mut reporter, outcome),
            // The agent is stopping or lost the lease, and the job stopped
            // before it finished. Leaving it started without an outcome lets
            // Renga retry it by its retry class, and a redelivery run it again.
            None => info!(job_id = %job.id, "job stopped unfinished; leaving it to its lease"),
        }
    }

    fn policy_current(&self) -> bool {
        self.policy_generation
            .still_current(self.expected_generation)
    }

    /// Runs the capability on its own thread, posting heartbeats so the lease
    /// stays held. Returns `None` when the job stopped unfinished because the
    /// agent is shutting down or the lease is gone.
    fn run(
        &self,
        job: &LeasedJob,
        capability: Arc<dyn Capability>,
        reporter: &mut Reporter<'_, A>,
    ) -> Option<Outcome> {
        let timeout = capability
            .timeout()
            .min(Duration::from_millis(job.timeout_ms.max(1)));
        let deadline = Instant::now() + timeout;
        // Capabilities observe the deadline themselves, even while this
        // supervisor is blocked renewing the lease.
        let cancellation = Cancellation::with_deadline(deadline);
        let (sender, receiver) = mpsc::channel();
        let runner = self
            .policy_generation
            .if_current(self.expected_generation, || {
                let cancellation = cancellation.clone();
                let parameters = job.parameters.clone();
                thread::spawn(move || {
                    let result = capability.run(&parameters, &cancellation);
                    let _ = sender.send((Instant::now(), result));
                })
            })?;

        let mut next_heartbeat = Instant::now() + self.heartbeat;
        let mut cancel_requested = false;
        let result = loop {
            let now = Instant::now();
            if self.stopped.cancelled() {
                cancellation.cancel();
                let _ = runner.join();
                return None;
            }
            // Backpressure may prevent another report from reaching Renga.
            // Lease loss must still stop execution without waiting for a 409.
            if now >= reporter.lease_deadline {
                reporter.lost = true;
                cancellation.cancel();
            }
            if now >= deadline {
                cancellation.cancel();
                warn!(job_id = %job.id, timeout_seconds = timeout.as_secs(), "job timed out");
                break Err(JobFailure::Failed(format!(
                    "timed out after {} seconds",
                    timeout.as_secs()
                )));
            }
            if now >= next_heartbeat {
                if let Some(ack) = reporter.send(ReportType::Progress, &json!({})) {
                    if ack.cancel_requested && !cancel_requested {
                        info!(job_id = %job.id, "cancellation requested");
                        cancel_requested = true;
                        cancellation.cancel();
                    }
                }
                if reporter.lost {
                    cancellation.cancel();
                }
                // Reporting is blocking. Re-read every condition it could have
                // crossed before deciding whether a buffered result was timely.
                if self.stopped.cancelled() {
                    cancellation.cancel();
                    let _ = runner.join();
                    return None;
                }
                let now = Instant::now();
                match receiver.try_recv() {
                    Ok((completed_at, result)) if completed_at <= deadline => break result,
                    Ok(_) => {
                        cancellation.cancel();
                        warn!(job_id = %job.id, timeout_seconds = timeout.as_secs(), "job timed out");
                        break timeout_failure(timeout);
                    }
                    Err(mpsc::TryRecvError::Disconnected) => {
                        break Err(JobFailure::Failed(
                            "the capability stopped unexpectedly".into(),
                        ))
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
                if now >= deadline {
                    cancellation.cancel();
                    warn!(job_id = %job.id, timeout_seconds = timeout.as_secs(), "job timed out");
                    break timeout_failure(timeout);
                }
                next_heartbeat = now + self.heartbeat;
            }
            let now = Instant::now();
            let wait = POLL
                .min(deadline.saturating_duration_since(now))
                .min(next_heartbeat.saturating_duration_since(now));
            match receiver.recv_timeout(wait) {
                Ok((completed_at, result)) if completed_at <= deadline => break result,
                Ok(_) => {
                    cancellation.cancel();
                    warn!(job_id = %job.id, timeout_seconds = timeout.as_secs(), "job timed out");
                    break timeout_failure(timeout);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    break Err(JobFailure::Failed(
                        "the capability stopped unexpectedly".into(),
                    ))
                }
            }
        };
        // A timed-out capability was told to stop. Waiting for it keeps the
        // worker at a concurrency of one.
        let _ = runner.join();

        Some(match result {
            Ok(result) => Outcome {
                kind: ReportType::Succeeded,
                payload: json!({ "result": result }),
            },
            Err(JobFailure::Cancelled) if cancel_requested => cancelled(),
            Err(JobFailure::Cancelled) => return None,
            Err(JobFailure::Failed(reason)) => Outcome {
                kind: ReportType::Failed,
                payload: failure(&reason),
            },
        })
    }

    /// Records the outcome before reporting it, so a lost report is re-sent
    /// on redelivery instead of the job running again.
    fn finish(
        &self,
        records: &mut JobRecords,
        job: &LeasedJob,
        reporter: &mut Reporter<'_, A>,
        outcome: Outcome,
    ) {
        if let Err(error) = records.finish(job.id, outcome.clone(), Utc::now()) {
            warn!(job_id = %job.id, %error, "cannot record job outcome");
        }
        if reporter.lost {
            return;
        }
        if reporter.send(outcome.kind, &outcome.payload).is_some() {
            confirm(records, job.id);
            info!(job_id = %job.id, outcome = ?outcome.kind, "job finished");
        }
    }
}

/// Numbers one lease's reports and notices when Renga says to stop.
struct Reporter<'a, A: JobApi> {
    api: &'a A,
    job_id: Uuid,
    lease_token: String,
    sequence: u64,
    lease_deadline: Instant,
    /// Renga withdrew authentication/authorization or the lease moved on,
    /// so execution stops and nothing more is sent under this authority.
    lost: bool,
}

impl<'a, A: JobApi> Reporter<'a, A> {
    fn new(api: &'a A, job: &LeasedJob) -> Self {
        Self {
            api,
            job_id: job.id,
            lease_token: job.lease_token.clone(),
            sequence: 0,
            lease_deadline: Instant::now()
                + (job.lease_expires_at - Utc::now())
                    .to_std()
                    .unwrap_or_default(),
            lost: false,
        }
    }

    fn send(&mut self, kind: ReportType, payload: &Value) -> Option<ReportAck> {
        if self.lost || Instant::now() >= self.lease_deadline {
            self.lost = true;
            return None;
        }
        self.sequence += 1;
        let report = JobReport {
            lease_token: &self.lease_token,
            sequence: self.sequence,
            kind,
            payload,
        };
        let sent_at = Instant::now();
        match self
            .api
            .report_before(self.job_id, &report, self.lease_deadline)
        {
            Ok(ack) => {
                // Every accepted report renews Renga's 60-second lease. Use
                // the request start, not response time, as the safe boundary.
                self.lease_deadline = sent_at + Duration::from_secs(60);
                Some(ack)
            }
            Err(error) => {
                if matches!(
                    error.status(),
                    Some(StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN | StatusCode::CONFLICT)
                ) {
                    self.lost = true;
                }
                warn!(job_id = %self.job_id, report = ?kind, %error, "job report failed");
                None
            }
        }
    }
}

fn failure(reason: &str) -> Value {
    json!({ "reason": reason })
}

fn cancelled() -> Outcome {
    Outcome {
        kind: ReportType::Cancelled,
        payload: json!({}),
    }
}

fn timeout_failure(timeout: Duration) -> Result<Value, JobFailure> {
    Err(JobFailure::Failed(format!(
        "timed out after {} seconds",
        timeout.as_secs()
    )))
}

fn confirm(records: &mut JobRecords, job_id: Uuid) {
    if let Err(error) = records.confirm(job_id, Utc::now()) {
        warn!(%job_id, %error, "cannot mark job outcome acknowledged");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        jobs::{RiskClass, Selector},
        transport::FailureKind,
    };
    use std::{
        cell::{Cell, RefCell},
        collections::VecDeque,
        fs,
        path::PathBuf,
        sync::Mutex,
    };

    /// Scripted Renga: hands out queued leases and answers reports in order.
    #[derive(Default)]
    struct FakeApi {
        leases: RefCell<VecDeque<Vec<LeasedJob>>>,
        answers: RefCell<VecDeque<Result<ReportAck, TransportError>>>,
        reports: RefCell<Vec<(Uuid, u64, ReportType, Value)>>,
        report_delays: RefCell<VecDeque<Duration>>,
        lease_calls: Cell<usize>,
        reload_on_lease: RefCell<Option<(usize, PolicyGeneration)>>,
    }

    impl FakeApi {
        fn lease_once(job: LeasedJob) -> Self {
            let api = Self::default();
            api.leases.borrow_mut().push_back(vec![job]);
            api
        }

        fn answer(&self, answer: Result<ReportAck, TransportError>) {
            self.answers.borrow_mut().push_back(answer);
        }

        fn lease_next(&self, job: LeasedJob) {
            self.leases.borrow_mut().push_back(vec![job]);
        }

        fn reload_on_lease(&self, call: usize, generation: PolicyGeneration) {
            *self.reload_on_lease.borrow_mut() = Some((call, generation));
        }

        fn delay_reports(&self, delays: impl IntoIterator<Item = Duration>) {
            self.report_delays.borrow_mut().extend(delays);
        }

        fn kinds(&self) -> Vec<ReportType> {
            self.reports.borrow().iter().map(|r| r.2).collect()
        }

        fn last_payload(&self) -> Value {
            self.reports.borrow().last().unwrap().3.clone()
        }
    }

    impl JobApi for FakeApi {
        fn lease(&self, _: &[String], _: u32) -> Result<Vec<LeasedJob>, TransportError> {
            let call = self.lease_calls.get() + 1;
            self.lease_calls.set(call);
            if self
                .reload_on_lease
                .borrow()
                .as_ref()
                .is_some_and(|(reload_on, _)| *reload_on == call)
            {
                self.reload_on_lease.borrow().as_ref().unwrap().1.advance();
            }
            Ok(self.leases.borrow_mut().pop_front().unwrap_or_default())
        }

        fn report(
            &self,
            job_id: Uuid,
            report: &JobReport<'_>,
        ) -> Result<ReportAck, TransportError> {
            self.reports.borrow_mut().push((
                job_id,
                report.sequence,
                report.kind,
                report.payload.clone(),
            ));
            if let Some(delay) = self.report_delays.borrow_mut().pop_front() {
                thread::sleep(delay);
            }
            self.answers
                .borrow_mut()
                .pop_front()
                .unwrap_or(Ok(ReportAck {
                    cancel_requested: false,
                }))
        }
    }

    type Run = Box<dyn Fn(&Cancellation) -> Result<Value, JobFailure> + Send + Sync>;

    struct Fake {
        retry_class: RetryClass,
        timeout: Duration,
        runs: Mutex<usize>,
        run: Run,
    }

    impl Capability for Fake {
        fn name(&self) -> &'static str {
            "test.job"
        }
        fn version(&self) -> u32 {
            1
        }
        fn risk_class(&self) -> RiskClass {
            RiskClass::Observe
        }
        fn retry_class(&self) -> RetryClass {
            self.retry_class
        }
        fn timeout(&self) -> Duration {
            self.timeout
        }
        fn run(&self, _: &Value, cancellation: &Cancellation) -> Result<Value, JobFailure> {
            *self.runs.lock().unwrap() += 1;
            (self.run)(cancellation)
        }
    }

    fn fake(retry_class: RetryClass, run: Run) -> Arc<Fake> {
        Arc::new(Fake {
            retry_class,
            timeout: Duration::from_secs(5),
            runs: Mutex::new(0),
            run,
        })
    }

    fn succeeds() -> Run {
        Box::new(|_| Ok(json!({"ok": true})))
    }

    /// Runs until cancelled.
    fn waits_for_cancel() -> Run {
        Box::new(|cancellation| {
            while !cancellation.cancelled() {
                thread::sleep(Duration::from_millis(5));
            }
            Err(JobFailure::Cancelled)
        })
    }

    fn leased(id: Uuid) -> LeasedJob {
        LeasedJob {
            id,
            capability: "test.job@1".into(),
            parameters: json!({}),
            attempt: 1,
            lease_token: "token".into(),
            lease_expires_at: Utc::now() + chrono::Duration::seconds(60),
            timeout_ms: 60_000,
            output_limit_bytes: 65_536,
        }
    }

    struct Fixture {
        state: PathBuf,
        catalog: Catalog,
        policy: JobPolicy,
        stopped: Cancellation,
        policy_generation: PolicyGeneration,
    }

    impl Fixture {
        fn new(capability: Arc<Fake>) -> Self {
            let state = std::env::temp_dir().join(format!("renga-worker-{}", Uuid::new_v4()));
            fs::create_dir_all(&state).unwrap();
            Self {
                state,
                catalog: Catalog::new(vec![capability]),
                policy: JobPolicy::default(),
                stopped: Cancellation::default(),
                policy_generation: PolicyGeneration::default(),
            }
        }

        fn pass(&self, api: &FakeApi) -> usize {
            let mut worker = Worker::new(
                api,
                &self.catalog,
                &self.policy,
                &self.state,
                &self.stopped,
                &self.policy_generation,
                self.policy_generation.current(),
            );
            worker.heartbeat = Duration::from_millis(20);
            worker.run_pass().unwrap()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.state);
        }
    }

    fn ok() -> Result<ReportAck, TransportError> {
        Ok(ReportAck {
            cancel_requested: false,
        })
    }

    fn conflict() -> TransportError {
        TransportError::new("conflict".into(), FailureKind::Permanent)
            .with_status(StatusCode::CONFLICT)
    }

    #[test]
    fn runs_a_job_and_reports_numbered_start_and_result() {
        let capability = fake(RetryClass::Idempotent, succeeds());
        let fixture = Fixture::new(capability.clone());
        let id = Uuid::new_v4();
        let api = FakeApi::lease_once(leased(id));

        assert_eq!(fixture.pass(&api), 1);
        assert_eq!(api.kinds(), [ReportType::Started, ReportType::Succeeded]);
        assert_eq!(
            api.reports.borrow().iter().map(|r| r.1).collect::<Vec<_>>(),
            [1, 2]
        );
        assert_eq!(api.last_payload(), json!({"result": {"ok": true}}));
        let records = JobRecords::open(&fixture.state).unwrap();
        assert_eq!(
            records.get(id).unwrap().outcome.as_ref().unwrap().kind,
            ReportType::Succeeded
        );
    }

    #[test]
    fn a_redelivered_job_re_sends_its_recorded_outcome_without_running_again() {
        let capability = fake(RetryClass::Idempotent, succeeds());
        let fixture = Fixture::new(capability.clone());
        let id = Uuid::new_v4();

        // The final report is lost, so Renga leases the job again.
        let api = FakeApi::lease_once(leased(id));
        api.answer(ok());
        api.answer(Err(TransportError::new(
            "down".into(),
            FailureKind::Transient,
        )));
        fixture.pass(&api);

        let mut again = leased(id);
        again.attempt = 2;
        let api = FakeApi::lease_once(again);
        fixture.pass(&api);

        assert_eq!(*capability.runs.lock().unwrap(), 1);
        assert_eq!(api.kinds(), [ReportType::Succeeded]);
        assert_eq!(api.reports.borrow()[0].1, 1, "a new lease numbers from one");
        assert_eq!(api.last_payload(), json!({"result": {"ok": true}}));
    }

    #[test]
    fn a_job_interrupted_mid_run_reruns_unless_it_is_imperative() {
        for (retry_class, runs, kinds) in [
            (
                RetryClass::Idempotent,
                1,
                vec![ReportType::Started, ReportType::Succeeded],
            ),
            (RetryClass::Imperative, 0, vec![ReportType::Failed]),
        ] {
            let capability = fake(retry_class, succeeds());
            let fixture = Fixture::new(capability.clone());
            let id = Uuid::new_v4();
            JobRecords::open(&fixture.state)
                .unwrap()
                .start(id, "test.job@1", retry_class, Utc::now())
                .unwrap();

            let api = FakeApi::lease_once(leased(id));
            fixture.pass(&api);

            assert_eq!(*capability.runs.lock().unwrap(), runs, "{retry_class:?}");
            assert_eq!(api.kinds(), kinds, "{retry_class:?}");
        }
    }

    #[test]
    fn leases_nothing_while_policy_enables_nothing() {
        let mut fixture = Fixture::new(fake(RetryClass::Idempotent, succeeds()));
        fixture.policy = JobPolicy {
            enabled: Some(vec![]),
        };
        let api = FakeApi::lease_once(leased(Uuid::new_v4()));
        assert_eq!(fixture.pass(&api), 0);
        assert_eq!(api.leases.borrow().len(), 1, "no lease was requested");
    }

    #[test]
    fn refuses_a_leased_job_its_policy_does_not_enable() {
        let capability = fake(RetryClass::Idempotent, succeeds());
        let mut fixture = Fixture::new(capability.clone());
        fixture.policy = JobPolicy {
            enabled: Some(vec![Selector::parse("test.job@1").unwrap()]),
        };
        // Leased against an advertisement this policy has since withdrawn.
        let mut job = leased(Uuid::new_v4());
        job.capability = "test.job@2".into();
        let api = FakeApi::lease_once(job);

        fixture.pass(&api);
        assert_eq!(api.kinds(), [ReportType::Failed]);
        assert_eq!(*capability.runs.lock().unwrap(), 0);
    }

    #[test]
    fn reload_while_leasing_prevents_the_returned_job_from_starting() {
        let capability = fake(RetryClass::Idempotent, succeeds());
        let fixture = Fixture::new(capability.clone());
        let api = FakeApi::lease_once(leased(Uuid::new_v4()));
        api.reload_on_lease(1, fixture.policy_generation.clone());

        assert_eq!(fixture.pass(&api), 0);
        assert_eq!(*capability.runs.lock().unwrap(), 0);
        assert!(api.reports.borrow().is_empty());
    }

    #[test]
    fn reload_between_jobs_retires_the_existing_pass() {
        let capability = fake(RetryClass::Idempotent, succeeds());
        let fixture = Fixture::new(capability.clone());
        let api = FakeApi::lease_once(leased(Uuid::new_v4()));
        api.lease_next(leased(Uuid::new_v4()));
        api.reload_on_lease(2, fixture.policy_generation.clone());

        assert_eq!(fixture.pass(&api), 1);
        assert_eq!(*capability.runs.lock().unwrap(), 1);
        assert_eq!(api.kinds(), [ReportType::Started, ReportType::Succeeded]);
    }

    #[test]
    fn stops_and_reports_cancelled_when_renga_asks() {
        let capability = fake(RetryClass::Idempotent, waits_for_cancel());
        let fixture = Fixture::new(capability);
        let api = FakeApi::lease_once(leased(Uuid::new_v4()));
        api.answer(ok());
        api.answer(Ok(ReportAck {
            cancel_requested: true,
        }));

        fixture.pass(&api);
        assert_eq!(
            api.kinds(),
            [
                ReportType::Started,
                ReportType::Progress,
                ReportType::Cancelled
            ]
        );
    }

    #[test]
    fn a_job_that_outlives_its_timeout_is_reported_failed() {
        let capability = fake(RetryClass::Idempotent, waits_for_cancel());
        let fixture = Fixture::new(capability);
        let mut job = leased(Uuid::new_v4());
        job.timeout_ms = 50;
        let api = FakeApi::lease_once(job);

        fixture.pass(&api);
        assert_eq!(*api.kinds().last().unwrap(), ReportType::Failed);
        assert!(api.last_payload()["reason"]
            .as_str()
            .unwrap()
            .starts_with("timed out"));
    }

    #[test]
    fn a_late_result_buffered_during_a_slow_heartbeat_still_times_out() {
        let capability = fake(
            RetryClass::Idempotent,
            Box::new(|_| {
                thread::sleep(Duration::from_millis(70));
                Ok(json!({"late": true}))
            }),
        );
        let fixture = Fixture::new(capability);
        let mut job = leased(Uuid::new_v4());
        job.timeout_ms = 50;
        let api = FakeApi::lease_once(job);
        api.delay_reports([Duration::ZERO, Duration::from_millis(100)]);

        fixture.pass(&api);

        assert_eq!(*api.kinds().last().unwrap(), ReportType::Failed);
        assert!(api.last_payload()["reason"]
            .as_str()
            .unwrap()
            .starts_with("timed out"));
    }

    #[test]
    fn an_on_time_result_buffered_during_a_slow_heartbeat_succeeds() {
        let capability = fake(
            RetryClass::Idempotent,
            Box::new(|_| {
                thread::sleep(Duration::from_millis(30));
                Ok(json!({"on_time": true}))
            }),
        );
        let fixture = Fixture::new(capability);
        let mut job = leased(Uuid::new_v4());
        job.timeout_ms = 70;
        let api = FakeApi::lease_once(job);
        api.delay_reports([Duration::ZERO, Duration::from_millis(100)]);

        fixture.pass(&api);

        assert_eq!(*api.kinds().last().unwrap(), ReportType::Succeeded);
        assert_eq!(api.last_payload(), json!({"result": {"on_time": true}}));
    }

    #[test]
    fn agent_shutdown_leaves_the_job_to_its_lease() {
        let capability = fake(RetryClass::Idempotent, waits_for_cancel());
        let fixture = Fixture::new(capability);
        let id = Uuid::new_v4();
        let api = FakeApi::lease_once(leased(id));
        let stopped = fixture.stopped.clone();
        let stopper = thread::spawn(move || {
            thread::sleep(Duration::from_millis(50));
            stopped.cancel();
        });

        fixture.pass(&api);
        stopper.join().unwrap();
        assert_eq!(api.kinds()[0], ReportType::Started);
        assert!(!api.kinds().iter().any(|kind| kind.terminal()));
        let records = JobRecords::open(&fixture.state).unwrap();
        assert_eq!(records.get(id).unwrap().outcome, None);
    }

    #[test]
    fn a_conflict_stops_the_job_and_leaves_it_to_rerun() {
        let capability = fake(RetryClass::Idempotent, waits_for_cancel());
        let fixture = Fixture::new(capability);
        let id = Uuid::new_v4();
        let api = FakeApi::lease_once(leased(id));
        api.answer(ok());
        api.answer(Err(conflict()));

        fixture.pass(&api);
        assert_eq!(api.kinds(), [ReportType::Started, ReportType::Progress]);
        let records = JobRecords::open(&fixture.state).unwrap();
        assert_eq!(records.get(id).unwrap().outcome, None);
    }

    #[test]
    fn withdrawn_authority_stops_running_work_without_acknowledging_an_outcome() {
        for status in [StatusCode::UNAUTHORIZED, StatusCode::FORBIDDEN] {
            let capability = fake(RetryClass::Imperative, waits_for_cancel());
            let fixture = Fixture::new(capability.clone());
            let id = Uuid::new_v4();
            let api = FakeApi::lease_once(leased(id));
            api.answer(ok());
            api.answer(Err(TransportError::new(
                "authorization withdrawn".into(),
                FailureKind::Permanent,
            )
            .with_status(status)));

            fixture.pass(&api);
            assert_eq!(*capability.runs.lock().unwrap(), 1);
            assert_eq!(api.kinds(), [ReportType::Started, ReportType::Progress]);
            let records = JobRecords::open(&fixture.state).unwrap();
            assert_eq!(records.get(id).unwrap().outcome, None);
        }
    }

    #[test]
    fn an_expired_lease_never_runs_even_without_a_server_conflict() {
        let capability = fake(RetryClass::Idempotent, succeeds());
        let fixture = Fixture::new(capability.clone());
        let mut job = leased(Uuid::new_v4());
        job.lease_expires_at = Utc::now() - chrono::Duration::seconds(1);
        let api = FakeApi::lease_once(job);

        fixture.pass(&api);

        assert_eq!(*capability.runs.lock().unwrap(), 0);
        assert!(api.kinds().is_empty());
    }

    #[test]
    fn a_result_finished_after_the_lease_is_lost_is_kept_for_redelivery() {
        let capability = fake(
            RetryClass::Idempotent,
            Box::new(|_| {
                thread::sleep(Duration::from_millis(60));
                Ok(json!({"ok": true}))
            }),
        );
        let fixture = Fixture::new(capability.clone());
        let id = Uuid::new_v4();
        let api = FakeApi::lease_once(leased(id));
        api.answer(ok());
        api.answer(Err(conflict()));
        fixture.pass(&api);
        assert_eq!(api.kinds(), [ReportType::Started, ReportType::Progress]);

        let api = FakeApi::lease_once(leased(id));
        fixture.pass(&api);
        assert_eq!(api.kinds(), [ReportType::Succeeded]);
        assert_eq!(*capability.runs.lock().unwrap(), 1);
    }
}
