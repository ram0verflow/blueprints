## What

New blueprint `mysql-replica-consistency-checksum`: **Find and Fix Silent MySQL Replica Drift with pt-table-checksum and an Approval.**

A MySQL replica can look healthy (both threads running, zero lag) and still hold different data than the primary. Typical causes:
- a write made directly on the replica;
- a crash with unsafe settings;
- a replica rebuilt from a broken backup;
- a non-deterministic statement.

Nobody notices until a read from that replica returns the wrong row, or until it is promoted.

This flow runs Percona Toolkit's standard procedure end to end:
1. `pt-table-checksum` compares every table chunk by chunk through replication itself.
2. `pt-table-sync --print` previews the statements that would repair each replica.
3. A person approves them.
4. They run on the primary and reach the replica through replication.
5. The tables that differed are checksummed again to prove they match.

## Why it is different

**The gap:** main has 21 MySQL and MariaDB flows. The replication ones watch lag (`mysql-replication-lag-sentinel`), restart stopped replication (`mysql-stopped-replication-recovery-guard`) or enforce `super_read_only` (`mysql-replica-super-read-only-enforcement-guard`). None compares the data on a replica with the primary, and no flow in main or in any open or closed PR uses `pt-table-checksum` or `pt-table-sync` (checked 2026-10-16). It pairs with the merged `mysql-online-schema-change-gh-ost` and the open MySQL point-in-time restore drill.

The safety mechanics are the ones DBAs learn the hard way:
- **The fix never writes to a replica.** pt-table-sync runs `REPLACE`/`DELETE` on the primary with the primary's own values. They are no-ops there and repair the replica as they replicate, so GTIDs stay consistent.
- **Refuses before checking** when a replica is stopped, unreachable, or has replicas of its own. With row-based binlogs a chained replica copies its source's checksum results instead of computing its own, which would hide drift.
- **Errant GTIDs are reported.** These are transactions a replica has and the primary never ran: the usual sign of direct writes, and a failover hazard.
- **Refuses fixes that are too big** (`max_fix_statements`): a replica that far off should be rebuilt, and the cause found first.
- **Tables without a PRIMARY or UNIQUE key** are still checksummed, but excluded from the fix and named, since pt-table-sync cannot repair them.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/mysql-replica-consistency-checksum/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `weekly_check` (`Schedule`, shipped disabled) or `after_incident` (`Webhook`, after a failover or a replica rebuild). `concurrency` limit 1.
2. `preflight` (`shell.Commands`, `percona/percona-toolkit:3.7.1`):
   - replication state, with the applier's own error from `performance_schema`;
   - chained replicas, errant GTIDs, keyless tables;
   - writes the replicas to `percona.dsns`, so exactly those are checked.
3. `replicas_ready` (`If` + `Fail`).
4. `checksum`: `pt-table-checksum --max-lag --chunk-time`, then the documented diff query on every replica. Exit code 16 ("differences found") is the result, not an error.
5. `any_drift` (`If`):
   - **no drift:** `kv.Set` + Slack;
   - **drift:**
     1. `preview_fix` (`pt-table-sync --print`, statements kept as `fix-*.sql` outputs);
     2. `fix_size`;
     3. `request_approval` (Slack) and `approve_fix` (`Pause`, 4 h);
     4. `apply_fix` (`--execute`, then `pt-table-checksum --tables` on what differed);
     5. `fixed` (`If`): Slack, or `Fail` with what still differs and why.
6. `errors` → one Slack alert with the task, the reason and the last clean check.

## Error handling

- **Nothing is changed** unless a person approves the exact statements. A decline, no decision within 4 hours, or a fix over the limit leaves the replicas as they are, and says so.
- **The applier's real error** is quoted when replication is stopped, e.g. "Could not execute Write_rows event on table shop.customers; Duplicate entry '5001' for key 'customers.PRIMARY'", instead of the generic "Coordinator stopped".
- **The repair is verified.** If a table still differs, the run fails and says whether it is a keyless table or something still writing to the replica.
- **Credentials** go to a defaults file inside the task container (`F=` in the DSNs), never onto a command line.
- **Found while testing:**
  - The `perconalab/percona-toolkit:3.7.1` image's Perl MySQL driver does not load (an undefined C++ symbol); `percona/percona-toolkit:3.7.1` works.
  - A relative `F=client.cnf` silently connected without a password; the path must be absolute.
  - Toolkit 3.7 renamed `--sync-to-master` and the `master_*` columns of `percona.checksums` (now `--sync-to-source`, `source_cnt`, `source_crc`).
  - Kestra runs shell commands with `set -e`, which ended `preflight` silently twice before every lookup was made to succeed.

