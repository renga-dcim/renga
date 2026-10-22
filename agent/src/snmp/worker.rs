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
#[derive(Default)]
pub struct Modules {
    running: Vec<(SnmpCollector, Cancellation)>,
}

impl Modules {
    /// Starts one thread per module. Each polls immediately, then every `interval`.
    pub fn start(collectors: Vec<SnmpCollector>, sink: Sink) -> Self {
        let mut modules = Self::default();
        modules.reload(collectors, &sink);
        modules
    }

    /// Puts `collectors` into effect. A module whose settings are unchanged keeps polling on its
    /// own schedule; a changed or removed one stops, and a changed or new one starts afresh.
    pub fn reload(&mut self, collectors: Vec<SnmpCollector>, sink: &Sink) {
        self.reload_with(collectors, sink, spawn_wire);
    }

    fn reload_with(
        &mut self,
        collectors: Vec<SnmpCollector>,
        sink: &Sink,
        spawn: impl Fn(SnmpCollector, Cancellation, Sink),
    ) {
        let mut previous = std::mem::take(&mut self.running);
        let mut starting = Vec::new();
        for collector in collectors {
            match previous
                .iter()
                .position(|(running, _)| *running == collector)
            {
                Some(index) => self.running.push(previous.swap_remove(index)),
                None => starting.push(collector),
            }
        }
        // Superseded modules stop before their replacements start, so the two overlap by at
        // most the one request the old module has in flight.
        for (_, stop) in previous {
            stop.cancel();
        }
        for collector in starting {
            let stop = Cancellation::default();
            spawn(collector.clone(), stop.clone(), Arc::clone(sink));
            self.running.push((collector, stop));
        }
    }

    /// Asks every module to stop. A poll in flight ends at its next request.
    pub fn stop(&self) {
        for (_, stop) in &self.running {
            stop.cancel();
        }
    }
}

impl Drop for Modules {
    fn drop(&mut self) {
        self.stop();
    }
}

fn spawn_wire(collector: SnmpCollector, stop: Cancellation, sink: Sink) {
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
    fn reload_restarts_only_the_modules_that_changed() {
        let module = |id: &str, interval_ms| SnmpCollector {
            id: id.into(),
            targets: vec![Target::parse("10.0.0.1").unwrap()],
            credentials: Credentials::V2c {
                community_file: "/dev/null".into(),
            },
            interval: Duration::from_millis(interval_ms),
            timeout: Duration::from_secs(1),
            max_concurrent_targets: 1,
        };
        // Each start records whether each module started before it had been stopped by then.
        let started: Mutex<Vec<(String, Cancellation)>> = Mutex::new(Vec::new());
        let stopped_at_start = Mutex::new(Vec::new());
        let spawn = |collector: SnmpCollector, stop: Cancellation, _sink: Sink| {
            let mut started = started.lock().unwrap();
            let stopped: Vec<_> = started.iter().map(|(_, stop)| stop.cancelled()).collect();
            stopped_at_start.lock().unwrap().push(stopped);
            started.push((collector.id, stop));
        };
        let sink: Sink = Arc::new(|_, _: &[u8]| {});
        let mut modules = Modules::default();
        modules.reload_with(
            vec![module("core", 60_000), module("edge", 60_000)],
            &sink,
            spawn,
        );
        modules.reload_with(
            vec![
                module("core", 60_000),
                module("edge", 30_000),
                module("lab", 60_000),
            ],
            &sink,
            spawn,
        );
        modules.reload_with(vec![module("core", 60_000)], &sink, spawn);

        // The changed "edge" starts only once the old "edge" has stopped.
        assert_eq!(
            stopped_at_start.into_inner().unwrap(),
            [
                vec![],
                vec![false],
                vec![false, true],
                vec![false, true, false]
            ]
        );
        let started = started.into_inner().unwrap();
        let ids: Vec<_> = started.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["core", "edge", "edge", "lab"]);
        let stopped: Vec<_> = started.iter().map(|(_, stop)| stop.cancelled()).collect();
        assert_eq!(stopped, [false, true, true, true]);
        let running: Vec<_> = modules.running.iter().map(|(module, _)| module).collect();
        assert_eq!(running, [&module("core", 60_000)]);
    }

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
