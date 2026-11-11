# Exploratory asynchronous capacity measurements

**The corrected 3,000-host experiment failed its acceptance gate: 58 re-enrollment requests were throttled, including 54 check-ins. All accepted work drained, but this is not safe launch capacity.** These measurements exercise the core asynchronous path in [PR #339](https://github.com/renga-dcim/renga/pull/339), stacked on the capacity foundation in [PR #338](https://github.com/renga-dcim/renga/pull/338). Stage 2 batching, stage 3 protected leased-output reservations, and immutable topology inputs are missing. The production pool default remains 10; the larger experimental pool is not a recommendation to increase it.

`scripts/load-capacity.exs` follows accepted evidence through autonomous reconciliation, committed success, canonical projections, and reservation debit. Fast HTTP acceptance alone cannot pass. Historical synchronous results in [capacity-load.md](capacity-load.md) are unchanged and are not asynchronous launch evidence.

## What the experiment measures

The run uses the real Phoenix Endpoint in-process, PostgreSQL, production-style connection checkout, and the autonomous fixed-one reconciliation executor. It includes body parsing, credential lookup, admission, acceptance, scheduling, canonical processing, and required refreshes. It does not use TCP/TLS, a built agent, multiple application nodes, concurrent operator mutations, or an external load generator. Results are single-run observations, not repeated-run medians or production guarantees.

| Phase | Workload and required outcome |
| --- | --- |
| Seed | 3,000 hosts with four NICs and twelve individually identified DIMMs; accept and drain before proceeding |
| Normal | 3,000 check-ins spread over 60 seconds, plus 50 inventory reports (hourly inventory equivalent) |
| Full re-enrollment | Replace all 3,000 installation identities over 300 seconds while continuing 60-second check-ins; stable machine/MAC identity must retain exactly 3,000 canonical hosts, 12,000 interfaces, and 36,000 present DIMMs |
| Admission neighbor | Hold the noisy organization's bulk permits; reject its 100 new-lease requests while accepting and draining 100 quiet check-ins and 100 quiet inventories |
| Processing neighbor | Suspend the executor, accept and correlate 500 distinct noisy host roots with matching unit/byte reservations, resume it, then require 20 quiet roots to succeed while noisy work remains pending; finally drain the noisy backlog |

Fresh receipts are joined to their persisted work, observation, and installation. Organization, source, installation, client and database observation IDs, processing position, and acceptance instant must match. Distinct fresh submissions cannot reuse a receipt. Reuse drains any previously accepted seed work before checking the fixture.

**Success latency means acceptance to first observed committed success, an upper bound.** A database-clock sample is recorded only after another connection sees a succeeded work row. This includes canonical writes, required effects, status, and debit commit. The nominal polling interval is 100 ms, but scheduling and query/connection delay can increase observation lag; 100 ms is not an error guarantee. No reconciliation-attempt timestamp is substituted for commit visibility.

Backlog samples use one SQL snapshot for lane totals and unresolved statuses/oldest age. A separate atomic aggregate compares reservations with every unresolved obligation, including quarantine. Each phase drains its fresh receipts; the final scoped backlog must have no unresolved work, units, or bytes. A quarantined obligation, missing receipt, wrong canonical projection, or drain timeout fails the run.

## Large-site acceptance still fails at pool 32

One corrected run on a 2-vCPU, 3,931-MiB orb with PostgreSQL 18.6 (`max_connections=100`) exited 1. It used pool 32, one autonomous executor, default limits, and no concurrent regression suite or other load process. The largest organization had four admitted operations per intake lane; bulk and maintenance rates were each 60,000/minute, installation rate 600/minute/lane, and provisional pending allowances 1,000,000 units / 4,294,967,296 bytes. Those allowances were not exhausted.

| Phase | Accepted / HTTP requests | Succeeded roots | Endpoint p95 / p99 |
| --- | --- | --- | --- |
| Seed | 6,000 / 6,000 | 3,000 | 10 / 18 ms |
| Normal | 3,050 / 3,050 | 50 | 5 / 10 ms |
| Re-enrollment | 20,938 / 20,996 | 2,996 | 10 / 45 ms |
| Admission neighbor | 200 / 200 quiet; 100 expected noisy lease rejections | 100 | 9 / 55 ms |
| Processing neighbor | 40 / 40 quiet | 20 | 12 / 62 ms |

Re-enrollment rejected 54 check-ins and four inventories. Response-stage classification recorded 28 credential-lookup rejections and 30 limits/admission rejections; it does not establish why the holders were delayed. The harness did not retry rejected requests, so this measures first-attempt acceptance, not agent eventual-delivery success. Final canonical projections remained exactly 3,000 hosts, 12,000 interfaces, and 36,000 present DIMMs. That verifies no population doubling, not successful processing of the four rejected reports.

Endpoint percentiles include all recorded phase requests, accepted or rejected. Neighbor-phase durations cover quiet requests; the separately asserted noisy-lease probes are not included in those percentiles.

## Committed work drains, with minutes of backlog lag

All 6,666 accepted roots, including the 500-root noisy prefill, reached visible committed success; final reservations for both organizations were zero. A fast endpoint percentile therefore must not be read as fast reconciliation.

| Phase | Observed-success p95 / p99 | Drain after last phase response | Peak sampled units in one organization |
| --- | --- | --- | --- |
| Seed | 211,808 / 219,295 ms | 221,293 ms | 2,962 |
| Normal | 1,606 / 2,702 ms | 5 ms | 2 |
| Re-enrollment | 220,885 / 224,268 ms | 143,150 ms | 2,251 |
| Admission neighbor | 8,323 / 8,588 ms | 8,623 ms | 98 |
| Processing neighbor (quiet) | 2,806 / 2,806 ms | 2,844 ms | 500 (noisy) |

The oldest sampled pending root reached 220,394 ms in seed and 225,129 ms in re-enrollment. Sampling is not an exact peak bound. Seed acceptance took 40,154 ms; re-enrollment acceptance spanned 299,985 ms, during which processing continued. Drain starts after all phase responses and includes receipt validation, success polling, and debit checks. The short normal drain does not erase latency already spent during its 60-second traffic window.

The processing control verified 500 pending unit-one roots and exactly 933,380 reserved bytes before resuming the executor. All 20 quiet roots then succeeded while 477 noisy roots remained outstanding; the noisy backlog subsequently drained. This establishes overlap for this workload, not general fairness under arbitrary arrival rates or independent capacity for protected job evidence.

## Corrected smoke control

A 12-host run with pool 32, a one-second normal horizon, and a three-second re-enrollment horizon exited 0. This checks instrumentation and controls, not large-site capacity; its normal phase has no hourly inventory report because the fixture has fewer than 60 hosts. Check-ins maintain contact/lease state without creating reconciliation roots, so that phase correctly reports zero roots rather than treating check-ins as canonical processing.

| Phase | Accepted HTTP requests | Succeeded roots | Observed-success p95 / p99 |
| --- | --- | --- | --- |
| Seed | 24 / 24 | 12 | 2,355 / 2,355 ms |
| Normal | 12 / 12 | 0 | Not applicable |
| Re-enrollment | 24 / 24 | 12 | 1,064 / 1,064 ms |
| Admission neighbor | 200 / 200 quiet; 100 expected noisy lease rejections | 100 | 9,900 / 10,356 ms |
| Processing neighbor | 40 / 40 quiet | 20 | 3,364 / 3,364 ms |

The processing prefill held exactly 500 units and 921,845 bytes. Quiet processing completed with 477 noisy roots still pending, establishing overlap rather than merely testing an idle scheduler. All noisy work then drained and both organizations ended with zero reservations. These are separate admission and processing controls: held permits alone are not evidence of processing fairness.

## Controls reject false success and support fixture reuse

| Control | Observed result |
| --- | --- |
| Disable autonomous reconciliation before startup; submit two fresh hosts | Four HTTP requests accepted; drain exits 1 with two pending roots, two units, 3,680 bytes, and zero canonical resources |
| Substitute distinct already-succeeded seed receipt IDs during two-host re-enrollment, preserving the correct echoed new observation IDs | Drain exits 1 with `receipt does not identify submitted obligation`; old successful work cannot stand in for new accepted work |
| Rerun the recorded 12-host smoke fixture with `LOAD_REUSE=true` | Exits 0; both seed and re-enrollment retain 12 hosts / 48 NICs / 144 DIMMs; quiet stable identities still map one-to-one; all reservations drain |

The stale-receipt control modifies only the harness response interpretation in memory, not the server or checked-in source. Its timings are not capacity measurements. The reuse control selects the two recorded smoke organizations; older development fixtures sharing their display names were renamed first. Reuse is a behavior check, not a fresh-database performance comparison.

## Reproduce without changing shared data

Use an otherwise idle, disposable local database; do not run regression suites or another load process concurrently. The harness refuses ordinary test and production database names and retains fixtures for inspection. Stop every process using the disposable database before deleting it.

```sh
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity_async mix ecto.create
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity_async mix ecto.migrate
nix develop --command env MIX_ENV=test MIX_TEST_PARTITION=_capacity_async LOAD_POOL_SIZE=32 mix run --no-start scripts/load-capacity.exs
```

Omitting `LOAD_POOL_SIZE` tests the unchanged production default of 10. No explicit rate, concurrency, or pending-work override is set, but existing pool-derived admission capacity increases with the experimental pool size; this is not the same capacity budget as pool 10. Output includes resolved limits, organization IDs, script SHA-256, request statuses and endpoint duration, receipt counts, committed-success observation percentiles, backlog samples, and final debit/projection assertions. Reconciliation is explicitly enabled before application startup even though test configuration normally disables it.

`LOAD_HOSTS=12 LOAD_BASELINE_SECONDS=1 LOAD_ENROLLMENT_SECONDS=3` runs the smoke workload. `LOAD_REUSE=true` reuses that database's fleet and checks stable canonical identity rather than requiring quiet-host population growth. Keep host count consistent. `LOAD_DRAIN_TIMEOUT_MS` defaults to 300,000 per drain. `LOAD_RECONCILIATION_ENABLED=false` is a negative control: on a fresh fixture, accepted seed work must remain pending and the drain must fail, not report completion.

## Evidence boundaries and remaining gates

The measured application baseline is [4e785fc8](https://github.com/renga-dcim/renga/commit/4e785fc846cdffc289b5197fbd02415f96be1c01); subsequent PR #339 fixture-only corrections do not change the scheduler/API. Both corrected runs used script SHA-256 `f93d03ea1b322149a66f4c934164d573d8405167ba0efbfee0e18b6a1c8d86ea`. Reviewed JSON captures are retained as `.amp/in/artifacts/async-capacity-{full32,smoke}.json` and raw local logs as `tmp/capacity-async-{full32,corrected-smoke}.log`; these disposable outputs are not repository fixtures. The current OpenAPI breaking-change gate for #339 is unresolved and requires its owner's decision; this experiment does not authorize bypassing it. No quota-deferral/retry behavior is measured or inferred from later dependency layers.

Earlier development runs used a reconciliation-attempt timestamp captured before required effects and commit. Their latency percentiles are invalid as completion evidence and are excluded here. The earlier pool-10 full run recorded 3,039/3,050 normal requests and 17,884/20,996 re-enrollment requests accepted, plus 100/200 quiet requests under admission saturation; it exited 1. Those HTTP failures remain evidence against declaring default-10 healthy, but that run is not a corrected, matched latency comparison. Pool 32 changes admission capacity too; neither the failed requests nor invalid completion metrics are represented as a passing default-budget gate.

Before launch, rerun matched realistic workloads after the missing stages land, including protected report/renewal progress at saturation, bounded transactions and organization-lock occupancy, lease-sweep ready delay, continuous-arrival topology publication, failures/retries, and cross-node fencing. The current serial host-root experiment cannot establish those contracts or a safe connection budget across replicas.
