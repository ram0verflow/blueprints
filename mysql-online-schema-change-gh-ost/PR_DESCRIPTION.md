## What

New blueprint `mysql-online-schema-change-gh-ost`: **Online MySQL Schema Change with gh-ost and an Approved Cut-Over.**

A plain `ALTER TABLE` on a large, busy MySQL table locks or stalls writes and floods the replicas. [gh-ost](https://github.com/github/gh-ost) avoids that: it copies the table to a ghost table with the new schema, follows the binlog, and swaps the two tables in a short atomic cut-over. This flow wraps gh-ost in the safety steps a team needs before it trusts the swap:
- a dry run of the ALTER;
- a copy that throttles on replica lag;
- a row count and checksum comparison of the ghost table with the original;
- a postponed cut-over that waits for a person;
- cleanup of every gh-ost table on a decline, a timeout or a failure.

## Why it is different

**The gap:** the catalog has no online schema change for MySQL. The six Liquibase blueprints (`liquibase-migrate-on-release`, `liquibase-pre-deploy-gate`, `liquibase-tagged-rollback`, …) apply changelogs, so a column added to a large MySQL table is still a locking `ALTER TABLE`. No blueprint uses gh-ost or pt-online-schema-change, and no open or closed PR does either (checked 2026-10-15).

It is a day-2 operation with safety mechanics around each step:
- the dry run catches bad SQL, renames and leftover tables before any copy;
- throttling on replica lag and load;
- two consistent verifications;
- an approval for the exact moment of the swap;
- cleanup that never drops the original or the previous table.

It also teaches a reusable Kestra pattern: a long-running worker task and a human gate running in `Parallel`, coordinating through a one-row control table.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/mysql-online-schema-change-gh-ost/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `from_ci` (`Webhook`, key from a secret). `concurrency` limit 1.
2. `build` (`If`) → `build_ghost_image` (`docker.Build`): gh-ost v1.1.11 built from source, plus the mysql client.
3. `dry_run` (gh-ost without `--execute`, Docker runner).
4. `open_control_row` (MySQL `Queries`): creates `_<table>_kestra`.
5. `migrate` (`Parallel`):
   - **`run_ghost`:**
     - runs gh-ost `--execute` with `--postpone-cut-over-flag-file`, `--max-lag-millis`, `--throttle-control-replicas`, `--max-load` and `--critical-load`;
     - every 5 s writes gh-ost's status to the control row and reads the decision;
     - on `cutover` removes the flag file, on `abort` sends `panic`.
   - **`gate`** (`Sequential` with its own `errors`):
     - `wait_for_copy` (`LoopUntil` over a MySQL `Query`) waits until the cut-over is postponed;
     - `verify` (`LoopUntil`) compares the two tables;
     - `request_approval` (Slack) → `approve_cut_over` (`Pause`, BOOL + note) → `send_decision`.
     - If the gate fails, `abort_on_gate_failure` tells gh-ost to stop.
6. `final_state` → `report` (`If`): DONE or ABORTED on Slack.
7. `finally` → `cleanup`: drops `_gho`/`_ghc`, the empty sentry table of a failed cut-over (only if it carries gh-ost's `ghost-cut-over-sentry` comment), and the control table.
8. `errors` → `alert_failure`: the task and gh-ost's or MySQL's error.

## Error handling

- **Bad SQL, renames and leftovers stop at the dry run**, with MySQL's message, e.g.:
  - "Error 1064 (42000): … near 'BIGINTT NULL'";
  - gh-ost's rename precaution (`--approve-renamed-columns`);
  - "table `_orders_del` already exists" from the previous migration.
- **Replica lag and load throttle the copy.** The approval message says how long it was throttled.
- **The cut-over cannot block writes for long.** Each attempt waits at most `cut_over_lock_timeout_seconds` for its lock and is retried. If every retry fails, gh-ost gives up and the table is unchanged.
- **No proof, no swap.** The comparison reads both tables in one statement, so from the same snapshot. Columns added or dropped by the ALTER are excluded. It is retried 10 times, because gh-ost applies binlog events with a small delay. A ghost table that never matches is never offered for approval.
- **Nothing left behind.**
  - Found while testing: a failed cut-over leaves an empty `_<table>_del` sentry table, which blocks the next migration. `cleanup` now drops it, but only when it has gh-ost's sentry comment, so a `_del` table holding the previous data is never touched.
  - Found while testing: the alert first said "exit code 1" instead of gh-ost's reason, because the failure line went to stdout. It now goes to stderr and is quoted.

## Hacktober requirements

- **3+ runnable tasks:** `build_ghost_image`, `dry_run`, `open_control_row`, `run_ghost`, `read_state`, `compare`, `send_decision`, `cleanup`, `report_done`, `alert_failure`
- **Flowable tasks:** `Parallel`, `Sequential` (with `errors`), `LoopUntil` (×2), `Pause`, `If` (×4), flow `finally`, `concurrency`
- **Triggers:** `Webhook`
- **Non-core plugins:** `plugin-docker` (`Build`), `plugin-script-shell` with the Docker task runner, `plugin-jdbc-mysql`, `plugin-slack`

## Testing

Every case ran on the final revision on both `kestra/kestra:v2.0.1` and `kestra/kestra:latest` (2.0.6). The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations. The numbers below are from 2.0.1; case K ran on 2.0.1 only. On 2.0.6 case E2 counted 7 lock timeouts instead of 8; everything else matched.

Test setup:
- MySQL 8.0 primary and replica with GTID, ROW binlog and FULL row image; the replica was passed as `throttle_replicas`.
- `shop.orders` with 300,000 rows (600,000 in case B), migrated with `ADD COLUMN amount_cents BIGINT NULL, ADD INDEX idx_created_at (created_at)`.
- A local Slack sink.

| Case | Result |
|---|---|
| A. Happy path | ✅ Paused with "Ghost table matches the original: 300000 rows, checksum 4020281279 over id,customer,amount,created_at". Approved → "DONE … is live; the previous table is kept as _orders_del"; the column and index exist, `_gho`/`_ghc`/control table gone |
| J. 1500 × (insert + update + delete) during the copy and the wait (`chunk_size: 500`) | ✅ Verification matched; after the swap `orders` and `_orders_del` both have 300,000 rows and 0 rows differ on the common columns |
| B. Replica SQL thread stopped for 20 s during the copy (600,000 rows) | ✅ Copy throttled; approval message "Throttled for about 20 s on load or replica lag"; then cut over |
| C. Declined | ✅ "ABORTED before the cut-over (declined: wait for the marketing campaign to end)"; only `orders` left, unchanged |
| D. `approval_timeout: PT15S`, run on its own | ✅ "ABORTED … (no decision within the approval window)"; only `orders` left. See the note on `Pause` below |
| E. A transaction holds a row lock on `orders` for 20 s during the cut-over | ✅ "DONE … (the cut-over hit the lock timeout 4 time(s) and retried)" |
| E2. The lock is held for 60 s, `cut_over_retries: 3` | ✅ FAILED: "GH-OST FAILED after 8 cut-over lock timeouts: Error 1205 (HY000): Lock wait timeout exceeded"; `orders` unchanged (300,000 rows), sentry table removed |
| H. A row of `_orders_gho` changed directly while the cut-over is postponed | ✅ FAILED at `verification_failed` after 10 tries (checksums differ); no approval requested; gh-ost aborted; ghost tables removed |
| F. `ADD COLUMN amount_cents BIGINTT NULL` / `DROP COLUMN no_such_column` / `CHANGE COLUMN amount total …` | ✅ All rejected by `dry_run`: MySQL's syntax error / gh-ost "unable to ALTER ghost table" / gh-ost's renamed-columns precaution |
| G. MySQL stopped | ✅ FAILED at `dry_run`: "dial tcp 127.0.0.1:3306: connect: connection refused" |
| K. `build_image: true` | ✅ `docker.Build` built the image and `dry_run` and `run_ghost` ran on it (see Notes) |
| I. Webhook | ✅ Key from the secret → HTTP 200; wrong key → HTTP 404 |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/mysql-online-schema-change-gh-ost/run-gantt.png" alt="Gantt view of a migration that waited for approval and cut over" width="800">

## Notes

- **Test image.**
  - The test environment has no direct internet, so `go install` inside `docker.Build` could not reach the Go proxy.
  - The runs used an image built from the same Dockerfile with the proxy's CA added. Case K ran the `Build` task itself on a two-line Dockerfile based on that image, to show the image the task builds is the one the next tasks use.
- **Test copies used `networkMode: host`** to reach the local MySQL; the blueprint does not set it.
- **`--allow-on-master`.** gh-ost connects to the primary and reads lag from `throttle_replicas`. gh-ost prefers to inspect a replica; "How to extend" says how.
- **Not tested:** MySQL 5.7, Aurora/RDS (which need `--assume-rbr` and other flags), and tables without a primary key (gh-ost refuses them).
- **Kestra `Pause` timeout, found while testing (2.0.1 and 2.0.6).**
  - In 7 of 16 approval-timeout runs across these four blueprints, the `Pause` stayed PAUSED after `pauseDuration` ran out.
  - Each stuck run started right after another run of the same flow had been resumed, and all four flows have `concurrency` limit 1.
  - A stuck run holds the flow's queue until someone answers or kills it. It changes nothing in the meantime.
  - A 2-task flow with `concurrency` and a `Pause` reproduced it once, but not on a clean repeat.
  - Run on their own, the timeout cases in the table passed on both versions. The docs tell users to answer or kill a waiting run before starting another.
- Tags: `Data, Infrastructure`; the tag validator passes on this branch.
