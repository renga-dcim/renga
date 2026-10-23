use clap::{Parser, Subcommand};
use renga_agent::{
    cancellation::Cancellation,
    collectors,
    config::Config,
    exporters::Scrapers,
    gnmi::worker::Modules as GnmiModules,
    home::{self, Home},
    installation_key::InstallationKey,
    jobs::{
        inventory_collect::InventoryCollect,
        queries,
        worker::{PolicyGeneration, Worker},
        Capability, Catalog, JobPolicy,
    },
    libvirt::worker::Module as LibvirtModule,
    logging,
    notices::{Listener, Notices},
    osquery::{self, OsqueryConfig},
    payload::{
        CheckIn, CheckInAck, KeyApproval, KeyStatus, Observation, PresentedKey, QueueReport,
    },
    power::{bmc, collector::Sinks, pdu, PowerModule, PowerSources},
    queue::{
        DiskQueue, Drained, QueueError, QueueKind, QueueMonitor,
        FLUSH_INTERVAL as QUEUE_FLUSH_INTERVAL,
    },
    scheduler::{Job, Scheduler},
    snmp::worker::{Modules, Sink},
    transport::{encode_observation, FailureKind, HttpClient},
};
use std::{
    collections::BTreeMap,
    error::Error,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard, PoisonError, TryLockError},
    thread,
    time::{Duration, Instant, SystemTime},
};
use tracing::{error, info, warn};
use tracing_subscriber::{util::SubscriberInitExt, EnvFilter};

/// The most telemetry batches one flush offers, after every queued observation, so a telemetry
/// backlog cannot hold the delivery worker from the next inventory (RFD 10, "Measured history").
#[cfg(not(test))]
const TELEMETRY_PER_FLUSH: usize = 120;
#[cfg(test)]
const TELEMETRY_PER_FLUSH: usize = 2;
/// How long an inventory waits for a queue flush already using the delivery worker.
const INVENTORY_DEFER: Duration = Duration::from_secs(1);
/// How long a flush waits for an inventory already using the delivery worker.
const FLUSH_DEFER: Duration = Duration::from_secs(1);
/// Queue ownership is polled so a cancelled job never waits behind a long flush.
const QUEUE_LOCK_POLL: Duration = Duration::from_millis(25);
/// Backoff between startup home resolutions while the resolver is unreachable.
const HOME_RETRY_INITIAL: Duration = Duration::from_secs(5);
const HOME_RETRY_MAX: Duration = Duration::from_secs(300);
/// Backoff between resolutions after `410 moved` that fail or return the same home, so a
/// resolver that has not caught up is asked again rarely while the queue holds observations.
const RELOCATION_RETRY_INITIAL: Duration = Duration::from_secs(30);
const RELOCATION_RETRY_MAX: Duration = Duration::from_secs(900);
/// The daemon's first relocation backoff; daemon tests follow a move without waiting it out.
#[cfg(not(test))]
const DAEMON_RELOCATION_RETRY: Duration = RELOCATION_RETRY_INITIAL;
#[cfg(test)]
const DAEMON_RELOCATION_RETRY: Duration = Duration::from_millis(200);
/// How long a reload waits for a home resolution already in flight.
const RELOAD_DEFER: Duration = Duration::from_secs(1);

/// A pending relocation: the home said the organization moved, and nothing has named a
/// different home yet. It stays pending until one does, whatever the old home answers next.
struct Relocation {
    not_before: Instant,
    delay: Duration,
}

impl Relocation {
    fn new(now: Instant, first_delay: Duration) -> Self {
        Self {
            not_before: now,
            delay: first_delay,
        }
    }

    fn due(&self, now: Instant) -> bool {
        now >= self.not_before
    }

    /// Defers the next resolution and returns how long it waits.
    fn back_off(&mut self, now: Instant) -> Duration {
        let delay = self.delay;
        self.not_before = now + delay;
        self.delay = (delay * 2).min(RELOCATION_RETRY_MAX);
        delay
    }
}

/// Why a home resolution was started.
enum Purpose {
    /// A reloaded configuration whose address or deployment identifier changed.
    Reload(Box<Config>),
    /// The current home said the organization moved.
    Relocation,
}

/// A home resolution running off the scheduler thread, so a slow resolver never delays
/// check-ins or lease renewals. Only one runs at a time, and reloads wait for it, so the
/// configuration it was started for is still current when it finishes.
struct Resolution {
    purpose: Purpose,
    handle: thread::JoinHandle<Result<Home, home::HomeError>>,
}

impl Resolution {
    fn spawn(purpose: Purpose, config: &Config, stopped: &Cancellation) -> Self {
        let config = match &purpose {
            Purpose::Reload(config) => config.as_ref().clone(),
            Purpose::Relocation => config.clone(),
        };
        let stopped = stopped.clone();
        Self {
            purpose,
            handle: thread::spawn(move || home::fetch(&config, &stopped)),
        }
    }

    fn finish(self) -> (Purpose, Result<Home, Box<dyn Error>>) {
        let result = match self.handle.join() {
            Ok(result) => result.map_err(Into::into),
            Err(_) => Err("home resolution panicked".into()),
        };
        (self.purpose, result)
    }
}

/// The latest health of each queue, for check-ins.
#[derive(Clone, Default)]
struct QueueMonitors {
    observations: QueueMonitor,
    telemetry: QueueMonitor,
}

/// Queue failure degrades durability, not lease renewal or direct delivery. Only delivery
/// work retries opening it, so filesystem recovery cannot hold up periodic check-ins.
/// Observations and telemetry have separate queues, so neither can evict the other's entries.
struct DeliveryQueue {
    state_directory: PathBuf,
    queue: Option<DiskQueue>,
    telemetry: Option<DiskQueue>,
    monitors: QueueMonitors,
}

impl DeliveryQueue {
    fn new(state_directory: PathBuf) -> Self {
        let mut delivery = Self {
            state_directory,
            queue: None,
            telemetry: None,
            monitors: QueueMonitors::default(),
        };
        if let Err(error) = delivery.ready() {
            warn!(%error, "cannot open observation queue; using direct delivery until it recovers");
        }
        if let Err(error) = delivery.telemetry_ready() {
            warn!(%error, "cannot open telemetry queue; dropping readings until it recovers");
        }
        delivery
    }

    fn ready(&mut self) -> Result<&mut DiskQueue, QueueError> {
        Self::open(
            &mut self.queue,
            &self.state_directory,
            QueueKind::Observations,
            &self.monitors.observations,
        )
    }

    fn telemetry_ready(&mut self) -> Result<&mut DiskQueue, QueueError> {
        Self::open(
            &mut self.telemetry,
            &self.state_directory,
            QueueKind::Telemetry,
            &self.monitors.telemetry,
        )
    }

    fn open<'a>(
        queue: &'a mut Option<DiskQueue>,
        state_directory: &Path,
        kind: QueueKind,
        monitor: &QueueMonitor,
    ) -> Result<&'a mut DiskQueue, QueueError> {
        if queue.is_none() {
            *queue = Some(DiskQueue::open(
                state_directory,
                kind,
                kind.default_limits(),
                monitor.clone(),
            )?);
        }
        Ok(queue.as_mut().unwrap())
    }
}

/// Work running on the delivery thread, which owns the observation queue while it runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DeliveryTask {
    Inventory,
    Flush,
}

/// When the flush runs next, given what was using the delivery worker when it came due. An
/// inventory delivers only observations, and only a flush delivers telemetry, so a flush
/// that found an inventory running waits for it rather than skipping a whole interval:
/// inventory keeps going first, and telemetry still gets its turn.
fn next_flush(running: Option<DeliveryTask>) -> Duration {
    match running {
        Some(DeliveryTask::Inventory) => FLUSH_DEFER,
        Some(DeliveryTask::Flush) | None => QUEUE_FLUSH_INTERVAL,
    }
}

struct DeliveryWorker {
    task: DeliveryTask,
    handle: thread::JoinHandle<()>,
}

impl DeliveryWorker {
    fn running(worker: &Option<Self>) -> Option<DeliveryTask> {
        worker
            .as_ref()
            .filter(|worker| !worker.handle.is_finished())
            .map(|worker| worker.task)
    }

    fn spawn(
        previous: &mut Option<Self>,
        task: DeliveryTask,
        work: impl FnOnce() + Send + 'static,
    ) {
        if let Some(worker) = previous.take() {
            let _ = worker.handle.join();
        }
        *previous = Some(Self {
            task,
            handle: thread::spawn(work),
        });
    }
}

#[derive(Parser)]
#[command(name = "renga-agent", version, about = "Renga host inventory agent")]
struct Args {
    #[arg(long, default_value = "/etc/renga/agent.toml")]
    config: PathBuf,
    #[arg(long, default_value = "/var/lib/renga")]
    state_directory: PathBuf,
    #[arg(long)]
    once: bool,
    /// Collect and print an observation without loading config or using the network.
    #[arg(long)]
    dry_run: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    // The service runs this as root before starting. It takes no paths, so a caller
    // cannot point the privileged copy anywhere else.
    /// Copy the root-only SMBIOS tables into a snapshot the agent can read
    SnapshotSmbios,
    /// Print the installation key's fingerprint to compare on the Collectors page
    Fingerprint,
}

fn main() {
    logging::subscriber(
        std::io::stderr,
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
    )
    .init();
    if let Err(failure) = run(Args::parse()) {
        error!(error = %failure, "agent failed");
        std::process::exit(1);
    }
}

fn run(args: Args) -> Result<(), Box<dyn Error>> {
    match args.command {
        Some(Command::SnapshotSmbios) => return snapshot_smbios(),
        // Reads only: run as another user, it must not create a key the
        // service then cannot read.
        Some(Command::Fingerprint) => {
            println!(
                "{}",
                InstallationKey::load(&args.state_directory)?.fingerprint()
            );
            return Ok(());
        }
        None => {}
    }
    if args.dry_run {
        let observation = Observation::new(collectors::collect(&Cancellation::default())?);
        println!("{}", serde_json::to_string_pretty(&observation)?);
        return Ok(());
    }

    // Install shutdown handling before configuration or transport setup so even
    // startup and --once deliveries share the interruptible path.
    let stopped = install_shutdown_handler()?;
    run_configured(args, stopped)
}

