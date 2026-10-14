## What

New blueprint `postgres-pitr-restore-drill`: **Prove Your Postgres Backups Restore to the Second You Need.**

Point-in-time recovery (PITR) is what brings rows back after an accidental `DELETE`: restore the base backup, then replay the WAL archive up to the second before the mistake. It also breaks quietly. A WAL segment that never reached the bucket, an `archive_command` that started failing, or a backup from the wrong major version is usually found during the incident. This flow runs the recovery for real, right after each base backup or once a week:
- it downloads the base backup (`pg_basebackup -Ft -z`) and replays archived WAL from S3 to `target_time`, in a throwaway PostgreSQL container;
- it runs your SQL checks on the recovered database;
- the drill fails if a check fails or the restore takes longer than `rto_minutes`, and the flow `sla` stops a drill that hangs;
- each run sends one Slack message: PASSED with numbers, or FAILED with PostgreSQL's reason and the date of the last good drill.

**Demo mode needs only Docker.** It builds a small database with WAL archiving, takes a base backup, writes 1000 more orders and notes the time. Then it deletes every order and recovers to the second before the DELETE, and all 2000 orders must come back.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-pitr-restore-drill/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `after_base_backup` (`Webhook`, key from a secret, called at the end of the backup job) or `weekly_drill` (`Schedule`, shipped disabled). `concurrency` limit 1 with `QUEUE`.
2. `validate` (`If`) → `missing_bucket` (`Fail`) when s3 mode has no bucket.
3. `restore` (`shell.Commands` on the Docker task runner, image `postgres:16-alpine`):
   - fetches the base backup;
   - writes `restore_command`, `recovery_target_time`, `recovery_target_action = 'promote'` and `recovery.signal`;
   - starts PostgreSQL and waits until recovery has ended and the server was promoted;
   - runs the checks and returns the result as JSON built by PostgreSQL.
4. `verdict` (`If`): every check `ok` and `restore_seconds <= rto_minutes * 60`.
   - If yes: `remember_good_restore` (`kv.Set`) → `report_pass` (Slack).
   - If not: `drill_failed` (`Fail`, the message lists every check).
5. `errors` → `unless_deadline` → `alert_failure`: one message naming the task, the cause and the last good drill.
6. Flow `sla` (`MAX_DURATION` PT1H, `behavior: FAIL`, label `drill: deadline_exceeded`) → `afterExecution` → `deadline_alert` → `alert_deadline`.

## Error handling

- **WAL gap.** PostgreSQL accepts read-only connections before recovery is complete. When a segment is missing, it shuts down only after that, so `pg_ctl -w start` alone reports success. The drill watches `pg_is_in_recovery()` and `pg_ctl status`, and quotes PostgreSQL: "recovery stopped: recovery ended before configured recovery target was reached" (scenario C). Found while testing: the first version waited forever here.
- **Wrong or missing base backup:** "no base.tar.gz under s3://drill/base/nope/ (expected pg_basebackup -Ft -z output)". A backup the server cannot start from fails with the FATAL line from its log.
- **Broken check.** A check that cannot run counts as failed and quotes the database error (scenario E), so it never passes silently.
- **Slower than the RTO** fails the drill even when the data is right (scenario F).
- **Hung drill.** The flow `sla` kills it. In 2.0.1 `errors` is not guaranteed to run after an SLA failure, so the alert comes from `afterExecution`, which always runs. `errors` skips runs labelled `deadline_exceeded`, so a run is never reported twice (scenario I).
- **One message per failure.** `drill_failed` is a single `Fail`. The `errors` alert picks the "DRILL FAILED" line first, then the first `ERROR:`/`FATAL:` line, so a locale warning or a `tail` of the log is never the headline.
- **Production is never touched.** The drill only reads the bucket, and the recovered database exists only inside the container. Demo mode reads no AWS secrets: the secret lookups are inside an `s3`-only ternary.

## Why it is different

The catalog has two restore-verification blueprints:
- `postgres-backup-s3-restore-verify` takes a `pg_dump` to S3, restores it into a scratch database and compares table counts;
- `automated-backup-restore-verification-drill` restores a `.sql.gz` and compares table counts and a sha256.