## Hacktober requirements

- **3+ runnable tasks:** `preflight`, `checksum`, `preview_fix`, `request_approval`, `apply_fix`, `remember_clean`, `report_clean`, `report_fixed`, `alert_failure`
- **Flowable tasks:** `If` (`replicas_ready`, `any_drift`, `fix_size`, `fix_gate`, `fixed`), `Pause`, `concurrency`
- **Triggers:** `Webhook` (event-based, from failover tooling) and `Schedule` (shipped disabled)
- **Non-core plugins:** `plugin-script-shell` with the Docker task runner, `plugin-slack`

## Testing

Every case ran on the final flow on `kestra/kestra:latest` (2.0.6) and `kestra/kestra:v2.0.1`. The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations.

Setup:
- A real MySQL 8.0.46 primary and two GTID replicas, with `shop.orders` (50,000 rows), `shop.customers` (2,000) and a keyless `shop.audit_log`.
- A local Slack sink.
- Drift was made on the replicas with `sql_log_bin = 0`:
  - replica 1: 3 changed totals, 2 deleted orders, 1 extra order;
  - replica 2: 1 changed customer email.

| Case | Result |
|---|---|
| A. Drift on both replicas, approved | ✅ "127.0.0.1:3311: shop.orders (1 chunk); 127.0.0.1:3312: shop.customers (1 chunk)". Plan: 6 statements (5 REPLACE, 1 DELETE) and 1 REPLACE. → "drift fixed … A new checksum of shop.customers,shop.orders matches on every replica". Counts and sums equal on all three nodes; no errant GTIDs created |
| B. Consistent replicas | ✅ "3 table(s), 52002 rows of shop identical on 127.0.0.1:3311,127.0.0.1:3312 and the primary" |
| C. Drift, declined | ✅ "left as it is (declined) … Nothing was changed"; replica 1 still 49999 orders |
| D. No decision (`pauseDuration` PT20S in the test copy) | ✅ "left as it is (no decision …)"; nothing changed |
| I. `max_fix_statements: 5` | ✅ FAILED at `too_much_drift`: "the fix for 127.0.0.1:3311 (6) is over 5 statements. Rebuild that replica from a backup instead … Nothing was changed." |
| J. Extra row in the keyless `audit_log` plus the drift above | ✅ The other tables are fixed. FAILED at `still_drifting`: "shop.audit_log has no PRIMARY or UNIQUE key, so pt-table-sync cannot repair it: copy it from the primary by hand or add a key" |
| E. `STOP REPLICA` on replica 2 | ✅ FAILED before any checksum: "127.0.0.1:3312 is not replicating (IO No, SQL No)" |
| F. Duplicate key stops replica 1's applier | ✅ FAILED: "… SQL No: Could not execute Write_rows event on table shop.customers; Duplicate entry '5001' for key 'customers.PRIMARY' …" |
| G. Replica 2 container stopped | ✅ FAILED: "127.0.0.1:3312 does not answer: Can't connect to MySQL server …" |
| H. Replica 2 replicating from replica 1 | ✅ FAILED: "127.0.0.1:3311 has 1 replica(s) of its own: with row-based binlogs they would copy its checksums instead of computing theirs" |
| L. A direct write on replica 2 with its binlog on | ✅ The approval message notes "errant GTIDs …:1: something wrote to it directly …", the drift is fixed, and the errant GTID stays (documented) |
| K. Wrong password | ✅ FAILED at `preflight`: "Access denied for user 'root'@'127.0.0.1' (using password: YES)" |
| M. Webhook | ✅ HTTP 200, clean check; wrong key → HTTP 404 |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/mysql-replica-consistency-checksum/run-gantt.png" alt="Gantt view of an approved fix" width="800">

## Notes

- The approval timeout is a constant (`PT4H`), not an input: on Kestra 2.0.x a templated `pauseDuration` can carry one execution's value into the next ([kestra-io/kestra#18581](https://github.com/kestra-io/kestra/issues/18581), fixed on develop).
- In the test containers the replicas got errant GTIDs from the MySQL image's own init scripts until `RESET MASTER` was run before replication started. The warning caught that too.
- **Not tested:** MariaDB; very large tables (chunking and `--max-lag` throttling were not exercised under load); multi-source replication.
- Tags: `Infrastructure`; the tag validator passes on this branch.
