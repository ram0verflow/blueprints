## What

New blueprint `postgres-expand-contract-column-migration`: **Change a Postgres Column Without Downtime (Expand and Contract).**

Changing a column on a busy table cannot be done with one `ALTER TABLE` without locking writers or breaking the app version that still reads the old column. Examples: dollars to cents, `int` to `bigint`, a renamed or normalized field. The standard answer is expand and contract, and this flow runs it end to end:
- **expand:** a new column, plus a trigger that keeps it in sync on every write;
- **backfill** in batches inside a `LoopUntil`, with a KV checkpoint, so a killed run resumes where it stopped;
- **verify** every row through the same transform;
- **contract** (drop the trigger and the old column) only after a person approves and a second verification passes.

`action: rollback` undoes the expand, and refuses once the old column is gone.

**Demo mode needs only Postgres:** it creates `demo_orders` with 100,000 rows and migrates `amount` (numeric dollars) to `amount_cents` (bigint).

## Why it is different

**The gap:** the catalog's database-change blueprints are the six Liquibase flows (`liquibase-migrate-on-release`, `liquibase-pre-deploy-gate`, `liquibase-tagged-rollback`, …). They apply a changelog in one step. None of them keeps an old and a new column in sync during a rollout, backfills in resumable batches, proves the data matches, or gates the destructive step behind an approval. No open or closed PR does either (checked 2026-10-15).

It is a day-2 operation with its safety mechanics in the flow, not in a runbook:
- `lock_timeout` on every DDL, retried only on lock timeouts;
- a transform tried on a sample before it goes into a trigger;
- a kill-safe checkpoint;
- two verifications;
- a rollback that refuses when it would lose data.

The `LoopUntil` + KV checkpoint pattern is reusable for any batched job.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-expand-contract-column-migration/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `from_ci` (`Webhook`, key from a secret). `concurrency` limit 1.
2. `seed` (`If`) → `create_demo_table` (demo only).
3. `action_switch` (`Switch`):
   - **`migrate`:**
     - `expand` (`Queries`, a `DO` block): checks the table, the integer key and the old column; tries the transform on 1000 rows; adds the column; installs the sync trigger;
     - `start_point` (`OutputValues`, the KV checkpoint);
     - `backfill` (`LoopUntil`): `batch` (`Query`, one `UPDATE … WHERE key IN (next batch)`) → `checkpoint` (`kv.Set`);
     - `verify` → `verification_gate` (`If` → `Fail`);
     - `request_approval` (Slack) → `approve_contract` (`Pause`, BOOL + note);
     - `decision` (`If`): `reverify` → `reverification_gate` → `contract` → `forget_checkpoint` → `report_done`, or `report_kept`.
   - **`rollback`:** `undo_expand` → `forget_checkpoint_after_rollback` → `report_rollback`.
4. `errors` → `alert_failure`: the task, Postgres's message, and where a re-run resumes.

## Error handling

- **Lock queues.**
  - An `ALTER TABLE` waiting behind a long transaction blocks every query on the table that comes after it.
  - Every DDL runs with `lock_timeout` (5 s) and is retried 5 times, 10 s apart, inside the `DO` block. Only `lock_not_available` is retried; any other error fails at once.
  - Found while testing: the first version used Kestra's task `retry`, which also retried deterministic errors such as a bad transform, delaying the alert by 45 s.
- **A broken transform never reaches the trigger.** It is tried on 1000 rows first, so `bigintt` or an unknown column fails `expand` before anything is created.
- **Kill-safe.** The checkpoint is saved after each batch. A re-run starts after it, so at most one batch is redone, and redoing it is harmless.
- **The trigger respects the new column.** It only computes the new value when the old column changed (or on an insert without one), so an app that already writes `amount_cents` is not overwritten.
- **Writes that bypass the trigger block the contract.** For example `session_replication_role = replica`. The alert lists the first differing keys. The re-check after the approval catches a row that changed while the run was waiting.
- **Found while testing on 2.0.1:** `Pause.onPause` sent the approval message again after the resume (four Slack messages for one approval), so the request is now a plain task before the `Pause`.

## Hacktober requirements

- **3+ runnable tasks:** `expand`, `batch`, `checkpoint`, `verify`, `contract`, `undo_expand`, `request_approval`, `report_done`, `alert_failure`
- **Flowable tasks:** `Switch`, `LoopUntil`, `Pause`, `If` (×5), `concurrency`
- **Triggers:** `Webhook` (from the deploy pipeline)
- **Non-core plugins:** `plugin-jdbc-postgres`, `plugin-slack`

## Testing

