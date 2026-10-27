# Intake capacity validation (RFD 21)

**Overall launch gate: OPEN; latest integrated fleet gate has regressions.**
An earlier 64-connection checkpoint passed normal, full re-enrollment, and
quiet-neighbor phases without raising intake limits. Subsequent integrated
runs rejected some re-enrollment requests; the retained failures and current
investigation appear below. Fixed-watermark resumable neighbor generation is
implemented and tested, but does not by itself close the fleet gate.

## Reproduce

Use the Nix development shell and an otherwise idle PostgreSQL instance. The
script refuses production and ordinary test databases. It retains its fixture
for inspection; subsequent runs may use `LOAD_REUSE=true`. Create and migrate
the disposable database first:

```sh
nix develop --command sh -c 'MIX_ENV=test MIX_TEST_PARTITION=_capacity mix ecto.create && MIX_ENV=test MIX_TEST_PARTITION=_capacity mix ecto.migrate'
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity mix run --no-start scripts/load-capacity.exs
```

The harness uses `DBConnection.ConnectionPool`, not SQL Sandbox auto-checkout,
and calls the real Phoenix Endpoint with JSON bodies and authenticated intake
keys. PostgreSQL, payload validation, admission, acceptance, reconciliation,
and contact flushing are real. HTTP sockets/TLS, external collectors and the
other periodic workers are not exercised. Do not run the regression suite or
another fleet load concurrently. Allow the selected pool's application
connections (64 by default), plus PostgreSQL's administrative reserve and
any other running services.

## Workload and acceptance criterion

`scripts/load-capacity.exs` seeds 3,000 hosts, each with four Ethernet NICs and
twelve 32-GiB memory components. Inventory identifiers are stable while
observation IDs and new installation IDs are fresh. Every phase reports HTTP
status counts, reconciliation failures, p95/p99 endpoint duration, and the
lane/reason for admission failures. Any throttle or failed reconciliation in
the ordinary phases makes the command exit nonzero.

