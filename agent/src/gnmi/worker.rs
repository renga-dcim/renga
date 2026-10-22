//! Runs each gNMI module on its own thread and interval (RFD 11, "Scheduling and limits"), like
//! the SNMP modules, so a slow switch never holds up host inventory or lease check-ins.

use super::{
    client::{Session, WireSession},
    config::GnmiCollector,
    poll,
};
use crate::{
    cancellation::Cancellation,
    snmp::config::Target,
    switch_report::{self, Sink},
};
use std::{sync::Arc, thread};
use tracing::warn;

/// The running modules of one configuration.
pub struct Modules {
    collectors: Vec<GnmiCollector>,
    stop: Cancellation,
}

impl Modules {
    /// Starts one thread per module. Each polls immediately, then every `interval`.
    pub fn start(collectors: Vec<GnmiCollector>, sink: Sink) -> Self {
        let stop = Cancellation::default();
        for collector in &collectors {
            let collector = collector.clone();
            let stop = stop.clone();
            let sink = Arc::clone(&sink);
            let name = format!("gnmi-{}", collector.id);
            if let Err(error) = thread::Builder::new().name(name).spawn(move || {
                let open = |target: &Target| {
                    WireSession::open(target, &collector)
                        .map(|session| Box::new(session) as Box<dyn Session>)
                };
                switch_report::run(
                    &collector.id,
                    "gNMI",
                    collector.interval,
                    &stop,
                    &sink,
                    &|| poll(&collector, &stop, open),
                );
            }) {
                warn!(%error, "cannot start a gNMI module");
            }
        }
        Self { collectors, stop }
    }

    pub fn collectors(&self) -> &[GnmiCollector] {
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
