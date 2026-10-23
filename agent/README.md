# Renga host agent

The Renga agent is a cross-platform service with a Linux-first inventory backend.
It reads host facts and sends check-ins and observations to Renga over HTTP(S).
It also runs on-demand jobs from a fixed set of capabilities compiled into the
agent, such as an immediate inventory collection. It does **not** provide a
remote shell, execute server-supplied commands, or expose a listening network
service.

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

`agent/scripts/test-service.sh` runs the shipped systemd unit against a
loopback stub server and checks that SMBIOS snapshot failures never stop the
agent from starting and checking in. It needs root on a disposable systemd host
and runs in CI.

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

An optional `[labels]` table adds key/value labels to every observation, for
example `team = "storage"`; Renga's triage rules can match them. Labels are
read only from the file, not from environment variables, and follow the limits
documented in the example.

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

The agent also creates an Ed25519 key pair at `/var/lib/renga/installation-key`
(mode `0600`) and presents the public key on every check-in. Renga shows the
key as pending on the Collectors page until an owner or admin approves it.
Before approving, compare the fingerprint there with the one the host prints:

```sh
sudo -u renga-agent renga-agent fingerprint
```

The command only reads the key; it never creates one. A different key returns
the installation to pending, and if the old key was approved Renga opens a
finding. Exclude the key from machine images for the same reason as the
installation UUID.

Privileged jobs, such as restarts and terminals, need an approved key and run
only on resources an owner or admin bound to this installation. Renga offers
them without their parameters, and the agent claims each offer by signing it
with the key, so a copied intake key alone never leases one.

Every collected observation is written to `observations/` under the state
directory before the first delivery attempt, so an outage or restart does not
lose it. The agent delivers queued observations oldest first after each
inventory and retries anything left every two minutes, replaying the stored
body unchanged so Renga recognizes a repeat by its observation ID. An entry is
removed once Renga accepts it, or when Renga rejects the payload itself as
malformed, oversized, or reusing an observation ID; network, server, credential,
and enrollment failures leave it queued. The queue keeps at most 512
observations, 64 MiB, and seven days, dropping the oldest first when a limit is
reached. Each delivery pass that leaves or removes anything logs an
`observation queue` line with the backlog's size, its oldest entry's age, and
counts of observations dropped for space, expired, or rejected. Every check-in
reports the same health, and Renga shows the last reported health in the
Delivery queue column of the Collectors settings page; drop counts cover the
agent's current run. Check-ins omitting queue health retain the last report.
Queued observations belong to the installation, not the server: after pointing
an agent at a different Renga, it delivers its backlog there.

If the queue cannot open or make room, check-ins continue and new inventory is
sent directly without durability. Delivery work retries opening the queue on
later inventory and flush passes; periodic check-ins never wait for that retry.

`--dry-run` collects once and prints pretty JSON without loading configuration or
using the network. `--once` loads configuration and attempts both a check-in and
an inventory observation; after both attempts it exits unsuccessfully if either
failed and reports all failures. An observation that `--once` could not deliver
stays queued for the next run or the daemon. With neither option the agent
attempts both at startup, logs either failure independently, then schedules
periodic check-ins and inventory, and retries transient HTTP failures with
backoff. SIGTERM/SIGINT stops retry attempts and backoff promptly,
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

### Home deployment

`renga_url` is where the agent asks for its _home_, the deployment it sends
every authenticated request to (RFD 23). A Renga deployment answers with its own
public URL, so pointing `renga_url` at a deployment works as before. An operator
running several deployments can instead point every agent at one resolver
address, which answers with the deployment that owns the intake key.

Before its first check-in, the agent sends `GET /api/v1/agent/home` to
`renga_url` with the deployment identifier read from its intake key (empty for a
key that carries none). That request carries no credential, so the intake key
only ever reaches the resolved home. The home must be an `https` origin unless
`allow_insecure_http` is set, and redirects are not followed. The agent stores
the answer in `home.json` under the state directory and reuses it on later
starts. It asks again when `renga_url` or the key's deployment identifier
changes, or when the file is deleted. While the address cannot be reached at
startup, the daemon keeps retrying, backing off from 5 seconds to 5 minutes;
`--once` fails instead. A reload that changes `renga_url` or the key's
identifier resolves again in the background, so check-ins continue meanwhile,
and takes effect only once the new home is usable; otherwise the previous
configuration and home stay in place.