#[cfg(target_os = "linux")]
fn snapshot_smbios() -> Result<(), Box<dyn Error>> {
    use renga_agent::smbios::snapshot::Publisher;
    let generation = Publisher::system()?.publish()?;
    info!(generation, "published SMBIOS snapshot");
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn snapshot_smbios() -> Result<(), Box<dyn Error>> {
    Err("SMBIOS snapshots are only supported on Linux".into())
}

fn install_shutdown_handler() -> Result<Cancellation, ctrlc::Error> {
    let stopped = Cancellation::default();
    let signal_flag = stopped.clone();
    ctrlc::set_handler(move || signal_flag.cancel())?;
    Ok(stopped)
}

fn run_configured(args: Args, stopped: Cancellation) -> Result<(), Box<dyn Error>> {
    let mut config = Config::load(&args.config, &args.state_directory)?;
    let installation_key = Arc::new(InstallationKey::load_or_create(&args.state_directory)?);
    info!(fingerprint = %installation_key.fingerprint(), "installation key loaded");
    let presented_key = PresentedKey::ed25519(installation_key.public_key());
    let Some(mut home) = resolve_home(&config, &args.state_directory, &stopped, !args.once)? else {
        return Ok(());
    };
    log_home(&config, &home);
    let mut client = HttpClient::for_home(&config, &home.home, stopped.clone())?
        .with_installation_key(Arc::clone(&installation_key));
    let queue = DeliveryQueue::new(args.state_directory.clone());
    let monitors = queue.monitors.clone();
    let queue = Arc::new(Mutex::new(queue));
    let power_sources = PowerSources::default();
    // Anchor periodic deadlines before startup work so a slow startup check-in cannot postpone
    // the first lease renewal by another full check-in interval.
    let scheduler_epoch = Instant::now();
    if args.once {
        let operations = RuntimeOperations {
            client: &client,
            stopped: &stopped,
            labels: &config.labels,
            // A single run never leases, so it advertises no job capabilities
            // that would leave jobs waiting for an agent that is not coming back.
            capabilities: job_capabilities(&Catalog::default(), &config.jobs),
            queue: &queue,
            monitors: &monitors,
            power_sources: &power_sources,
            presented_key: &presented_key,
            osquery: &config.osquery,
        };
        let result = deliver_startup(&operations);
        discard_home_if_moved(&client, &home, &args.state_directory);
        return aggregated_result(result);
    }
    let checkin = send_checkin(
        &client,
        &monitors,
        &power_sources,
        advertised_capabilities(&config, &client, &queue),
        &presented_key,
        &config.osquery,
    );
    if let Err(failure) = &checkin {
        warn!(error = %failure, "startup delivery failed: check-in");
    }
    let mut job_worker = None;
    let policy_generation = PolicyGeneration::default();
    let notices = Notices::default();
    let mut listener = start_listener(&client, &config, &queue, &notices, &stopped);
    if leases_now(&checkin) {
        spawn_job_pass(
            &mut job_worker,
            &client,
            &stopped,
            &config,
            &queue,
            &args.state_directory,
            &policy_generation,
        );
    }
    if stopped.cancelled() {
        if let Some(listener) = listener {
            listener.stop();
        }
        if let Some(worker) = job_worker {
            let _ = worker.join();
        }
        discard_home_if_moved(&client, &home, &args.state_directory);
        return Ok(());
    }

    let mut scheduler = Scheduler::new(
        scheduler_epoch,
        config.checkin_interval,
        config.inventory_interval,
        config.config_refresh_interval,
        QUEUE_FLUSH_INTERVAL,
    );
    // The startup inventory may first replay a backlog left by an outage, so it runs on the
    // delivery thread like every later one instead of holding up lease check-ins.
    let mut delivery_worker = None;
    spawn_inventory(&mut delivery_worker, &client, &stopped, &config, &queue);
    let mut snmp = Modules::start(config.snmp.clone(), queue_sink(&queue, &stopped));
    let mut gnmi = GnmiModules::start(config.gnmi.clone(), queue_sink(&queue, &stopped));
    let mut libvirt = LibvirtModule::start(config.libvirt.clone(), queue_sink(&queue, &stopped));
    // Host power readings need no configuration, so reloads leave the module running.
    let _power = PowerModule::start(telemetry_sink(&queue, &stopped), power_sources.clone());
    let mut exporters = Scrapers::start(
        config.exporters.clone(),
        telemetry_sink(&queue, &stopped),
        power_sources.clone(),
    );
    let collector_sinks = || Sinks {
        observations: queue_sink(&queue, &stopped),
        telemetry: telemetry_sink(&queue, &stopped),
    };
    let mut pdus = pdu::Pollers::start(
        config.power.clone(),
        collector_sinks(),
        power_sources.clone(),
    );
    let mut bmcs =
        bmc::Pollers::start(config.bmc.clone(), collector_sinks(), power_sources.clone());
    let mut relocation: Option<Relocation> = None;
    let mut resolution: Option<Resolution> = None;
    // Puts a reloaded configuration, its home, and the client for it into effect.
    macro_rules! adopt_reload {
        ($new_config:expr, $new_home:expr, $new_client:expr) => {{
            let (new_config, new_client) = ($new_config, $new_client);
            let jobs_changed = reload_changes_jobs(&config, &client, &new_config, &new_client);
            let old_checkin_interval = config.checkin_interval;
            let old_inventory_interval = config.inventory_interval;
            config = new_config;
            home = $new_home;
            // A periodic refresh usually changes nothing, and advancing the generation
            // abandons a job between its lease and its start until the lease expires. An
            // equivalent client is not adopted either, so passes, the socket, and every later
            // request keep using the one client they were built from.
            if jobs_changed {
                client = new_client;
                policy_generation.advance();
                // The socket carries the old credentials and policy.
                if let Some(previous) = listener.take() {
                    previous.stop();
                }
                listener = start_listener(&client, &config, &queue, &notices, &stopped);
            }
            // Modules keep polling through a reload unless their own settings changed.
            snmp.reload(config.snmp.clone(), &queue_sink(&queue, &stopped));
            if gnmi.collectors() != config.gnmi.as_slice() {
                gnmi.stop();
                gnmi = GnmiModules::start(config.gnmi.clone(), queue_sink(&queue, &stopped));
            }
            if libvirt.collector() != config.libvirt.as_ref() {
                libvirt.restart(config.libvirt.clone(), queue_sink(&queue, &stopped));
            }
            if exporters.exporters() != config.exporters.as_slice() {
                drop(exporters);
                exporters = Scrapers::start(
                    config.exporters.clone(),
                    telemetry_sink(&queue, &stopped),
                    power_sources.clone(),
                );
            }
            if pdus.collectors() != config.power.as_slice() {
                drop(pdus);
                pdus = pdu::Pollers::start(
                    config.power.clone(),
                    collector_sinks(),
                    power_sources.clone(),
                );
            }
            if bmcs.collectors() != config.bmc.as_slice() {
                drop(bmcs);
                bmcs = bmc::Pollers::start(
                    config.bmc.clone(),
                    collector_sinks(),
                    power_sources.clone(),
                );
            }
            scheduler.refresh_intervals(
                Instant::now(),
                old_checkin_interval,
                config.checkin_interval,
                old_inventory_interval,
                config.inventory_interval,
            );
            info!("configuration reloaded");
        }};
    }
    info!("daemon started");

    while !stopped.cancelled() {
        let now = Instant::now();
        for job in scheduler.due_until_cancelled(now, &stopped) {
            match job {
                Job::CheckIn => {
                    let checkin = send_checkin(
                        &client,
                        &monitors,
                        &power_sources,
                        advertised_capabilities(&config, &client, &queue),
                        &presented_key,
                        &config.osquery,
                    );
                    if let Err(failure) = &checkin {
                        warn!(error = %failure, "check-in failed");
                    }
                    if leases_now(&checkin) {
                        spawn_job_pass(
                            &mut job_worker,
                            &client,
                            &stopped,
                            &config,
                            &queue,
                            &args.state_directory,
                            &policy_generation,
                        );
                    }
                    scheduler.reschedule(job, Instant::now(), config.checkin_interval);
                }
                // Inventory can consume its full collection and delivery budgets, and a flush can
                // replay a long backlog. Both run on one delivery thread outside the scheduler so
                // neither can delay lease check-ins, and only one of them touches the queue.
                Job::Inventory => match DeliveryWorker::running(&delivery_worker) {
                    Some(DeliveryTask::Inventory) => {
                        warn!("inventory still running; skipping overlapping collection");
                        scheduler.reschedule(job, Instant::now(), config.inventory_interval);
                    }
                    // A flush is not a collection, so wait for it rather than skip an interval.
                    Some(DeliveryTask::Flush) => {
                        scheduler.reschedule(job, Instant::now(), INVENTORY_DEFER)
                    }
                    None => {
                        spawn_inventory(&mut delivery_worker, &client, &stopped, &config, &queue);
                        scheduler.reschedule(job, Instant::now(), config.inventory_interval);
                    }
                },
                Job::Flush => {
                    let running = DeliveryWorker::running(&delivery_worker);
                    if running.is_none() {
                        let flush_client = client.clone();
                        let flush_stopped = stopped.clone();
                        let flush_queue = Arc::clone(&queue);
                        DeliveryWorker::spawn(
                            &mut delivery_worker,
                            DeliveryTask::Flush,
                            move || {
                                if let Err(failure) =
                                    flush(&flush_client, &flush_stopped, &flush_queue)
                                {
                                    warn!(error = %failure, "queued observation delivery failed");
                                }
                            },
                        );
                    }
                    scheduler.reschedule(job, Instant::now(), next_flush(running));
                }
                Job::Reload => {
                    // The resolution in flight decides the home before the next reload does.
                    if resolution.is_some() {
                        scheduler.reschedule(job, Instant::now(), RELOAD_DEFER);
                        continue;
                    }
                    match Config::load(&args.config, &args.state_directory) {
                        Ok(new_config) => {
                            // While a move is pending the persisted home is gone, but an
                            // unchanged address and identifier still mean the current home.
                            let known = if relocation.is_some() {
                                Ok(home.answers(&new_config).then(|| home.clone()))
                            } else {
                                home::persisted(&new_config, &args.state_directory)
                            };
                            match known {
                                Ok(Some(known)) => match client_for(
                                    &new_config,
                                    &known,
                                    &client,
                                    &installation_key,
                                    &stopped,
                                ) {
                                    Ok(new_client) => adopt_reload!(new_config, known, new_client),
                                    Err(failure) => {
                                        warn!(error = %failure, "configuration reload failed; retaining previous configuration")
                                    }
                                },
                                // A changed address or identifier, or a deleted home: resolve
                                // without holding up check-ins, then adopt it all at once.
                                Ok(None) => {
                                    resolution = Some(Resolution::spawn(
                                        Purpose::Reload(Box::new(new_config)),
                                        &config,
                                        &stopped,
                                    ))
                                }
                                Err(failure) => {
                                    warn!(error = %failure, "configuration reload failed; retaining previous configuration")
                                }
                            }
                        }
                        Err(failure) => {
                            warn!(error = %failure, "configuration reload failed; retaining previous configuration")
                        }
                    }
                    scheduler.reschedule(
                        Job::Reload,
                        Instant::now(),
                        config.config_refresh_interval,
                    );
                }
            }
        }
        // Requests already on their way to the old home fail with `moved` and stay queued
        // or are retried on the next pass, which uses the new client.
        if client.take_moved() && relocation.is_none() {
            discard_moved_home(&home, &args.state_directory);
            relocation = Some(Relocation::new(Instant::now(), DAEMON_RELOCATION_RETRY));
        }
        if resolution
            .as_ref()
            .is_some_and(|resolution| resolution.handle.is_finished())
        {
            let (purpose, result) = resolution.take().unwrap().finish();
            match (purpose, result) {
                (Purpose::Reload(new_config), Ok(new_home)) => {
                    log_home(&new_config, &new_home);
                    // The home is persisted only once its client exists, so a reload that
                    // fails here leaves the previous home in place as well as the configuration.
                    // A home that already said the organization moved is never persisted again.
                    let still_moved = relocation.is_some() && new_home.home == home.home;
                    match client_for(&new_config, &new_home, &client, &installation_key, &stopped)
                        .and_then(|new_client| {
                            if !still_moved {
                                home::persist(&args.state_directory, &new_home)?;
                            }
                            Ok(new_client)
                        }) {
                        Ok(new_client) => {
                            if new_home.home != home.home {
                                relocation = None;
                            }
                            adopt_reload!(*new_config, new_home, new_client);
                        }
                        Err(failure) => {
                            warn!(error = %failure, "configuration reload failed; retaining previous configuration")
                        }
                    }
                }
                (Purpose::Reload(_), Err(failure)) => {
                    warn!(error = %failure, "configuration reload failed; retaining previous configuration")
                }
                (Purpose::Relocation, Ok(new_home)) if new_home.home != home.home => {
                    log_home(&config, &new_home);
                    match client_for(&config, &new_home, &client, &installation_key, &stopped)
                        .and_then(|new_client| {
                            home::persist(&args.state_directory, &new_home)?;
                            Ok(new_client)
                        }) {
                        Ok(new_client) => {
                            home = new_home;
                            client = new_client;
                            relocation = None;
                            // A pass built for the old home holds its client, so it would
                            // start, run, and report jobs there. A different home always means
                            // a client that sends differently, and the generation advances
                            // only here, once that client is in place, so the next pass is
                            // built for the new home. A failed resolution or the same home
                            // again leaves the pass and socket alone.
                            policy_generation.advance();
                            if let Some(previous) = listener.take() {
                                previous.stop();
                            }
                            listener = start_listener(&client, &config, &queue, &notices, &stopped);
                        }
                        Err(failure) => {
                            if let Some(relocation) = relocation.as_mut() {
                                let retry_in = relocation.back_off(Instant::now());
                                warn!(error = %failure, ?retry_in, "cannot use the home named after a move");
                            }
                        }
                    }
                }
                (Purpose::Relocation, Ok(same)) => {
                    log_home(&config, &same);
                    if let Some(relocation) = relocation.as_mut() {
                        let retry_in = relocation.back_off(Instant::now());
                        warn!(home = %same.home, ?retry_in, "home says the organization moved, but resolution returned it again");
                    }
                }
                (Purpose::Relocation, Err(failure)) => {
                    if let Some(relocation) = relocation.as_mut() {
                        let retry_in = relocation.back_off(Instant::now());
                        warn!(error = %failure, ?retry_in, "home resolution after a move failed");
                    }
                }
            }
        }
        if resolution.is_none()
            && relocation
                .as_ref()
                .is_some_and(|relocation| relocation.due(Instant::now()))
        {
            resolution = Some(Resolution::spawn(Purpose::Relocation, &config, &stopped));
        }
        // A notice that arrives while a pass runs stays raised, so the next
        // pass starts as soon as this one ends.
        if !job_pass_running(&job_worker) && notices.take() {
            spawn_job_pass(
                &mut job_worker,
                &client,
                &stopped,
                &config,
                &queue,
                &args.state_directory,
                &policy_generation,
            );
        }
        let wait = scheduler
            .wait(Instant::now())
            .min(Duration::from_millis(250));
        thread::sleep(wait);
    }
    // Nothing after the loop adopts a resolution or starts a pass; it waits for work in flight.
    info!("daemon stopping");
    if let Some(listener) = listener {
        listener.stop();
    }
    if let Some(resolution) = resolution {
        let _ = resolution.finish();
    }
    if let Some(worker) = delivery_worker {
        let _ = worker.handle.join();
    }
    if let Some(worker) = job_worker {
        let _ = worker.join();
    }
    // A request still in flight at shutdown may have heard `moved` after the loop stopped.
    discard_home_if_moved(&client, &home, &args.state_directory);
    // A virsh call in flight must be killed and reaped before the agent exits.
    libvirt.shutdown();
    info!("daemon stopped");
    Ok(())
}

/// The job capabilities compiled into this build, bound to the current
/// client and labels so a reload reaches the next job.
fn job_catalog(
    client: &HttpClient,
    labels: &BTreeMap<String, String>,
    queue: &Arc<Mutex<DeliveryQueue>>,
) -> Catalog {
    let client = client.clone();
    let labels = labels.clone();
    let queue = Arc::clone(queue);
    // The collection runs through the ordinary queue, so a job's observation
    // is delivered and deduplicated exactly like a scheduled one.
    let collect = move |cancellation: &Cancellation| {
        send_inventory(&client, cancellation, &labels, &queue).map_err(|error| error.to_string())
    };
    let mut capabilities: Vec<Arc<dyn Capability>> =
        vec![Arc::new(InventoryCollect::new(Box::new(collect)))];
    capabilities.extend(queries::catalog());
    Catalog::new(capabilities)
}

/// What the agent reports, plus the job capabilities its policy enables. Policy
/// is read on every check-in, so a reload withdraws a capability at once.
fn advertised_capabilities(
    config: &Config,
    client: &HttpClient,
    queue: &Arc<Mutex<DeliveryQueue>>,
) -> Vec<String> {
    job_capabilities(&job_catalog(client, &config.labels, queue), &config.jobs)
}

fn job_capabilities(catalog: &Catalog, policy: &JobPolicy) -> Vec<String> {
    collectors::capabilities()
        .into_iter()
        .map(String::from)
        .chain(catalog.enabled_keys(policy))
        .collect()
}

fn send_checkin(
    client: &HttpClient,
    monitors: &QueueMonitors,
    power_sources: &PowerSources,
    capabilities: Vec<String>,
    presented_key: &PresentedKey,
    osquery: &OsqueryConfig,
) -> Result<CheckInAck, Box<dyn Error>> {
    let now = SystemTime::now();
    let report = |monitor: &QueueMonitor| {
        monitor
            .latest()
            .map(|health| QueueReport::new(&health, now))
    };
    let checkin = CheckIn::new(capabilities, report(&monitors.observations))
        .with_telemetry_queue(report(&monitors.telemetry))
        .with_power_sources(power_sources.reports())
        .with_installation_key(presented_key.clone())
        .with_osquery(osquery::probe(osquery));
    let ack = client.post_checkin(&checkin)?;
    match &ack.installation_key {
        Some(KeyStatus {
            fingerprint,
            status: KeyApproval::Pending,
        }) => info!(
            %fingerprint,
            "check-in posted; installation key awaits approval on the Collectors page"
        ),
        _ => info!("check-in posted"),
    }
    Ok(ack)
}

/// Leases when Renga says jobs are waiting. Without that answer (a failed
/// check-in or an older server) the agent still tries once per check-in
/// interval, so jobs never depend on the hint.
fn leases_now(checkin: &Result<CheckInAck, Box<dyn Error>>) -> bool {
    match checkin {
        Ok(ack) => ack.jobs_waiting != Some(false),
        Err(_) => true,
    }
}

/// Whether adopting a reload has to restart job passes and the notice socket: the new client
/// sends differently, or the labels or `[jobs]` policy a pass and the socket are built from
/// changed. Every field is named, so a new setting has to say which side it is on.
fn reload_changes_jobs(
    old: &Config,
    old_client: &HttpClient,
    new: &Config,
    new_client: &HttpClient,
) -> bool {
    let Config {
        // Bound into the `inventory.collect` capability a pass runs.
        labels,
        // Decides what a pass leases and runs, and whether the socket opens.
        jobs,
        // What a client is built from, which `HttpClient::sends_like` compares. `renga_url`
        // matters only through the home it resolves to.
        renga_url: _,
        allow_insecure_http: _,
        intake_api_key: _,
        installation_id: _,
        request_timeout: _,
        max_retry_attempts: _,
        // Read afresh by the reload, the scheduler, and the collector modules.
        config_path: _,
        inventory_interval: _,
        checkin_interval: _,
        config_refresh_interval: _,
        snmp: _,
        gnmi: _,
        libvirt: _,
        power: _,
        bmc: _,
        exporters: _,
        // Read afresh by each pass's catalog and each check-in's probe; it never changes which
        // keys a pass offers.
        osquery: _,
    } = new;
    !old_client.sends_like(new_client) || old.labels != *labels || old.jobs != *jobs
}

/// Opens the job notice socket when the policy enables a job capability, so
/// an agent that runs no jobs never connects.
fn start_listener(
    client: &HttpClient,
    config: &Config,
    queue: &Arc<Mutex<DeliveryQueue>>,
    notices: &Notices,
    stopped: &Cancellation,
) -> Option<Listener> {
    let catalog = job_catalog(client, &config.labels, queue);
    if catalog.enabled_keys(&config.jobs).is_empty() {
        return None;
    }
    Some(Listener::spawn(
        client.notice_endpoint(),
        notices.clone(),
        stopped.clone(),
    ))
}

fn job_pass_running(worker: &Option<thread::JoinHandle<()>>) -> bool {
    worker.as_ref().is_some_and(|handle| !handle.is_finished())
}

/// Starts a job pass on its own thread unless one is still running, so jobs
/// never delay check-ins or scheduled inventory.
fn spawn_job_pass(
    worker: &mut Option<thread::JoinHandle<()>>,
    client: &HttpClient,
    stopped: &Cancellation,
    config: &Config,
    queue: &Arc<Mutex<DeliveryQueue>>,
    state_directory: &Path,
    policy_generation: &PolicyGeneration,
) {
    if job_pass_running(worker) {
        return;
    }
    if let Some(previous) = worker.take() {
        let _ = previous.join();
    }
    let client = client.clone();
    let stopped = stopped.clone();
    let policy = config.jobs.clone();
    let catalog = job_catalog(&client, &config.labels, queue);
    let state_directory = state_directory.to_path_buf();
    let expected_generation = policy_generation.current();
    let policy_generation = policy_generation.clone();
    *worker = Some(thread::spawn(move || {
        let worker = Worker::new(
            &client,
            &catalog,
            &policy,
            &state_directory,
            &stopped,
            &policy_generation,
            expected_generation,
        );
        match worker.run_pass() {
            Ok(0) => {}
            Ok(handled) => info!(handled, "job pass finished"),
            Err(error) => warn!(%error, "job pass failed"),
        }
    }));
}

fn spawn_inventory(
    worker: &mut Option<DeliveryWorker>,
    client: &HttpClient,
    stopped: &Cancellation,
    config: &Config,
    queue: &Arc<Mutex<DeliveryQueue>>,
) {
    let client = client.clone();
    let stopped = stopped.clone();
    let labels = config.labels.clone();
    let queue = Arc::clone(queue);
    DeliveryWorker::spawn(worker, DeliveryTask::Inventory, move || {
        if let Err(failure) = send_inventory(&client, &stopped, &labels, &queue) {
            warn!(error = %failure, "inventory failed");
        }
    });
}

/// Collects an observation, queues it on disk, and delivers the queue oldest first. A failure
/// leaves the observation queued for the next inventory or flush, even across restarts.
fn send_inventory(
    client: &HttpClient,
    stopped: &Cancellation,
    labels: &BTreeMap<String, String>,
    queue: &Mutex<DeliveryQueue>,
) -> Result<uuid::Uuid, Box<dyn Error>> {
    let observation = Observation::new(collectors::collect(stopped)?).with_labels(labels);
    let observation_id = observation.observation_id;
    let body = encode_observation(&observation)?;
    if stopped.cancelled() {
        return Err("observation delivery cancelled".into());
    }
    deliver_observation(client, stopped, queue, observation_id, &body)
}

/// Queues collector module reports on disk; the inventory and flush passes deliver them with the
/// current credentials, so a module never holds an HTTP client across reloads.
fn queue_sink(queue: &Arc<Mutex<DeliveryQueue>>, stopped: &Cancellation) -> Sink {
    let queue = Arc::clone(queue);
    let stopped = stopped.clone();
    Arc::new(move |observation_id, body| {
        let Some(mut delivery) = lock_until_cancelled(&queue, &stopped) else {
            return;
        };
        match delivery
            .ready()
            .and_then(|queue| queue.enqueue(observation_id, body, SystemTime::now()))
        {
            Ok(_) => info!(%observation_id, "collector report queued"),
            Err(error) => {
                warn!(%error, %observation_id, "cannot queue collector report; dropping it")
            }
        }
    })
}

/// Queues telemetry batches on disk; flushes deliver them after any queued observations.
fn telemetry_sink(queue: &Arc<Mutex<DeliveryQueue>>, stopped: &Cancellation) -> Sink {
    let queue = Arc::clone(queue);
    let stopped = stopped.clone();
    Arc::new(move |replay_id, body| {
        let Some(mut delivery) = lock_until_cancelled(&queue, &stopped) else {
            return;
        };
        if let Err(error) = delivery
            .telemetry_ready()
            .and_then(|queue| queue.enqueue(replay_id, body, SystemTime::now()))
        {
            warn!(%error, %replay_id, "cannot queue telemetry batch; dropping it");
        }
    })
}

fn deliver_observation(
    client: &HttpClient,
    cancellation: &Cancellation,
    queue: &Mutex<DeliveryQueue>,
    observation_id: uuid::Uuid,
    body: &[u8],
) -> Result<uuid::Uuid, Box<dyn Error>> {
    let Some(mut delivery) = lock_until_cancelled(queue, cancellation) else {
        return Err("observation delivery cancelled".into());
    };
    if cancellation.cancelled() {
        return Err("observation delivery cancelled".into());
    }
    if let Err(failure) = delivery
        .ready()
        .and_then(|queue| queue.enqueue(observation_id, body, SystemTime::now()))
    {
        // Delivering without durability still beats losing this observation outright. The
        // server keeps its newest observation current, so overtaking older entries is safe.
        warn!(error = %failure, %observation_id, "cannot queue observation; delivering it directly");
        if cancellation.cancelled() {
            return Err("observation delivery cancelled".into());
        }
        client.post_encoded_observation_with_cancellation(body, cancellation)?;
        info!(%observation_id, "observation posted");
        return Ok(observation_id);
    }

    let queue = delivery.ready()?;
    let mut outcome = None;
    let drained = queue.drain(SystemTime::now(), cancellation, |entry| {
        let result = client.post_encoded_observation_with_cancellation(entry, cancellation);
        if entry == body {
            outcome = Some(result.clone());
        }
        result
    })?;
    report_queue(queue, &drained);
    match outcome {
        Some(Ok(())) => {
            info!(%observation_id, "observation posted");
            Ok(observation_id)
        }
        Some(Err(error)) if error.kind() == FailureKind::PayloadRejected => Err(error.into()),
        Some(Err(error)) => {
            Err(format!("observation {observation_id} queued for retry: {error}").into())
        }
        None => Err(match drained.blocked {
            Some(error) => {
                format!("observation {observation_id} queued behind an undelivered one: {error}")
            }
            None => format!("observation {observation_id} queued; delivery was cancelled"),
        }
        .into()),
    }
}

/// Retries whatever is queued, oldest first: every observation, then a capped share of
/// telemetry. Telemetry waits while observations cannot be delivered, since both go to the same
/// server and inventory comes first.
fn flush(
    client: &HttpClient,
    stopped: &Cancellation,
    queue: &Mutex<DeliveryQueue>,
) -> Result<(), Box<dyn Error>> {
    let mut delivery = lock(queue);
    let observations = delivery.ready()?;
    let drained = observations.drain(SystemTime::now(), stopped, |entry| {
        client.post_encoded_observation(entry)
    })?;
    report_queue(observations, &drained);
    if let Some(error) = drained.blocked {
        return if error.is_cancelled() {
            Ok(())
        } else {
            Err(error.into())
        };
    }

    let telemetry = delivery.telemetry_ready()?;
    let drained =
        telemetry.drain_at_most(SystemTime::now(), TELEMETRY_PER_FLUSH, stopped, |entry| {
            client.post_encoded_telemetry(entry)
        })?;
    report_queue(telemetry, &drained);
    match drained.blocked {
        Some(error) if !error.is_cancelled() => Err(error.into()),
        _ => Ok(()),
    }
}

/// Logs queue health whenever a pass changed or left anything, so an outage's backlog is
/// visible in the agent's logs until it clears.
fn report_queue(queue: &DiskQueue, drained: &Drained) {
    let kind = queue.kind().name();
    let health = match queue.health() {
        Ok(health) => health,
        Err(error) => {
            warn!(queue = kind, %error, "cannot read queue health");
            return;
        }
    };
    if drained.delivered == 0 && drained.rejected == 0 && health.entries == 0 {
        return;
    }
    info!(
        delivered = drained.delivered,
        rejected = drained.rejected,
        queued = health.entries,
        queued_bytes = health.bytes,
        oldest_queued_seconds = health
            .oldest_age(SystemTime::now())
            .map(|age| age.as_secs()),
        dropped_for_space = health.counters.dropped_for_space,
        expired = health.counters.expired,
        rejected_total = health.counters.rejected,
        unreadable = health.counters.unreadable,
        queue = kind,
        "queue"
    );
}

/// The queue holds no invariant a panicking holder could break mid-update: every entry change
/// is a single file operation.
fn lock(queue: &Mutex<DeliveryQueue>) -> MutexGuard<'_, DeliveryQueue> {
    queue.lock().unwrap_or_else(PoisonError::into_inner)
}

