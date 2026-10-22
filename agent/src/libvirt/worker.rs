//! Runs the libvirt module on its own thread and interval (RFD 11, "Scheduling and limits").

use super::{config::LibvirtCollector, poll, reports, virsh, Virsh};
use crate::{cancellation::Cancellation, snmp::worker::Sink};
use std::{
    thread,
    time::{Duration, Instant},
};
use tracing::{info, warn};

const WAIT_SLICE: Duration = Duration::from_millis(250);

/// The running module of one configuration, if any.
pub struct Module {
    collector: Option<LibvirtCollector>,
    stop: Cancellation,
}

impl Module {
    /// Starts the module when configured. It polls immediately, then every `interval`.
    pub fn start(collector: Option<LibvirtCollector>, sink: Sink) -> Self {
        let stop = Cancellation::default();
        if let Some(collector) = collector.clone() {
            let stop = stop.clone();
            if let Err(error) = thread::Builder::new()
                .name(format!("libvirt-{}", collector.id))
                .spawn(move || {
                    let run = |args: &[&str]| virsh(&collector, &stop, args);
                    run_module(&collector, &stop, &sink, &run);
                })
            {
                warn!(%error, "cannot start the libvirt module");
            }
        }
        Self { collector, stop }
    }

    pub fn collector(&self) -> Option<&LibvirtCollector> {
        self.collector.as_ref()
    }

    /// Asks the module to stop. A `virsh` call in flight is killed.
    pub fn stop(&self) {
        self.stop.cancel();
    }
}

impl Drop for Module {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run_module(collector: &LibvirtCollector, stop: &Cancellation, sink: &Sink, virsh: Virsh<'_>) {
    while !stop.cancelled() {
        let started = Instant::now();
        let poll = poll(&collector.id, stop, virsh);
        if stop.cancelled() {
            break;
        }
        let domains = poll.result.as_ref().map_or(0, Vec::len);
        if let Err(error) = &poll.result {
            warn!(collector = %collector.id, %error, "libvirt hypervisor not read");
        }
        let complete = poll.complete;
        let reports = reports(collector, poll);
        for (observation_id, body) in &reports {
            sink(*observation_id, body);
        }
        info!(
            collector = %collector.id,
            domains,
            complete,
            reports = reports.len(),
            "libvirt poll finished"
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
    use std::sync::{mpsc, Arc, Mutex};

    #[test]
    fn polls_on_its_interval_until_stopped() {
        let collector = LibvirtCollector {
            id: "libvirt".into(),
            uri: "qemu:///system".into(),
            interval: Duration::from_millis(50),
            timeout: Duration::from_secs(1),
        };
        let (sent, received) = mpsc::channel();
        let sent = Mutex::new(sent);
        let sink: Sink = Arc::new(move |id, _body: &[u8]| {
            sent.lock().unwrap().send(id).unwrap();
        });
        let stop = Cancellation::default();
        let worker = {
            let stop = stop.clone();
            thread::spawn(move || {
                let virsh = |_: &[&str]| Ok(String::new());
                run_module(&collector, &stop, &sink, &virsh);
            })
        };

        let first = received.recv_timeout(Duration::from_secs(5)).unwrap();
        let second = received.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_ne!(first, second, "each poll is a new observation");
        stop.cancel();
        worker.join().unwrap();
    }

    #[test]
    fn an_unconfigured_module_does_nothing() {
        let module = Module::start(None, Arc::new(|_, _: &[u8]| panic!("no reports")));
        assert!(module.collector().is_none());
    }
}