When the home answers `410 Gone` with `{"error": "moved"}`, the organization
now lives on another deployment. The agent stops retrying that request, keeps
the observation queued, deletes `home.json`, and asks `renga_url` again. A
different answer becomes the new home at once, with the same installation
identity. The same answer, or no answer, means the resolver has not caught up,
so the agent keeps sending to its current home and asks again after 30
seconds, doubling up to 15 minutes, until a different home is named. A `--once`
run that hears `moved` deletes `home.json` so the next run resolves again. Any
other status, including `401` and `403`, never triggers resolution. The agent
logs `renga_url`, the home, and when the home was resolved at startup and after
every resolution.

Upgrade the Renga server before its agents: an agent pointed directly at a
server that does not answer `/api/v1/agent/home` yet gets `404` and does not
start, because it never sends its intake key to an address that has not named
itself as the home.

## Switch polling over SNMP

An installation can also poll network switches read-only over SNMP (RFD 11).
Each `[[collectors.snmp]]` table is one poller with its own collector stream in
Renga, identified by its `id`; changing its targets or credentials keeps the
same stream.

```toml
[[collectors.snmp]]
id = "core-switches"
targets = ["10.0.0.1", "10.0.0.2:1161"]
username = "renga"
auth_protocol = "sha256"            # md5, sha, sha224, sha256 (default), sha384, sha512
auth_password_file = "/etc/renga/snmp-auth"
privacy_protocol = "aes128"         # des, aes128 (default), aes192, aes256
privacy_password_file = "/etc/renga/snmp-priv"
interval_seconds = 900              # default 15 minutes, at least 60
timeout_seconds = 5                 # per request
max_concurrent_targets = 4
```

SNMPv3 with authentication and privacy is the default and the only v3 level
used. SNMPv2c sends its community in clear text, so it needs both
`version = "2c"` and `allow_v2c = true`, with the community in
`community_file`. Keep those files readable only by the `renga-agent`
account. The poller reads them before every poll, so a rotated password needs
no restart, and never sends them to Renga or logs them.

Each poll reads the switch's identity (`SNMPv2-MIB`, and its chassis serial,
vendor, and model from `ENTITY-MIB`), interfaces (`IF-MIB`), LLDP neighbors
(`LLDP-MIB`), and VLAN membership (`Q-BRIDGE-MIB`). Renga identifies a switch
by its chassis serial, so two pollers reaching the same switch report one
resource. A target that does not answer, or has no chassis serial, is reported
unreachable: its switch stays as Renga last saw it instead of disappearing.
Neighbors and VLANs count as complete only when every reached switch answered
that MIB.

Pollers run on their own threads, so a slow switch never delays host inventory
or job check-ins. Reports go through the same on-disk queue as host
observations, split by target to stay within the observation size limit.

## Switch polling over gNMI

For switches whose SNMP agents are incomplete, a `[[collectors.gnmi]]` table
polls them read-only over gNMI with OpenConfig models instead. It reports the
same switch resource as the SNMP poller, so Renga treats both alike, and a
switch reached by both is still one resource.

```toml
[[collectors.gnmi]]
id = "spines"
targets = ["10.0.0.1", "spine2.example:6030"]   # port 9339 by default
username = "renga"                              # optional, with password_file
password_file = "/etc/renga/gnmi-password"
tls_ca_file = "/etc/renga/gnmi-ca.pem"          # default: the public web roots
tls_server_name = "spine.example"               # optional; the name the certificates carry
tls_client_cert_file = "/etc/renga/gnmi.crt"    # optional mutual TLS, with
tls_client_key_file = "/etc/renga/gnmi.key"     # tls_client_cert_file
interval_seconds = 900                          # default 15 minutes, at least 60
timeout_seconds = 10                            # per request
max_concurrent_targets = 4
```

Connections use TLS. Plaintext needs `allow_plaintext = true`, for lab gear
only, since the password would cross the network in clear text. The password
and certificates are read from their files on every poll.

