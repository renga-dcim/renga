# Renga host agent

The Renga agent is a cross-platform service with a Linux-first inventory backend.
It reads host facts and sends check-ins and observations to Renga over HTTP(S).
It does **not** provide a remote shell, execute server-supplied commands, or expose
a listening network service.

## Build and checks

From the repository root, build a development or optimized binary with:

```sh
cargo build -p renga-agent
cargo build --release -p renga-agent
```

Run the Rust checks with:

```sh
cargo fmt --check
cargo test --workspace
cargo clippy --workspace --all-features -- -D warnings
```

The repository-wide checks are `make lint` and `mix precommit`.

## Configuration

Copy [`dist/agent.toml.example`](dist/agent.toml.example) to
`/etc/renga/agent.toml`. Generate the installation identity once and keep it
stable across restarts and upgrades:

```sh
uuidgen
```

The example documents every key and its default. `renga_url`, `token`, and
`installation_id` are required. Environment variables override file values:

* `RENGA_URL`
* `RENGA_TOKEN`
* `RENGA_INSTALLATION_ID`
* `RENGA_INVENTORY_INTERVAL_SECONDS`
* `RENGA_CHECKIN_INTERVAL_SECONDS`
* `RENGA_CONFIG_REFRESH_INTERVAL_SECONDS`
* `RENGA_REQUEST_TIMEOUT_SECONDS`
* `RENGA_MAX_RETRY_ATTEMPTS`

`RUST_LOG` controls log filtering and defaults to `info`; it is not an agent
configuration field. The supplied unit optionally reads `/etc/renga/agent.env`,
which may contain `KEY=value` overrides. Keep the token out of shell history and
make configuration readable only by root and the service group:

```sh
sudo chown root:renga-agent /etc/renga/agent.toml
sudo chmod 0640 /etc/renga/agent.toml
sudo chown root:renga-agent /etc/renga/agent.env  # if used
sudo chmod 0640 /etc/renga/agent.env
```

`--dry-run` collects once and prints pretty JSON without loading configuration or
using the network. `--once` loads configuration, posts one check-in and one
inventory observation, then exits. With neither option the agent sends both at
startup, schedules periodic check-ins and inventory, and retries transient HTTP
failures with backoff. SIGTERM/SIGINT stops retry attempts and backoff promptly,
including during `--once`. A blocking request already in flight can continue up
to `request_timeout_seconds` before the process exits.

The daemon reloads the TOML file and environment overrides on the configured
refresh interval. A valid reload replaces transport and interval settings; an
invalid reload is logged and the last valid configuration remains active. There
is currently no signal-triggered reload, so edit the file atomically or restart
the service when an immediate change is required. Logs are structured JSON on
stderr; systemd records them in the journal.

## Debian/Ubuntu proof-of-concept service

These assets are operator examples, not a `.deb` package. The unit does not create
the user/group, install the binary, or create configuration. After building, an
operator can install them with:

```sh
sudo groupadd --system renga-agent
sudo useradd --system --gid renga-agent --home-dir /nonexistent \
  --no-create-home --shell /usr/sbin/nologin renga-agent
sudo install -o root -g root -m 0755 target/release/renga-agent /usr/bin/renga-agent
sudo install -d -o root -g renga-agent -m 0750 /etc/renga
sudo install -o root -g renga-agent -m 0640 agent/dist/agent.toml.example /etc/renga/agent.toml
# Replace all placeholders in /etc/renga/agent.toml before starting the service.
sudo install -o root -g root -m 0644 agent/dist/renga-agent.service /etc/systemd/system/renga-agent.service
sudo systemctl daemon-reload
sudo systemctl enable --now renga-agent.service
sudo journalctl -u renga-agent.service -f
```

The hardened unit allows outbound IPv4/IPv6, local sockets, and netlink while
leaving `/proc`, `/proc/sys`, and `/sys` readable for inventory. It grants no
capabilities and makes the host filesystem read-only to the service.
The example unit allows 40 seconds for shutdown, slightly above the default
30-second request timeout. If `request_timeout_seconds` is increased, operators
should increase `TimeoutStopSec` too; otherwise systemd may forcibly stop an
in-flight request when its 40-second limit expires.

## Collector scope, portability, and degradation

The currently implemented backend supports Linux. It reads hostname, OS/kernel,
architecture, machine and DMI identity, CPU, memory, block devices, filesystems,
interfaces, addresses, and basic virtualization hints from `/etc`, procfs, sysfs,
and the `hostname`/`ip` commands. Missing firmware files, utilities, permissions,
or unsupported kernel data generally omit the affected optional facts rather
than failing the whole observation. A usable `/etc/hostname` is currently
required.

Collection is accessed through a platform-neutral facade rather than directly
from the Linux backend. This keeps configuration, scheduling, payloads, retries,
and transport shared across operating systems. Future macOS and Windows backends
can collect the facts available on those systems and advertise a reduced
capability set when they cannot provide the full Linux inventory surface. Until
those backends are implemented, running on another operating system returns a
clear unsupported-collector error instead of emitting an incomplete observation.

The `virtualization` component reports an `environment`: `bare_metal`,
`vm_guest`, `container_guest`, or `unknown`. `bare_metal` requires conclusive
negative container and VM results from `systemd-detect-virt`; missing utilities,
command failures, and absent DMI hints instead produce `unknown`. Positive DMI
and container-marker evidence can still identify a guest. VM guests also report
their detected `provider`; when the agent runs in a container on a VM,
`container_guest` takes precedence while the underlying VM provider remains
present, and a detector-provided container type is reported as `container_type`.
`container_host` is reported only when a Docker, containerd, or Podman runtime
socket is visible; container markers and cgroups describe agent execution, not
hosting capability.
