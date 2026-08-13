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

Build a portable Linux archive and Debian package for the current CPU in
`dist/`, then verify their contents and exercise the packaged binary's dry-run
collector with:

```sh
make agent-packages
make verify-agent-packages
```

The build uses cargo-dist with the version from `agent/Cargo.toml`,
`Cargo.lock`, and static musl targets so artifacts do not depend on the build
host's libc or Nix store. Release CI builds native x86-64/amd64 and
AArch64/arm64 archives and Debian packages. The repository script retains
ownership of `.deb` metadata and systemd lifecycle hooks because cargo-dist
does not generate Debian packages. Set `SOURCE_DATE_EPOCH` to produce archives
with a caller-selected timestamp.

## Configuration

Copy [`dist/agent.toml.example`](dist/agent.toml.example) to
`/etc/renga/agent.toml`. The example documents every key and its default.
`renga_url` and `intake_api_key` are required. Environment variables override
file values:

* `RENGA_URL`
* `RENGA_ALLOW_INSECURE_HTTP` (`true` or `false`, exactly)
* `RENGA_INTAKE_API_KEY`
* `RENGA_INVENTORY_INTERVAL_SECONDS`
* `RENGA_CHECKIN_INTERVAL_SECONDS`
* `RENGA_CONFIG_REFRESH_INTERVAL_SECONDS`
* `RENGA_REQUEST_TIMEOUT_SECONDS`
* `RENGA_MAX_RETRY_ATTEMPTS`

`checkin_interval_seconds` must be between 1 and 60 seconds. The 60-second
maximum keeps check-ins within the server's fixed 90-second lease while
reserving a 25-second total check-in delivery budget. Request timeouts may not
exceed 20 seconds and retry attempts may not exceed five.

HTTPS is required by default, and redirects are never followed. For deliberate
local development only, `allow_insecure_http = true` (or the strict environment
override `RENGA_ALLOW_INSECURE_HTTP=true`) permits an `http://` URL. **Do not use
this in production:** plaintext HTTP exposes the bearer token and host inventory
to interception. Prefer a locally trusted HTTPS endpoint whenever possible.

`RUST_LOG` controls log filtering and defaults to `info`; it is not an agent
configuration field. The supplied unit optionally reads `/etc/renga/agent.env`,
which may contain `KEY=value` overrides. Keep the intake key out of shell history
and make configuration readable only by root and the service group:

```sh
sudo chown root:renga-agent /etc/renga/agent.toml
sudo chmod 0640 /etc/renga/agent.toml
sudo chown root:renga-agent /etc/renga/agent.env  # if used
sudo chmod 0640 /etc/renga/agent.env
```

On first configured startup, the agent generates an installation UUID and writes
it to `/var/lib/renga/installation-id`. The directory is mode `0700`, the file is
mode `0600`, and the Debian package and systemd unit assign both to the
`renga-agent` account. Restarts, package upgrades, removal, and reinstallation
reuse this state. A machine image must exclude `/var/lib/renga` so every clone
generates a distinct identity even when all clones share one organization intake
key.

For migration only, an existing installation may temporarily set
`installation_id` in TOML or `RENGA_INSTALLATION_ID`. The agent persists that UUID
when state is absent, requires it to match existing state, and then no longer
needs the override. Portable-tarball installations can select a writable path
with `--state-directory`; its default is `/var/lib/renga`.

`--dry-run` collects once and prints pretty JSON without loading configuration or
using the network. `--once` loads configuration and attempts both a check-in and
an inventory observation; after both attempts it exits unsuccessfully if either
failed and reports all failures. With neither option the agent attempts both at
startup, logs either failure independently, then schedules periodic check-ins and inventory, and retries transient HTTP
failures with backoff. SIGTERM/SIGINT stops retry attempts and backoff promptly,
including during `--once`. A blocking request already in flight can continue up
to `request_timeout_seconds` before the process exits. Collector subprocesses
are separately bounded to two seconds and are killed and reaped on timeout or
shutdown. Cancellation is checked before every due job, so no remaining jobs in
the current scheduler batch start after shutdown is requested.

The daemon reloads the TOML file and environment overrides on the configured
refresh interval. A valid reload replaces transport and interval settings; an
invalid reload is logged and the last valid configuration remains active. There
is currently no signal-triggered reload, so edit the file atomically or restart
the service when an immediate change is required. Logs are structured JSON on
stderr; systemd records them in the journal.

