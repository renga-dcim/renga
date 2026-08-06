//! Bounded, cancellation-aware execution for optional collector commands.

use crate::cancellation::Cancellation;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::{
    io::{self, Read},
    process::{Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};

pub const COLLECTOR_COMMAND_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_OUTPUT_BYTES: u64 = 256 * 1024;
const POLL_INTERVAL: Duration = Duration::from_millis(10);

#[derive(Debug)]
pub struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
}

pub fn run(command: &mut Command, cancellation: &Cancellation) -> io::Result<Output> {
    run_with_timeout(command, cancellation, COLLECTOR_COMMAND_TIMEOUT)
}

fn run_with_timeout(
    command: &mut Command,
    cancellation: &Cancellation,
    timeout: Duration,
) -> io::Result<Output> {
    if cancellation.cancelled() {
        return Err(io::Error::new(io::ErrorKind::Interrupted, "agent stopping"));
    }
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let stdout = child.stdout.take().expect("piped stdout");
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout
            .take(MAX_OUTPUT_BYTES)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    });
    let started = Instant::now();
    let status = loop {
        if cancellation.cancelled() || started.elapsed() >= timeout {
            terminate_command_tree(&mut child);
            let _ = child.wait();
            let _ = reader.join();
            let message = if cancellation.cancelled() {
                "agent stopping"
            } else {
                "command timed out"
            };
            return Err(io::Error::new(
                if cancellation.cancelled() {
                    io::ErrorKind::Interrupted
                } else {
                    io::ErrorKind::TimedOut
                },
                message,
            ));
        }
        if let Some(status) = child.try_wait()? {
            break status;
        }
        thread::sleep(POLL_INTERVAL);
    };
    // A short-lived collector must not leave descendants holding its output pipe open.
    terminate_command_tree(&mut child);
    let stdout = reader
        .join()
        .map_err(|_| io::Error::other("output reader panicked"))??;
    Ok(Output { status, stdout })
}

fn terminate_command_tree(child: &mut std::process::Child) {
    #[cfg(unix)]
    // SAFETY: the child was placed in a process group whose ID is its PID. A negative PID asks
    // kill(2) to signal only that group; failures are best-effort because it may already be gone.
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    #[cfg(not(unix))]
    let _ = child.kill();
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn quick_command_succeeds() {
        let output = run_with_timeout(
            Command::new("sh").args(["-c", "printf ok"]),
            &Cancellation::default(),
            Duration::from_secs(1),
        )
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"ok");
    }

    #[test]
    fn command_times_out() {
        let error = run_with_timeout(
            Command::new("sh").args(["-c", "sleep 5"]),
            &Cancellation::default(),
            Duration::from_millis(40),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }

    #[test]
    fn successful_parent_does_not_wait_for_descendant_inheriting_stdout() {
        let started = Instant::now();
        let output = run_with_timeout(
            Command::new("sh").args(["-c", "sleep 5 &"]),
            &Cancellation::default(),
            Duration::from_millis(200),
        )
        .unwrap();

        assert!(output.status.success());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn cancellation_before_and_during_execution_interrupts() {
        let stopped = Cancellation::default();
        stopped.cancel();
        assert_eq!(
            run(Command::new("sh").arg("-c").arg("exit 0"), &stopped)
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );

        let stopped = Cancellation::default();
        let trigger = stopped.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            trigger.cancel();
        });
        let error = run_with_timeout(
            Command::new("sh").args(["-c", "sleep 5"]),
            &stopped,
            Duration::from_secs(1),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
    }
}
