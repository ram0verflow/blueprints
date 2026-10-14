## What

New blueprint `pgvector-search-recall-check`: **Know When Your Vector Search Stops Finding the Right Results.**

An HNSW or IVFFlat index makes pgvector search fast by not looking at every row. The cost is recall: some of the true top-k neighbours are missed. Nothing reports it. A query still returns k rows, but some are the wrong ones. Recall gets worse after a bulk load, a re-embedding, an index built with cheap settings, or an IVFFlat index created before most of the data arrived, and a RAG answer gets worse with it.

This flow measures recall@k directly and turns the result into a decision:
- for a sample of query vectors, it compares the indexed (approximate) top-k with an exact scan, for each value of `hnsw.ef_search` or `ivfflat.probes` in a sweep, and records latency;
- it reads the value the application actually gets (role setting, database setting or the pgvector default);
- **ok** or **dropped since the last run** sends one line;
- **tune**: when a higher value reaches the target, it shows the sweep and asks on-call (`Pause`, dynamic `SELECT`) whether to apply the lowest passing value with `ALTER ROLE … IN DATABASE … SET`, then reads the catalog again to confirm;
- **rebuild**: when no value reaches the target, it says what to rebuild with, and the run ends `WARNING`.

**Demo mode needs only a PostgreSQL with pgvector.** It creates `recall_demo.documents`: 30,000 clustered 64-dimension vectors and an HNSW index built cheaply. At the default `ef_search = 40` it finds 88% of the true neighbours.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/pgvector-search-recall-check/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `after_bulk_load` (`Webhook`, key from a secret) or `weekly` (`Schedule`, shipped disabled). `concurrency` limit 1 with `QUEUE`.
2. `demo_setup` (`If`) → `create_demo_table` (`Queries`, created once).
3. `find_index` (`Query` with bind parameters) reads:
   - the index: method, operator class → distance operator, build options, size and validity;
   - the column type;
   - the setting the application gets.
   `index_guard` → `no_usable_index` (`Fail`) when there is no table, no ANN index, or only an INVALID one.
4. `measure` (`Queries`, one transaction):
   - a PL/pgSQL `DO` block builds the exact top-k with index scans off;
   - it checks with `EXPLAIN` that the index is used;
   - it sweeps the setting with `set_config(…, true)`;
   - a final `SELECT` returns the sweep, the recall at the current value, the best value and the outcome.
5. `remember` (`kv.Set`): the recall this time, so the next run can detect a drop.
6. `decide` (`Switch` on the outcome):
   - `ok` → `report_ok`;
   - `dropped` → `report_drop`;
   - `tune` → `ask_on_call` → `wait_for_approval` (`Pause`, 24 h, dynamic `SELECT`) → `apply_gate` → `apply_setting` → `confirm_setting` (the same catalog SQL as step 3, through flow `variables`) → `report_applied`, or `report_kept`;
   - `rebuild` → `report_rebuild` → `needs_rebuild` (`Exit` `WARNING`).
7. `errors` → `alert_failure`.

## Error handling

- **Inputs never become SQL text.**
  - `find_index` uses bind parameters.
  - `measure` and `apply_setting` receive their settings as one JSON value in a dollar-quoted literal, with every `$` escaped as `$`, so no input can end the literal.
  - Identifiers are quoted by PostgreSQL (`format('%I')`) and the table is resolved through `regclass`.
  - `apply_setting` refuses any setting other than `hnsw.ef_search` and `ivfflat.probes`.
- **No usable index** stops at `index_guard` with the reason: missing table, no HNSW/IVFFlat index ("searches are exact scans"), or an INVALID index.
- **The planner skipped the index.** On a small table, or with a query shape the index cannot serve, the "approximate" result would really be exact and recall would read 1.0. `measure` checks the plan first and fails with "the planner did not use index …".
- **A broken `sample_sql`** fails with the database error, quoted in the alert.
- **Nothing changes without approval.** No answer within 24 hours keeps the current value. An approved change is confirmed by reading `pg_db_role_setting` again in a new session.
- **A finding is not an error.** "Rebuild needed" ends `WARNING` through `Exit`, with one Slack message and no error alert.
- **The measurement does not touch the application's sessions.** The sweep uses `set_config(…, true)`, which is local to the transaction, and the temporary tables are `ON COMMIT DROP`. Kestra's connection pool reuses connections, so nothing may outlive the transaction.

## Why it is different

The catalog has two pgvector blueprints:
- `pgvector-unindexed-vector-column-index-guard` finds vector columns with no ANN index and builds one;
- `pgvector-ivfflat-lists-undersized-reindex-guard` compares an IVFFlat index's `lists` with the row count and rebuilds it.

Both reason from the catalog. Neither measures what users see: how many of the true nearest neighbours the index returns, at which latency, for which `ef_search`/`probes`. This blueprint measures recall against an exact scan, works for HNSW and IVFFlat, finds the cheapest setting that meets a target, and applies it after approval. It covers what the catalog cannot show: a well-shaped index whose search setting is too low, or an HNSW index built with cheap parameters. No open PR adds a recall measurement (checked 2026-10-14).

## Hacktober requirements

