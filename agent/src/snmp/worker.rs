//! Runs each SNMP module on its own thread and interval (RFD 11, "Scheduling and limits"), so a
//! slow switch never holds up host inventory or lease check-ins.

use super::{
    client::{PollError, Session, WireSession},
    config::{SnmpCollector, Target},
    poll, reports,
};
use crate::cancellation::Cancellation;
use std::{
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
use tracing::{info, warn};
use uuid::Uuid;

const WAIT_SLICE: Duration = Duration::from_millis(250);

/// Where finished reports go: the agent's on-disk queue, which delivers them oldest first.
pub type Sink = Arc<dyn Fn(Uuid, &[u8]) + Send + Sync>;

/// The running modules of one configuration.
pub struct Modules {
    collectors: Vec<SnmpCollector>,
    stop: Cancellation,
}

impl Modules {
    /// Starts one thread per module. Each polls immediately, then every `interval`.
    pub fn start(collectors: Vec<SnmpCollector>, sink: Sink) -> Self {
        let stop = Cancellation::default();
        for collector in &collectors {
            let collector = collector.clone();
            let stop = stop.clone();
            let sink = Arc::clone(&sink);
            let name = format!("snmp-{}", collector.id);
            if let Err(error) = thread::Builder::new().name(name).spawn(move || {
                let credentials = collector.credentials.clone();
                let timeout = collector.timeout;
                let open = move |target: &Target| {
                    WireSession::open(target, &credentials, timeout)
                        .map(|session| Box::new(session) as Box<dyn Session>)
                };
                run(&collector, &stop, &sink, &open);
            }) {
                warn!(%error, "cannot start an SNMP module");
            }
        }
        Self { collectors, stop }
    }

    pub fn collectors(&self) -> &[SnmpCollector] {
        &self.collectors
    }

    /// Asks every module to stop. A poll in flight ends at its next target or request timeout.
    pub fn stop(&self) {
        self.stop.cancel();
    }
}

impl Drop for Modules {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Connects to one target; tests answer from recordings instead.
type Opener<'a> = &'a (dyn Fn(&Target) -> Result<Box<dyn Session>, PollError> + Sync);

fn run(collector: &SnmpCollector, stop: &Cancellation, sink: &Sink, open: Opener<'_>) {
    while !stop.cancelled() {
        let started = Instant::now();
        let outcomes = poll(collector, stop, open);
        if stop.cancelled() {
            break;
        }
        let unreachable = outcomes
            .iter()
            .filter(|outcome| outcome.result.is_err())
            .count();
        for outcome in &outcomes {
            if let Err(error) = &outcome.result {
                warn!(collector = %collector.id, target = %outcome.target.address, %error, "SNMP target not read");
            }
        }
        let reports = reports(&collector.id, outcomes);
        for (observation_id, body) in &reports {
            sink(*observation_id, body);
        }
        info!(
            collector = %collector.id,
            targets = collector.targets.len(),
            unreachable,
            reports = reports.len(),
            "SNMP poll finished"
        );
        let next = started + collector.interval;
        while !stop.cancelled() && Instant::now() < next {
            thread::sleep(WAIT_SLICE.min(next.saturating_duration_since(Instant::now())));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snmp::{client::tests::Recorded, config::Credentials, mibs};
    use std::sync::{mpsc, Mutex};

    #[test]
    fn polls_on_its_interval_until_stopped() {
        let collector = SnmpCollector {
            id: "core".into(),
            targets: vec![Target::parse("10.0.0.1").unwrap()],
            credentials: Credentials::V2c {
                community_file: "/dev/null".into(),
            },
            interval: Duration::from_millis(50),
            timeout: Duration::from_secs(1),
            max_concurrent_targets: 1,
        };
        let (sent, received) = mpsc::channel();
        let sent = Mutex::new(sent);
        let sink: Sink = Arc::new(move |id, body: &[u8]| {
            sent.lock().unwrap().send((id, body.len())).unwrap();
        });
        let stop = Cancellation::default();
        let worker = {
            let stop = stop.clone();
            thread::spawn(move || {
                let open = |_: &Target| -> Result<Box<dyn Session>, PollError> {
                    Ok(Box::new(Recorded::new(&mibs::tests::answers())))
                };
                run(&collector, &stop, &sink, &open);
            })
        };

        let (first, _) = received.recv_timeout(Duration::from_secs(5)).unwrap();
        let (second, _) = received.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_ne!(first, second, "each poll is a new observation");
        stop.cancel();
        worker.join().unwrap();
    }
}
