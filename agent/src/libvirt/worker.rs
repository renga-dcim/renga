//! Runs the libvirt module on its own thread and interval (RFD 11, "Scheduling and limits").

use super::{config::LibvirtCollector, poll, reports, virsh, Virsh};
use crate::{cancellation::Cancellation, snmp::worker::Sink};
use std::{
    sync::Arc,
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
use tracing::{info, warn};

const WAIT_SLICE: Duration = Duration::from_millis(250);

/// The running module of one configuration, if any.
pub struct Module {
    collector: Option<LibvirtCollector>,
    stop: Cancellation,
    thread: Option<JoinHandle<()>>,
    /// Threads of configurations a reload replaced. They were told to stop but may still be
    /// killing a `virsh` call, so shutdown waits for them too.
    retired: Vec<JoinHandle<()>>,
    runner: Arc<Runner>,
}

/// Runs one `virsh` subcommand for the module; tests substitute a stand-in.
type Runner =
    dyn Fn(&LibvirtCollector, &Cancellation, &[&str]) -> Result<String, String> + Send + Sync;

impl Module {
    /// Starts the module when configured. It polls immediately, then every `interval`.
    pub fn start(collector: Option<LibvirtCollector>, sink: Sink) -> Self {
        Self::with_runner(collector, sink, Arc::new(virsh))
    }

    fn with_runner(collector: Option<LibvirtCollector>, sink: Sink, runner: Arc<Runner>) -> Self {
        let stop = Cancellation::default();
        let thread = Self::spawn(collector.clone(), &stop, sink, &runner);
        Self {
            collector,
            stop,
            thread,
            retired: Vec::new(),
            runner,
        }
    }

    fn spawn(
        collector: Option<LibvirtCollector>,
        stop: &Cancellation,
        sink: Sink,
        runner: &Arc<Runner>,
    ) -> Option<JoinHandle<()>> {
        let collector = collector?;
        let stop = stop.clone();
        let runner = Arc::clone(runner);
        thread::Builder::new()
            .name(format!("libvirt-{}", collector.id))
            .spawn(move || {
                let run = |args: &[&str]| runner(&collector, &stop, args);
                run_module(&collector, &stop, &sink, &run);
            })
            .map_err(|error| warn!(%error, "cannot start the libvirt module"))
            .ok()
    }

    /// Replaces the running configuration without waiting: the old thread is told to stop and
    /// kept until it finishes, so [`shutdown`](Self::shutdown) can still wait for it.
    pub fn restart(&mut self, collector: Option<LibvirtCollector>, sink: Sink) {
        self.stop();
        self.retired.extend(self.thread.take());
        self.retired.retain(|thread| !thread.is_finished());
        self.stop = Cancellation::default();
        self.thread = Self::spawn(collector.clone(), &self.stop, sink, &self.runner);
        self.collector = collector;
    }

    pub fn collector(&self) -> Option<&LibvirtCollector> {
        self.collector.as_ref()
    }

    /// Asks the module to stop. A `virsh` call in flight is killed.
    pub fn stop(&self) {
        self.stop.cancel();
    }

    /// Stops the module and waits until every `virsh` call it or a configuration it replaced
    /// started, with everything those started, is gone, so nothing outlives the agent.
    pub fn shutdown(mut self) {
        self.stop();
        for thread in self.thread.take().into_iter().chain(self.retired.drain(..)) {
            let _ = thread.join();
        }
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
    use std::sync::{mpsc, Mutex};

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

    /// A module whose `virsh` stand-in starts a grandchild, records both PIDs, and blocks.
    #[cfg(unix)]
    fn blocking_module(directory: &std::path::Path) -> (Module, std::path::PathBuf) {
        let pids = directory.join("pids");
        let script = format!(
            "sleep 60 & echo $! > {0}; echo $$ >> {0}; sleep 60",
            pids.display()
        );
        let collector = LibvirtCollector {
            id: "libvirt".into(),
            uri: "qemu:///system".into(),
            interval: Duration::from_secs(300),
            timeout: Duration::from_secs(60),
        };
        let runner: Arc<Runner> = Arc::new(move |collector, stop, _args| {
            crate::command::run_with_timeout(
                std::process::Command::new("sh").args(["-c", &script]),
                stop,
                collector.timeout,
            )
            .map(|_| String::new())
            .map_err(|error| error.to_string())
        });
        let sink: Sink = Arc::new(|_, _: &[u8]| {});
        (Module::with_runner(Some(collector), sink, runner), pids)
    }

    #[cfg(unix)]
    fn running_pids(pids: &std::path::Path) -> Vec<i32> {
        let started = Instant::now();
        while std::fs::read_to_string(pids).map_or(true, |pids| pids.lines().count() < 2) {
            assert!(
                started.elapsed() < Duration::from_secs(10),
                "virsh stand-in never ran"
            );
            thread::sleep(Duration::from_millis(20));
        }
        std::fs::read_to_string(pids)
            .unwrap()
            .lines()
            .map(|pid| pid.parse().unwrap())
            .collect()
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_kills_the_virsh_call_in_flight_and_its_children() {
        for reload_first in [false, true] {
            let directory =
                std::env::temp_dir().join(format!("renga-libvirt-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&directory).unwrap();
            let (mut module, pids) = blocking_module(&directory);
            let pids = running_pids(&pids);

            // A reload that disables the module leaves the old call to finish on its own.
            if reload_first {
                module.restart(None, Arc::new(|_, _: &[u8]| {}));
            }
            let stopping = Instant::now();
            module.shutdown();
            assert!(stopping.elapsed() < Duration::from_secs(5));
            assert_all_gone(&pids);
            std::fs::remove_dir_all(directory).unwrap();
        }
    }

    /// SIGKILL is delivered asynchronously, and a killed grandchild is reparented and may
    /// linger as a zombie until init reaps it, so each process gets a moment to finish exiting.
    #[cfg(unix)]
    fn assert_all_gone(pids: &[i32]) {
        let running = |pid: i32| {
            std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .ok()
                .filter(|stat| {
                    stat.rsplit_once(") ")
                        .is_some_and(|(_, rest)| !rest.starts_with('Z'))
                })
        };
        let started = Instant::now();
        for pid in pids {
            while let Some(stat) = running(*pid) {
                assert!(
                    started.elapsed() < Duration::from_secs(2),
                    "process {pid} outlived shutdown: {stat}"
                );
                thread::sleep(Duration::from_millis(10));
            }
        }
    }

    #[test]
    fn shutdown_waits_for_a_replaced_configuration_still_running() {
        let collector = LibvirtCollector {
            id: "libvirt".into(),
            uri: "qemu:///system".into(),
            interval: Duration::from_secs(300),
            timeout: Duration::from_secs(60),
        };
        // The stand-in ignores cancellation, as a call still being killed would, until released.
        let (entered, in_call) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let (entered, released) = (Mutex::new(entered), Mutex::new(released));
        let runner: Arc<Runner> = Arc::new(move |_, _, _| {
            entered.lock().unwrap().send(()).unwrap();
            let _ = released.lock().unwrap().recv();
            Err("released".into())
        });
        let mut module = Module::with_runner(Some(collector), Arc::new(|_, _: &[u8]| {}), runner);
        in_call.recv_timeout(Duration::from_secs(5)).unwrap();
        module.restart(None, Arc::new(|_, _: &[u8]| {}));

        let (finished, shut_down) = mpsc::channel();
        let shutdown = thread::spawn(move || {
            module.shutdown();
            finished.send(()).unwrap();
        });
        assert!(
            shut_down.recv_timeout(Duration::from_millis(300)).is_err(),
            "shutdown returned while the replaced configuration was still in a call"
        );
        drop(release);
        shut_down.recv_timeout(Duration::from_secs(5)).unwrap();
        shutdown.join().unwrap();
    }

    #[test]
    fn an_unconfigured_module_does_nothing() {
        let module = Module::start(None, Arc::new(|_, _: &[u8]| panic!("no reports")));
        assert!(module.collector().is_none());
    }
}
