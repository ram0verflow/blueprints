## What

New blueprint `elasticsearch-mapping-explosion-guard`. Dynamic mapping adds a field for every new key it sees. When the keys come from users, an index reaches `index.mapping.total_fields.limit` (1000 by default), and then every document with a new key is rejected. The flow:
- counts every object, leaf and multi-field per index against its limit (`_mapping` + `_settings`, cluster default included);
- names the object where new fields keep appearing since the last run, with the number of new mapped fields and sample keys;
- alerts Slack once per change, not on every run;
- with on-call approval, sets that object to `dynamic: false` (or `flattened` for new indices) in the index template and `dynamic: false` in the write index, optionally rolls the write alias over, then reads the mappings back and reports the result.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/elasticsearch-mapping-explosion-guard/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `explosion_reported` (`Webhook`, event-based) or `hourly_check` (`Schedule`, disabled)
2. `validate_inputs` (`If`), `check_cluster` (retries, fails fast on 401/unreachable), `fetch_mappings`, `fetch_limits`, `write_alias_lookup` (`If`)
3. `analyze` (`Python`, standard library, Process runner): counts fields, compares with the KV baseline, assigns each new path to the deepest object that gained `object_growth_min` fields
4. `alert_change` (`If`) → Slack; `store_baseline` (KV) advances only after the alert
5. `decide` (`If`) → `wait_for_decision` (`Pause`, 2 h, `apply_fix` BOOL, `template_mode` SELECT)
6. `apply` (`If`): `template_patch` (`If`), `write_mapping` (`Loop` with a `Sequential` allowFailure per index), `rollover` (`If`), `recheck_mappings`, `recheck_limits`, `recheck` (`Python`), `notify_outcome`; else branch `notify_no_change`

The approval form:

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/elasticsearch-mapping-explosion-guard/resume-dialog.png" alt="Resume dialog with apply_fix and template_mode" width="420">

## Error handling

- **Settings checked before any call:** warn below critical, non-empty pattern, rollover needs a write alias.
- **Every HTTP response checked:** `code >= 400` fails with Elasticsearch's `error.reason`, e.g. `Elasticsearch at http://127.0.0.1:9201 answered HTTP 401: unable to authenticate user [elastic] ... Check ELASTICSEARCH_USERNAME and ELASTICSEARCH_PASSWORD`.
- **Retries** with exponential backoff on network calls.
- **Alert once per change:** the baseline advances only after the Slack alert is sent. If Slack is down, the next run re-alerts (extra check C).
- **Each index isolated** in the loop; the recheck reads the mapping back, so the report shows real state, not request status.
- **Nothing changes by default:** a Pause that gets no answer resumes with `apply_fix=false` and posts "no fix was applied ... Nothing was changed" (extra check A).
- **`errors` alert** names the failing task (`check_cluster`, `fail_cluster`, `invalid_settings`, ...).

## Why it is different

The catalog has cluster health and circuit-breaker monitors for Elasticsearch, plus a reconcile guard for search indices against PostgreSQL. None reads the field count against `total_fields.limit`, names the object where dynamic keys land, or changes the mapping. Upstream main has no match for `total_fields`, field-limit or mapping-explosion keywords, and no open PR adds an Elasticsearch mapping flow (checked 2026-10-13).

## Hacktober requirements

- **3+ runnable tasks:** `check_cluster`, `fetch_mappings`, `fetch_limits`, `analyze`, `put_mapping`, `recheck`, notifications
- **Flowable tasks:** `Pause` (with `onResume` inputs), `Loop` with `Sequential` (allowFailure), `If` (×12)
- **Triggers:** `Webhook` (event-based) and `Schedule` (disabled)
- **Non-core plugins:** `plugin-script-python`, `plugin-slack`

## Testing

Tested on `kestra/kestra:v2.0.1` (server 2.0.1) and `kestra/kestra:latest` (server 2.0.5) against Elasticsearch 8.15.3 (`xpack.security` off for the main cluster; a second cluster with security on for the bad-auth case). Slack is a local HTTP sink that stores each POST. Each version was run from a fresh Kestra container.

| Case / Step | Result (2.0.1 and latest, same on both) |
|---|---|
| 1. Healthy cluster, first run | ✅ SUCCESS, no Slack message, baseline stored |
| 2. 80 new numeric keys under `payload.user_defined` | ✅ PAUSED; one alert: "80 new mapped fields under `payload.user_defined` (80 new keys ..., e.g. attr_000 ...)" |
| 3. Same state, second run while 2 waits | ✅ SUCCESS, no new message, no pause |
| 4. Approval (`apply_fix`, `dynamic_false`, rollover on) | ✅ SUCCESS; "83 of 100 fields before, 83 after, `payload.user_defined`: dynamic false"; new index `user-events-000002`: dynamic false; template dynamic false; rollover HTTP 200; "all targets fixed" |
| 5. 50 new keys after the fix | ✅ field count 3 → 3; no alert, no pause |
| 6. 40 string keys under `meta.tags`, approval declined | ✅ alert "80 new mapped fields under `meta.tags` (40 new keys ...)"; resume with `apply_fix=false` → "Nothing was changed"; `meta.tags` still dynamic |
| 7. Elasticsearch unreachable (port closed) | ✅ FAILED at `check_cluster` after retries; errors alert "at `check_cluster`: Connect ... failed: Connection refused" |
| 8. Wrong password (secured cluster) | ✅ FAILED; errors alert "answered HTTP 401: unable to authenticate user [elastic]" |
| 9. Webhook trigger | ✅ HTTP 200, trigger `explosion_reported`, SUCCESS, no message |
| 10. Warn above critical | ✅ FAILED at `invalid_settings` before any cluster call |
| Extra A. No answer, Pause resumes (30 s copy of the flow) | ✅ SUCCESS; "no fix was applied ... Nothing was changed"; mapping unchanged |
| Extra B. Approval with `template_mode=flattened` | ✅ template and new index `payload.user_defined` = flattened; write index dynamic false; 3 → 3 fields after 50 new keys |
| Extra C. Slack down during the alert, then back | ✅ run FAILED with Slack down, baseline kept old state; next run with Slack back re-sent the alert |

All 10 scenarios on the final revision succeeded on both versions. Extra checks A–C also passed on both.

Counting checked against Elasticsearch: an object and its leaf both count (limit 3 with `a`, `a.b`, `c` rejects `d`), and so does each multi-field (`f` + `f.raw` counts 2).

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/elasticsearch-mapping-explosion-guard/run-gantt.png" alt="Gantt view of the approved run: 32 tasks, 34.25 s" width="800">

## Notes

- The count is what the limit counts: every object, leaf and multi-field. Runtime fields are not included.
- A string key maps two fields (text and keyword sub-field), so `object_growth_min` (default 20) means 10 string keys.
- Write index: `dynamic: false` on an existing object is the only fix that applies; `flattened` only applies to the template for new indices (a flattened field cannot replace an object that already has subfields).
- No flow `concurrency`: a Pause holds the slot for up to two hours, so limit 1 would delay monitoring. Overlapping runs can double-alert in the seconds between analysis and the KV write.
- Not exercised by a test: the Loop isolation for a `_mapping` update that fails (no failing update was forced), and Elasticsearch 7.x.
- Required secrets: `ELASTICSEARCH_USERNAME`, `ELASTICSEARCH_PASSWORD` (basic auth, sent to `es_url`), `SLACK_WEBHOOK_URL`.
- Tag validator: 0 failing files on the branch, which is based on current kestra-io main.