fn lock_until_cancelled<'a>(
    queue: &'a Mutex<DeliveryQueue>,
    cancellation: &Cancellation,
) -> Option<MutexGuard<'a, DeliveryQueue>> {
    loop {
        if cancellation.cancelled() {
            return None;
        }
        match queue.try_lock() {
            Ok(guard) => return Some(guard),
            Err(TryLockError::Poisoned(error)) => return Some(error.into_inner()),
            Err(TryLockError::WouldBlock) => thread::sleep(QUEUE_LOCK_POLL),
        }
    }
}

trait Operations {
    fn checkin(&self) -> Result<(), Box<dyn Error>>;
    fn inventory(&self) -> Result<(), Box<dyn Error>>;
}

struct RuntimeOperations<'a> {
    client: &'a HttpClient,
    stopped: &'a Cancellation,
    labels: &'a BTreeMap<String, String>,
    capabilities: Vec<String>,
    queue: &'a Mutex<DeliveryQueue>,
    monitors: &'a QueueMonitors,
    power_sources: &'a PowerSources,
    presented_key: &'a PresentedKey,
    osquery: &'a OsqueryConfig,
}

impl Operations for RuntimeOperations<'_> {
    fn checkin(&self) -> Result<(), Box<dyn Error>> {
        send_checkin(
            self.client,
            self.monitors,
            self.power_sources,
            self.capabilities.clone(),
            self.presented_key,
            self.osquery,
        )
        .map(|_| ())
    }
    fn inventory(&self) -> Result<(), Box<dyn Error>> {
        send_inventory(self.client, self.stopped, self.labels, self.queue).map(|_| ())
    }
}

fn deliver_startup(operations: &dyn Operations) -> Vec<String> {
    [
        ("check-in", operations.checkin()),
        ("inventory", operations.inventory()),
    ]
    .into_iter()
    .filter_map(|(name, result)| result.err().map(|error| format!("{name}: {error}")))
    .collect()
}

fn aggregated_result(failures: Vec<String>) -> Result<(), Box<dyn Error>> {
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; ").into())
    }
}

/// The client for `home`, hearing the current client's moves when the home is unchanged.
fn client_for(
    config: &Config,
    home: &Home,
    current: &HttpClient,
    installation_key: &Arc<InstallationKey>,
    stopped: &Cancellation,
) -> Result<HttpClient, Box<dyn Error>> {
    Ok(HttpClient::for_home(config, &home.home, stopped.clone())?
        .with_installation_key(Arc::clone(installation_key))
        .sharing_moved_signal(current))
}

/// Discards the home when a request through `client` heard that the organization moved.
fn discard_home_if_moved(client: &HttpClient, home: &Home, state_directory: &Path) {
    if client.take_moved() {
        discard_moved_home(home, state_directory);
    }
}

/// Forgets the home that said the organization moved (RFD 23), so neither this run nor a
/// restart sends requests there again without asking `renga_url`.
fn discard_moved_home(home: &Home, state_directory: &Path) {
    warn!(home = %home.home, "home says the organization moved; resolving it again");
    if let Err(error) = home::discard(state_directory) {
        warn!(%error, "cannot discard the moved home");
    }
}

/// Resolves where authenticated requests go before any is sent. A daemon keeps asking while
/// the resolver is unreachable, as it would keep retrying a check-in; a single run reports the
/// failure. `None` means the agent was stopped first.
fn resolve_home(
    config: &Config,
    state_directory: &Path,
    stopped: &Cancellation,
    keep_trying: bool,
) -> Result<Option<Home>, Box<dyn Error>> {
    let mut delay = HOME_RETRY_INITIAL;
    loop {
        match home::resolve(config, state_directory, stopped) {
            Ok(home) => return Ok(Some(home)),
            Err(_) if stopped.cancelled() => return Ok(None),
            Err(failure) if keep_trying && failure.transient() => {
                warn!(error = %failure, retry_in = ?delay, "home resolution failed");
                let until = Instant::now() + delay;
                while let Some(left) = until.checked_duration_since(Instant::now()) {
                    if stopped.cancelled() {
                        return Ok(None);
                    }
                    thread::sleep(left.min(Duration::from_millis(250)));
                }
                delay = (delay * 2).min(HOME_RETRY_MAX);
            }
            Err(failure) => return Err(failure.into()),
        }
    }
}

