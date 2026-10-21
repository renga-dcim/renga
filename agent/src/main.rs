use clap::{Parser, Subcommand};
use renga_agent::{
    cancellation::Cancellation,
    collectors,
    config::Config,
    installation_key::InstallationKey,
    jobs::{
        inventory_collect::InventoryCollect,
        worker::{PolicyGeneration, Worker},
        Catalog, JobPolicy,
    },
    logging,
    notices::{Listener, Notices},
    payload::{
        CheckIn, CheckInAck, KeyApproval, KeyStatus, Observation, PresentedKey, QueueReport,
    },
    queue::{Drained, ObservationQueue, QueueError, QueueLimits, QueueMonitor},
    scheduler::{Job, Scheduler},
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

/// How often the daemon retries observations left in the queue by a failed delivery.
const QUEUE_FLUSH_INTERVAL: Duration = Duration::from_secs(120);
/// How long an inventory waits for a queue flush already using the delivery worker.
const INVENTORY_DEFER: Duration = Duration::from_secs(1);
/// Queue ownership is polled so a cancelled job never waits behind a long flush.
const QUEUE_LOCK_POLL: Duration = Duration::from_millis(25);

/// Queue failure degrades durability, not lease renewal or direct delivery. Only delivery
/// work retries opening it, so filesystem recovery cannot hold up periodic check-ins.
struct DeliveryQueue {
    state_directory: PathBuf,
    queue: Option<ObservationQueue>,
    monitor: QueueMonitor,
}

impl DeliveryQueue {
    fn new(state_directory: PathBuf) -> Self {
        let mut delivery = Self {
            state_directory,
            queue: None,
            monitor: QueueMonitor::default(),
        };
        if let Err(error) = delivery.ready() {
            warn!(%error, "cannot open observation queue; using direct delivery until it recovers");
        }
        delivery
    }

    fn ready(&mut self) -> Result<&mut ObservationQueue, QueueError> {
        if self.queue.is_none() {
            self.queue = Some(ObservationQueue::open(
                &self.state_directory,
                QueueLimits::default(),
                self.monitor.clone(),
            )?);
        }
        Ok(self.queue.as_mut().unwrap())
    }
}

/// Work running on the delivery thread, which owns the observation queue while it runs.
#[derive(Clone, Copy, PartialEq, Eq)]
enum DeliveryTask {
    Inventory,
    Flush,
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
    let installation_key = InstallationKey::load_or_create(&args.state_directory)?;
    info!(fingerprint = %installation_key.fingerprint(), "installation key loaded");
    let presented_key = PresentedKey::ed25519(installation_key.public_key());
    let mut client = HttpClient::new(&config, stopped.clone())?;
    let queue = DeliveryQueue::new(args.state_directory.clone());
    let monitor = queue.monitor.clone();
    let queue = Arc::new(Mutex::new(queue));
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
            monitor: &monitor,
            presented_key: &presented_key,
        };
        return aggregated_result(deliver_startup(&operations));
    }
    let checkin = send_checkin(
        &client,
        &monitor,
        advertised_capabilities(&config, &client, &queue),
        &presented_key,
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
    info!("daemon started");

    while !stopped.cancelled() {
        let now = Instant::now();
        for job in scheduler.due_until_cancelled(now, &stopped) {
            match job {
                Job::CheckIn => {
                    let checkin = send_checkin(
                        &client,
                        &monitor,
                        advertised_capabilities(&config, &client, &queue),
                        &presented_key,
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
                    // A running inventory drains the queue itself.
                    if DeliveryWorker::running(&delivery_worker).is_none() {
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
                    scheduler.reschedule(job, Instant::now(), QUEUE_FLUSH_INTERVAL);
                }
                Job::Reload => {
                    let old_checkin_interval = config.checkin_interval;
                    let old_inventory_interval = config.inventory_interval;
                    match reload(&args.config, &args.state_directory, stopped.clone()) {
                        Ok((new_config, new_client)) => {
                            config = new_config;
                            client = new_client;
                            policy_generation.advance();
                            // The socket carries the old credentials and policy.
                            if let Some(previous) = listener.take() {
                                previous.stop();
                            }
                            listener = start_listener(&client, &config, &queue, &notices, &stopped);
                            scheduler.refresh_intervals(
                                Instant::now(),
                                old_checkin_interval,
                                config.checkin_interval,
                                old_inventory_interval,
                                config.inventory_interval,
                            );
                            info!("configuration reloaded");
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
    if let Some(listener) = listener {
        listener.stop();
    }
    if let Some(worker) = delivery_worker {
        let _ = worker.handle.join();
    }
    if let Some(worker) = job_worker {
        let _ = worker.join();
    }
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
    Catalog::new(vec![Arc::new(InventoryCollect::new(Box::new(collect)))])
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
    monitor: &QueueMonitor,
    capabilities: Vec<String>,
    presented_key: &PresentedKey,
) -> Result<CheckInAck, Box<dyn Error>> {
    let queue = monitor
        .latest()
        .map(|health| QueueReport::new(&health, SystemTime::now()));
    let checkin = CheckIn::new(capabilities, queue).with_installation_key(presented_key.clone());
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

/// Retries whatever is queued, oldest first.
fn flush(
    client: &HttpClient,
    stopped: &Cancellation,
    queue: &Mutex<DeliveryQueue>,
) -> Result<(), Box<dyn Error>> {
    let mut delivery = lock(queue);
    let queue = delivery.ready()?;
    let drained = queue.drain(SystemTime::now(), stopped, |entry| {
        client.post_encoded_observation(entry)
    })?;
    report_queue(queue, &drained);
    match drained.blocked {
        Some(error) if !error.is_cancelled() => Err(error.into()),
        _ => Ok(()),
    }
}

/// Logs queue health whenever a pass changed or left anything, so an outage's backlog is
/// visible in the agent's logs until it clears.
fn report_queue(queue: &ObservationQueue, drained: &Drained) {
    let health = match queue.health() {
        Ok(health) => health,
        Err(error) => {
            warn!(%error, "cannot read observation queue health");
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
        "observation queue"
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
    monitor: &'a QueueMonitor,
    presented_key: &'a PresentedKey,
}

impl Operations for RuntimeOperations<'_> {
    fn checkin(&self) -> Result<(), Box<dyn Error>> {
        send_checkin(
            self.client,
            self.monitor,
            self.capabilities.clone(),
            self.presented_key,
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

fn reload(
    path: &PathBuf,
    state_directory: &PathBuf,
    cancellation: Cancellation,
) -> Result<(Config, HttpClient), Box<dyn Error>> {
    let config = Config::load(path, state_directory)?;
    let client = HttpClient::new(&config, cancellation)?;
    Ok((config, client))
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine};
    use renga_agent::{
        jobs::{inventory_collect::InventoryCollect, worker::JobApi},
        payload::{JobReport, LeasedJob, ReportAck, ReportType},
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
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            statuses
                .into_iter()
                .map(|status| {
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
                        "HTTP/1.1 {status} Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    )
                    .unwrap();
                    body
                })
                .collect()
        });
        (origin, server)
    }

    fn read_http_request(stream: TcpStream) -> (String, BufReader<TcpStream>) {
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
        (request_line, reader)
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
                            if request.contains("/api/v1/agent/checkins") {
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
                            if request.contains("/api/v1/agent/checkins") {
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
                            if request.contains("/api/v1/agent/checkins") {
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
        let monitor = lock(&queue).monitor.clone();
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
