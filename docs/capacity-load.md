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
not to meet the default limits. The exact contention source is not established
by these counters and needs database wait/query profiling.

## Remaining launch gates

* Profile and correct the re-enrollment bottleneck, then rerun every phase at
  a documented deployment size without weakening the quiet tenant's reserve.
* Implement neighbor-expiry staging at a fixed evidence watermark, including
  adjacency and neighbor/cable findings, with resumable batches and atomic
  version-checked publication. The current whole-organization transaction is
  rolled back on a background deadline, which prevents partial publication
  but can repeatedly time out without making progress. It is **not** the
  resumable-generation contract in RFD 21.
* Establish a maximum ready-organization scheduling delay for job expiry under
  overload. Persistent round-robin position and independent job-sweep capacity
  prevent retention from blocking leases, but alone do not establish a maximum
  delay for an unbounded number of ready organizations.
* Audit remaining assignment, domain-verification, export, and invitation
  workers before claiming deployment-wide fair background isolation. Those
  workers are outside the rotations introduced in this change.
