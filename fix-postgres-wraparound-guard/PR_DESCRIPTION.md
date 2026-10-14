Follow-up to #691 (`postgres-wraparound-guard`). One file changed.

## Fixes

### 1. Overlapping approved runs no longer freeze the same tables twice (follow-up from a review pass, reproduced while testing)

The flow runs hourly and has no `concurrency` limit, on purpose: a 2-hour approval must not hold up monitoring. But two runs could then both be paused with the same "Freeze the oldest tables" proposal. Approving both ran `VACUUM (FREEZE)` on the same tables twice, which on large tables means hours of redundant I/O.

Each table now goes through `freeze_check` right before its `VACUUM (FREEZE)`. It is skipped, and reported as "skipped, …", when:
- a VACUUM is already running on it (`pg_stat_progress_vacuum`), from another run or from autovacuum; or
- its age is below the age shown in the proposal. A table's age only goes down when it is frozen, so another run or autovacuum has already done the work.

Tested on Kestra 2.0.1 with PostgreSQL 16 (20,000 transactions burned, thresholds lowered, two runs paused on the same proposal; run 1 approved and finished, then run 2 approved):
- the flow on main: run 2 froze both tables again ("pg_catalog.pg_amop: age 20007 → 0");
- with the fix: run 2 reports "pg_catalog.pg_amop: skipped, already frozen since the proposal (age now 0)" for both tables, and runs no VACUUM.

Not tested: the "VACUUM already running" branch. A VACUUM could not be kept running long enough on the small test tables to hit it reliably.

### 2. Webhook key read from a secret (follow-up from a review pass)

`key: pg-wraparound-change-me` → `key: "{{ secret('PG_WRAPAROUND_WEBHOOK_KEY') }}"`, listed under Secrets, and the Quick start step that said "change its key" now says to add the secret. Tested: the secret's value returns HTTP 200 and starts a run; the old placeholder returns HTTP 404.

## Validation

The flow passes `POST /api/v1/flows/validate` on Kestra 2.0.1 (no constraints, warnings or deprecations). The Error handling section of the description now covers the overlap guard.