- **3+ runnable tasks:** `create_demo_table`, `find_index`, `measure`, `remember`, `apply_setting`, `confirm_setting`, the Slack reports
- **Flowable tasks:** `Switch` (four outcomes), `Pause` (dynamic `SELECT`), `If` (`demo_setup`, `index_guard`, `apply_gate`), `Exit` (`WARNING`)
- **Triggers:** `Webhook` (event-based, after a bulk load or re-embedding) and `Schedule` (shipped disabled)
- **Non-core plugins:** `plugin-jdbc-postgres` (`Query` and `Queries`), `plugin-slack`

## Testing

Tested on `kestra/kestra:v2.0.1` against `pgvector/pgvector:pg16` (PostgreSQL 16, pgvector 0.8.7), with a local Slack sink. The flow passes `POST /api/v1/flows/validate` with no constraints, warnings or deprecations. Every case ran on the final revision. Each run sent exactly one Slack message, plus the approval request where it paused.

| Case | Result |
|---|---|
| 1. Demo, first run | ✅ Paused: "recall@10 0.924 at hnsw.ef_search = 40 (pgvector default), target 0.95", sweep 20…640, exact scan 3.9 ms/query. Approved "Apply hnsw.ef_search = 80" → `ALTER DATABASE`; `confirm_setting` read `hnsw.ef_search = 80 (database)`; "Measured recall@10 0.954 at 0.26 ms/query (was 0.924)" |
| 2. Next run | ✅ "recall OK … 0.954 at hnsw.ef_search = 80" |
| 3. Setting reset, approver answers "Keep 40" | ✅ "setting kept … stays below the 0.95 target"; `pg_db_role_setting` unchanged (0 rows) |
| 4. `app_role: app_user`, approved | ✅ `ALTER ROLE app_user IN DATABASE search SET hnsw.ef_search = 80`; a new session as `app_user` shows 80 and the flow's own role still shows 40; the next run reports OK with the role's value |
| 5. `target_recall: 0.995` | ✅ Ends `WARNING` through `Exit`: "BELOW TARGET at every tested setting … best recall@10 0.982 … needs a rebuild: higher m and ef_construction"; no error alert |
| 6. Index rebuilt with `m = 4, ef_construction = 10` between two runs (target 0.3) | ✅ "recall DROPPED … 0.372 at hnsw.ef_search = 40, was 0.924 on 2026-10-14T10:37:34Z" (previous value from the KV store) |
| 7. Column without an ANN index | ✅ FAILED at `no_usable_index`: "no HNSW or IVFFlat index on recall_demo.plain(embedding): searches are exact scans" |
| 8. Table does not exist | ✅ FAILED: "table recall_demo.nope does not exist" |
| 9. IVFFlat (`lists = 100`), `vector_l2_ops`, columns `item_id`/`vec`, random query vectors through `sample_sql` | ✅ Operator `<->` and `ivfflat.probes` picked from the catalog; probes 1 → 0.251, 10 → 0.831, 20 → 0.974; proposed `ivfflat.probes = 20`; "Keep 1" honoured |
| 10. 50-row table with an HNSW index | ✅ FAILED at `measure`: "the planner did not use index tiny_hnsw for ORDER BY embedding <=> <query> LIMIT 10 (too few rows …), so recall cannot be measured" |
| 11. `sample_sql` with an unknown column | ✅ FAILED at `measure`: `column "nope" does not exist` |
| 12. Webhook | ✅ Key from the secret → HTTP 200, check started; wrong key → HTTP 404 |

A table of the same 30,000 rows also ran with the table's own rows as query vectors. IVFFlat then scored 1.0 even at `probes = 1`, because each query sits inside its own cluster. That is why the docs recommend real query vectors through `sample_sql`.

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/pgvector-search-recall-check/run-gantt.png" alt="Gantt view of a run that paused for approval, applied hnsw.ef_search = 80 to a role and confirmed it" width="800">

## Notes

- **HNSW builds are not deterministic.** The demo's recall at the default setting was 0.88 to 0.94 across rebuilds in testing, always below the 0.95 target. The docs say "8 to 12%" instead of a fixed number.
- **What "current setting" means.** The value comes from `pg_db_role_setting`: the role in this database, then the role, then the database, then the pgvector default. A value the application sets per session with `SET` is invisible to the catalog.
- **Cost.** Each query vector costs one exact scan of the table. 100 queries on 30,000 64-dimension vectors took under a second. On large tables, lower `sample_size`, run off-peak, or point `POSTGRES_URL` at a replica. A setting can only be applied on the primary.
- **Kestra notes found while building:**
  - `Queries` keeps everything after a `CREATE FUNCTION` as one statement, so the measurement is a `DO` block followed by a `SELECT`, not a temporary function.
  - Named parameters treat `::` as a parameter marker, so `find_sql` uses `CAST()`.
  - The `CAST()` rule has a comment in the flow.
- **Not tested:** pgvector before 0.8, `halfvec`/`sparsevec`/`bit` columns (the operator mapping covers them), and tables over a few hundred thousand rows.
- Tags: `AI, Data`; the tag validator passes on this branch.
