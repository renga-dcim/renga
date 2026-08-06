use clap::Parser;
use renga_agent::{
    cancellation::Cancellation,
    collectors,
    config::Config,
    payload::{CheckIn, Observation},
    scheduler::{Job, Scheduler},
    transport::HttpClient,
};
use std::{
    error::Error,
    path::PathBuf,
    thread,
    time::{Duration, Instant},
};
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "renga-agent", version, about = "Renga host inventory agent")]
struct Args {
    #[arg(long, default_value = "/etc/renga/agent.toml")]
    config: PathBuf,
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
    let mut config = Config::load(&args.config)?;
    let mut client = HttpClient::new(&config, stopped.clone())?;
    let operations = RuntimeOperations {
        client: &client,
        config: &config,
        stopped: &stopped,
    };
    let startup_failures = deliver_startup(&operations);
    if args.once {
        return aggregated_result(startup_failures);
    }
    for failure in startup_failures {
        warn!(error = %failure, "startup delivery failed");
    }
    if stopped.cancelled() {
        return Ok(());
    }

    let now = Instant::now();
    let mut scheduler = Scheduler::new(
        now,
        config.checkin_interval,
        config.inventory_interval,
        config.config_refresh_interval,
    );
    info!("daemon started");

    while !stopped.cancelled() {
        let now = Instant::now();
        for job in scheduler.due_until_cancelled(now, &stopped) {
            match job {
                Job::CheckIn => {
                    if let Err(failure) = send_checkin(&client, &config) {
                        warn!(error = %failure, "check-in failed");
                    }
                    scheduler.reschedule(job, Instant::now(), config.checkin_interval);
                }
                Job::Inventory => {
                    if let Err(failure) = send_inventory(&client, &stopped) {
                        warn!(error = %failure, "inventory failed");
                    }
                    scheduler.reschedule(job, Instant::now(), config.inventory_interval);
                }
                Job::Reload => {
                    let old_checkin_interval = config.checkin_interval;
                    let old_inventory_interval = config.inventory_interval;
                    match reload(&args.config, stopped.clone()) {
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
    info!("daemon stopped");
    Ok(())
}

fn send_checkin(client: &HttpClient, config: &Config) -> Result<(), Box<dyn Error>> {
    client.post_checkin(&CheckIn::new(
        config.installation_id,
        collectors::capabilities(),
    ))?;
    info!("check-in posted");
    Ok(())
}

fn send_inventory(client: &HttpClient, stopped: &Cancellation) -> Result<(), Box<dyn Error>> {
    let observation = Observation::new(collectors::collect(stopped)?);
    client.post_observation(&observation)?;
    info!(observation_id = %observation.observation_id, "observation posted");
    Ok(())
}

trait Operations {
    fn checkin(&self) -> Result<(), Box<dyn Error>>;
    fn inventory(&self) -> Result<(), Box<dyn Error>>;
}

struct RuntimeOperations<'a> {
    client: &'a HttpClient,
    config: &'a Config,
    stopped: &'a Cancellation,
}

impl Operations for RuntimeOperations<'_> {
    fn checkin(&self) -> Result<(), Box<dyn Error>> {
        send_checkin(self.client, self.config)
    }
    fn inventory(&self) -> Result<(), Box<dyn Error>> {
        send_inventory(self.client, self.stopped)
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
    cancellation: Cancellation,
) -> Result<(Config, HttpClient), Box<dyn Error>> {
    let config = Config::load(path)?;
    let client = HttpClient::new(&config, cancellation)?;
    Ok((config, client))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, io};

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
