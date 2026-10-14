Follow-up to #1215 (`elasticsearch-mapping-explosion-guard`). One file changed.

## Fixes

### 1. New keys at the document root are detected (follow-up from a review pass, reproduced while testing)

New fields were grouped under the objects above them, and a top-level key has no object above it, so an explosion of top-level keys (the most common case for "log the whole user payload") was never reported. Reproduced on main: 80 new top-level keys took the index from 2 to 82 fields with no alert and no proposal.

Now a path whose top-level key is new is also counted under `(root)`. The deepest qualifying object still wins, and `(root)` only collects keys that are new at the top level, so growth spread across existing objects is never turned into a root-wide `dynamic: false`. The fix path for `(root)` (mapping `dynamic: false` at the root, and in the template) already existed and is now reachable.

Tested: 80 new top-level keys → alert "80 new mapped fields under `(root)` … e.g. k000, k001 …"; approved → index and template report `(root)`: dynamic false; 50 more top-level keys afterwards are not mapped (83 fields before and after) and the next run is silent.

### 2. One baseline per cluster and index pattern (follow-up from a review pass)

The KV key was the fixed name `baseline`, so two copies of the flow in a namespace (or two runs with a different `index_pattern`) overwrote each other's baseline. It is now `es_mapping_baseline_<sha256 of es_url|index_pattern>`.

Tested: runs for `user-events-*` and `orders-*` created two separate keys; a nested explosion under `payload.user_defined` in `orders-*` was still detected and reported after `user-events-*` had been fixed, and declining it changed nothing.

Upgrade note: the first run after this change starts a fresh baseline under the new key, so it is silent once.

### 3. `recheck` reports an error body instead of crashing (follow-up from a review pass, reproduced while testing)

If the mapping or settings read-back returned 4xx (for example the index was deleted while the approval waited), `recheck` parsed the error body as indices and crashed:

```
if (entry.get('defaults') or {}).get(KEY):
AttributeError: 'int' object has no attribute 'get'
```

so the run failed with a Python traceback in the alert. It now checks the HTTP codes and the body first and reports "fix sent for `payload.extra`, but the result could not be read back (HTTP 404/404: no such index [solo-idx]). Check the mappings by hand."

Tested: same scenario on main (traceback, run `FAILED` at `recheck`) and with the fix (the message above).

### 4. No "Rollover … HTTP skipped" line when rollover is off (follow-up from a review pass)

The outcome message printed `Rollover of <alias>: HTTP skipped` whenever a write alias was set, even with `rollover_on_approval: false`. The line now appears only when the rollover request ran. Tested: an approved fix with rollover off has no rollover line.

### 5. Webhook key read from a secret (follow-up from a review pass)

`key: es-mapping-guard-change-me` → `key: "{{ secret('ES_MAPPING_GUARD_WEBHOOK_KEY') }}"`. The literal key is removed from the trigger description's curl example, and the secret is listed under Secrets. Tested: the secret's value returns HTTP 200 and starts a run; the old placeholder returns HTTP 404.

## How it was tested

Kestra 2.0.1 (`kestra/kestra:v2.0.1`) with Elasticsearch 8.15.3 in Docker and a local Slack sink. The flow passes `POST /api/v1/flows/validate` (no constraints, warnings or deprecations). The same script ran the original flow from main first, for the two reproductions above, then the fixed flow through the scenarios above.