Both test logical dumps. Neither replays WAL, recovers to a point in time, detects a gap in the WAL archive, or measures the restore against an RTO or a deadline. This blueprint tests the physical backup plus the WAL archive, which is what a point-in-time restore uses. No open PR adds a PITR drill (checked 2026-10-14).

## Hacktober requirements

- **3+ runnable tasks:** `restore`, `remember_good_restore`, `report_pass`, `drill_failed`, `alert_failure`, `alert_deadline`
- **Flowable tasks:** `If` (`validate`, `verdict`, `unless_deadline`, `deadline_alert`), flow-level `sla`, `afterExecution`, `concurrency`
- **Triggers:** `Webhook` (event-based, after each base backup) and `Schedule` (shipped disabled)
- **Non-core plugins:** `plugin-script-shell` with the Docker task runner, `plugin-slack`

## Testing

All scenarios ran on `kestra/kestra:v2.0.1` against the final revision:
- the s3 scenarios used a real PostgreSQL 16 source container archiving WAL with `archive_command = 'aws s3 cp …'` and a `pg_basebackup -Ft -z -X stream` base backup;
- the source had 1000 orders, then the base backup, then 1000 more orders and the target time T, then a `DELETE` of every order.

Each run produced exactly one Slack message on a local sink.

| Case | Result |
|---|---|
| A. s3, `target_time` = T | ✅ PASSED in 7 s; 4 WAL segments; check "2000 orders" ok |
| B. s3, no `target_time` | ✅ PASSED in 9 s; replayed the whole archive including the DELETE; check "0 orders (the DELETE was replayed too)" ok. Shows why the target time matters |
| C. WAL segment 4 removed from the bucket | ✅ FAILED at `restore`: "recovery stopped: recovery ended before configured recovery target was reached" |
| D. Wrong `s3_base_prefix` | ✅ FAILED: "no base.tar.gz under s3://drill/base/nope/ (expected pg_basebackup -Ft -z output)" |
| E. A check on a table that does not exist | ✅ FAILED at `drill_failed`: "a check failed on the recovered database … FAILED: check could not run: ERROR: relation no_such_table does not exist" |
| F. Demo, `rto_minutes: 0` | ✅ FAILED: "the restore took 2 s, over the 0 min RTO" |
| G. s3 mode without a bucket | ✅ FAILED at `missing_bucket` before any container started |
| H. Webhook | ✅ Key from the secret → HTTP 200, demo drill PASSED in 2 s; the old placeholder key → HTTP 404 |
| I. SLA (test copy with a 15 s deadline and a `sleep 40`), run twice | ✅ Killed, labelled `drill: deadline_exceeded`, exactly one `afterExecution` alert each time, no `errors` alert |
| J. Demo mode, Kestra restarted with no AWS secrets defined | ✅ PASSED in 2 s; 2000 orders recovered |

The KV entry `pitr_drill_last_good` was written by every passing run and quoted in later failure messages ("Last good drill: 2026-10-14T09:49:20Z").

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-pitr-restore-drill/run-gantt.png" alt="Gantt view of a passing s3 drill: restore took 9 seconds" width="800">

## Notes

- **Test setup.**
  - S3 was `moto_server`, an S3-compatible server, passed as `s3_endpoint`; a MinIO image was not available in the test environment.
  - The drill image in the s3 tests was `postgres:16-alpine` with `aws-cli` preinstalled, so the `apk add aws-cli` fallback did not run inside Kestra (it ran in a plain container).
  - The test copies used `networkMode: host` on the Docker runner to reach the local S3 endpoint; the blueprint does not set it.
- **Same major version.** WAL can only be replayed by the same PostgreSQL major version. Set `postgres_image` to match your server.
- **Other backup tools.** For pgBackRest or WAL-G, replace the download and `restore_command` lines. "How to extend" in the blueprint shows how.
- **Not tested:** AWS S3 itself, very large backups (the restore runs in the worker's Docker), and PostgreSQL versions other than 16.
- Tags: `Data, Infrastructure`; the tag validator passes on this branch.
