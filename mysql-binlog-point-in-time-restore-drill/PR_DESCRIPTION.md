## What

New blueprint `mysql-binlog-point-in-time-restore-drill`: **Prove Your MySQL Backups Restore to the Second, or to the Statement Before a Mistake.**

A MySQL point-in-time restore needs two backups that fail separately:
- **A full dump**, which can be cut short, or made without the binlog coordinates a replay needs.
- **Every binlog written since**, whose archiver can stop, skip a file, or upload a corrupt one, while the dump job keeps succeeding.

And the usual way to stop a replay, `--stop-datetime`, works to the second: a mistake made in the same second as the last good writes cannot be separated from them by time.

This flow restores for real, in a throwaway container. Demo mode needs only Docker. It drills the newest mysqldump from S3 and checks its binlog chain from the dump's coordinates on for gaps, corrupt checksums and archive lag. It replays up to a target time, or right before the first transaction matching a statement you name (`DROP TABLE`, a `DELETE` without `WHERE`). Then it runs your SQL checks and compares the restore time with your RTO.

## Why it is different

**The gap:** main has 21 MySQL and MariaDB flows. The closest is `mysql-binlog-retention-safety-guard`, which decides which binlogs may be purged on the server. None of them restores a dump or replays binlogs, and no flow in main or in any open or closed PR uses `mysqlbinlog` (checked 2026-10-16). This is the MySQL counterpart of the merged Postgres point-in-time restore drill, and it follows the same shape: demo and s3 modes, SQL checks, RTO, `sla`.

MySQL details a reader would not think of:
- **The stop.**
  - `--stop-datetime` excludes the whole target second.
  - In the tests, 700 inserts and an accidental `DELETE` ran in the same second: stopping at that second lost the inserts (10000 orders); one second later it replayed the `DELETE` (100 orders).
  - `stop_before_statement` scans the binlogs with `mysqlbinlog -v` (row events match on their pseudo-SQL) and stops at the start of the matching transaction: exactly 10700.
- **The chain.** No binlog number may be missing from the dump's file on, and every event checksum is verified (`--verify-binlog-checksum`) before anything is replayed.
- **One `mysqlbinlog` call for all files**, as temporary tables and transactions can span files, into a scratch server with no binlog of its own and the source's GTID mode, so `GTID_PURGED` and the binlogs' `GTID_NEXT` apply.
- **The official `mysql` image no longer ships `mysqlbinlog`** (found while testing). The default image is Percona Server 8.0, a drop-in MySQL build that does. Its `mysqldump` writes `CHANGE MASTER TO` even with `--source-data`, and the drill reads both forms.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/mysql-binlog-point-in-time-restore-drill/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `after_backup` (`Webhook`, called by the dump job) or `weekly_drill` (`Schedule`, shipped disabled). `concurrency` limit 1, flow `sla` of 1 hour.
2. `s3_mode` (`If`):
   - `list_dumps` (`aws.s3.List`) and `dump_found` (`If` + `Fail`);
   - `download_dump` (`aws.s3.Download`, the newest by upload time, picked with the `jq` Pebble filter);
   - `download_binlogs` (`aws.s3.Downloads`).
3. `restore` (`shell.Commands`, Docker runner). `inputFiles` is the downloaded binlog map merged with the dump (`outputFiles | merge({...})`). The task checks the dump and the chain, finds the stop, restores, runs the checks, and reports JSON whether it passes or not.
4. `verdict` (`If`): pass → `kv.Set` (last good drill) + Slack; otherwise `Fail` with every problem.
5. `errors` → one Slack alert with the task, the reason and the last good drill. `afterExecution` reports a run stopped by the `sla`.

## Error handling

- **Every problem is collected.** A binlog gap and the check it breaks are reported together, and the run ends FAILED.
- **What cannot be restored stops the drill with its reason:**
  - an unreadable or cut-short dump (no `-- Dump completed`), or a dump without coordinates;
  - a corrupt binlog;
  - a `stop_before_statement` that matches nothing;
  - a scratch `mysqld` that does not start (its first error is quoted);
  - a replay error from `mysql` or `mysqlbinlog`.
- **A check that cannot run** counts as failed and quotes MySQL's error. A restore slower than the RTO fails even when the data is right.
- **Found while testing:**
  - A `--stop-datetime` value with a space was split by the shell, so `mysqlbinlog` stopped at midnight and only printed an error nobody read. The drill now quotes it, and also fails on any `mysqlbinlog` error, not just on `mysql`'s exit status.
  - Kestra runs shell commands with `set -e`, which ended one version silently on a loop whose last test was false.

## Hacktober requirements

