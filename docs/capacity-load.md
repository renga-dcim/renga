# Intake capacity validation (RFD 21)

**Launch gate: NOT PASSED.** The checked-in test demonstrates bounded intake
and an isolated quiet neighbor, but the candidate defaults reject realistic
single-organization load. They must not be described as established safe
launch defaults. Raising a limiter until this test passes is not a substitute
for measuring database contention and preserving the other organization's
reserve.

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
another fleet load concurrently. Allow at least 64 application connections
plus PostgreSQL's administrative reserve and any other running services.

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
`max((pool_size - 3) / 3, 1)` integer slots; one organization can use at most
half a lane (at least one slot). The two authentication lanes each have
`max(pool_size / 8, 1)` slots. The recorder, job sweep and general background
rotation use separate execution capacity. Per-organization overrides cannot
remove the hard half-lane isolation cap. These are bounded execution lanes,
not physically separate PostgreSQL pools. Small pools, including the runtime
default of ten, have less isolation headroom; this run does not validate them.

## Recorded results

Run in an Amp Linux x64 orb with local PostgreSQL, a 64-connection application
pool, candidate defaults unchanged, and no concurrent test suite. The final
run reused the fully seeded fixture in `renga_test_capacity2`. It exited 1.

| Phase | Requests | Accepted (202) | Throttled (429) | p95 / p99 | Failed reconciliations |
| --- | ---: | ---: | ---: | --- | ---: |
| Normal schedule | 3,050 | 3,049 | 1 | 80 / 146 ms | 0 |
| Full re-enrollment | 20,996 | 8,149 | 12,847 | 1,503 / 1,746 ms | 0 |
| Quiet neighbor under noisy bulk saturation | 200 | 200 | 0 | 121 / 149 ms | 0 |

Initial seeding accepted all 6,000 requests, with p95/p99 257/422 ms and no
failed reconciliations, in 557,853 ms. The final normal phase took 59,986 ms,
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
Archive **creation** remains an unbounded background snapshot/task and is not
covered by the expiry/reclamation fix.

## Remaining launch gates

* Profile and correct the re-enrollment bottleneck, then rerun every phase at
  a documented deployment size without weakening the quiet tenant's reserve.
* Implement neighbor-expiry staging at a fixed evidence watermark, including
  adjacency and neighbor/cable findings, with resumable batches and atomic
  version-checked publication. The current whole-organization transaction is
  rolled back on a background deadline, which prevents partial publication
  but can repeatedly time out without making progress. It is **not** the
  resumable-generation contract in RFD 21.
* The measured lease-sweep delay must be paired with a supported ready-org and
  backlog envelope; it does not establish a maximum for unbounded load.
* Bound and fairly admit archive generation before claiming deployment-wide
  fair background isolation. Its repeatable-read snapshot cannot simply be
  split into independently committed batches without losing archive consistency.