* Normal schedule: 3,000 check-ins spread over 60 seconds, plus 50 hourly
  inventories (the agent's default inventory/check-in schedules).
* Full re-enrollment: all 3,000 installations replaced over five minutes,
  including their inventory. Old installations keep checking in until their
  replacement enrolls; replacements continue periodic check-ins afterwards.
* Noisy-neighbor control: hold the noisy organization's entire bulk allowance
  through the test, reject 100 of its new-lease requests, and accept 100 quiet
  check-ins and 100 quiet inventories. This is controlled permit saturation,
  not a simulation of an unbounded network flood. All quiet responses must
  succeed while the permits remain held.

The candidate per-node rates are 60,000/minute/organization for each of bulk
and maintenance, and 600/minute/installation/lane. A domain lane has
`max((pool_size - 4) / 3, 1)` integer slots; one organization can use at most
half a lane (at least one slot). The two authentication lanes each have
`max(pool_size / 8, 1)` slots. The recorder, job sweep, archive generation,
and general background rotation use separate execution capacity.
Per-organization overrides cannot remove the hard half-lane isolation cap.
These are bounded execution lanes, not physically separate PostgreSQL pools.
After an earlier strict checkpoint passed without a limit increase, the
production pool default was aligned with that 64-connection budget. Subsequent
failures mean this remains an experimental default, not a validated launch
requirement or evidence that PostgreSQL needs 64 active queries per node.
Smaller-pool validation below also changes the derived admission caps; it is
not an isolated measurement of database connection demand.

## Recorded results

Run in an Amp Linux x64 orb with local PostgreSQL, a 64-connection application
pool, candidate defaults unchanged, and no concurrent test suite. The original
failing run reused the fully seeded fixture in `renga_test_capacity2`. It exited 1.

| Phase | Requests | Accepted (202) | Throttled (429) | p95 / p99 | Failed reconciliations |
| --- | ---: | ---: | ---: | --- | ---: |
| Normal schedule | 3,050 | 3,049 | 1 | 80 / 146 ms | 0 |
| Full re-enrollment | 20,996 | 8,149 | 12,847 | 1,503 / 1,746 ms | 0 |
| Quiet neighbor under noisy bulk saturation | 200 | 200 | 0 | 121 / 149 ms | 0 |

Initial seeding accepted all 6,000 requests, with p95/p99 257/422 ms and no
failed reconciliations, in 557,853 ms. The original normal phase took 59,986 ms,
re-enrollment 300,952 ms, and the quiet-neighbor control 10,670 ms.

The normal rejection was maintenance organization concurrency. Re-enrollment
rejected 11,769 check-ins and 1,078 observations, also at organization
concurrency. The control additionally observed the expected 100 noisy lease
rejections. No accepted response reported a failed reconciliation. The
benchmark does not prove that rejected check-ins preserve fleet liveness:
agents must retry, and the launch criterion explicitly requires this workload
not to meet the default limits. These initial counters did not establish the
contention source; the investigation below retains that failed baseline.

### Contention investigation (limits unchanged)

`LOAD_PROFILE=true` records the fifteen SQL shapes with the most aggregate
query time, including lock waits, plus connection queue time for each phase.
PostgreSQL activity samples during the failing workload showed organization
`FOR UPDATE` queues holding up check-in `FOR SHARE` requests. In a repeat of
the original workload, MAC-set matching used 133,037 ms across 1,660 queries,
and snapshot-boundary lookup used 22,575 ms across 3,320 queries. The native
MAC column was cast to text, preventing its index from being used; EXPLAIN
ANALYZE filtered 12,396 unrelated interfaces. The snapshot query ran a lateral
probe for every historical source, including unrelated installations.

The MAC predicate now uses native `macaddr` and an explicit tenant predicate.
The same real-database plan fell from 11.874 ms to 0.329 ms. Snapshot lookup
now uses resource-local indexed `DISTINCT ON (source_id)`, retaining the same
observed-time/observation-ID tie break. With these two query changes alone,
re-enrollment throttles fell from 13,921 to 538, but the strict gate still
failed. Normal load still rejected one request. This is not a passing result.

Canonical and fixed-system-principal mutations now use `FOR NO KEY UPDATE`,
while intake and job maintenance use `FOR KEY SHARE`. Human authorization
keeps its exclusive row lock. The non-partial, non-deferrable unique
`organizations_status_lock_key (id, status)` is **part of the fence**, not a
redundant optional index: it makes PostgreSQL treat even a direct status
UPDATE as a key update that conflicts with intake. The migration must be
installed before the new code, and must not be removed while it is running.
Row-before-advisory ordering remains unchanged; old SHARE/UPDATE writers
still serialize with new canonical writers. Real PostgreSQL concurrency
tests cover accepted-intake commit versus direct suspension, re-reading a
suspended status after waiting, and concurrent check-ins during canonical
work. Deletion also conflicts with KEY SHARE.

With these fences and the two query changes, normal load accepted all 3,050
requests (p95/p99 9/129 ms), and no re-enrollment check-in was rejected. The
full phase still rejected 92 observations out of 20,996 requests (p95/p99
341/1,026 ms); the quiet neighbor accepted 200/200 (100/126 ms). The gate
remained failed. Its next profile exposed provider-component matching that
did not push tenant/resource predicates down to historical evidence; these
predicates now match the existing resource/source index, and stronger serial
identities no longer execute weaker provider/position searches unnecessarily.

The original fixture nested DIMM serials inside `attributes`, which the
actual machine payload treats as an opaque extra rather than an identity.
The fixture now uses the machine API's flat component fields. Run
`LOAD_COMPONENT_SERIALS=false` to retain the tougher identity-less
re-enrollment control; passing the corrected fixture alone must not erase the
earlier failures. All results above used identity-less DIMMs and remain
preserved here.

After the provider-evidence query correction, the identity-less control
accepted 20,995 of 20,996 re-enrollment requests (one bulk concurrency throttle,
84/331 ms p95/p99), and the corrected flat-serial fixture accepted 20,994
(two bulk concurrency throttles, 78/115 ms). Both normal schedules accepted
3,050/3,050, and both quiet-neighbor controls accepted 200/200. All check-ins
were accepted and no reconciliations failed. **Both runs still failed the
strict launch gate.** The harness now also retains a bounded top-100 slow SQL
timeline and reports slow/rejected requests, so aggregate improvements cannot
hide the remaining contention tails. No candidate limit has been raised.

The next tail-profile run still rejected 27 re-enrollment requests (ten
check-ins and seventeen observations; 80/140 ms p95/p99). Every recorded SQL
tail of at least 100 ms was an organization `FOR NO KEY UPDATE` wait, rather
than a different slow query shape. Reconciliation was reloading the same
tenant-scoped source, resource, and full observation payload for **each DIMM**.
The internal projection now uses those already-loaded records to construct
the same component-evidence changeset, preserving the public context's
tenant-validation contract while removing redundant round trips and payload
decoding inside the canonical critical section.

### Strict passing run after the critical-section fix

This run was on local commits rebased onto main `510953907d67e99537f32861c9e63d7446f70200`,
including authorization and lifecycle enforcement. It reused the seeded
historical fleet, used flat DIMM serial identities, and exited **0**:

| Phase | Requests | Accepted (202) | Throttled (429) | p95 / p99 | Failed reconciliations |
| --- | ---: | ---: | ---: | --- | ---: |
| Normal schedule | 3,050 | 3,050 | 0 | 8 / 124 ms | 0 |
| Full re-enrollment | 20,996 | 20,996 | 0 | 73 / 93 ms | 0 |
| Quiet neighbor under noisy bulk saturation | 200 | 200 | 0 | 81 / 83 ms | 0 |

Elapsed times were 59,986 ms, 299,990 ms, and 7,348 ms respectively. The
noisy tenant's separate 100 new-lease attempts were all rejected as intended;
they are not included in the 200 quiet requests. No candidate limit changed.
This validates the documented 64-connection/3,000-host profile, not an
arbitrary pool size, an unbounded tenant population, or network/TLS overhead.

### Ready-organization lease-sweep delay

Run separately from intake load, on the same disposable database:

```sh
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity mix run --no-start scripts/load-lease-sweep.exs
```

The control creates 100 organizations with 25 real leased jobs each. It holds
one organization's row `FOR UPDATE` throughout the rotation and saturates the
entire general-background lane. All leases are made overdue at the same
instant; the job sweep runs at its real one-second cadence. It measures when
each quiet organization's first batch starts, and independently checks that
every quiet lease has left leased/running state. The fixture is removed after
the run; unrelated capacity fixtures are retained.

With the unchanged 64-connection pool, all 99 quiet organizations were served
in six rounds. Maximum ready-to-batch delay was **10,217 ms**, total elapsed
10,612 ms, all 2,475 quiet leases were processed, and the 25 locked noisy
leases were untouched. Maximum delay plus the 250 ms batch budget was inside
the tested 30-second handling budget. This establishes the bound for this
100-ready-organization/25-jobs workload, **not** an unbounded organization or
backlog count. The separate job reserve kept retention from consuming it.

After integrating authorization and lifecycle from main, the same control
passed again: six rounds, **10,483 ms** maximum ready-to-batch delay,
10,848 ms total, all 2,475 quiet leases processed and all 25 locked noisy
leases untouched. The measured maximum plus the batch budget remained below
30 seconds.

### Background recheck audit

| Work | Bounded unit and durable progress | Correctness boundary |
| --- | --- | --- |
| Assignment expiry | 25 assignments per organization per round | Existing per-row `SKIP LOCKED`; deadlines remain authoritative before audit catches up |
| Verified-domain recheck | Five domains per organization, oldest attempt first | Attempt recorded before DNS; unavailable DNS retains verification; stale answers cannot undo a newer verification |
| Invitation delivery | Five deliveries per organization | Existing durable lease and retry preserve delivery recovery after worker timeout |
| Export expiry/reclamation | Five exports and 25 chunks per export per organization | Expiry first atomically stops downloads; expired/failed/revoked exports with remaining chunks stay ready until reclaimed |

These use the persistent organization cursor. The domain worker checks due
claims every minute while retaining a 24-hour recheck interval per claim; it
has a five-second round budget and one-second organization batches because
DNS is external work. Other batches retain the 250 ms deadline. Existing
domain re-verification race tests and export expiry/revocation tests pass.

### Archive generation reserve and wall budget

Archive creation now uses the existing running-export row as a durable queue,
one queued export per organization. A separate one-slot node reserve and
persistent organization rotation admit one export per turn. A persisted
60-second claim fails after a crash rather than restarting or publishing an
old snapshot. The repeatable-read snapshot stays intact, with a 59-second
generation budget including claim/setup time and cancellation of its child
task. Storage checks the persisted deadline before and after chunk insertion;
ready publication remains atomic. The lifecycle export authorization and
per-chunk download reauthorization remain unchanged.

Run the real-connection cancellation control separately:

```sh
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity mix run --no-start scripts/load-export-capacity.exs
```

It blocks a real snapshot after reading its first record type. With a 500 ms
test budget, cancellation completed in **565 ms**: the child was dead, the
export was failed, and no archive chunks or private scratch files remained.
The export reserve rejected concurrent generation, while a quiet export
completed with the general-background lane saturated. This is a cancellation
and isolation control, not a claim that arbitrary archives finish in 59 seconds.

The final integrated rerun completed ordinary deadline cancellation in
**536 ms**, again with no partial chunks or deadline-path scratch files. It
also forcibly killed the generation owner while its snapshot was blocked and
verified that the linked snapshot child exited within one second. That
forced-death control verifies cancellation, not crash-safe scratch reclamation;
the harness removes its interrupted private directory during fixture cleanup.

### Integrated regression verification

After rebasing the capacity work onto the merged authorization/lifecycle
baseline, `nix develop --command sh -c 'MIX_ENV=test mix precommit'` passed:
**3,124 passed (one doctest and 3,123 tests), one excluded**. This includes
the generated API-document checks and the lifecycle/authorization suites.
The production runtime configuration test was then extended to verify the
measured 64-connection default and an explicit 16-connection override;
all eleven runtime-configuration tests passed.

### Resumable neighbor expiry

Expiry now captures a durable input version and server `as_of`. Independent
transactions stage matches, globally ordered adjacency selection, and every
endpoint's neighbor/cable-disagreement findings. A final version check under
the organization row fence and topology advisory lock publishes one pointer;
unfinished scans cannot remove links or resolve findings. Confirmed cables
and time-independent cable findings are not retracted merely because LLDP
expires. Relevant input mutations invalidate drafts, including old writers
through database triggers. Unrelated source registration and presence updates
do not invalidate topology or contend with builds.

The scheduler allows a 150 ms organization turn (within its 250 ms outer
deadline), committing small units independently: ten matches/candidates, one
endpoint's findings, or 25 compaction rows. Each statement has a 200 ms
timeout. A timed-out last unit does not erase prior progress. Published
overlays remain authoritative through resumable compaction; obsolete staging
is reclaimed 100 rows per later batch. A legacy writer materializes a published
overlay before its own mutation, preserving the old relation names, physical
foreign keys, and archive semantics. That compatibility operation is not the
background compaction path and is not claimed to be constant time.

Run the real-connection generation control separately from all other load:

```sh
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity2 mix run --no-start scripts/load-neighbor-generation.exs
```

It creates 3,000 interfaces and 1,500 links, half due to expire, with a fresh
caller process for every committed batch. It checks unchanged visibility
before publication, exactly 750 remaining links afterward, and unchanged
visibility throughout compaction. A quiet organization's independent expiry
is interleaved while the large generation remains unfinished. This is a
3,000-interface sparse-graph control, not an unbounded neighbor-degree or
continuous-input convergence guarantee; a relevant concurrent write correctly
invalidates the draft instead of publishing stale output.

Preserved failed evidence: the first 3,000-interface run timed out in an
endpoint-neighborhood join through derived views
(`tmp/neighbor-generation-3000-timeout.log`, with its plan in
`tmp/neighbor-generation-slow-plan.log`). Using the staged candidate graph
removed that join. Typed, indexed endpoint/evidence expressions then reduced
total generation wall time from 247,020 ms to 83,250 ms, and compaction from
51,925 ms to 12,730 ms. The quiet organization completed in 151 ms. These
generation totals span thousands of transactions, **not** a single atomic
publication or organization-lock hold. The checked-in control separately
reports batch, final publication, and conservative organization-fence timings.

Instrumented rerun (same 3,000-interface fixture):

| Measurement | Time |
| --- | ---: |
| Whole generation, across committed batches | 91,593 ms |
| Whole published compaction, across committed batches | 13,837 ms |
| Maximum batch wall time / transaction time | 119.417 / 119.376 ms |
| Maximum organization-fence upper bound | 118.496 ms |
| Final publication wall time / transaction time | 6.859 / 6.815 ms |
| Final publication organization-fence upper bound | 5.506 ms |
| Quiet organization's whole generation | 187 ms |

Query telemetry brackets BEGIN/COMMIT and the organization-fence SELECT.
Fence timing deliberately starts before that query, so it includes any
connection/lock wait and conservatively bounds actual row-lock hold time;
it is not presented as a server-side lock-duration sample. The control had
zero partial publications. The long generation total is never one lock hold.

Five regression tests cover restart/fixed time, renewal immediately before
publication, SQL timeout during staging and compaction, history retention,
and old-writer cutover. The combined topology/archive/intake suites passed
230 tests (one excluded) after the indexed-view change.

The subsequent full `MIX_ENV=test mix precommit` passed **3,129**
(one doctest and 3,128 tests), one excluded. The lease control passed again
with 99 quiet organizations served in five rounds, maximum ready delay
8,500 ms, all 2,475 quiet leases processed, and all 25 noisy leases untouched.
The export control cancelled in 536 ms, published no partial chunks, and
passed both reserve isolation and forced-owner-death cancellation.

### Further retained-data diagnosis

The following are **failed strict runs**, not replacement acceptance criteria.
Every row passed normal traffic (3,050/3,050), the quiet-neighbor control
(200/200), and reconciliation correctness (zero failures). Limits did not
change. Retained fixture history grows between runs, and observation overhead
differs, so these rows are not a controlled causal comparison of optimizations.

| Retained log in `tmp/` | Re-enrollment accepted / 20,996 | Rejected check-ins / observations |
| --- | ---: | ---: |
| `capacity-canonical-hold-fleet.log` | 20,961 | 25 / 10 |
| `capacity-database-sampled-fleet.log` | 20,987 | 3 / 6 |
| `capacity-antijoin-fleet.log` | 20,995 | 0 / 1 |
| `capacity-antijoin-control-fleet.log` | 20,986 | 5 / 5 |
| `capacity-loaded-claims-fleet.log` | 20,987 | 5 / 4 |
| `capacity-batched-fleet.log` | 20,975 | 7 / 14 |

Query-only profiling measured a 755.447 ms post-acquisition canonical interval,
718.861 ms in SQL, including a 248.130 ms component-match INSERT. A later
database-sampled run caught an unblocked `DataFileRead` during historical
component-finding lookup (120.741 ms, within a 559.589 ms holder). Testing the
nullable join key rather than the matched row ID gives PostgreSQL an index-only
anti join. Counterbalanced plans in `capacity-catalog-antijoin-plans.log` show
zero match heap fetches and 1,555 versus 2,046 shared buffer hits; warm execution
times overlap, so no universal timing speedup is claimed.

The in-VM sampler itself had a 321 ms gap during one stall. The independent
`scripts/profile-capacity.sql` observer therefore runs outside the BEAM and
records active statements, idle blockers and wait events every 50 ms, with
cumulative IO/WAL/checkpointer counters about once per second. It refuses
non-capacity databases. `LOAD_DATABASE_PROFILE=true` enables and checks IO/WAL
timing on test connections only; it changes no production settings. Run the
observer alongside the load in another shell, writing live diagnostics outside
the workspace, then retain them after completion:

Observer shell:

```sh
timeout 390s nix develop --command psql -X -h "$PWD/tmp/postgres-socket" -U postgres -d renga_test_capacity2 -f scripts/profile-capacity.sql > /tmp/capacity-db-profile.jsonl
```

Load shell, while the observer is running:

```sh
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity2 LOAD_REUSE=true LOAD_DATABASE_PROFILE=true mix run --no-start scripts/load-capacity.exs
```

Without in-process profiling, a failing second still had 587 ms organization
waiters, root holders idle in transaction waiting for the application, CPU 98%
busy and 0% IO wait. Surrounding three-second cumulative deltas were 58.856 ms
of relation reads and 106.649 ms of WAL fsync, with no full WAL buffers. Storage
alone does not explain that queue. Separate per-process samples captured
control-plane and background Git CPU competing during a later 690 ms queue.
The orb has workload CPU weight 50 versus control-plane weight 1,000, and a
3 GiB workload memory ceiling. These observations identify executor contention
but do **not** establish it as the sole cause; a controlled CPU-reservation
comparison is needed before drawing that conclusion. Runtime policy has not
been changed to manufacture a passing result.

Scoped claim inputs now avoid twelve source/observation rereads per
six-identifier inventory, with unchanged history locks, link validation and
transaction boundaries (235 regressions passed). Immutable component evidence
is inserted in validated batches of at most 100 rows, retaining ordered
canonical matching and first-evidence semantics. All 263 inventory, claim
concurrency and catalog checks passed, including a 128-DIMM duplicate/retry
case. Neither change is claimed to close the strict gate.

### Latest combined verification and executor constraint

After these changes, the combined topology, archive, background and intake
suites passed **284 tests**, one excluded
(`tmp/capacity-latest-combined-controls.log`). Compilation with warnings as
errors and formatting checks passed. Two subsequent full precommit attempts
were killed with exit 137; the retry used two BEAM schedulers. The workload
cgroup recorded OOM kills and reached its 3 GiB ceiling. These attempts do
**not** establish a pass. A further full run with serial ExUnit execution
completed: **3,130 passed** (one doctest, 3,129 tests), one excluded, in 486.7
seconds (`tmp/capacity-latest-precommit-serial.log`). The command was
`nix develop --command sh -c 'ERL_FLAGS="+S 2:2" MIX_ENV=test mix precommit --max-cases 1'`.
No assertions were skipped or limits changed. This establishes latest full
correctness under the serial test envelope, not a passing fleet load gate or
a successful parallel full-suite run within the same memory ceiling.

The latest lease control initially stopped once all first batches had started,
leaving 48 quiet leases after bounded batches timed out. That failure remains
in `tmp/capacity-latest-lease-control.log`. The harness now waits for actual
completion within the same 30-second budget, and uses UUID organization slugs
to avoid cross-VM fixture collisions in a retained database. The corrected
control passed in six rounds: maximum first-batch delay **10,119 ms**, all
2,475 quiet leases moved by **10,531 ms**, and all 25 locked noisy leases
remained untouched (`tmp/capacity-latest-lease-completion-uuid-control.log`).
The generation reserve/owner-death export control passed again, cancellation
**533 ms**, with no partial chunks or scratch files
(`tmp/capacity-latest-export-control.log`).

The next diagnostic comparison requires a resource-isolated workload or an
explicitly approved temporary equal-weight CPU experiment, restoring the
original weight afterwards. No executor policy or admission limit has been
changed. CPU competition is observed, but its contribution to strict fleet
rejections remains unquantified; a passing isolated run would still need to
be reported with its resource envelope rather than erase these failed runs.

### Smaller-pool validation without changing synchronous admission

The owner requested smaller pools before changing executor policy. The same
3,000-host retained fixture ran sequentially with 16 and 32 connections,
without query profiling, limit overrides, or executor-policy changes. The
initial runs used lazy `mix run` code loading; current commands include the
release-style bootstrap correction described below:

```sh
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity2 LOAD_REUSE=true LOAD_POOL_SIZE=16 mix run --no-start scripts/load-capacity.exs
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity2 LOAD_REUSE=true LOAD_POOL_SIZE=32 mix run --no-start scripts/load-capacity.exs
```

| Pool per node | Normal accepted / 3,050 | Re-enrollment accepted / 20,996 | Quiet accepted / 200 | Re-enrollment p95 / p99 |
| --- | ---: | ---: | ---: | ---: |
| 16 | 3,044 | 20,985 | 200 | 65 / 80 ms |
| 32 | 3,044 | 20,979 | 200 | 62 / 76 ms |

Both commands exited 1 and both had zero failed reconciliations. All six
normal rejections in each run were check-ins. Re-enrollment rejected four
check-ins/seven observations at 16, and fourteen check-ins/three observations
at 32. Raw logs are `tmp/capacity-small-pool-{16,32}-fleet.log`. All eleven
re-enrollment rejections at 16 were attributed to organization concurrency;
at 32, nine maintenance and three bulk rejections were attributed, with five
not classified by the original admission telemetry. Three of each run's
normal rejections were likewise unclassified. Retained history grows between
runs, and ambient CPU contention varies: these are strict validation
failures, not a controlled finding that either pool is faster or requires
more PostgreSQL compute.

A separate 16-connection diagnostic run adds rejection-stage classification
and independent 50 ms PostgreSQL activity snapshots. It retained six normal
and eighteen re-enrollment rejections, accepted all 200 quiet requests, and
had zero failed reconciliations. The normal rejections were three credential
lookup-capacity failures and three organization maintenance-concurrency
failures, clustered within 61 ms. Re-enrollment had two credential-capacity
failures and sixteen organization-concurrency failures (nine maintenance,
seven bulk). This identifies the gates, not why their holders were delayed.

The snapshots recorded at most three active database backends, including
autovacuum, and at most two idle-in-transaction backends. Adjacent snapshots
around the normal rejection cluster showed zero to two active statements;
several later rejections coincided with `ClientRead` holders and transaction
lock waits. These observations do not demonstrate PostgreSQL connection
exhaustion, but sampling can miss short bursts and does not measure whether
an application still has an idle connection checked out. The observer now
counts client connections separately and includes backend type in activity.
The retained diagnostic files are
`tmp/capacity-small-pool-16-profiled-fleet.log` and
`tmp/capacity-small-pool-16-db-profile.jsonl`.

Admission still spans synchronous acceptance and reconciliation. Every
accepted check-in still renews its lease in its own transaction; only
authenticated-contact timestamps are coalesced off the request path. Neither
16 nor 32 is yet validated as a launch default, and the earlier 64-connection
failures remain relevant. No runtime default or admission fraction changed.

#### Verified code-loading mismatch and corrected validation

The next diagnostic run snapshots the active permit holders' stacks when an
ordinary request is rejected. During the normal-phase failures those holders
were in `:code_server.call/1` / `:code.ensure_loaded/1`, including
`AgentController.accepted/4` calling `Jobs.jobs_waiting?/2` and Ecto queryable
loading. That run retained three normal rejections, thirty-two re-enrollment
rejections, quiet 200/200, and zero failed reconciliations. Its raw witnesses
are `tmp/capacity-small-pool-16-holder-{fleet.log,db-profile.jsonl}`.

The Dockerfile builds `mix release`. `mix help release` documents the default
`RELEASE_MODE=embedded`, which preloads modules before serving traffic;
`mix run` instead lazily loads code. The fixture now explicitly preloads the
started runtime applications' modules, excluding the Mix/Hex build tools,
before starting workload traffic. It makes no synthetic warm-up requests,
changes no production code or admission limits, and reports
`application_modules_preloaded: true`. An initial attempt also included build
tools and aborted on Hex archive modules absent from the code path; those
setup errors are retained in
`tmp/capacity-release-preload-build-tools-error-{16,32}.log`.

With that bootstrap correction, fresh processes reran the same strict
16/32-connection matrix without query profiling:

| Pool per node | Normal accepted / 3,050 | Re-enrollment accepted / 20,996 | Quiet accepted / 200 | Re-enrollment p95 / p99 |
| --- | ---: | ---: | ---: | ---: |
| 16 | 3,050 | 20,995 | 200 | 61 / 72 ms |
| 32 | 3,050 | 20,978 | 200 | 58 / 67 ms |

Normal-phase throttles disappeared in both runs, supporting the verified
code-loading diagnosis. Both still exited 1 because re-enrollment did not
pass. At 16, one check-in hit maintenance organization concurrency; all
observations succeeded. At 32, sixteen check-ins and two observations were
rejected: eight credential-lookup capacity failures, six maintenance and two
bulk organization-concurrency failures, and two post-authentication lookup
capacity failures (ten post-authentication rejections versus eight explicit
domain-admission rejections). Both had zero failed reconciliations, and all
100 noisy new-lease requests were correctly backpressured. Logs are
`tmp/capacity-release-loaded-pool-{16,32}-fleet.log`.

These are still validation failures, not permission to select the better
looking run or a finding that 16 connections outperform 32. The raw failures
remain alongside the correction. Neither budget is yet a validated launch
default, and a lower minimum PostgreSQL instance size has not been measured.

#### Post-preload checkout and holder diagnostic

Ordinary rejection snapshots now include DBConnection's ready-connection and
checkout-queue metrics, with no SQL or per-query handler required. Intentional
lease-control rejections are excluded. A separate 16-connection run with the
independent PostgreSQL and OS observers accepted normal 3,047/3,050,
re-enrollment 20,939/20,996, and quiet 200/200, with zero failed
reconciliations. All 60 rejected ordinary requests had **11–15 connections
ready and zero checkout waiters** in the post-rejection snapshot. No captured
permit-holder stack was waiting on the code server. These failures therefore
cannot be described as observed connection-pool exhaustion.

Snapshots within 75 ms of those rejections include organization transaction
lock waiters, root holders waiting for the application (`ClientRead`), and
unblocked `DataFileRead` waits. The historical unmatched-component-evidence
query was caught in `DataFileRead` at 149.608 ms statement age, within a
477.671 ms transaction; the longest sampled organization transaction-lock
wait was 123.312 ms. The OS observer reached 3,221,209,088 bytes against the
3,221,225,472-byte workload ceiling. Memory-limit events increased from
327,063 to 327,273, without another OOM kill during this diagnostic. These are
mixed I/O, application-progress, and resource-pressure witnesses, not proof
that CPU priority alone explains every tail. The observers add overhead, so
this is diagnostic evidence, not a replacement for the unprofiled matrix.

Retained files are `tmp/capacity-release-pool16-ready-fleet.log`,
`tmp/capacity-release-pool16-ready-db-profile.jsonl`, and
`tmp/capacity-release-pool16-ready-os-profile.jsonl`. The subsequent full
serial precommit attempt also terminated with exit 137 before a result
(`tmp/capacity-smaller-pools-precommit.log`); it does not supersede the
earlier completed 3,130-check serial pass.

Check-in registration now join-preloads its existing source and retains it
on the returned agent for response assembly. This removes two source reads
from an existing-installation check-in without changing admission, lease
renewal, or lifecycle fences. All 176 inventory, registration-concurrency,
installation-key, and agent-controller regressions passed. The subsequent
unprofiled 16-connection fleet run accepted normal 3,050/3,050, re-enrollment
20,933/20,996 (48 check-ins and 15 observations rejected), and quiet 200/200,
with zero failed reconciliations. Its re-enrollment p95/p99 were 61/77 ms.
This removes verified redundant work but does **not** close the strict gate;
`tmp/capacity-source-reuse-pool16-fleet.log` retains that failure.

The captured historical component-finding query led to a further scoped
anti-join probe. With 312 historical evidence rows, the existing query made
312 global match-index searches, using 997 warm buffers in 1.209 ms. Exposing
the organization/resource predicates guaranteed by the composite evidence FK
lets PostgreSQL scan just that resource's matches. Predicates alone still
read match heap rows: the first scoped execution took 90.345 ms, its warm
repeat 0.373 ms. A transaction-local covering-index probe reduced the warm
plan to 44 buffers, one match-index search, and 0.223 ms (first execution
0.372 ms); the probe index was rolled back. This establishes less work, not
a general latency promise or a cold-cache speedup.

The implementation now supplies those predicates and adds a covering
organization/resource match index including `component_evidence_id`. It
preserves all evidence, ambiguity semantics, existing lookup indexes, and
transaction/lifecycle boundaries. All 269 combined catalog, inventory,
intake, topology-generation, background, lease-sweep, and export regressions
passed. Probe plans are retained in
`tmp/capacity-catalog-scoped-antijoin-plans.log` and
`tmp/capacity-catalog-covering-antijoin-plans.log`. Production index-build
duration and deployment remain unverified; the new migration has run only
against disposable local databases.

## Remaining launch gates

* A subsequent integrated fleet run rejected one normal check-in and seven
  re-enrollment requests (one check-in, six observations); the quiet control
  accepted 200/200, with zero failed reconciliations. Preserve
  `tmp/capacity-neighbor-fleet.log`; this run did **not** pass the strict gate.
  A trigger-on/off/on probe had warm medians of 80/80 ms and did not establish
  the trigger as the cause. The isolated rerun passed normal 3,050/3,050 and
  quiet 200/200 but rejected 18 re-enrollment requests (one check-in and 17
  observations, 87/387 ms p95/p99), also with zero failed reconciliations.
  `tmp/capacity-neighbor-isolated-fleet.log` retains that failure. Sequential
  native-table versus generation-view probes did not establish a view
  regression (warm medians 95 vs 83 ms); canonical-lock tails remain under
  investigation. No defaults have been raised to mask them.
  Loading immutable component evidence once per observation and skipping
  impossible existing-match reads for newly inserted evidence removes 23
  SELECTs from each fresh twelve-component inventory. All 93 reconciler and
  component-match regressions pass. That change alone did **not** close the
  gate: `tmp/capacity-component-prefetch-fleet.log` records normal 3,050/3,050,
  re-enrollment 20,984/20,996 (five check-ins and seven observations rejected,
  67/88 ms p95/p99), and quiet 200/200, with zero failed reconciliations.
  The profiled canonical-lock waits reached 701 ms. The harness now separates
  post-acquisition canonical-fence time from waiting-query time and retains
  the five slowest SQL shapes per long transaction, without logging parameters.
* The measured lease-sweep delay must be paired with a supported ready-org and
  backlog envelope; it does not establish a maximum for unbounded load.
* Neither the smaller-pool profiles nor 64 connections have a consistently
  passing integrated fleet gate. The 64-connection default remains
  experimental, not an established minimum. Operators must budget all
  replicas against PostgreSQL's connection limit. These results do not yet
  establish a safe smaller-pool default or a database instance-size floor.
