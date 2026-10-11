use clap::Parser;
use renga_agent::{
    cancellation::Cancellation,
    collectors,
    config::Config,
    payload::{CheckIn, Observation},
    queue::{Drained, ObservationQueue, QueueLimits},
    scheduler::{Job, Scheduler},
    transport::{encode_observation, FailureKind, HttpClient},
};
use std::{
    collections::BTreeMap,
    error::Error,
    path::PathBuf,
    sync::{Arc, Mutex, MutexGuard, PoisonError},
    thread,
    time::{Duration, Instant, SystemTime},
};
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

/// How often the daemon retries observations left in the queue by a failed delivery.
const QUEUE_FLUSH_INTERVAL: Duration = Duration::from_secs(120);
/// How long an inventory waits for a queue flush already using the delivery worker.
const INVENTORY_DEFER: Duration = Duration::from_secs(1);

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
}

fn main() {
    tracing_subscriber::fmt()
        .json()
        .with_writer(std::io::stderr)
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
    if let Err(failure) = run(Args::parse()) {
        error!(error = %failure, "agent failed");
        std::process::exit(1);
    }
}

fn run(args: Args) -> Result<(), Box<dyn Error>> {
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

fn install_shutdown_handler() -> Result<Cancellation, ctrlc::Error> {
    let stopped = Cancellation::default();
    let signal_flag = stopped.clone();
    ctrlc::set_handler(move || signal_flag.cancel())?;
    Ok(stopped)
}

fn run_configured(args: Args, stopped: Cancellation) -> Result<(), Box<dyn Error>> {
    let mut config = Config::load(&args.config, &args.state_directory)?;
    let mut client = HttpClient::new(&config, stopped.clone())?;
    let queue = Arc::new(Mutex::new(ObservationQueue::open(
        &args.state_directory,
        QueueLimits::default(),
    )?));
    // Anchor periodic deadlines before startup work so a slow startup check-in cannot postpone
    // the first lease renewal by another full check-in interval.
    let scheduler_epoch = Instant::now();
    if args.once {
        let operations = RuntimeOperations {
            client: &client,
            stopped: &stopped,
            labels: &config.labels,
            queue: &queue,
        };
        return aggregated_result(deliver_startup(&operations));
    }
    if let Err(failure) = send_checkin(&client) {
        warn!(error = %failure, "startup delivery failed: check-in");
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
                    if let Err(failure) = send_checkin(&client) {
                        warn!(error = %failure, "check-in failed");
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
        let wait = scheduler
            .wait(Instant::now())
            .min(Duration::from_millis(250));
        thread::sleep(wait);
    }
    if let Some(worker) = delivery_worker {
        let _ = worker.handle.join();
    }
    info!("daemon stopped");
    Ok(())
}

fn send_checkin(client: &HttpClient) -> Result<(), Box<dyn Error>> {
    client.post_checkin(&CheckIn::new(collectors::capabilities()))?;
    info!("check-in posted");
    Ok(())
}

fn spawn_inventory(
    worker: &mut Option<DeliveryWorker>,
    client: &HttpClient,
    stopped: &Cancellation,
    config: &Config,
    queue: &Arc<Mutex<ObservationQueue>>,
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
    queue: &Mutex<ObservationQueue>,
) -> Result<(), Box<dyn Error>> {
    let observation = Observation::new(collectors::collect(stopped)?).with_labels(labels);
    let observation_id = observation.observation_id;
    let body = encode_observation(&observation)?;
    let mut queue = lock(queue);
    if let Err(failure) = queue.enqueue(observation_id, &body, SystemTime::now()) {
        // Delivering without durability still beats losing this observation outright. The
        // server keeps its newest observation current, so overtaking older entries is safe.
        warn!(error = %failure, %observation_id, "cannot queue observation; delivering it directly");
        client.post_encoded_observation(&body)?;
        info!(%observation_id, "observation posted");
        return Ok(());
    }

    let mut outcome = None;
    let drained = queue.drain(SystemTime::now(), stopped, |entry| {
        let result = client.post_encoded_observation(entry);
        if entry == body.as_slice() {
            outcome = Some(result.clone());
        }
        result
    })?;
    report_queue(&queue, &drained);
    match outcome {
        Some(Ok(())) => {
            info!(%observation_id, "observation posted");
            Ok(())
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
    queue: &Mutex<ObservationQueue>,
) -> Result<(), Box<dyn Error>> {
    let mut queue = lock(queue);
    let drained = queue.drain(SystemTime::now(), stopped, |entry| {
        client.post_encoded_observation(entry)
    })?;
    report_queue(&queue, &drained);
    match drained.blocked {
        Some(error) if !error.is_cancelled() => Err(error.into()),
        _ => Ok(()),
    }
}

/// Logs queue health whenever a pass changed or left anything, so an outage's backlog is
/// visible in the agent's logs until it clears.
fn report_queue(queue: &ObservationQueue, drained: &Drained) {
    let health = match queue.health(SystemTime::now()) {
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
        oldest_queued_seconds = health.oldest_age.map(|age| age.as_secs()),
        dropped_for_space = health.counters.dropped_for_space,
        expired = health.counters.expired,
        rejected_total = health.counters.rejected,
        unreadable = health.counters.unreadable,
        "observation queue"
    );
}

/// The queue holds no invariant a panicking holder could break mid-update: every entry change
/// is a single file operation.
fn lock(queue: &Mutex<ObservationQueue>) -> MutexGuard<'_, ObservationQueue> {
    queue.lock().unwrap_or_else(PoisonError::into_inner)
}

trait Operations {
    fn checkin(&self) -> Result<(), Box<dyn Error>>;
    fn inventory(&self) -> Result<(), Box<dyn Error>>;
}

struct RuntimeOperations<'a> {
    client: &'a HttpClient,
    stopped: &'a Cancellation,
    labels: &'a BTreeMap<String, String>,
    queue: &'a Mutex<ObservationQueue>,
}

impl Operations for RuntimeOperations<'_> {
    fn checkin(&self) -> Result<(), Box<dyn Error>> {
        send_checkin(self.client)
    }
    fn inventory(&self) -> Result<(), Box<dyn Error>> {
        send_inventory(self.client, self.stopped, self.labels, self.queue)
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
    use std::{
        cell::RefCell,
        io::{self, BufRead, BufReader, Read, Write},
        net::TcpListener,
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

    fn stub_client(origin: &str) -> HttpClient {
        let config = Config {
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
        };
        HttpClient::new(&config, Cancellation::default()).unwrap()
    }

    #[test]
    fn flush_replays_queued_bodies_exactly_and_keeps_what_the_server_could_not_take() {
        let state = std::env::temp_dir().join(format!("renga-flush-{}", uuid::Uuid::new_v4()));
        let queue = Mutex::new(ObservationQueue::open(&state, QueueLimits::default()).unwrap());
        for body in [&br#"{"n":1}"#[..], br#"{"n":2}"#] {
            lock(&queue)
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
        assert_eq!(lock(&queue).health(SystemTime::now()).unwrap().entries, 1);

        // A later flush finds the server back, and a repeat answered as a duplicate counts.
        let (origin, server) = stub_server(vec![200]);
        flush(&stub_client(&origin), &stopped, &queue).unwrap();
        assert_eq!(server.join().unwrap(), [br#"{"n":2}"#.to_vec()]);
        assert_eq!(lock(&queue).health(SystemTime::now()).unwrap().entries, 0);
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