fn log_home(config: &Config, home: &Home) {
    info!(
        renga_url = %config.renga_url,
        home = %home.home,
        resolved_at = %home.resolved_at.to_rfc3339(),
        "home deployment"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine};
    use renga_agent::{
        jobs::{inventory_collect::InventoryCollect, worker::JobApi},
        libvirt::config::LibvirtCollector,
        payload::{JobReport, LeasedJob, ReportAck, ReportType},
        snmp::config::{Credentials, SnmpCollector},
        transport::TransportError,
    };
    use serde_json::json;
    use std::{
        cell::RefCell,
        io::{self, BufRead, BufReader, Read, Write},
        net::{TcpListener, TcpStream},
        sync::{
            atomic::{AtomicBool, AtomicUsize, Ordering},
            mpsc,
        },
    };
    use tungstenite::{
        handshake::server::{Request, Response},
        http::{header::SEC_WEBSOCKET_PROTOCOL, HeaderValue},
        Message,
    };

    /// Answers observation posts with `statuses` in order and returns each request body.
    fn stub_server(statuses: Vec<u16>) -> (String, thread::JoinHandle<Vec<Vec<u8>>>) {
        stub_responses(statuses.into_iter().map(|status| (status, "")).collect())
    }

    fn stub_responses(
        responses: Vec<(u16, &'static str)>,
    ) -> (String, thread::JoinHandle<Vec<Vec<u8>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            responses
                .into_iter()
                .map(|(status, response)| {
                    let (stream, _) = listener.accept().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut length = 0;
                    loop {
                        let mut line = String::new();
                        reader.read_line(&mut line).unwrap();
                        if line == "\r\n" {
                            break;
                        }
                        if let Some((name, value)) = line.split_once(':') {
                            if name.eq_ignore_ascii_case("content-length") {
                                length = value.trim().parse().unwrap();
                            }
                        }
                    }
                    let mut body = vec![0; length];
                    reader.read_exact(&mut body).unwrap();
                    write!(
                        reader.get_mut(),
                        "HTTP/1.1 {status} Status\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}",
                        response.len()
                    )
                    .unwrap();
                    body
                })
                .collect()
        });
        (origin, server)
    }

    fn read_http_request(stream: TcpStream) -> (String, BufReader<TcpStream>) {
        let (request_line, _body, reader) = read_http_request_body(stream);
        (request_line, reader)
    }

    fn read_http_request_body(stream: TcpStream) -> (String, Vec<u8>, BufReader<TcpStream>) {
        let mut reader = BufReader::new(stream);
        let mut request_line = String::new();
        reader.read_line(&mut request_line).unwrap();
        let mut length = 0;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line == "\r\n" {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                if name.eq_ignore_ascii_case("content-length") {
                    length = value.trim().parse().unwrap();
                }
            }
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        (request_line, body, reader)
    }

    fn answer(reader: &mut BufReader<TcpStream>, status: u16, body: &str) {
        write!(
            reader.get_mut(),
            "HTTP/1.1 {status} Status\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
    }

    /// Runs enough of the agent API and Phoenix protocol to exercise the
    /// daemon's listener-to-worker path with real sockets and HTTP requests.
    #[allow(clippy::result_large_err)]
    fn notice_daemon_server(
        stopped: Cancellation,
    ) -> (
        String,
        mpsc::Receiver<usize>,
        Arc<AtomicBool>,
        thread::JoinHandle<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let home = json!({ "home": origin }).to_string();
        let first_lease_started = Arc::new(AtomicBool::new(false));
        let overlapping_leases = Arc::new(AtomicBool::new(false));
        let active_leases = Arc::new(AtomicUsize::new(0));
        let lease_count = Arc::new(AtomicUsize::new(0));
        let (leases, received) = mpsc::channel();
        let overlap_result = Arc::clone(&overlapping_leases);
        let server = thread::spawn(move || {
            let mut connections = Vec::new();
            while !stopped.cancelled() {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let first_lease_started = Arc::clone(&first_lease_started);
                        let overlapping_leases = Arc::clone(&overlapping_leases);
                        let active_leases = Arc::clone(&active_leases);
                        let lease_count = Arc::clone(&lease_count);
                        let leases = leases.clone();
                        let stopped = stopped.clone();
                        let home = home.clone();
                        connections.push(thread::spawn(move || {
                            let mut peek = [0; 256];
                            let bytes = stream.peek(&mut peek).unwrap();
                            let opening = String::from_utf8_lossy(&peek[..bytes]);
                            if opening.contains("/api/v1/agent/socket/websocket") {
                                let mut socket = tungstenite::accept_hdr(
                                    stream,
                                    |_request: &Request, mut response: Response| {
                                        response.headers_mut().insert(
                                            SEC_WEBSOCKET_PROTOCOL,
                                            HeaderValue::from_static("phoenix"),
                                        );
                                        Ok(response)
                                    },
                                )
                                .unwrap();
                                let join: serde_json::Value =
                                    serde_json::from_str(socket.read().unwrap().to_text().unwrap())
                                        .unwrap();
                                let topic = join[2].clone();
                                socket
                                    .send(Message::text(
                                        json!(["1", "1", topic, "phx_reply", {
                                            "status": "ok",
                                            "response": {"jobs_waiting": false}
                                        }])
                                        .to_string(),
                                    ))
                                    .unwrap();
                                socket
                                    .send(Message::text(
                                        json!([null, null, join[2], "jobs_waiting", {}])
                                            .to_string(),
                                    ))
                                    .unwrap();
                                while !first_lease_started.load(Ordering::SeqCst) {
                                    thread::sleep(Duration::from_millis(5));
                                }
                                socket
                                    .send(Message::text(
                                        json!([null, null, join[2], "jobs_waiting", {}])
                                            .to_string(),
                                    ))
                                    .unwrap();
                                while socket.read().is_ok() {}
                                return;
                            }

                            let (request, mut reader) = read_http_request(stream);
                            if request.contains("/api/v1/agent/home") {
                                answer(&mut reader, 200, &home);
                            } else if request.contains("/api/v1/agent/checkins") {
                                answer(
                                    &mut reader,
                                    202,
                                    r#"{"status":"accepted","jobs_waiting":false}"#,
                                );
                            } else if request.contains("/api/v1/observations") {
                                answer(&mut reader, 202, "{}");
                            } else if request.contains("/api/v1/agent/jobs/lease") {
                                let active = active_leases.fetch_add(1, Ordering::SeqCst) + 1;
                                if active > 1 {
                                    overlapping_leases.store(true, Ordering::SeqCst);
                                }
                                let lease = lease_count.fetch_add(1, Ordering::SeqCst) + 1;
                                leases.send(lease).unwrap();
                                if lease == 1 {
                                    first_lease_started.store(true, Ordering::SeqCst);
                                    thread::sleep(Duration::from_millis(300));
                                }
                                answer(&mut reader, 200, r#"{"jobs":[]}"#);
                                active_leases.fetch_sub(1, Ordering::SeqCst);
                                if lease == 2 {
                                    stopped.cancel();
                                }
                            } else {
                                answer(&mut reader, 404, "{}");
                            }
                        }));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("notice daemon server failed: {error}"),
                }
            }
            for connection in connections {
                connection.join().unwrap();
            }
        });
        (origin, received, overlap_result, server)
    }

    fn refused_notice_server(
        stopped: Cancellation,
    ) -> (String, mpsc::Receiver<()>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let home = json!({ "home": origin }).to_string();
        let checkins = Arc::new(AtomicUsize::new(0));
        let (leased, received) = mpsc::channel();
        let server = thread::spawn(move || {
            let mut connections = Vec::new();
            while !stopped.cancelled() {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let checkins = Arc::clone(&checkins);
                        let leased = leased.clone();
                        let stopped = stopped.clone();
                        let home = home.clone();
                        connections.push(thread::spawn(move || {
                            let mut peek = [0; 256];
                            let bytes = stream.peek(&mut peek).unwrap();
                            let opening = String::from_utf8_lossy(&peek[..bytes]);
                            if opening.contains("/api/v1/agent/socket/websocket") {
                                let mut stream = stream;
                                write!(
                                    stream,
                                    "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                                )
                                .unwrap();
                                return;
                            }

                            let (request, mut reader) = read_http_request(stream);
                            if request.contains("/api/v1/agent/home") {
                                answer(&mut reader, 200, &home);
                            } else if request.contains("/api/v1/agent/checkins") {
                                let checkin = checkins.fetch_add(1, Ordering::SeqCst);
                                let body = if checkin == 0 {
                                    r#"{"status":"accepted","jobs_waiting":false}"#
                                } else {
                                    r#"{"status":"accepted"}"#
                                };
                                answer(&mut reader, 202, body);
                            } else if request.contains("/api/v1/observations") {
                                answer(&mut reader, 202, "{}");
                            } else if request.contains("/api/v1/agent/jobs/lease") {
                                answer(&mut reader, 200, r#"{"jobs":[]}"#);
                                leased.send(()).unwrap();
                                stopped.cancel();
                            } else {
                                answer(&mut reader, 404, "{}");
                            }
                        }));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("refused notice server failed: {error}"),
                }
            }
            for connection in connections {
                connection.join().unwrap();
            }
        });
        (origin, received, server)
    }

    fn reload_notice_server(
        stopped: Cancellation,
    ) -> (
        String,
        mpsc::Receiver<String>,
        mpsc::Receiver<usize>,
        Arc<AtomicUsize>,
        thread::JoinHandle<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let home = json!({ "home": origin }).to_string();
        let checkins = Arc::new(AtomicUsize::new(0));
        let checkin_result = Arc::clone(&checkins);
        let sockets = Arc::new(AtomicUsize::new(0));
        let (protocols, received_protocols) = mpsc::channel();
        let (closed, received_closed) = mpsc::channel();
        let server = thread::spawn(move || {
            let mut connections = Vec::new();
            while !stopped.cancelled() {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let checkins = Arc::clone(&checkins);
                        let sockets = Arc::clone(&sockets);
                        let protocols = protocols.clone();
                        let closed = closed.clone();
                        let home = home.clone();
                        connections.push(thread::spawn(move || {
                            let mut peek = [0; 256];
                            let bytes = stream.peek(&mut peek).unwrap();
                            let opening = String::from_utf8_lossy(&peek[..bytes]);
                            if opening.contains("/api/v1/agent/socket/websocket") {
                                let socket_number = sockets.fetch_add(1, Ordering::SeqCst) + 1;
                                let mut reader = BufReader::new(stream);
                                let mut protocol = String::new();
                                loop {
                                    let mut line = String::new();
                                    reader.read_line(&mut line).unwrap();
                                    if line == "\r\n" {
                                        break;
                                    }
                                    if let Some((name, value)) = line.split_once(':') {
                                        if name.eq_ignore_ascii_case("sec-websocket-protocol") {
                                            protocol = value.trim().to_string();
                                        }
                                    }
                                }
                                protocols.send(protocol).unwrap();
                                let response =
                                    b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n";
                                for byte in response.iter().cycle() {
                                    if reader.get_mut().write_all(&[*byte]).is_err() {
                                        break;
                                    }
                                    let _ = reader.get_mut().flush();
                                    thread::sleep(Duration::from_millis(25));
                                }
                                closed.send(socket_number).unwrap();
                                return;
                            }

                            let (request, mut reader) = read_http_request(stream);
                            if request.contains("/api/v1/agent/home") {
                                answer(&mut reader, 200, &home);
                            } else if request.contains("/api/v1/agent/checkins") {
                                checkins.fetch_add(1, Ordering::SeqCst);
                                answer(
                                    &mut reader,
                                    202,
                                    r#"{"status":"accepted","jobs_waiting":false}"#,
                                );
                            } else if request.contains("/api/v1/observations") {
                                answer(&mut reader, 202, "{}");
                            } else {
                                answer(&mut reader, 404, "{}");
                            }
                        }));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("reload notice server failed: {error}"),
                }
            }
            for connection in connections {
                connection.join().unwrap();
            }
        });
        (
            origin,
            received_protocols,
            received_closed,
            checkin_result,
            server,
        )
    }

    /// Answers each HTTP request with `route(request line and headers)` until stopped.
    fn routed_server(
        stopped: Cancellation,
        route: impl Fn(&str) -> (u16, String) + Send + Sync + 'static,
    ) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let route = Arc::new(route);
        let server = thread::spawn(move || {
            let mut connections = Vec::new();
            while !stopped.cancelled() {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let route = Arc::clone(&route);
                        connections.push(thread::spawn(move || {
                            let (request, mut reader) = read_http_request(stream);
                            let (status, body) = route(&request);
                            answer(&mut reader, status, &body);
                        }));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("routed server failed: {error}"),
                }
            }
            for connection in connections {
                let _ = connection.join();
            }
        });
        (origin, server)
    }

    #[test]
    fn an_unchanged_home_after_a_move_is_asked_again_less_often() {
        let start = Instant::now();
        let mut relocation = Relocation::new(start, RELOCATION_RETRY_INITIAL);
        assert!(relocation.due(start));

        let waits: Vec<_> = (0..7).map(|_| relocation.back_off(start)).collect();

        assert_eq!(
            waits,
            [30, 60, 120, 240, 480, 900, 900].map(Duration::from_secs)
        );
        assert!(!relocation.due(start + Duration::from_secs(899)));
        assert!(relocation.due(start + Duration::from_secs(900)));
    }

    #[test]
    fn follows_a_moved_organization_to_the_home_the_resolver_names_next() {
        let state = std::env::temp_dir().join(format!("renga-moved-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (checked_in, new_home_checkins) = mpsc::channel();
        let new_home_stop = stopped.clone();
        let (new_origin, new_server) = routed_server(stopped.clone(), move |request| {
            if request.contains("/api/v1/agent/checkins") {
                let _ = checked_in.send(());
                new_home_stop.cancel();
                (202, r#"{"status":"accepted","jobs_waiting":false}"#.into())
            } else if request.contains("/api/v1/observations") {
                (202, "{}".into())
            } else {
                (404, "{}".into())
            }
        });
        let expected_home = format!("{new_origin}/");
        let old_requests = Arc::new(Mutex::new(Vec::new()));
        let old_log = Arc::clone(&old_requests);
        let (old_origin, old_server) = routed_server(stopped.clone(), move |request| {
            old_log
                .lock()
                .unwrap()
                .push(request.lines().next().unwrap().to_owned());
            if request.contains("/api/v1/agent/socket") {
                (404, "{}".into())
            } else {
                (410, r#"{"error":"moved"}"#.into())
            }
        });
        let resolutions = Arc::new(AtomicUsize::new(0));
        let resolved = Arc::clone(&resolutions);
        let (resolver, resolver_server) = routed_server(stopped.clone(), move |request| {
            assert!(request.contains("GET /api/v1/agent/home?deployment=eu-1 "));
            assert!(!request.to_ascii_lowercase().contains("authorization"));
            let home = if resolved.fetch_add(1, Ordering::SeqCst) == 0 {
                &old_origin
            } else {
                &new_origin
            };
            (200, json!({ "home": home }).to_string())
        });
        let config = state.join("agent.toml");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(
            &config,
            format!(
                "renga_url = {resolver:?}\nallow_insecure_http = true\nintake_api_key = \"renga_intake_eu-1_{}\"\ncheckin_interval_seconds = 1\nrequest_timeout_seconds = 2\nmax_retry_attempts = 3\n",
                "a".repeat(43)
            ),
        )
        .unwrap();
        let daemon_stop = stopped.clone();
        let daemon_state = state.clone();
        let daemon = thread::spawn(move || {
            run_configured(
                Args {
                    config,
                    state_directory: daemon_state,
                    once: false,
                    dry_run: false,
                    command: None,
                },
                daemon_stop,
            )
            .map_err(|error| error.to_string())
        });

        new_home_checkins
            .recv_timeout(Duration::from_secs(10))
            .unwrap();
        stopped.cancel();
        daemon.join().unwrap().unwrap();
        for server in [new_server, old_server, resolver_server] {
            server.join().unwrap();
        }

        assert_eq!(resolutions.load(Ordering::SeqCst), 2);
        // `moved` is not retried against the home that said it.
        let old_checkins = old_requests
            .lock()
            .unwrap()
            .iter()
            .filter(|line| line.contains("/api/v1/agent/checkins"))
            .count();
        assert_eq!(old_checkins, 1);
        let persisted: serde_json::Value =
            serde_json::from_slice(&std::fs::read(state.join("home.json")).unwrap()).unwrap();
        assert_eq!(persisted["deployment"], "eu-1");
        assert_eq!(persisted["home"], expected_home);
        std::fs::remove_dir_all(state).unwrap();
    }

    /// Writes an agent configuration resolving from `resolver` into `state`.
    fn write_agent_config(state: &Path, resolver: &str, intake_api_key: &str) -> PathBuf {
        let config = state.join("agent.toml");
        std::fs::create_dir_all(state).unwrap();
        std::fs::write(
            &config,
            format!(
                "renga_url = {resolver:?}\nallow_insecure_http = true\nintake_api_key = {intake_api_key:?}\ncheckin_interval_seconds = 1\nconfig_refresh_interval_seconds = 1\nrequest_timeout_seconds = 2\nmax_retry_attempts = 1\n"
            ),
        )
        .unwrap();
        config
    }

    fn spawn_daemon(
        config: PathBuf,
        state: &Path,
        once: bool,
        stopped: Cancellation,
    ) -> thread::JoinHandle<Result<(), String>> {
        let state = state.to_path_buf();
        thread::spawn(move || {
            run_configured(
                Args {
                    config,
                    state_directory: state,
                    once,
                    dry_run: false,
                    command: None,
                },
                stopped,
            )
            .map_err(|error| error.to_string())
        })
    }

    /// A silent SNMP target on a local UDP port, and how many requests it has received.
    fn silent_snmp_target(stopped: Cancellation) -> (String, Arc<AtomicUsize>) {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        socket
            .set_read_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        let target = socket.local_addr().unwrap().to_string();
        let requests = Arc::new(AtomicUsize::new(0));
        let received = Arc::clone(&requests);
        thread::spawn(move || {
            let mut buffer = [0; 1500];
            while !stopped.cancelled() {
                if socket.recv_from(&mut buffer).is_ok() {
                    received.fetch_add(1, Ordering::SeqCst);
                }
            }
        });
        (target, requests)
    }

    /// Writes a configuration resolving from `resolver` with one SNMP module reading `target`.
    fn write_snmp_config(state: &Path, resolver: &str, target: &str) -> PathBuf {
        let config = write_agent_config(state, resolver, "renga_intake_test");
        let community = state.join("community");
        std::fs::write(&community, "renga\n").unwrap();
        let mut toml = std::fs::read_to_string(&config).unwrap();
        toml.push_str(&format!(
            "[[collectors.snmp]]\nid = \"core\"\ntargets = [{target:?}]\nversion = \"2c\"\nallow_v2c = true\ncommunity_file = {community:?}\ninterval_seconds = 3600\ntimeout_seconds = 1\n"
        ));
        std::fs::write(&config, toml).unwrap();
        config
    }

    fn wait_until(what: &str, deadline: Instant, done: impl Fn() -> bool) {
        while !done() {
            assert!(Instant::now() < deadline, "{what} never happened");
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// What a reload test's job server and the daemon's log saw, in the order they saw it.
    #[derive(Debug, Clone, PartialEq)]
    enum Seen {
        SocketOpened,
        SocketClosed,
        Lease,
        /// A report on the leased job, by type.
        Report(String),
        Reloaded,
    }

    /// Everything seen so far, so a test waits on events instead of on the clock.
    struct Timeline {
        receiver: mpsc::Receiver<Seen>,
        seen: Vec<Seen>,
    }

    impl Timeline {
        /// Waits until `done` holds for everything seen so far.
        fn until(&mut self, what: &str, done: impl Fn(&[Seen]) -> bool) {
            let deadline = Instant::now() + Duration::from_secs(30);
            while !done(&self.seen) {
                let left = deadline.saturating_duration_since(Instant::now());
                match self.receiver.recv_timeout(left) {
                    Ok(seen) => self.seen.push(seen),
                    Err(_) => panic!("{what} never happened; saw {:?}", self.seen),
                }
            }
        }

        fn count(&self, seen: &Seen) -> usize {
            self.seen.iter().filter(|each| *each == seen).count()
        }
    }

    /// Forwards the daemon's "configuration reloaded" lines to a timeline.
    #[derive(Clone)]
    struct ReloadLog(mpsc::Sender<Seen>);

    impl Write for ReloadLog {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            if String::from_utf8_lossy(buf).contains("configuration reloaded") {
                let _ = self.0.send(Seen::Reloaded);
            }
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// Runs the daemon with its main loop's log feeding `seen`, so a test knows a reload
    /// has been put into effect.
    fn spawn_daemon_seeing_reloads(
        config: PathBuf,
        state: &Path,
        stopped: Cancellation,
        seen: mpsc::Sender<Seen>,
    ) -> thread::JoinHandle<Result<(), String>> {
        let state = state.to_path_buf();
        thread::spawn(move || {
            let log = tracing_subscriber::fmt()
                .with_ansi(false)
                .with_writer(move || ReloadLog(seen.clone()))
                .finish();
            tracing::subscriber::with_default(log, || {
                run_configured(
                    Args {
                        config,
                        state_directory: state,
                        once: false,
                        dry_run: false,
                        command: None,
                    },
                    stopped,
                )
                .map_err(|error| error.to_string())
            })
        })
    }

    /// Leases one `inventory.collect` job and holds its `started` report until the test
    /// sends on the returned channel, so a reload can land while the report is in flight.
    #[allow(clippy::result_large_err)]
    fn held_start_job_server(
        stopped: Cancellation,
        seen: mpsc::Sender<Seen>,
    ) -> (String, mpsc::SyncSender<()>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let home = json!({ "home": origin }).to_string();
        let job_id = uuid::Uuid::new_v4();
        let leased = Arc::new(AtomicBool::new(false));
        let (release, released) = mpsc::sync_channel(1);
        let released = Arc::new(Mutex::new(Some(released)));
        let server = thread::spawn(move || {
            let mut connections = Vec::new();
            while !stopped.cancelled() {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let leased = Arc::clone(&leased);
                        let released = Arc::clone(&released);
                        let seen = seen.clone();
                        let home = home.clone();
                        connections.push(thread::spawn(move || {
                            let mut peek = [0; 256];
                            let bytes = stream.peek(&mut peek).unwrap();
                            let opening = String::from_utf8_lossy(&peek[..bytes]);
                            if opening.contains("/api/v1/agent/socket/websocket") {
                                let _ = seen.send(Seen::SocketOpened);
                                let mut socket = tungstenite::accept_hdr(
                                    stream,
                                    |_request: &Request, mut response: Response| {
                                        response.headers_mut().insert(
                                            SEC_WEBSOCKET_PROTOCOL,
                                            HeaderValue::from_static("phoenix"),
                                        );
                                        Ok(response)
                                    },
                                )
                                .unwrap();
                                let join: serde_json::Value =
                                    serde_json::from_str(socket.read().unwrap().to_text().unwrap())
                                        .unwrap();
                                socket
                                    .send(Message::text(
                                        json!(["1", "1", join[2], "phx_reply", {
                                            "status": "ok",
                                            "response": {"jobs_waiting": false}
                                        }])
                                        .to_string(),
                                    ))
                                    .unwrap();
                                while socket.read().is_ok() {}
                                let _ = seen.send(Seen::SocketClosed);
                                return;
                            }

                            let (request, body, mut reader) = read_http_request_body(stream);
                            if request.contains("/api/v1/agent/home") {
                                answer(&mut reader, 200, &home);
                            } else if request.contains("/api/v1/agent/checkins") {
                                answer(
                                    &mut reader,
                                    202,
                                    r#"{"status":"accepted","jobs_waiting":true}"#,
                                );
                            } else if request.contains("/api/v1/agent/jobs/lease") {
                                let _ = seen.send(Seen::Lease);
                                if leased.swap(true, Ordering::SeqCst) {
                                    answer(&mut reader, 200, r#"{"jobs":[]}"#);
                                    return;
                                }
                                let job = json!({
                                    "id": job_id,
                                    "capability": "inventory.collect@1",
                                    "parameters": {},
                                    "attempt": 1,
                                    "lease_token": "lease",
                                    "lease_expires_at": chrono::Utc::now() + chrono::Duration::seconds(60),
                                    "timeout_ms": 30_000,
                                    "output_limit_bytes": 65_536
                                });
                                answer(&mut reader, 200, &json!({ "jobs": [job] }).to_string());
                            } else if request.contains(&format!("/api/v1/agent/jobs/{job_id}/events")) {
                                let report: serde_json::Value =
                                    serde_json::from_slice(&body).unwrap();
                                let kind = report["type"].as_str().unwrap().to_string();
                                let _ = seen.send(Seen::Report(kind.clone()));
                                if kind == "started" {
                                    let held = released.lock().unwrap().take();
                                    if let Some(held) = held {
                                        // Bounded, so a broken test cannot hang the suite.
                                        let _ = held.recv_timeout(Duration::from_secs(30));
                                    }
                                }
                                answer(&mut reader, 200, r#"{"cancel_requested":false}"#);
                            } else if request.contains("/api/v1/observations") {
                                answer(&mut reader, 202, "{}");
                            } else {
                                answer(&mut reader, 404, "{}");
                            }
                        }));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("held start job server failed: {error}"),
                }
            }
            for connection in connections {
                connection.join().unwrap();
            }
        });
        (origin, release, server)
    }

    /// A daemon whose job's `started` report the server is holding.
    struct HeldStart {
        state: PathBuf,
        config: PathBuf,
        stopped: Cancellation,
        timeline: Timeline,
        /// Answers the held report.
        release: mpsc::SyncSender<()>,
        server: thread::JoinHandle<()>,
        daemon: thread::JoinHandle<Result<(), String>>,
    }

    /// Starts the daemon against a held-start job server, and waits until the job's
    /// `started` report is in flight and the notice socket is open.
    fn daemon_holding_started(name: &str) -> HeldStart {
        let state = std::env::temp_dir().join(format!("renga-{name}-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (seen, receiver) = mpsc::channel();
        let (origin, release, server) = held_start_job_server(stopped.clone(), seen.clone());
        let config = write_agent_config(&state, &origin, "renga_intake_test");
        // The held report must outlast a slow machine without timing out on its own, or the
        // job would be dropped for that reason rather than the reload.
        let settings = std::fs::read_to_string(&config).unwrap().replace(
            "request_timeout_seconds = 2\n",
            "request_timeout_seconds = 20\n",
        );
        assert!(settings.contains("request_timeout_seconds = 20\n"));
        std::fs::write(&config, settings).unwrap();
        let daemon = spawn_daemon_seeing_reloads(config.clone(), &state, stopped.clone(), seen);
        let mut timeline = Timeline {
            receiver,
            seen: Vec::new(),
        };
        timeline.until("the started report and the notice socket", |seen| {
            seen.contains(&Seen::Report("started".into())) && seen.contains(&Seen::SocketOpened)
        });
        HeldStart {
            state,
            config,
            stopped,
            timeline,
            release,
            server,
            daemon,
        }
    }

    #[test]
    fn an_unchanged_reload_keeps_the_notice_socket_and_the_job_it_is_starting() {
        let HeldStart {
            state,
            config: _,
            stopped,
            mut timeline,
            release,
            server,
            daemon,
        } = daemon_holding_started("reload-same");
        // The file is untouched, so this is a periodic refresh that changes nothing.
        let held_at = timeline.seen.len();
        timeline.until("a reload while started is in flight", |seen| {
            seen[held_at..].contains(&Seen::Reloaded)
        });
        release.send(()).unwrap();

        timeline.until("the job's outcome", |seen| {
            seen.iter()
                .any(|each| matches!(each, Seen::Report(kind) if kind != "started"))
        });
        assert!(
            timeline.seen.contains(&Seen::Report("succeeded".into())),
            "{:?}",
            timeline.seen
        );
        assert_eq!(
            timeline.count(&Seen::SocketOpened),
            1,
            "{:?}",
            timeline.seen
        );
        assert_eq!(
            timeline.count(&Seen::SocketClosed),
            0,
            "{:?}",
            timeline.seen
        );

        stopped.cancel();
        daemon.join().unwrap().unwrap();
        server.join().unwrap();
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_reload_that_changes_the_labels_drops_the_job_it_is_starting_and_reconnects() {
        let HeldStart {
            state,
            config,
            stopped,
            mut timeline,
            release,
            server,
            daemon,
        } = daemon_holding_started("reload-labels");
        // The pass's `inventory.collect` is bound to the labels it was built with.
        let mut changed = std::fs::read_to_string(&config).unwrap();
        changed.push_str("\n[labels]\nteam = \"storage\"\n");
        let staged = config.with_extension("staged");
        std::fs::write(&staged, changed).unwrap();
        std::fs::rename(&staged, &config).unwrap();
        timeline.until("a socket for the new policy", |seen| {
            seen.iter()
                .filter(|each| **each == Seen::SocketOpened)
                .count()
                == 2
        });
        let released_at = timeline.seen.len();
        release.send(()).unwrap();

        // The old pass leases again only after finishing the job; a new pass leases at once.
        timeline.until("a lease after the started report was answered", |seen| {
            seen[released_at..].contains(&Seen::Lease)
        });
        assert!(
            !timeline
                .seen
                .iter()
                .any(|each| matches!(each, Seen::Report(kind) if kind != "started")),
            "{:?}",
            timeline.seen
        );
        assert_eq!(
            timeline.count(&Seen::SocketClosed),
            1,
            "{:?}",
            timeline.seen
        );

        stopped.cancel();
        daemon.join().unwrap().unwrap();
        server.join().unwrap();
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn collector_settings_change_with_the_home_a_reload_resolves_and_outlast_a_move() {
        let state =
            std::env::temp_dir().join(format!("renga-reload-snmp-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let accept = |request: &str| {
            if request.contains("/api/v1/agent/checkins") {
                (202, r#"{"status":"accepted","jobs_waiting":false}"#.into())
            } else if request.contains("/api/v1/observations") {
                (202, "{}".into())
            } else {
                (404, "{}".into())
            }
        };
        let (first_home, first_server) = routed_server(stopped.clone(), accept);
        // The second home says the organization moved once told to; the third home is where
        // the move leads.
        let moving = Arc::new(AtomicBool::new(false));
        let move_now = Arc::clone(&moving);
        let moved = Arc::new(AtomicBool::new(false));
        let said_moved = Arc::clone(&moved);
        let (second_home, second_server) = routed_server(stopped.clone(), move |request| {
            if move_now.load(Ordering::SeqCst) {
                said_moved.store(true, Ordering::SeqCst);
                (410, r#"{"error":"moved"}"#.into())
            } else {
                accept(request)
            }
        });
        let third_checkins = Arc::new(AtomicUsize::new(0));
        let checked_in = Arc::clone(&third_checkins);
        let (third_home, third_server) = routed_server(stopped.clone(), move |request| {
            if request.contains("/api/v1/agent/checkins") {
                checked_in.fetch_add(1, Ordering::SeqCst);
            }
            accept(request)
        });
        let (first_resolver, first_resolver_server) = routed_server(stopped.clone(), move |_| {
            (200, json!({ "home": first_home }).to_string())
        });
        // The new resolver fails until released, then names the second home until it says
        // the organization moved, and the third after.
        let resolvable = Arc::new(AtomicBool::new(false));
        let released = Arc::clone(&resolvable);
        let asked = Arc::new(AtomicUsize::new(0));
        let asked_count = Arc::clone(&asked);
        let (second_resolver, second_resolver_server) = routed_server(stopped.clone(), move |_| {
            asked_count.fetch_add(1, Ordering::SeqCst);
            if !released.load(Ordering::SeqCst) {
                (503, "{}".into())
            } else if moved.load(Ordering::SeqCst) {
                (200, json!({ "home": third_home }).to_string())
            } else {
                (200, json!({ "home": second_home }).to_string())
            }
        });
        let (old_target, old_polls) = silent_snmp_target(stopped.clone());
        let (new_target, new_polls) = silent_snmp_target(stopped.clone());
        std::fs::create_dir_all(&state).unwrap();
        let config = write_snmp_config(&state, &first_resolver, &old_target);
        let daemon = spawn_daemon(config, &state, false, stopped.clone());
        let deadline = Instant::now() + Duration::from_secs(20);
        wait_until("the first poll", deadline, || {
            old_polls.load(Ordering::SeqCst) == 1
        });

        // While the new configuration's home cannot be resolved, the old settings stay.
        write_snmp_config(&state, &second_resolver, &new_target);
        wait_until("a failed resolution", deadline, || {
            asked.load(Ordering::SeqCst) >= 2
        });
        assert_eq!(new_polls.load(Ordering::SeqCst), 0);

        // Once it resolves, the new settings come with the new home.
        resolvable.store(true, Ordering::SeqCst);
        wait_until("a poll with the new settings", deadline, || {
            new_polls.load(Ordering::SeqCst) == 1
        });

        // A move changes the home and its client, never the collectors: a restarted module
        // would poll again at once. Queued reports go out on the next flush, which uses the
        // new client.
        moving.store(true, Ordering::SeqCst);
        wait_until("check-ins at the home the move leads to", deadline, || {
            third_checkins.load(Ordering::SeqCst) >= 2
        });
        stopped.cancel();
        daemon.join().unwrap().unwrap();
        for server in [
            first_server,
            second_server,
            third_server,
            first_resolver_server,
            second_resolver_server,
        ] {
            server.join().unwrap();
        }

        assert_eq!(old_polls.load(Ordering::SeqCst), 1);
        assert_eq!(new_polls.load(Ordering::SeqCst), 1);
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_move_stays_pending_until_a_different_home_is_named() {
        let state = std::env::temp_dir().join(format!("renga-pending-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (checked_in, new_home_checkins) = mpsc::channel();
        let new_home_stop = stopped.clone();
        let (new_origin, new_server) = routed_server(stopped.clone(), move |request| {
            if request.contains("/api/v1/agent/checkins") {
                let _ = checked_in.send(());
                new_home_stop.cancel();
                (202, r#"{"status":"accepted","jobs_waiting":false}"#.into())
            } else {
                (404, "{}".into())
            }
        });
        // The old home says `moved` once and then only fails, as a deployment going away
        // would, so nothing but the pending relocation can find the new home.
        let said_moved = Arc::new(AtomicBool::new(false));
        let (old_origin, old_server) = routed_server(stopped.clone(), move |request| {
            if request.contains("/api/v1/agent/checkins")
                && !said_moved.swap(true, Ordering::SeqCst)
            {
                (410, r#"{"error":"moved"}"#.into())
            } else {
                (503, "{}".into())
            }
        });
        let expected_home = format!("{new_origin}/");
        // The resolver has not caught up when first asked after the move.
        let resolutions = Arc::new(AtomicUsize::new(0));
        let resolved = Arc::clone(&resolutions);
        let (resolver, resolver_server) = routed_server(stopped.clone(), move |_request| {
            let home = if resolved.fetch_add(1, Ordering::SeqCst) < 2 {
                &old_origin
            } else {
                &new_origin
            };
            (200, json!({ "home": home }).to_string())
        });
        let config = write_agent_config(&state, &resolver, "renga_intake_test");
        let daemon = spawn_daemon(config, &state, false, stopped.clone());

        new_home_checkins
            .recv_timeout(Duration::from_secs(15))
            .unwrap();
        stopped.cancel();
        daemon.join().unwrap().unwrap();
        for server in [new_server, old_server, resolver_server] {
            server.join().unwrap();
        }

        assert_eq!(resolutions.load(Ordering::SeqCst), 3);
        let persisted: serde_json::Value =
            serde_json::from_slice(&std::fs::read(state.join("home.json")).unwrap()).unwrap();
        assert_eq!(persisted["home"], expected_home);
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_reload_during_a_move_never_persists_the_home_that_said_moved() {
        let state =
            std::env::temp_dir().join(format!("renga-moved-reload-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let said_moved = Arc::new(AtomicBool::new(false));
        let moved_once = Arc::clone(&said_moved);
        let (old_origin, old_server) = routed_server(stopped.clone(), move |request| {
            if request.contains("/api/v1/agent/checkins")
                && !moved_once.swap(true, Ordering::SeqCst)
            {
                (410, r#"{"error":"moved"}"#.into())
            } else {
                (503, "{}".into())
            }
        });
        let first_answer = old_origin.clone();
        let (resolver, resolver_server) = routed_server(stopped.clone(), move |_request| {
            (200, json!({ "home": first_answer }).to_string())
        });
        // The replacement resolver has not caught up either.
        let replacement_asked = Arc::new(AtomicUsize::new(0));
        let asked = Arc::clone(&replacement_asked);
        let (replacement, replacement_server) = routed_server(stopped.clone(), move |_request| {
            asked.fetch_add(1, Ordering::SeqCst);
            (200, json!({ "home": old_origin }).to_string())
        });
        let config = write_agent_config(&state, &resolver, "renga_intake_test");
        let daemon = spawn_daemon(config, &state, false, stopped.clone());
        let deadline = Instant::now() + Duration::from_secs(10);
        // The home was persisted before the check-in that heard `moved`, so its absence after
        // that means the daemon discarded it.
        while !said_moved.load(Ordering::SeqCst) || state.join("home.json").exists() {
            assert!(
                Instant::now() < deadline,
                "the moved home was never discarded"
            );
            thread::sleep(Duration::from_millis(20));
        }

        write_agent_config(&state, &replacement, "renga_intake_test");
        while replacement_asked.load(Ordering::SeqCst) < 2 {
            assert!(
                Instant::now() < deadline,
                "the replacement resolver was never asked"
            );
            thread::sleep(Duration::from_millis(20));
        }
        stopped.cancel();
        daemon.join().unwrap().unwrap();
        for server in [old_server, resolver_server, replacement_server] {
            server.join().unwrap();
        }

        assert!(!state.join("home.json").exists());
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_move_heard_while_stopping_still_discards_the_home() {
        // One case per request still in flight when the daemon is asked to stop: the startup
        // check-in, and an observation on the delivery thread.
        for path in ["/api/v1/agent/checkins", "/api/v1/observations"] {
            let state =
                std::env::temp_dir().join(format!("renga-moved-stop-{}", uuid::Uuid::new_v4()));
            let stopped = Cancellation::default();
            let server_stop = Cancellation::default();
            let (arrived, request_arrived) = mpsc::channel();
            let (release, released) = mpsc::channel::<()>();
            let released = Arc::new(Mutex::new(released));
            let (home_origin, home_server) = routed_server(server_stop.clone(), move |request| {
                if request.contains(path) {
                    let _ = arrived.send(());
                    let _ = released.lock().unwrap().recv();
                    (410, r#"{"error":"moved"}"#.into())
                } else if request.contains("/api/v1/agent/checkins") {
                    (202, r#"{"status":"accepted","jobs_waiting":false}"#.into())
                } else {
                    (404, "{}".into())
                }
            });
            let (resolver, resolver_server) = routed_server(server_stop.clone(), move |_request| {
                (200, json!({ "home": home_origin }).to_string())
            });
            let config = write_agent_config(&state, &resolver, "renga_intake_test");
            let daemon = spawn_daemon(config, &state, false, stopped.clone());

            request_arrived
                .recv_timeout(Duration::from_secs(10))
                .unwrap();
            assert!(state.join("home.json").exists());
            stopped.cancel();
            // Let the scheduler loop notice the stop before the answer arrives.
            thread::sleep(Duration::from_millis(600));
            release.send(()).unwrap();
            daemon.join().unwrap().unwrap();
            server_stop.cancel();
            home_server.join().unwrap();
            resolver_server.join().unwrap();

            assert!(!state.join("home.json").exists(), "{path}");
            std::fs::remove_dir_all(state).unwrap();
        }
    }

    #[test]
    fn a_single_run_that_hears_moved_forgets_the_home_for_the_next_run() {
        let state = std::env::temp_dir().join(format!("renga-once-moved-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (old_origin, old_server) = routed_server(stopped.clone(), |_request| {
            (410, r#"{"error":"moved"}"#.into())
        });
        let resolver_home = old_origin.clone();
        let (resolver, resolver_server) = routed_server(stopped.clone(), move |_request| {
            (200, json!({ "home": resolver_home }).to_string())
        });
        let config = write_agent_config(&state, &resolver, "renga_intake_test");

        let result = spawn_daemon(config, &state, true, Cancellation::default())
            .join()
            .unwrap();
        stopped.cancel();
        old_server.join().unwrap();
        resolver_server.join().unwrap();

        assert!(result.is_err());
        assert!(!state.join("home.json").exists());
        std::fs::remove_dir_all(state).unwrap();
    }

    /// What the homes in a relocation test heard, in the order they heard it.
    #[derive(Debug, Clone, PartialEq)]
    enum Heard {
        SocketOpened(&'static str),
        SocketClosed(&'static str),
        Lease(&'static str),
        /// A report on the leased job, by type.
        Report(&'static str, String),
        /// An observation by ID, and the status it was answered with.
        Observation(&'static str, String, u16),
    }

    /// Everything heard so far, so a test waits on events instead of on the clock.
    struct Hearing {
        receiver: mpsc::Receiver<Heard>,
        heard: Vec<Heard>,
    }

    impl Hearing {
        fn until(&mut self, what: &str, done: impl Fn(&[Heard]) -> bool) {
            let deadline = Instant::now() + Duration::from_secs(30);
            while !done(&self.heard) {
                let left = deadline.saturating_duration_since(Instant::now());
                match self.receiver.recv_timeout(left) {
                    Ok(heard) => self.heard.push(heard),
                    Err(_) => panic!("{what} never happened; heard {:?}", self.heard),
                }
            }
        }

        /// Takes in whatever arrived since, once every server has stopped.
        fn drain(&mut self) {
            self.heard.extend(self.receiver.try_iter());
        }

        fn count(&self, heard: &Heard) -> usize {
            self.heard.iter().filter(|each| *each == heard).count()
        }

        fn reports(&self, home: &str) -> Vec<String> {
            self.heard
                .iter()
                .filter_map(|each| match each {
                    Heard::Report(at, kind) if *at == home => Some(kind.clone()),
                    _ => None,
                })
                .collect()
        }

        fn heard_from(&self, home: &str) -> bool {
            self.heard.iter().any(|each| match each {
                Heard::SocketOpened(at)
                | Heard::SocketClosed(at)
                | Heard::Lease(at)
                | Heard::Report(at, _)
                | Heard::Observation(at, _, _) => *at == home,
            })
        }
    }

    /// A home in a relocation test.
    struct RelocationHome {
        origin: String,
        /// Raised once the home says the organization moved.
        moved: Arc<AtomicBool>,
        /// Answers the held `started` report.
        release: mpsc::SyncSender<()>,
        server: thread::JoinHandle<()>,
    }

    /// A home that, when it `moves`, leases one `inventory.collect` job and holds its `started`
    /// report until released, answers its first observation with `410 moved` once that report
    /// is held, and from then on says the organization moved to everything but job reports and
    /// the notice socket. A home that does not move only accepts, and never has a job.
    #[allow(clippy::result_large_err)]
    fn relocation_home(
        name: &'static str,
        moves: bool,
        stopped: Cancellation,
        heard: mpsc::Sender<Heard>,
    ) -> RelocationHome {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let job_id = uuid::Uuid::new_v4();
        let leased = Arc::new(AtomicBool::new(!moves));
        let held = Arc::new(AtomicBool::new(false));
        let moved = Arc::new(AtomicBool::new(false));
        let home_moved = Arc::clone(&moved);
        let (release, released) = mpsc::sync_channel(1);
        let released = Arc::new(Mutex::new(Some(released)));
        let server = thread::spawn(move || {
            let mut connections = Vec::new();
            while !stopped.cancelled() {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let leased = Arc::clone(&leased);
                        let held = Arc::clone(&held);
                        let moved = Arc::clone(&home_moved);
                        let released = Arc::clone(&released);
                        let heard = heard.clone();
                        connections.push(thread::spawn(move || {
                            let mut peek = [0; 256];
                            let bytes = stream.peek(&mut peek).unwrap();
                            let opening = String::from_utf8_lossy(&peek[..bytes]);
                            if opening.contains("/api/v1/agent/socket/websocket") {
                                let _ = heard.send(Heard::SocketOpened(name));
                                let mut socket = tungstenite::accept_hdr(
                                    stream,
                                    |_request: &Request, mut response: Response| {
                                        response.headers_mut().insert(
                                            SEC_WEBSOCKET_PROTOCOL,
                                            HeaderValue::from_static("phoenix"),
                                        );
                                        Ok(response)
                                    },
                                )
                                .unwrap();
                                let join: serde_json::Value =
                                    serde_json::from_str(socket.read().unwrap().to_text().unwrap())
                                        .unwrap();
                                socket
                                    .send(Message::text(
                                        json!(["1", "1", join[2], "phx_reply", {
                                            "status": "ok",
                                            "response": {"jobs_waiting": false}
                                        }])
                                        .to_string(),
                                    ))
                                    .unwrap();
                                while socket.read().is_ok() {}
                                let _ = heard.send(Heard::SocketClosed(name));
                                return;
                            }

                            let gone = r#"{"error":"moved"}"#;
                            let (request, body, mut reader) = read_http_request_body(stream);
                            if request.contains(&format!("/api/v1/agent/jobs/{job_id}/events")) {
                                let report: serde_json::Value =
                                    serde_json::from_slice(&body).unwrap();
                                let kind = report["type"].as_str().unwrap().to_string();
                                let _ = heard.send(Heard::Report(name, kind.clone()));
                                if kind == "started" {
                                    held.store(true, Ordering::SeqCst);
                                    let release = released.lock().unwrap().take();
                                    if let Some(release) = release {
                                        // Inside the agent's 20-second request timeout, so
                                        // the pass is still waiting when the answer comes.
                                        release
                                            .recv_timeout(Duration::from_secs(15))
                                            .expect("the held start was never released");
                                    }
                                }
                                answer(&mut reader, 200, r#"{"cancel_requested":false}"#);
                            } else if request.contains("/api/v1/observations") {
                                let observation: serde_json::Value =
                                    serde_json::from_slice(&body).unwrap();
                                let id = observation["observation_id"]
                                    .as_str()
                                    .unwrap()
                                    .to_string();
                                if moves && !moved.load(Ordering::SeqCst) {
                                    let deadline = Instant::now() + Duration::from_secs(30);
                                    while !held.load(Ordering::SeqCst) && Instant::now() < deadline
                                    {
                                        thread::sleep(Duration::from_millis(5));
                                    }
                                    moved.store(true, Ordering::SeqCst);
                                }
                                let status = if moved.load(Ordering::SeqCst) { 410 } else { 202 };
                                let _ = heard.send(Heard::Observation(name, id, status));
                                answer(&mut reader, status, if status == 410 { gone } else { "{}" });
                            } else if moved.load(Ordering::SeqCst) {
                                answer(&mut reader, 410, gone);
                            } else if request.contains("/api/v1/agent/checkins") {
                                answer(
                                    &mut reader,
                                    202,
                                    r#"{"status":"accepted","jobs_waiting":true}"#,
                                );
                            } else if request.contains("/api/v1/agent/jobs/lease") {
                                let _ = heard.send(Heard::Lease(name));
                                if leased.swap(true, Ordering::SeqCst) {
                                    answer(&mut reader, 200, r#"{"jobs":[]}"#);
                                    return;
                                }
                                let job = json!({
                                    "id": job_id,
                                    "capability": "inventory.collect@1",
                                    "parameters": {},
                                    "attempt": 1,
                                    "lease_token": "lease",
                                    "lease_expires_at": chrono::Utc::now() + chrono::Duration::seconds(60),
                                    "timeout_ms": 30_000,
                                    "output_limit_bytes": 65_536
                                });
                                answer(&mut reader, 200, &json!({ "jobs": [job] }).to_string());
                            } else {
                                answer(&mut reader, 404, "{}");
                            }
                        }));
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("relocation home failed: {error}"),
                }
            }
            for connection in connections {
                connection.join().unwrap();
            }
        });
        RelocationHome {
            origin,
            moved,
            release,
            server,
        }
    }

    /// Signals when the daemon's main loop has stopped, from its "daemon stopping" line.
    #[derive(Clone)]
    struct StoppingLog(mpsc::Sender<()>);

    impl Write for StoppingLog {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            if String::from_utf8_lossy(buf).contains("daemon stopping") {
                let _ = self.0.send(());
            }
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// Starts a daemon for a relocation test, with a receiver told once its main loop stops.
    /// Reloads stay out of the way, so only the move can restart job passes or the socket;
    /// inventory runs often, so a queued observation goes out soon after the move; and a held
    /// report outlasts a slow machine.
    fn relocation_daemon(
        state: &Path,
        resolver: &str,
        stopped: Cancellation,
    ) -> (thread::JoinHandle<Result<(), String>>, mpsc::Receiver<()>) {
        let config = write_agent_config(state, resolver, "renga_intake_test");
        let settings = std::fs::read_to_string(&config)
            .unwrap()
            .replace(
                "config_refresh_interval_seconds = 1\n",
                "config_refresh_interval_seconds = 3600\ninventory_interval_seconds = 2\n",
            )
            .replace(
                "request_timeout_seconds = 2\n",
                "request_timeout_seconds = 20\n",
            );
        assert!(settings.contains("config_refresh_interval_seconds = 3600\n"));
        assert!(settings.contains("request_timeout_seconds = 20\n"));
        std::fs::write(&config, settings).unwrap();
        let (loop_stopped, stopping) = mpsc::channel();
        let state = state.to_path_buf();
        let daemon = thread::spawn(move || {
            let log = tracing_subscriber::fmt()
                .with_ansi(false)
                .with_writer(move || StoppingLog(loop_stopped.clone()))
                .finish();
            tracing::subscriber::with_default(log, || {
                run_configured(
                    Args {
                        config,
                        state_directory: state,
                        once: false,
                        dry_run: false,
                        command: None,
                    },
                    stopped,
                )
                .map_err(|error| error.to_string())
            })
        });
        (daemon, stopping)
    }

    #[test]
    fn a_move_to_a_different_home_abandons_the_pass_built_for_the_old_one() {
        let state =
            std::env::temp_dir().join(format!("renga-relocate-pass-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (heard, receiver) = mpsc::channel();
        let old = relocation_home("old", true, stopped.clone(), heard.clone());
        let new = relocation_home("new", false, stopped.clone(), heard);
        let asked = Arc::new(AtomicUsize::new(0));
        let resolver_asked = Arc::clone(&asked);
        let old_moved = Arc::clone(&old.moved);
        let (old_origin, new_origin) = (old.origin.clone(), new.origin.clone());
        let (resolver, resolver_server) = routed_server(stopped.clone(), move |_request| {
            resolver_asked.fetch_add(1, Ordering::SeqCst);
            let home = if old_moved.load(Ordering::SeqCst) {
                &new_origin
            } else {
                &old_origin
            };
            (200, json!({ "home": home }).to_string())
        });
        let (daemon, _stopping) = relocation_daemon(&state, &resolver, stopped.clone());
        let mut hearing = Hearing {
            receiver,
            heard: Vec::new(),
        };
        hearing.until("the held start and the old home's socket", |heard| {
            heard.contains(&Heard::Report("old", "started".into()))
                && heard.contains(&Heard::SocketOpened("old"))
        });
        // The old home says the organization moved only while the start is held, so the
        // agent adopts the new home with the old pass still waiting on the old one.
        hearing.until("the new home's socket", |heard| {
            heard.contains(&Heard::SocketOpened("new"))
        });
        let refused = hearing
            .heard
            .iter()
            .find_map(|each| match each {
                Heard::Observation("old", id, 410) => Some(id.clone()),
                _ => None,
            })
            .expect("the old home said the organization moved to an observation");
        old.release.send(()).unwrap();

        // Only one pass runs at a time, so a lease at the new home means the old pass ended.
        hearing.until("a lease at the new home", |heard| {
            heard.contains(&Heard::Lease("new"))
        });
        hearing.until("the refused observation at the new home", |heard| {
            heard.contains(&Heard::Observation("new", refused.clone(), 202))
        });
        stopped.cancel();
        daemon.join().unwrap().unwrap();
        for server in [old.server, new.server, resolver_server] {
            server.join().unwrap();
        }
        hearing.drain();

        // Nothing past the start went to the home that said the organization moved.
        assert_eq!(hearing.reports("old"), ["started"], "{:?}", hearing.heard);
        assert_eq!(hearing.count(&Heard::SocketOpened("old")), 1);
        assert_eq!(hearing.count(&Heard::SocketClosed("old")), 1);
        assert_eq!(hearing.count(&Heard::SocketOpened("new")), 1);
        // Every `moved` the old home said before and after the move led to one resolution.
        assert_eq!(asked.load(Ordering::SeqCst), 2, "{:?}", hearing.heard);
        let persisted: serde_json::Value =
            serde_json::from_slice(&std::fs::read(state.join("home.json")).unwrap()).unwrap();
        assert_eq!(persisted["home"], format!("{}/", new.origin));
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_move_that_names_no_new_home_keeps_the_pass_and_the_socket() {
        // The resolver names the old home again, or cannot answer at all.
        for resolvable in [true, false] {
            let state =
                std::env::temp_dir().join(format!("renga-relocate-none-{}", uuid::Uuid::new_v4()));
            let stopped = Cancellation::default();
            let (heard, receiver) = mpsc::channel();
            let old = relocation_home("old", true, stopped.clone(), heard);
            let asked = Arc::new(AtomicUsize::new(0));
            let resolver_asked = Arc::clone(&asked);
            let old_moved = Arc::clone(&old.moved);
            let old_origin = old.origin.clone();
            let (resolver, resolver_server) = routed_server(stopped.clone(), move |_request| {
                resolver_asked.fetch_add(1, Ordering::SeqCst);
                if old_moved.load(Ordering::SeqCst) && !resolvable {
                    (503, "{}".into())
                } else {
                    (200, json!({ "home": old_origin }).to_string())
                }
            });
            let (daemon, _stopping) = relocation_daemon(&state, &resolver, stopped.clone());
            let mut hearing = Hearing {
                receiver,
                heard: Vec::new(),
            };
            hearing.until("the held start and the socket", |heard| {
                heard.contains(&Heard::Report("old", "started".into()))
                    && heard.contains(&Heard::SocketOpened("old"))
            });
            // One resolution runs at a time, so a third ask means the first after the move
            // has been handled.
            wait_until(
                "two resolutions after the move",
                Instant::now() + Duration::from_secs(30),
                || asked.load(Ordering::SeqCst) >= 3,
            );
            old.release.send(()).unwrap();

            hearing.until("the job's outcome", |heard| {
                heard
                    .iter()
                    .any(|each| matches!(each, Heard::Report("old", kind) if kind != "started"))
            });
            assert_eq!(
                hearing.count(&Heard::SocketOpened("old")),
                1,
                "{resolvable}"
            );
            assert_eq!(
                hearing.count(&Heard::SocketClosed("old")),
                0,
                "{resolvable}"
            );
            stopped.cancel();
            daemon.join().unwrap().unwrap();
            for server in [old.server, resolver_server] {
                server.join().unwrap();
            }

            // The home that said the organization moved stays forgotten, and nothing replaced it.
            assert!(!state.join("home.json").exists(), "{resolvable}");
            std::fs::remove_dir_all(state).unwrap();
        }
    }

    #[test]
    fn stopping_while_a_move_resolves_adopts_nothing_and_runs_nothing_more() {
        let state =
            std::env::temp_dir().join(format!("renga-relocate-stop-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let server_stop = Cancellation::default();
        let (heard, receiver) = mpsc::channel();
        let old = relocation_home("old", true, server_stop.clone(), heard.clone());
        let new = relocation_home("new", false, server_stop.clone(), heard);
        // The resolution after the move names the new home only once released.
        let (resolving, relocation_asked) = mpsc::channel();
        let (answer_now, answered) = mpsc::channel::<()>();
        let answered = Arc::new(Mutex::new(answered));
        let old_moved = Arc::clone(&old.moved);
        let (old_origin, new_origin) = (old.origin.clone(), new.origin.clone());
        let (resolver, resolver_server) = routed_server(server_stop.clone(), move |_request| {
            if !old_moved.load(Ordering::SeqCst) {
                return (200, json!({ "home": old_origin }).to_string());
            }
            let _ = resolving.send(());
            let _ = answered
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(30));
            (200, json!({ "home": new_origin }).to_string())
        });
        let (daemon, loop_stopped) = relocation_daemon(&state, &resolver, stopped.clone());
        let mut hearing = Hearing {
            receiver,
            heard: Vec::new(),
        };
        hearing.until("the held start and the socket", |heard| {
            heard.contains(&Heard::Report("old", "started".into()))
                && heard.contains(&Heard::SocketOpened("old"))
        });
        relocation_asked
            .recv_timeout(Duration::from_secs(30))
            .unwrap();

        stopped.cancel();
        // The answers arrive only once the main loop has stopped, so nothing is left to adopt
        // them; shutdown then waits for the resolution and the pass they hold up.
        loop_stopped
            .recv_timeout(Duration::from_secs(30))
            .expect("the daemon's main loop never stopped");
        answer_now.send(()).unwrap();
        old.release.send(()).unwrap();
        wait_until(
            "the daemon stopping",
            Instant::now() + Duration::from_secs(10),
            || daemon.is_finished(),
        );
        daemon.join().unwrap().unwrap();
        server_stop.cancel();
        for server in [old.server, new.server, resolver_server] {
            server.join().unwrap();
        }
        hearing.drain();

        assert!(!hearing.heard_from("new"), "{:?}", hearing.heard);
        assert_eq!(hearing.reports("old"), ["started"], "{:?}", hearing.heard);
        assert!(!state.join("home.json").exists());
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_reload_that_cannot_use_its_new_home_keeps_the_old_one_and_keeps_checking_in() {
        let state = std::env::temp_dir().join(format!("renga-reload-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let checkins = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&checkins);
        let (home_origin, home_server) = routed_server(stopped.clone(), move |request| {
            if request.contains("/api/v1/agent/checkins") {
                counted.fetch_add(1, Ordering::SeqCst);
                (202, r#"{"status":"accepted","jobs_waiting":false}"#.into())
            } else {
                (404, "{}".into())
            }
        });
        let first_home = home_origin.clone();
        let (resolver, resolver_server) = routed_server(stopped.clone(), move |_request| {
            (200, json!({ "home": first_home }).to_string())
        });
        // The replacement resolver is slow and names a home the new key cannot be sent to.
        let asked = Arc::new(AtomicBool::new(false));
        let replacement_asked = Arc::clone(&asked);
        let (slow_resolver, slow_server) = routed_server(stopped.clone(), move |_request| {
            replacement_asked.store(true, Ordering::SeqCst);
            thread::sleep(Duration::from_millis(1500));
            (200, json!({ "home": "http://127.0.0.1:9" }).to_string())
        });
        let config = write_agent_config(&state, &resolver, "renga_intake_test");
        let daemon = spawn_daemon(config.clone(), &state, false, stopped.clone());
        let deadline = Instant::now() + Duration::from_secs(10);
        while checkins.load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        let persisted = std::fs::read(state.join("home.json")).unwrap();

        // A newline cannot go into the authorization header, so the new client cannot be built.
        write_agent_config(&state, &slow_resolver, "renga_intake_bad\nkey");
        while !asked.load(Ordering::SeqCst) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        let before = checkins.load(Ordering::SeqCst);
        thread::sleep(Duration::from_millis(1200));
        let during = checkins.load(Ordering::SeqCst) - before;
        thread::sleep(Duration::from_millis(1000));
        stopped.cancel();
        daemon.join().unwrap().unwrap();
        for server in [home_server, resolver_server, slow_server] {
            server.join().unwrap();
        }

        assert!(asked.load(Ordering::SeqCst));
        assert!(during >= 1, "check-ins stopped while the resolver was slow");
        assert_eq!(std::fs::read(state.join("home.json")).unwrap(), persisted);
        std::fs::remove_dir_all(state).unwrap();
    }

    fn stub_client(origin: &str) -> HttpClient {
        HttpClient::new(&stub_config(origin), Cancellation::default()).unwrap()
    }

    fn stub_config(origin: &str) -> Config {
        Config {
            config_path: PathBuf::from("agent.toml"),
            renga_url: origin.into(),
            allow_insecure_http: true,
            intake_api_key: "token".into(),
            installation_id: uuid::Uuid::nil(),
            inventory_interval: Duration::from_secs(3600),
            checkin_interval: Duration::from_secs(60),
            config_refresh_interval: Duration::from_secs(300),
            request_timeout: Duration::from_secs(5),
            max_retry_attempts: 1,
            labels: BTreeMap::new(),
            jobs: Default::default(),
            snmp: Vec::new(),
            gnmi: Vec::new(),
            libvirt: None,
            power: Vec::new(),
            bmc: Vec::new(),
            exporters: Vec::new(),
            osquery: OsqueryConfig {
                enabled: false,
                ..Default::default()
            },
        }
    }

    struct SlowHeartbeatApi {
        lease: Mutex<Option<LeasedJob>>,
        reports: Mutex<Vec<ReportType>>,
        progress_started: Mutex<Option<mpsc::Sender<()>>>,
    }

    impl JobApi for SlowHeartbeatApi {
        fn lease(&self, _: &[String], _: u32) -> Result<Vec<LeasedJob>, TransportError> {
            Ok(self.lease.lock().unwrap().take().into_iter().collect())
        }

        fn report(
            &self,
            _: uuid::Uuid,
            report: &JobReport<'_>,
        ) -> Result<ReportAck, TransportError> {
            self.reports.lock().unwrap().push(report.kind);
            if report.kind == ReportType::Progress {
                if let Some(started) = self.progress_started.lock().unwrap().take() {
                    started.send(()).unwrap();
                }
                thread::sleep(Duration::from_millis(200));
            }
            Ok(ReportAck {
                cancel_requested: false,
            })
        }
    }

    #[test]
    fn socket_notices_start_serial_lease_passes_before_the_next_checkin() {
        let state = std::env::temp_dir().join(format!("renga-notices-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (origin, leases, overlapping, server) = notice_daemon_server(stopped.clone());
        let config = state.join("agent.toml");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(
            &config,
            format!(
                "renga_url = {origin:?}\nallow_insecure_http = true\nintake_api_key = \"test-token\"\ncheckin_interval_seconds = 60\nrequest_timeout_seconds = 2\nmax_retry_attempts = 1\n"
            ),
        )
        .unwrap();
        let daemon_stop = stopped.clone();
        let daemon_state = state.clone();
        let daemon = thread::spawn(move || {
            run_configured(
                Args {
                    config,
                    state_directory: daemon_state,
                    once: false,
                    dry_run: false,
                    command: None,
                },
                daemon_stop,
            )
            .map_err(|error| error.to_string())
        });

        assert_eq!(leases.recv_timeout(Duration::from_secs(5)).unwrap(), 1);
        assert_eq!(leases.recv_timeout(Duration::from_secs(5)).unwrap(), 2);
        assert!(!overlapping.load(Ordering::SeqCst));

        stopped.cancel();
        daemon.join().unwrap().unwrap();
        server.join().unwrap();
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn refused_notice_socket_does_not_block_checkin_polling() {
        let state = std::env::temp_dir().join(format!("renga-fallback-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (origin, leased, server) = refused_notice_server(stopped.clone());
        let config = state.join("agent.toml");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(
            &config,
            format!(
                "renga_url = {origin:?}\nallow_insecure_http = true\nintake_api_key = \"test-token\"\ncheckin_interval_seconds = 1\nrequest_timeout_seconds = 2\nmax_retry_attempts = 1\n"
            ),
        )
        .unwrap();
        let started = Instant::now();
        let daemon_stop = stopped.clone();
        let daemon_state = state.clone();
        let daemon = thread::spawn(move || {
            run_configured(
                Args {
                    config,
                    state_directory: daemon_state,
                    once: false,
                    dry_run: false,
                    command: None,
                },
                daemon_stop,
            )
            .map_err(|error| error.to_string())
        });

        leased.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(started.elapsed() >= Duration::from_millis(800));

        stopped.cancel();
        daemon.join().unwrap().unwrap();
        server.join().unwrap();
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn reload_interrupts_slow_upgrade_and_replaces_credentials_and_policy() {
        let state = std::env::temp_dir().join(format!("renga-reload-{}", uuid::Uuid::new_v4()));
        let stopped = Cancellation::default();
        let (origin, protocols, closed, checkins, server) = reload_notice_server(stopped.clone());
        let config = state.join("agent.toml");
        std::fs::create_dir_all(&state).unwrap();
        let write_config = |token: &str, jobs_enabled: bool| {
            let jobs = if jobs_enabled {
                String::new()
            } else {
                "[jobs]\nenabled = []\n".into()
            };
            let next = config.with_extension("next");
            std::fs::write(
                &next,
                format!(
                    "renga_url = {origin:?}\nallow_insecure_http = true\nintake_api_key = {token:?}\ncheckin_interval_seconds = 1\nconfig_refresh_interval_seconds = 1\nrequest_timeout_seconds = 5\nmax_retry_attempts = 1\n{jobs}"
                ),
            )
            .unwrap();
            std::fs::rename(next, &config).unwrap();
        };
        write_config("old-token", true);
        let daemon_stop = stopped.clone();
        let daemon_state = state.clone();
        let daemon_config = config.clone();
        let daemon = thread::spawn(move || {
            run_configured(
                Args {
                    config: daemon_config,
                    state_directory: daemon_state,
                    once: false,
                    dry_run: false,
                    command: None,
                },
                daemon_stop,
            )
            .map_err(|error| error.to_string())
        });

        let old = protocols.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(old.contains(&STANDARD_NO_PAD.encode("old-token")));
        write_config("new-token", true);
        assert_eq!(closed.recv_timeout(Duration::from_secs(3)).unwrap(), 1);
        let new = protocols.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(new.contains(&STANDARD_NO_PAD.encode("new-token")));
        let checkins_after_replacement = checkins.load(Ordering::SeqCst);

        write_config("new-token", false);
        assert_eq!(closed.recv_timeout(Duration::from_secs(3)).unwrap(), 2);
        assert!(checkins.load(Ordering::SeqCst) > checkins_after_replacement);
        let checkins_after_disabling = checkins.load(Ordering::SeqCst);
        assert_eq!(
            protocols.recv_timeout(Duration::from_millis(1_200)),
            Err(mpsc::RecvTimeoutError::Timeout)
        );
        assert!(checkins.load(Ordering::SeqCst) > checkins_after_disabling);

        stopped.cancel();
        daemon.join().unwrap().unwrap();
        server.join().unwrap();
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn only_what_jobs_are_built_from_restarts_them_on_reload() {
        type Change = dyn Fn(&mut Config, &mut reqwest::Url);
        let state = std::env::temp_dir().join(format!("renga-restart-{}", uuid::Uuid::new_v4()));
        let key = Arc::new(InstallationKey::load_or_create(&state.join("key")).unwrap());
        let other_key = Arc::new(InstallationKey::load_or_create(&state.join("other")).unwrap());
        let config = stub_config("http://renga.test");
        let home: reqwest::Url = "http://home.test".parse().unwrap();
        let client = |config: &Config, home: &reqwest::Url, key: &Arc<InstallationKey>| {
            HttpClient::for_home(config, home, Cancellation::default())
                .unwrap()
                .with_installation_key(Arc::clone(key))
        };
        let current = client(&config, &home, &key);
        let restarts = |change: &Change| {
            let (mut new_config, mut new_home) = (config.clone(), home.clone());
            change(&mut new_config, &mut new_home);
            let new_client = client(&new_config, &new_home, &key);
            reload_changes_jobs(&config, &current, &new_config, &new_client)
        };

        // A periodic refresh rebuilds an equivalent client, and the scheduler and collector
        // modules reread their own settings.
        let independent: [(&str, &Change); 8] = [
            ("nothing", &|_, _| {}),
            ("renga_url, resolving to the same home", &|config, _| {
                config.renga_url = "http://elsewhere.test".into()
            }),
            ("config_path", &|config, _| {
                config.config_path = "elsewhere.toml".into()
            }),
            ("inventory_interval", &|config, _| {
                config.inventory_interval = Duration::from_secs(5)
            }),
            ("checkin_interval", &|config, _| {
                config.checkin_interval = Duration::from_secs(5)
            }),
            ("config_refresh_interval", &|config, _| {
                config.config_refresh_interval = Duration::from_secs(5)
            }),
            ("snmp", &|config, _| {
                config.snmp = vec![SnmpCollector {
                    id: "switches".into(),
                    targets: Vec::new(),
                    credentials: Credentials::V2c {
                        community_file: "community".into(),
                    },
                    interval: Duration::from_secs(60),
                    timeout: Duration::from_secs(5),
                    max_concurrent_targets: 1,
                }]
            }),
            ("libvirt", &|config, _| {
                config.libvirt = Some(LibvirtCollector {
                    id: "hypervisor".into(),
                    uri: "qemu:///system".into(),
                    interval: Duration::from_secs(60),
                    timeout: Duration::from_secs(5),
                })
            }),
        ];
        for (what, change) in independent {
            assert!(!restarts(change), "{what} restarted jobs");
        }

        let relevant: [(&str, &Change); 7] = [
            ("the home", &|_, home| {
                *home = "http://other.test".parse().unwrap()
            }),
            ("intake_api_key", &|config, _| {
                config.intake_api_key = "renga_intake_rotated".into()
            }),
            ("installation_id", &|config, _| {
                config.installation_id = uuid::Uuid::new_v4()
            }),
            ("request_timeout", &|config, _| {
                config.request_timeout = Duration::from_secs(1)
            }),
            ("max_retry_attempts", &|config, _| {
                config.max_retry_attempts = 3
            }),
            ("labels", &|config, _| {
                config.labels.insert("team".into(), "storage".into());
            }),
            ("jobs", &|config, _| config.jobs.enabled = Some(Vec::new())),
        ];
        for (what, change) in relevant {
            assert!(restarts(change), "{what} did not restart jobs");
        }
        assert!(
            reload_changes_jobs(
                &config,
                &current,
                &config,
                &client(&config, &home, &other_key)
            ),
            "the installation key did not restart jobs"
        );
        // Insecure HTTP only decides whether a home is allowed; an HTTPS home is sent the same.
        let mut secure = config.clone();
        let secure_home: reqwest::Url = "https://home.test".parse().unwrap();
        let secure_client = client(&secure, &secure_home, &key);
        secure.allow_insecure_http = false;
        assert!(
            !reload_changes_jobs(
                &config,
                &secure_client,
                &secure,
                &client(&secure, &secure_home, &key)
            ),
            "allow_insecure_http restarted jobs for an HTTPS home"
        );
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn flush_replays_queued_bodies_exactly_and_keeps_what_the_server_could_not_take() {
        let state = std::env::temp_dir().join(format!("renga-flush-{}", uuid::Uuid::new_v4()));
        let queue = Mutex::new(DeliveryQueue::new(state.clone()));
        for body in [&br#"{"n":1}"#[..], br#"{"n":2}"#] {
            lock(&queue)
                .ready()
                .unwrap()
                .enqueue(uuid::Uuid::new_v4(), body, SystemTime::now())
                .unwrap();
        }
        let stopped = Cancellation::default();

        // The server is unavailable for the second entry, which stays queued.
        let (origin, server) = stub_server(vec![202, 503]);
        assert!(flush(&stub_client(&origin), &stopped, &queue).is_err());
        assert_eq!(
            server.join().unwrap(),
            [br#"{"n":1}"#.to_vec(), br#"{"n":2}"#.to_vec()]
        );
        assert_eq!(lock(&queue).ready().unwrap().health().unwrap().entries, 1);

        // A later flush finds the server back, and a repeat answered as a duplicate counts.
        let (origin, server) = stub_server(vec![200]);
        flush(&stub_client(&origin), &stopped, &queue).unwrap();
        assert_eq!(server.join().unwrap(), [br#"{"n":2}"#.to_vec()]);
        assert_eq!(lock(&queue).ready().unwrap().health().unwrap().entries, 0);
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn flush_delivers_observations_before_a_capped_share_of_telemetry() {
        let state = std::env::temp_dir().join(format!("renga-telemetry-{}", uuid::Uuid::new_v4()));
        let queue = Mutex::new(DeliveryQueue::new(state.clone()));
        let enqueue = |telemetry: bool, body: &[u8]| {
            let mut delivery = lock(&queue);
            let queue = if telemetry {
                delivery.telemetry_ready()
            } else {
                delivery.ready()
            };
            queue
                .unwrap()
                .enqueue(uuid::Uuid::new_v4(), body, SystemTime::now())
                .unwrap();
        };
        for n in 1..=3 {
            enqueue(true, format!(r#"{{"t":{n}}}"#).as_bytes());
        }
        enqueue(false, br#"{"o":1}"#);
        let stopped = Cancellation::default();

        // An observation the server cannot take holds every telemetry batch back.
        let (origin, server) = stub_server(vec![503]);
        assert!(flush(&stub_client(&origin), &stopped, &queue).is_err());
        assert_eq!(server.join().unwrap(), [br#"{"o":1}"#.to_vec()]);

        // Then the observation goes first, and telemetry stops at its per-flush share.
        let (origin, server) = stub_server(vec![202, 202, 202]);
        flush(&stub_client(&origin), &stopped, &queue).unwrap();
        assert_eq!(
            server.join().unwrap(),
            [
                br#"{"o":1}"#.to_vec(),
                br#"{"t":1}"#.to_vec(),
                br#"{"t":2}"#.to_vec()
            ]
        );
        let telemetry = lock(&queue).monitors.telemetry.latest().unwrap();
        assert_eq!(telemetry.entries, 1);

        let (origin, server) = stub_server(vec![202]);
        flush(&stub_client(&origin), &stopped, &queue).unwrap();
        assert_eq!(server.join().unwrap(), [br#"{"t":3}"#.to_vec()]);
        assert!(state.join("telemetry").is_dir());
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn flush_replays_documented_telemetry_and_drops_a_batch_whose_collector_kind_conflicts() {
        let state = std::env::temp_dir().join(format!("renga-telemetry-{}", uuid::Uuid::new_v4()));
        let queue = Mutex::new(DeliveryQueue::new(state.clone()));
        let fixture: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../test/fixtures/openapi/accepted_telemetry.json"
        ))
        .unwrap();
        let bodies: Vec<Vec<u8>> = fixture
            .iter()
            .map(|batch| serde_json::to_vec(batch).unwrap())
            .collect();
        for body in &bodies {
            lock(&queue)
                .telemetry_ready()
                .unwrap()
                .enqueue(uuid::Uuid::new_v4(), body, SystemTime::now())
                .unwrap();
        }
        let stopped = Cancellation::default();
        let wrong_kind = r#"{"status":"rejected","errors":[{"path":"collector.kind","message":"does not match the collector's kind"}]}"#;

        // A batch for a collector whose stream has another kind can never be delivered, so it
        // is dropped and the next batch still goes, byte for byte.
        let (origin, server) = stub_responses(vec![(409, wrong_kind), (202, "")]);
        flush(&stub_client(&origin), &stopped, &queue).unwrap();
        assert_eq!(server.join().unwrap(), bodies);
        assert_eq!(
            lock(&queue)
                .telemetry_ready()
                .unwrap()
                .health()
                .unwrap()
                .entries,
            0
        );
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_flush_waits_for_a_running_inventory_instead_of_skipping_an_interval() {
        assert_eq!(next_flush(None), QUEUE_FLUSH_INTERVAL);
        assert_eq!(next_flush(Some(DeliveryTask::Flush)), QUEUE_FLUSH_INTERVAL);
        assert_eq!(next_flush(Some(DeliveryTask::Inventory)), FLUSH_DEFER);

        // With both due at once, inventory takes the worker first and the flush comes due
        // again as soon as the deferral passes, not a whole flush interval later.
        let start = Instant::now();
        let mut scheduler = Scheduler::new(
            start,
            Duration::from_secs(600),
            Duration::from_secs(120),
            Duration::from_secs(600),
            Duration::from_secs(120),
        );
        let due = start + Duration::from_secs(120);
        assert_eq!(scheduler.due(due), [Job::Inventory, Job::Flush]);
        scheduler.reschedule(Job::Inventory, due, Duration::from_secs(120));
        scheduler.reschedule(Job::Flush, due, next_flush(Some(DeliveryTask::Inventory)));
        assert_eq!(scheduler.due(due + FLUSH_DEFER), [Job::Flush]);
    }

    #[test]
    fn cancellation_while_the_queue_is_busy_exits_without_enqueuing_or_posting() {
        let state = std::env::temp_dir().join(format!("renga-busy-{}", uuid::Uuid::new_v4()));
        let queue = Arc::new(Mutex::new(DeliveryQueue::new(state.clone())));
        let held = lock(&queue);
        let operation = Cancellation::default();
        let worker_operation = operation.clone();
        let worker_queue = Arc::clone(&queue);
        let (finished, result) = std::sync::mpsc::channel();
        let worker = thread::spawn(move || {
            let outcome = deliver_observation(
                &stub_client("http://127.0.0.1:9"),
                &worker_operation,
                &worker_queue,
                uuid::Uuid::new_v4(),
                br#"{"observation_id":"not-posted"}"#,
            )
            .map_err(|error| error.to_string());
            finished.send(outcome).unwrap();
        });
        thread::sleep(Duration::from_millis(50));

        operation.cancel();
        let error = result
            .recv_timeout(Duration::from_millis(500))
            .expect("cancelled inventory should not wait for queue ownership")
            .unwrap_err();

        assert!(error.contains("cancelled"));
        drop(held);
        worker.join().unwrap();
        assert_eq!(lock(&queue).ready().unwrap().health().unwrap().entries, 0);
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn job_deadline_stops_queue_wait_while_heartbeat_is_blocked() {
        let state = std::env::temp_dir().join(format!("renga-deadline-{}", uuid::Uuid::new_v4()));
        let queue = Arc::new(Mutex::new(DeliveryQueue::new(state.clone())));
        let held = lock(&queue);
        let client = stub_client("http://127.0.0.1:9");
        let observation_id = uuid::Uuid::new_v4();
        let capability_queue = Arc::clone(&queue);
        let capability_client = client.clone();
        let capability = InventoryCollect::new(Box::new(move |cancellation| {
            deliver_observation(
                &capability_client,
                cancellation,
                &capability_queue,
                observation_id,
                br#"{"observation_id":"must-not-be-queued"}"#,
            )
            .map_err(|error| error.to_string())
        }));
        let catalog = Catalog::new(vec![Arc::new(capability)]);
        let (progress_started, progress) = mpsc::channel();
        let api = SlowHeartbeatApi {
            lease: Mutex::new(Some(LeasedJob {
                id: uuid::Uuid::new_v4(),
                capability: "inventory.collect@1".into(),
                parameters: json!({}),
                attempt: 1,
                lease_token: "token".into(),
                lease_expires_at: chrono::Utc::now(),
                timeout_ms: 60,
                output_limit_bytes: 65_536,
            })),
            reports: Mutex::new(Vec::new()),
            progress_started: Mutex::new(Some(progress_started)),
        };
        let stopped = Cancellation::default();
        let policy = JobPolicy::default();
        let generation = PolicyGeneration::default();

        thread::scope(|scope| {
            let worker = scope.spawn(|| {
                let mut worker = Worker::new(
                    &api,
                    &catalog,
                    &policy,
                    &state,
                    &stopped,
                    &generation,
                    generation.current(),
                );
                worker.heartbeat = Duration::from_millis(10);
                worker.run_pass().unwrap();
            });
            progress
                .recv_timeout(Duration::from_secs(1))
                .expect("worker should begin its heartbeat while inventory waits");
            thread::sleep(Duration::from_millis(70));
            drop(held);
            worker.join().unwrap();
        });

        assert_eq!(
            *api.reports.lock().unwrap(),
            [
                ReportType::Started,
                ReportType::Progress,
                ReportType::Failed
            ]
        );
        assert_eq!(lock(&queue).ready().unwrap().health().unwrap().entries, 0);
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn an_unavailable_queue_does_not_stop_startup_and_recovers_on_delivery_work() {
        let state = std::env::temp_dir().join(format!("renga-degraded-{}", uuid::Uuid::new_v4()));
        let identity = renga_agent::identity::load_or_create(&state, None).unwrap();
        std::fs::write(state.join("observations"), b"not a directory").unwrap();
        let (origin, server) = stub_server(vec![200, 202]);
        // A persisted home answers without asking the stub, which serves only intake routes.
        std::fs::write(
            state.join("home.json"),
            json!({
                "renga_url": origin,
                "deployment": "",
                "home": format!("{origin}/"),
                "resolved_at": "2026-10-21T00:00:00Z"
            })
            .to_string(),
        )
        .unwrap();
        let config = state.join("agent.toml");
        std::fs::write(&config, format!(
            "renga_url = {origin:?}\nallow_insecure_http = true\nintake_api_key = \"test-token\"\nmax_retry_attempts = 1\n"
        )).unwrap();

        run_configured(
            Args {
                config,
                state_directory: state.clone(),
                once: true,
                dry_run: false,
                command: None,
            },
            Cancellation::default(),
        )
        .unwrap();
        let bodies = server.join().unwrap();
        assert_eq!(bodies.len(), 2);
        let checkin: serde_json::Value = serde_json::from_slice(&bodies[0]).unwrap();
        let observation: serde_json::Value = serde_json::from_slice(&bodies[1]).unwrap();
        assert!(checkin["capabilities"].is_array());
        assert!(observation["observation_id"].is_string());
        assert_eq!(
            renga_agent::identity::load_or_create(&state, None).unwrap(),
            identity
        );

        // The same degraded runtime opens the queue after the operator repairs the path.
        let queue = Mutex::new(DeliveryQueue::new(state.clone()));
        let monitor = lock(&queue).monitors.observations.clone();
        assert!(monitor.latest().is_none());
        std::fs::remove_file(state.join("observations")).unwrap();
        let (origin, server) = stub_server(vec![202]);
        send_inventory(
            &stub_client(&origin),
            &Cancellation::default(),
            &BTreeMap::new(),
            &queue,
        )
        .unwrap();
        assert_eq!(server.join().unwrap().len(), 1);
        assert_eq!(lock(&queue).ready().unwrap().health().unwrap().entries, 0);
        assert_eq!(monitor.latest().unwrap().entries, 0);
        assert!(state.join("observations").is_dir());
        std::fs::remove_dir_all(state).unwrap();
    }

    struct FakeOperations {
        calls: RefCell<Vec<&'static str>>,
        checkin_fails: bool,
        inventory_fails: bool,
    }

    impl Operations for FakeOperations {
        fn checkin(&self) -> Result<(), Box<dyn Error>> {
            self.calls.borrow_mut().push("check-in");
            if self.checkin_fails {
                Err(io::Error::other("check-in unavailable").into())
            } else {
                Ok(())
            }
        }
        fn inventory(&self) -> Result<(), Box<dyn Error>> {
            self.calls.borrow_mut().push("inventory");
            if self.inventory_fails {
                Err(io::Error::other("inventory unavailable").into())
            } else {
                Ok(())
            }
        }
    }

    fn fake(checkin_fails: bool, inventory_fails: bool) -> FakeOperations {
        FakeOperations {
            calls: RefCell::new(Vec::new()),
            checkin_fails,
            inventory_fails,
        }
    }

    #[test]
    fn leases_unless_renga_says_nothing_is_waiting() {
        let ack = |jobs_waiting| {
            Ok(CheckInAck {
                jobs_waiting,
                ..CheckInAck::default()
            })
        };
        assert!(leases_now(&ack(Some(true))));
        assert!(!leases_now(&ack(Some(false))));
        assert!(leases_now(&ack(None)), "an older server gives no hint");
        assert!(leases_now(&Err(io::Error::other("offline").into())));
    }

    #[test]
    fn advertises_inventory_collect_unless_policy_disables_it() {
        let state = std::env::temp_dir().join(format!("renga-advertise-{}", uuid::Uuid::new_v4()));
        let queue = Arc::new(Mutex::new(DeliveryQueue::new(state.clone())));
        let client = stub_client("http://127.0.0.1:9");
        let mut config = stub_config("http://127.0.0.1:9");
        assert!(advertised_capabilities(&config, &client, &queue)
            .contains(&"inventory.collect@1".to_string()));

        config.jobs = JobPolicy {
            enabled: Some(vec![]),
        };
        assert!(!advertised_capabilities(&config, &client, &queue)
            .iter()
            .any(|capability| capability.contains('@')));
        let _ = std::fs::remove_dir_all(state);
    }

    #[test]
    fn checkin_failure_does_not_prevent_inventory_attempt() {
        let operations = fake(true, false);
        assert_eq!(deliver_startup(&operations).len(), 1);
        assert_eq!(*operations.calls.borrow(), ["check-in", "inventory"]);
    }

    #[test]
    fn inventory_failure_does_not_prevent_daemon_scheduling() {
        let operations = fake(false, true);
        let failures = deliver_startup(&operations);
        assert_eq!(failures.len(), 1);
        let scheduler = Scheduler::new(
            Instant::now(),
            Duration::from_secs(1),
            Duration::from_secs(1),
            Duration::from_secs(1),
            QUEUE_FLUSH_INTERVAL,
        );
        assert!(scheduler.wait(Instant::now()) <= Duration::from_secs(1));
    }

    #[test]
    fn once_attempts_both_and_reports_all_failures() {
        let operations = fake(true, true);
        let error = aggregated_result(deliver_startup(&operations))
            .unwrap_err()
            .to_string();
        assert_eq!(*operations.calls.borrow(), ["check-in", "inventory"]);
        assert!(error.contains("check-in unavailable") && error.contains("inventory unavailable"));
    }

    #[test]
    fn cancellation_handle_is_shared_with_configured_startup() {
        let installed_handler_state = Cancellation::default();
        let delivery_state = installed_handler_state.clone();
        installed_handler_state.cancel();

        assert!(delivery_state.cancelled());
    }
}