## Debian/Ubuntu package and smoke test

The `.deb` installs the binary, hardened systemd unit, example configuration,
and dedicated unprivileged account. It deliberately does not enable or start
the service because the packaged endpoint and credentials are placeholders.
Install and configure it with:

```sh
sudo apt install ./dist/renga-agent_0.1.0_amd64.deb
sudoedit /etc/renga/agent.toml
sudo -u renga-agent renga-agent --once --dry-run | python3 -m json.tool >/dev/null
sudo -u renga-agent renga-agent --once
sudo systemctl enable --now renga-agent.service
sudo systemctl status renga-agent.service
sudo journalctl -u renga-agent.service -f
```

Create an organization intake key from Renga's authenticated **Collectors** page,
then copy the one-time key into `agent.toml`. The collector appears automatically
on first contact. `--dry-run` does not load that file or contact Renga; `--once` sends both the check-in and
observation and fails if either request fails. After `--once`, verify the
collector is connected and its resource is current on the dashboard, then
leave the service running for at least two check-in intervals and verify its
lease remains connected. The portable tarball contains the standalone binary,
this README, and the changelog. Use the Debian package when the systemd unit,
example configuration, dedicated account, and lifecycle hooks are required.

The hardened unit allows outbound IPv4/IPv6, local sockets, and netlink while
leaving `/proc`, `/proc/sys`, and `/sys` readable for inventory. It grants no
capabilities, makes the host filesystem read-only to the service, and grants a
single writable state directory at `/var/lib/renga`.
Filesystem inventory is parsed through `procfs` from `/proc/1/mountinfo` so it
describes the host rather than the service's sandboxed mount view. If that view
is inaccessible or malformed, all filesystem components are omitted instead of
falling back to the agent's mount namespace.
The DMI UUID and serial number remain best-effort because an unprivileged
service may not have permission to read the relevant sysfs files. Do not run the
agent as root or weaken the sandbox to obtain those optional identifiers.
The example unit allows 40 seconds for shutdown, above the maximum 20-second
request timeout so an in-flight request can finish before systemd forcibly stops
the service.

## Collector scope, portability, and degradation

The currently implemented backend supports Linux. A portable `sysinfo` baseline
provides best-effort hostname, OS/kernel/architecture, CPU, memory, and visible
disk entries. The Linux backend enriches that baseline with stable machine and
DMI identity, FQDN, authoritative interfaces and addresses, PID 1 filesystems,
and virtualization hints from `/etc`, procfs, sysfs, and the `hostname` command.
`/etc/hostname` remains authoritative when usable, with the portable
hostname as a fallback. Missing firmware files, utilities, permissions, or
unsupported platform facts omit only the affected optional values rather than
failing the whole observation.

Network inventory uses the unmodified `getifs` crate and describes interfaces
visible in the agent's current network namespace. Because interface metadata and
addresses come from separate kernel dumps, the agent publishes them only after
two consecutive normalized snapshots match. Interrupted, inconsistent, or
changing samples are retried within a fixed bound; exhausted retries leave
network facts unavailable, while a stable empty snapshot is authoritative.
On Linux, link speed and physical-versus-virtual kind are enriched from sysfs.
MAC addresses have an additional safety check because `getifs` does not preserve
the kernel link-address length: `/sys/class/net/<name>/address` must be readable,
must contain exactly six two-digit hexadecimal octets, must be nonzero, and must
match the `getifs` value. Otherwise that interface's MAC is omitted.

Disk components are the portable disk entries visible to the agent and can vary
with operating-system APIs and service sandboxing. They are not the
authoritative filesystem inventory: filesystem components continue to come
only from Linux PID 1's mount namespace, parsed from `/proc/1/mountinfo` through
the `procfs` crate, and are omitted when the complete view is inaccessible or
malformed. The agent never falls back to its own potentially sandboxed mount
namespace.

Encoded observations are limited to 256,000 bytes, matching the Phoenix API.
The agent rejects larger observations locally before opening a network request.
Non-authoritative inventory is capped at 128 disk and 512 filesystem components;
when either cap is exceeded, a `collection_status` component reports the collector,
discovered and emitted counts, and `truncated: true`. Interfaces and addresses are
authoritative and are never truncated; exceptionally large network inventories
are instead rejected by the final encoded-size check.

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