Every case ran on the final revision on both `kestra/kestra:v2.0.1` and `kestra/kestra:latest` (2.0.6). The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations. The numbers below are from 2.0.1. On 2.0.6 only the random data differed: for example, case D found 2 bad keys instead of 3, because case C's random deletes had removed row 7.

PostgreSQL 16 (`postgres:16-alpine`), `demo_orders` with 100,000 rows, a local Slack sink. Independent checks ran in `psql` next to the flow.

| Case | Result |
|---|---|
| A. Happy path, approved | ✅ "backfilled and verified (100000 rows, 0 mismatches; this run started at id > 0 and ran 6 batches)". While paused, an insert and an update through the old column got `amount_cents` 1234 and 725 from the trigger, and an update that wrote only `amount_cents = 4200` was kept. Approved → "DONE: amount dropped, amount_cents verified on 100001 rows"; trigger, function and checkpoint gone |
| E. Declined | ✅ "paused in the expanded state … (declined: mobile app still reads amount)"; `amount` and the trigger kept, and a new insert was still synced |
| E2. `migrate` again after the decline | ✅ "started at id > 100000 and ran 1 batches", then contracted on approval |
| B. Killed mid-backfill (`batch_size: 2000`, `batch_interval: PT0.5S`) | ✅ Killed with the checkpoint at 30000 (32000 rows updated, one batch not yet checkpointed). The re-run "started at id > 30000 and ran 36 batches"; independent check 0 mismatches |
| C. 1500 × (update + insert + delete) in separate transactions during the backfill | ✅ Verify passed; independent check over 100,027 rows: 0 mismatches |
| D. 3 rows changed with `session_replication_role = replica` | ✅ FAILED at `verification_failed`: "MIGRATION BLOCKED: 3 of 100027 rows have amount_cents different from … (keys 5, 6, 7). Nothing was dropped"; checkpoint kept |
| J. One row changed the same way while waiting for approval, then approved | ✅ FAILED at `reverification_failed`: "while the run waited for approval, 1 of 100027 rows stopped matching. Nothing was dropped" |
| G. `action: rollback` | ✅ "ROLLED BACK: trigger and amount_cents removed, amount untouched, checkpoint cleared" |
| H. `rollback` after a contract | ✅ FAILED: "refusing to roll back: old column amount is already dropped, amount_cents holds the only copy of the data" |
| I. A 25 s transaction holds a lock on the table during `expand`; an app query runs every 0.3 s | ✅ With `lock_timeout: 0` (no timeout) the app query waited up to 24.1 s. With the default 5 s it waited at most 5.0 s, and `expand` succeeded on its third try once the transaction ended |
| I3. Lock held for 90 s, `lock_timeout: 2s` | ✅ FAILED: "no lock on demo_orders after 5 tries of lock_timeout 2s; a long transaction holds it (see pg_stat_activity)"; no column or trigger created |
| L. `transform: CAST(amount * 100 AS bigintt)` / an unknown column | ✅ FAILED at `expand`: `type "bigintt" does not exist` / `column "amount_usd" does not exist`; no trigger created |
| M. Table that does not exist / `table: "orders; drop table x"` | ✅ "table public.no_such_table does not exist" / HTTP 422 from the input `validator` |
| K. Webhook | ✅ Key from the secret → HTTP 200; wrong key → HTTP 404 |
| F. `approval_timeout: PT10S`, run on its own | ✅ "paused in the expanded state … (no decision within 0.2 min)"; `amount` and the trigger kept. See the note on `Pause` below |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-expand-contract-column-migration/run-gantt.png" alt="Gantt view of a migration: expand, backfill batches, verify, approval, contract" width="800">

## Notes

- **Integer key required.** The checkpoint is the last key done. Tables keyed by UUID would need a different cursor; "How to extend" does not cover it.
- **Indexes on the new column** belong in their own `CREATE INDEX CONCURRENTLY` task, which cannot run in a transaction; this is listed under "How to extend".
- **Not tested:** PostgreSQL versions other than 16, partitioned tables, and tables with other `BEFORE` triggers that change the old column.
- **Kestra `Pause` timeout, found while testing (2.0.1 and 2.0.6).**
  - In 7 of 16 approval-timeout runs across these four blueprints, the `Pause` stayed PAUSED after `pauseDuration` ran out.
  - Each stuck run started right after another run of the same flow had been resumed, and all four flows have `concurrency` limit 1.
  - A stuck run holds the flow's queue until someone answers or kills it. It changes nothing in the meantime.
  - A 2-task flow with `concurrency` and a `Pause` reproduced it once, but not on a clean repeat.
  - Run on their own, the timeout cases in the table passed on both versions. The docs tell users to answer or kill a waiting run before starting another.
- Tags: `Data, Infrastructure`; the tag validator passes on this branch.
