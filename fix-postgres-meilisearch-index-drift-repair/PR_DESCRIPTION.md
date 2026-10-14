Follow-up to #1094 (`postgres-meilisearch-index-drift-repair`). One file changed.

## Fixes

### 1. A batch Meilisearch refuses no longer fails the whole run (found while testing)

The blueprint says "a rejected batch is reported and the other batches still run": each batch is in a `Sequential` with `allowFailure`, and the Loop output marks it `rejected`. On Kestra 2.0.1 that path does not work when `add_documents` fails synchronously, for example with HTTP 413 because the batch is larger than Meilisearch's payload limit. The `Sequential` ends `WARNING`, but the retried `add_documents` attempts leave `FAILED` task runs in the iteration's sub-execution. The sub-execution then ends `FAILED`, so `reindex` fails ("Loop iteration 0 ended in FAILED in sub-execution"). The run stops before the orphan deletes, the wait for Meilisearch tasks and the summary.

Change: `add_documents` uses `options.allowFailed: true`, and the Loop output marks a batch `rejected` when the HTTP code is 400 or more. A new `reason` output carries Meilisearch's message, and the report now says, for example, "3 documents in batches Meilisearch refused to accept (HTTP 413: The provided payload reached the size limit. The maximum accepted payload size is 20 KB.)". Connection errors are still retried; the run still ends `WARNING` when a batch was rejected.

Tested on Kestra 2.0.1 with Meilisearch 1.54.3 (`MEILI_HTTP_PAYLOAD_SIZE_LIMIT=20KB`) and PostgreSQL 16. 50 rows were indexed, then 3 rows got 30 KB bodies (their batch is over the limit) and 2 rows were deleted:
- the flow on main: `FAILED` at `reindex`; the orphans were not deleted (index still 50 documents);
- with the fix: `WARNING`, the rejected batch reported with the message above, the 2 orphans deleted, the index at 48 documents for 48 rows.

### 2. No empty entry in the task uid list (follow-up from a review pass)

`collect_tasks` added a separator before the delete task's uid whenever the reindex Loop had outputs, even if every batch was rejected, which gives `uids: ",12"`. The list is now built from the accepted uids first, so it is `12`. With Meilisearch 1.54.3 the old value happened to work (`/tasks?uids=,12` was accepted; tested by running the fixed flow with only this expression reverted), so this is a cleanup, not a visible bug today.

### 3. Queued runs behind an approval are documented (follow-up from a review pass)

With `concurrency` (limit 1, `QUEUE`), a run waiting up to 24 hours for an orphan-delete approval holds every queued run behind it. Step 1 of "How it works" now says so. Documentation only.

### 4. Webhook key read from a secret (follow-up from a review pass)

`key: meili-drift-change-me` → `key: "{{ secret('MEILI_DRIFT_WEBHOOK_KEY') }}"`. The literal key is removed from the trigger's curl example, and the secret is listed under Secrets. Tested: the secret's value returns HTTP 200 and starts a run; the old placeholder returns HTTP 404.

## Regression check

On Kestra 2.0.1, the flow passes `POST /api/v1/flows/validate`. A normal repair (3 stale rows, 1 orphan, nothing rejected) ends `SUCCESS`, waits for every Meilisearch task, and reports "The index now has 47 documents; the table had 47 rows". A first run on a missing index builds it.
