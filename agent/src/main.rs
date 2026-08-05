use clap::Parser;
use renga_agent::{
    collectors::linux,
    config::Config,
    payload::{CheckIn, Observation},
    scheduler::{Job, Scheduler},
    transport::HttpClient,
};
use std::{
    error::Error,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "renga-agent", version, about = "Renga Linux inventory agent")]
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
        let observation = Observation::new(linux::collect()?);
        println!("{}", serde_json::to_string_pretty(&observation)?);
        return Ok(());
    }

    let mut config = Config::load(&args.config)?;
    let mut client = HttpClient::new(&config)?;
    send_checkin(&client, &config)?;
    send_inventory(&client)?;
    if args.once {
        return Ok(());
    }

    let stopped = Arc::new(AtomicBool::new(false));
    let signal_flag = Arc::clone(&stopped);
    ctrlc::set_handler(move || signal_flag.store(true, Ordering::SeqCst))?;
    let now = Instant::now();
    let mut scheduler = Scheduler::new(
        now,
        config.checkin_interval,
        config.inventory_interval,
        config.config_refresh_interval,
    );
    info!("daemon started");

    while !stopped.load(Ordering::SeqCst) {
        let now = Instant::now();
        for job in scheduler.due(now) {
            match job {
                Job::CheckIn => {
                    if let Err(failure) = send_checkin(&client, &config) {
                        warn!(error = %failure, "check-in failed");
                    }
                    scheduler.reschedule(job, Instant::now(), config.checkin_interval);
                }
                Job::Inventory => {
                    if let Err(failure) = send_inventory(&client) {
                        warn!(error = %failure, "inventory failed");
                    }
                    scheduler.reschedule(job, Instant::now(), config.inventory_interval);
                }
                Job::Reload => {
                    let old_checkin_interval = config.checkin_interval;
                    let old_inventory_interval = config.inventory_interval;
                    match reload(&args.config) {
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
    client.post_checkin(&CheckIn::new(config.installation_id))?;
    info!("check-in posted");
    Ok(())
}

fn send_inventory(client: &HttpClient) -> Result<(), Box<dyn Error>> {
    let observation = Observation::new(linux::collect()?);
    client.post_observation(&observation)?;
    info!(observation_id = %observation.observation_id, "observation posted");
    Ok(())
}

fn reload(path: &PathBuf) -> Result<(Config, HttpClient), Box<dyn Error>> {
    let config = Config::load(path)?;
    let client = HttpClient::new(&config)?;
    Ok((config, client))
}