- **3+ runnable tasks:** `list_dumps`, `download_dump`, `download_binlogs`, `restore`, `remember_good_restore`, `report_pass`, `alert_failure`, `alert_deadline`
- **Flowable tasks:** `If` (`s3_mode`, `check_bucket`, `dump_found`, `verdict`, `unless_deadline`, `deadline_alert`), `concurrency`, `sla`, `afterExecution`
- **Triggers:** `Webhook` (event-based, called by the dump job) and `Schedule` (shipped disabled)
- **Non-core plugins:** `plugin-aws` (S3 List, Download, Downloads), `plugin-script-shell` with the Docker task runner, `plugin-slack`

## Testing

Every case ran on the final flow on `kestra/kestra:latest` (2.0.6) and `kestra/kestra:v2.0.1`. The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations. The results were the same on both versions.

S3-mode setup, all real:
- A MySQL 8.0.46 source (official image) with GTIDs.
- `mysqlbinlog --read-from-remote-server --raw --stop-never` streaming the binlogs, synced to SeaweedFS every 5 s.
- `mysqldump --single-transaction --source-data=2 --set-gtid-purged=ON | gzip` uploaded to the same bucket.
- A local Slack sink.

| Case | Result |
|---|---|
| Demo | ✅ PASSED: "3 binlog(s) binlog.000001 to binlog.000003 (GTID ON …), replayed right before /DROP TABLE/ (binlog.000003 position 197), in 4 s. Checks: PASS: 2000 orders recovered" |
| S1. End of the archive | ✅ PASSED, 10000 orders |
| S2. `target_time` between two batches | ✅ PASSED, 11000 orders (the later 500 not replayed) |
| S3. 700 inserts and an accidental `DELETE` in the same second, `target_time` = that second | ✅ FAILED as it should: "check failed: 10000 orders (10700 expected)", the inserts are lost too |
| S3+1. `target_time` = the next second | ✅ FAILED: the `DELETE` is replayed, "100 orders" (and the target is after the last archived event) |
| S3b. `stop_before_statement: DELETE FROM `shop`.`orders`` | ✅ PASSED: "replayed right before /DELETE FROM `shop`.`orders`/ (binlog.000002 position 33260) … 10700 orders" |
| S4. `stop_before_statement` that matches nothing | ✅ FAILED: "no statement matching /DROP DATABASE/ in the binlogs after the dump" |
| S5. binlog.000002 deleted from the bucket | ✅ FAILED: "binlog.000002 is missing from the archive: nothing after binlog.000001 (…) can be replayed; check failed: 8000 orders (10200 expected)" |
| S6. 16 bytes overwritten in binlog.000002 | ✅ FAILED: "binlog.000002 is corrupt: ERROR: Could not read entry at offset 410 …" |
| S7. Archiver stopped 2 min ago, `archive_lag_minutes: 1` | ✅ FAILED: "the newest archived binlog event is from … UTC, 2 min ago, over the 1 min limit: the binlog archiver has stopped" |
| S8. `target_time` an hour after the archive ends | ✅ FAILED: "… is after the last archived event (…): whatever was written in between is not in the archive" |
| S9. Dump cut short | ✅ FAILED: "… ends without '-- Dump completed': the dump was cut short" |
| S10. Dump without `--source-data` | ✅ FAILED: "… has no binlog coordinates: make the dump with --source-data=2 …" |
| S11. A failing check and a check on a missing table | ✅ FAILED with both: "10000 orders (99999 expected); check could not run: ERROR 1146 … Table 'shop.nope' doesn't exist" |
| S12. `rto_minutes: 0` | ✅ FAILED: "the restore took 5 s, over the 0 min RTO" |
| S13. No dump under the prefix | ✅ FAILED at `no_dump` |
| S14. S3 stopped | ✅ FAILED at `list_dumps`: "Connection refused" |
| S15. Webhook | ✅ HTTP 200, demo drill PASSED; wrong key → HTTP 404 |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/mysql-binlog-point-in-time-restore-drill/run-gantt.png" alt="Gantt view of an s3-mode drill" width="800">

## Notes

- **S3 was SeaweedFS**; AWS S3 is the default endpoint and uses the same tasks.
- **For S3 the two statements were pinned to one binlog timestamp** with the session `SET TIMESTAMP`, so the same-second case does not depend on luck. On 2.0.6 the S3 group was re-run after that change; an earlier unpinned run had hit the same second and gave the same three results.
- **Not tested:**
  - MySQL 5.7 (its dumps use `MASTER_LOG_FILE`, which the drill reads);
  - xtrabackup;
  - dumps of several GB, where `restore_seconds` grows with the dump.
- **Not covered:** GTID mode OFF sources were not replayed end to end; the scratch server then starts with GTIDs off.
- Tags: `Infrastructure`; the tag validator passes on this branch.
