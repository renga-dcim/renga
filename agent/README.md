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
`/etc/renga/agent.toml`. Configured OIDC enrollment is the default. Set the
Renga server URL, organization slug, enrollment profile, externally managed
OIDC token path, and durable state directory:

```toml
renga_url = "https://renga.example.com"
auth_mode = "enrolled"
organization = "example-org"
profile = "linux-production"
oidc_token_file = "/run/secrets/renga-oidc-token"
state_path = "/var/lib/renga-agent"
```

On first boot the agent creates a random installation UUID and Ed25519 private
key in `state_path`, then exchanges the OIDC workload evidence for a
key-bound installation credential. Runtime requests and credential renewal are
bound to that same key; the UUID, key, and credential survive restarts and
ordinary package upgrades. Do not generate an installation UUID or copy an
OIDC token into the state directory.

The example documents every key and default. Environment variables override
file values; all supported overrides are:

* `RENGA_URL`
* `RENGA_ALLOW_INSECURE_HTTP` (`true` or `false`, exactly)
* `RENGA_AUTH_MODE` (`enrolled` or `legacy_token`)
* `RENGA_ORGANIZATION`
* `RENGA_PROFILE`
* `RENGA_OIDC_TOKEN_FILE`
* `RENGA_STATE_PATH`
* `RENGA_TOKEN`
* `RENGA_INSTALLATION_ID`
* `RENGA_INVENTORY_INTERVAL_SECONDS`
* `RENGA_CHECKIN_INTERVAL_SECONDS`
* `RENGA_CONFIG_REFRESH_INTERVAL_SECONDS`
* `RENGA_REQUEST_TIMEOUT_SECONDS`
* `RENGA_MAX_RETRY_ATTEMPTS`

`checkin_interval_seconds` must be between 1 and 60 seconds. The 60-second
maximum keeps check-ins within the server's fixed 90-second lease while
reserving a 25-second total check-in delivery budget. Request timeouts may not
exceed 20 seconds, retry attempts may not exceed five, and configuration refresh
may not exceed one hour (3,600 seconds).

`legacy_token` is an explicit migration mode for existing installations only.
It requires `token` and `installation_id` instead of the four enrolled fields:

```toml
auth_mode = "legacy_token"
token = "one-time-existing-source-token"
installation_id = "67e55044-10b1-426f-9247-bb680e5fe0c8"
```

An explicitly selected mode never falls back to the other mode when enrollment
or authentication fails. For upgrade compatibility, an old configuration that
omits `auth_mode` but contains `token` or `installation_id` is inferred as
`legacy_token`; new configurations default to `enrolled`.

HTTPS is required by default, and redirects are never followed. For deliberate
local development only, `allow_insecure_http = true` (or the strict environment
override `RENGA_ALLOW_INSECURE_HTTP=true`) permits an `http://` URL. **Do not use
this in production:** plaintext HTTP exposes the bearer token and host inventory
to interception. Prefer a locally trusted HTTPS endpoint whenever possible.

`RUST_LOG` controls log filtering and defaults to `info`; it is not an agent
configuration field. The supplied unit optionally reads `/etc/renga/agent.env`,
which may contain `KEY=value` overrides. Keep credentials out of shell history
and make configuration readable only by root and the service group:

```sh
sudo chown root:renga-agent /etc/renga/agent.toml
sudo chmod 0640 /etc/renga/agent.toml
sudo chown root:renga-agent /etc/renga/agent.env  # if used
sudo chmod 0640 /etc/renga/agent.env
```

The OIDC token file belongs to the workload identity provider or secret
manager. The agent rereads it when evidence is needed; it does not copy or
retain it. Arrange rotation atomically and grant the `renga-agent` account read
access only (for example `root:renga-agent` and mode `0640`); never make it
world-readable. The state directory must be owned by `renga-agent`, mode
`0700`, and its `state.json` and `state.lock` files are mode `0600`. Preserve
the complete state directory across normal upgrades, rollback, and service
restart: losing it creates a new installation identity and key.

`--dry-run` collects once and prints pretty JSON without loading configuration or
using the network. `--once` loads configuration and attempts both a check-in and
an inventory observation; after both attempts it exits unsuccessfully if either
failed and reports all failures. With neither option the agent attempts both at
startup, logs either failure independently, then schedules periodic check-ins
and inventory, and retries transient HTTP failures with backoff. SIGTERM/SIGINT
stops retry attempts and backoff promptly,
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
sudo install -o root -g renga-agent -m 0640 /path/from/identity-provider/oidc-token \
  /run/secrets/renga-oidc-token
sudo -u renga-agent renga-agent --once --dry-run | python3 -m json.tool >/dev/null
sudo -u renga-agent renga-agent --once
sudo systemctl enable --now renga-agent.service
sudo systemctl status renga-agent.service
sudo journalctl -u renga-agent.service -f
```

Create an OIDC enrollment profile for the organization in Renga, configure the
matching selectors and token file above, and run `--once`. The identity
provider, not the package, must provision and rotate that file; the `install`
command above is only a simple smoke-test example. `--dry-run` does not load
configuration, create enrollment state, or contact Renga. `--once` enrolls if
necessary, sends both the check-in and observation, and fails if any required
operation fails. Verify `/var/lib/renga-agent` remains mode `0700`, its files
are mode `0600`, and the newly enrolled collector and resource are current on
the dashboard. Then leave the service running for at least two check-in
intervals and verify its lease remains connected. The portable tarball contains
the standalone binary, this README, and the changelog. Use the Debian package
when the systemd unit, example configuration, dedicated account, and lifecycle
hooks are required.

The hardened unit allows outbound IPv4/IPv6, local sockets, and netlink while
leaving `/proc`, `/proc/sys`, and `/sys` readable for inventory. It grants no
capabilities and makes the host filesystem read-only to the service.
`StateDirectory=renga-agent` is the narrow writable exception and creates
`/var/lib/renga-agent` as the unprivileged account with mode `0700`; the Debian
post-install script also creates it before first service start. Package upgrade,
removal, and purge deliberately do not delete this identity state.
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

## Preparing reusable images

Never capture an enrolled machine as a reusable image. Immediately before
sealing an image, stop the service and remove every per-installation artifact
and externally supplied OIDC token (adjust the token path if configured
differently):

```sh
sudo systemctl stop renga-agent.service
sudo rm -rf -- /var/lib/renga-agent
sudo rm -f -- /run/secrets/renga-oidc-token
sudo install -d -o renga-agent -g renga-agent -m 0700 /var/lib/renga-agent
```

This removes the generated installation UUID, private key, credential, state
lock, and OIDC evidence. Inspect any custom `state_path`, environment override,
cloud-init staging location, and secret-manager cache too. A golden image may
contain only the agent binary, service unit, server endpoint, and enrollment
profile selectors; inject organization/workload selection and the OIDC token at
deployment or first boot. Never clone `state.json`, `state.lock`, a legacy token,
or an OIDC token.

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