Each poll asks every switch for `system/state`, `components/component/state`,
`interfaces/interface`, the VLAN table under `network-instances`, and
`lldp/interfaces/interface`, each in a separate `Get` with the `openconfig`
origin, so a switch that lacks one model still reports the rest. Only the
platform model is required: it holds the chassis serial that identifies the
switch. Trunk ports' allowed VLANs are read against the switch's VLAN table,
as with SNMP. Neighbors and VLANs count as complete only when every reached
switch answered for them.

## Virtual machines over libvirt

On a KVM hypervisor, the agent can also report the virtual machines libvirt
defines there (RFD 11). It runs `virsh` in read-only mode, so it needs the
`libvirt-clients` package (`libvirt-client` on Fedora) and access to libvirt's
read-only socket, which most distributions grant to every local account.

```toml
[collectors.libvirt]
id = "libvirt"                      # default; the collector stream in Renga
uri = "qemu:///system"              # default
interval_seconds = 300              # default 5 minutes, at least 60
timeout_seconds = 10                # per virsh call
```

The URI also names the hypervisor in every report and log line, so it must not
carry a password or a secret query parameter. For a remote hypervisor, keep
credentials in libvirt's authentication configuration, SSH keys, or
certificate files instead.

Each poll reports every defined domain: its name, state, whether it is
persistent, vCPU and memory allocation, disks, and virtual NICs with their MAC
addresses and the bridge or network they attach to. Renga matches a VM to the
host agent running inside it by the SMBIOS system UUID the guest sees (the
domain's `<hwuuid>` when set, otherwise its UUID), so the two views become one
machine. MAC addresses are only supporting evidence and never merge machines.

A hypervisor whose domains cannot be listed is reported unreachable, and its
VMs stay as Renga last saw them. A report counts as complete, and so lets Renga
retire domains it no longer lists, only when every domain was read and fit in
one report.

## Jobs

Renga can ask an agent to run a job, such as collecting inventory now instead
of at the next interval (RFD 9). A job names a capability compiled into the
agent, written `name@version`; the agent never runs anything else, and Renga
cannot add capabilities remotely. Each capability has a risk class fixed by its
definition: `observe` capabilities read the host and change nothing,
`operate` capabilities change host or guest state, and `interactive`
capabilities open a session a person drives.

The optional `[jobs]` table is local policy for which capabilities Renga may
request. Without it, every compiled-in `observe` capability is enabled, so
on-demand collection works without a configuration change. An explicit
`enabled` list, even an empty one, enables exactly what it names: a capability
name enables every version, and a `name@version` key enables one. `operate` and
`interactive` capabilities are never enabled by default. Names this agent does
not know are accepted and enable nothing, so one file can serve several agent
versions.

```toml
[jobs]
enabled = ["inventory.collect"]
```

This build has one capability:

* `inventory.collect@1` (`observe`): runs the normal inventory collection now,
  delivers it through the observation queue, and reports the observation ID.

Check-ins advertise the enabled capabilities next to `host.inventory`, read from
the current policy, so a reload withdraws a capability at once. The agent
leases jobs after a check-in that reports jobs waiting, or after any check-in
that gives no answer, and runs them one at a time on their own thread so they
never delay check-ins or scheduled inventory. A leased job whose capability the
policy does not enable is refused. Each job runs under its capability's
timeout, posts a heartbeat every 20 seconds to keep its lease, and stops when
Renga asks to cancel it or the agent shuts down; a job that outlives its timeout
is reported as failed.

When the policy enables any job capability, the agent also holds a WebSocket
open to `/api/v1/agent/socket` and joins its installation's channel. Renga
pushes an empty `jobs_waiting` message when it queues a job for the agent, and
the agent checks for it between scheduled operations, at least every quarter
second while otherwise idle, instead of waiting for its next check-in. An
HTTP request already in flight can delay that check. The socket authenticates
with the same intake key and
installation ID as the HTTPS API (the key travels in the
`Sec-WebSocket-Protocol` header, never the URL), uses the same TLS roots, and
never carries a job, so leasing still happens over HTTPS. If the socket cannot
connect, for example behind an HTTP proxy, which it does not use, the agent
logs one warning per outage, retries with backoff up to five minutes, and
leases on check-ins exactly as before.

Before running a job, the agent records its ID in `jobs.json` under the state
directory, and it adds the outcome once the job ends. A job delivered again
after a lost report re-sends the recorded outcome instead of running twice. A
job recorded as started without an outcome runs again unless its capability is
imperative, in which case it fails because it may have partly run. The record
keeps the last 128 jobs for eight days. `--once` runs no jobs and advertises
none.

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
The DMI UUID, serial number, and power supply records come from the raw SMBIOS
tables, which only root can read. Before each start the unit runs
`renga-agent snapshot-smbios` as root, outside the sandbox, under a five-second
deadline. It takes no arguments, reads only the two files in
`/sys/firmware/dmi/tables` without following links, and publishes a copy that
only root and the `renga-agent` group can read under the root-owned
`/run/renga/smbios`. The agent ignores a snapshot that is incomplete or from an
earlier boot. If the helper fails or times out, the service still starts; the
last complete snapshot from this boot remains usable, or those optional facts
are omitted when none exists. Do not run the agent itself as root or weaken the
sandbox to obtain them.
The example unit allows 40 seconds for shutdown, above the maximum 20-second
request timeout so an in-flight request can finish before systemd forcibly stops
the service.

## Collector scope, portability, and degradation

The currently implemented backends support Linux and macOS. A portable `sysinfo`
baseline provides best-effort hostname, OS/kernel/architecture, CPU, memory, and
visible disk entries. The Linux backend enriches that baseline with stable machine
and DMI identity, SMBIOS power supplies, FQDN, authoritative interfaces and addresses, PID 1 filesystems,
and virtualization hints from `/etc`, procfs, sysfs, and the `hostname` command.
`/etc/hostname` remains authoritative when usable, with the portable
hostname as a fallback. Missing firmware files, utilities, permissions, or
unsupported platform facts omit only the affected optional values rather than
failing the whole observation.

The macOS backend adds the platform UUID, serial number, hardware model, Darwin
interfaces and addresses, mounted filesystems, and native hypervisor status.
Platform identity comes from `IOPlatformExpertDevice`, the human-readable product
name comes from `system_profiler`, model and virtualization status come from
`sysctl`, and filesystems come directly from `getmntinfo(3)`. Those optional
sources degrade independently. A missing hostname still fails the observation
because the server would have no safe reconciliation identity.

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
with operating-system APIs and service sandboxing. On Linux, authoritative
filesystem components come only from PID 1's mount namespace, parsed from
`/proc/1/mountinfo` through the `procfs` crate, and are omitted when the complete
view is inaccessible or malformed. The Linux agent never falls back to its own
potentially sandboxed mount namespace. On macOS, filesystem components describe
the native mount table visible to the process.

Encoded observations are limited to 256,000 bytes, matching the Phoenix API.
The agent rejects larger observations locally before opening a network request.
Non-authoritative inventory is capped at 128 disk and 512 filesystem components;
when either cap is exceeded, a `collection_status` component reports the collector,
discovered and emitted counts, and `truncated: true`. Interfaces and addresses are
authoritative and are never truncated; exceptionally large network inventories
are instead rejected by the final encoded-size check.

Collection is accessed through a platform-neutral facade rather than directly
from the Linux backend. This keeps configuration, scheduling, payloads, retries,
and transport shared across operating systems. Running on a platform without a
backend, including Windows, returns a clear unsupported-collector error instead
of emitting an incomplete observation.

The `virtualization` component reports an `environment`: `bare_metal`,
`vm_guest`, `container_guest`, or `unknown`. On Linux, `bare_metal` requires
conclusive negative container and VM results from `systemd-detect-virt`; missing
utilities, command failures, and absent DMI hints instead produce `unknown`.
Positive DMI and container-marker evidence can still identify a guest. VM guests
also report their detected `provider`; when the Linux agent runs in a container
on a VM, `container_guest` takes precedence while the underlying VM provider
remains present, and a detector-provided container type is reported as
`container_type`. `container_host` is reported only when a Docker, containerd,
or Podman runtime socket is visible. On macOS, `kern.hv_vmm_present` provides the
guest determination and the hardware model identifies common providers.

For a safe native macOS smoke test that does not load credentials or contact the
server, run:

```sh
cargo test -p renga-agent collectors::macos
cargo run -p renga-agent -- --dry-run | python3 -m json.tool >/dev/null
```
