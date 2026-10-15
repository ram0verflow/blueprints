## What

New blueprint `restic-backup-restore-drill`: **Daily restic Restore Drill with RPO, Integrity and Checksum Checks.**

restic is one of the most used file-level backup tools, and its backups fail quietly:
- the backup job stops writing snapshots;
- a pack file rots on the storage;
- a backup dies and leaves a lock behind;
- the files restore, but they are not the files you backed up.

`restic check` without `--read-data` does not read your data, and `restic snapshots` does not tell you whether a restore works. This flow runs a real drill every day:
- it checks that the newest snapshot is younger than `rpo_hours`;
- it reads a rotating slice of the pack files with `restic check --read-data-subset`;
- it restores a random sample of files with `restore --verify` and compares them with the source by sha256;
- it removes stale locks left by dead jobs, and leaves live ones alone;
- it runs `forget --prune` only after a passing drill and a person's approval.

**Demo mode needs only Docker:** it backs up generated files to a repository inside the container and drills it.

## Why it is different

**The gap:** the catalog has no restic blueprint at all, and its restore drills cover other systems:
- `proxmox-backup-restore-drill` restores a Proxmox VM;
- `mongodb-verified-collection-backup` restores a MongoDB dump.

None of them checks a deduplicating repository's pack files, the age of the newest snapshot against an RPO, or stale repository locks, or compares restored files with the source. No open or closed PR adds a restic flow (checked 2026-10-15).

It is a day-2 job with safety mechanics:
- the read subset rotates by weekday, so every pack is read once a week;
- only locks restic itself considers stale are removed, and a live lock is waited for;
- files that changed after the snapshot are skipped, so they do not raise false alarms;
- prune needs a passing drill and an approval.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/restic-backup-restore-drill/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `daily_drill` (`Schedule`, shipped disabled) or `after_backup` (`Webhook`, key from a secret, called at the end of the backup job). `concurrency` limit 1.
2. `drill` (`shell.Commands`, Docker runner, `restic/restic:0.19.1`):
   - opens the repository with a bounded timeout and takes the newest snapshot (optional `host`/`tag`);
   - lists the locks and runs `restic unlock`;
   - runs `check --retry-lock <lock_wait> --read-data-subset=<n/7 or your value>`;
   - restores `sample_files` random files with `--verify` and compares them by sha256 with `source_root`;
   - outputs JSON with `::{"outputs":...}::`.
3. `rpo_check` (`If`): the snapshot's age is computed in Kestra (`timestamp` filter); over the RPO → `snapshot_too_old` (`Fail`).
4. `remember_good_drill` (`kv.Set`) → `report_pass` (Slack).
5. `retention` (`If`, only with `forget_policy`):
   - `forget_preview` shows what would be removed;
   - `request_approval` → `approve_prune` (`Pause`, BOOL) → `forget_and_prune`, or `report_kept`.
6. `errors` → `alert_failure`: the failing task, restic's own message, and the last good drill from the KV store.

## Error handling

- **Stale snapshot.** The repository is readable, but the backup job stopped. The alert says so in those words.
- **Corrupted data.** `check` reads the subset and quotes restic: "pack 5c7b0edb… contains 2 errors … ciphertext verification failed".
- **Wrong password / unreachable backend.**
  - restic's error is quoted.
  - Found while testing: restic retries an unreachable backend for many minutes, and the first version of the drill hung there. The first call now runs under `timeout` (`connect_timeout_seconds`) and quotes the last connection error.
- **Locks.**
  - A running restic refreshes its lock every 5 minutes, so `restic unlock` (which removes only locks older than 30 minutes, or held by a dead process on the same host) is safe to run first.
  - A live lock is waited for with `--retry-lock`, then reported with the host, PID and age, and never removed.
- **Bit rot on the source or the backup.** A restored file that differs from a source file whose size and mtime are unchanged fails the drill, naming both checksums. A file changed since the snapshot is counted as skipped.
- **A failing drill never prunes**, and every alert says "No snapshot was forgotten or pruned".

## Hacktober requirements

- **3+ runnable tasks:** `drill`, `remember_good_drill`, `report_pass`, `forget_preview`, `forget_and_prune`, `alert_failure`
- **Flowable tasks:** `If` (`rpo_check`, `retention`, `anything_to_forget`, `prune_gate`), `Pause`, `concurrency`
- **Triggers:** `Webhook` (event-based, after each backup) and `Schedule` (shipped disabled)
- **Non-core plugins:** `plugin-script-shell` with the Docker task runner, `plugin-slack`

## Testing

Every case ran on the final revision on both `kestra/kestra:v2.0.1` and `kestra/kestra:latest` (2.0.6). The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations. Both versions gave the same results; the numbers below are from 2.0.1.

Repository-mode tests:
- Backend: `restic/rest-server` with a real restic 0.19.1 repository (`--pack-size 4`, 56 files, 60 MB).
- Source: mounted read-only into the drill container (Docker runner `volumes`, with `volume-enabled: true`).
- Slack: a local sink.

| Case | Result |
|---|---|
| A. Repository mode, `read_data_subset: 100%`, `source_root: /` | ✅ PASSED: "restored 20 of 56 files with --verify, 20 match the source by sha256" |
| A2. `rotate` (Thursday) | ✅ PASSED, "check read pack subset 5/7" |
| B. Newest snapshot taken with `--time` 50 h ago | ✅ FAILED at `snapshot_too_old`: "the newest snapshot d2ab367f is 50.0 h old, over the 26 h RPO …"; the alert quotes the last good drill from the KV store |
| C. 16 bytes overwritten in one pack file, subset 100% | ✅ FAILED at `drill`: "restic check found a problem in subset 100%: pack 5c7b0edb… contains 2 errors: … ciphertext verification failed" |
| D. Wrong password | ✅ FAILED: "cannot open the repository: wrong password or no key found" |
| E. A backup killed with SIGKILL, its lock made 2 h old | ✅ PASSED; "restic unlock removed 1 stale lock(s) …" with the host (`backup-host-7`), PID and time; no lock left |
| E2. A backup is running (`lock_wait: 20s`) | ✅ FAILED: "repository still locked after waiting 20s: locked by PID 8 on backup-host-7 …, lock was created at … (28 s ago). The lock is live …, so it was not removed"; the lock is still there |
| E3. A backup holds the lock for 15 s (`lock_wait: 2m`) | ✅ `check` waited for the lock, then PASSED (17 s) |
| F. rest-server stopped (`connect_timeout_seconds: 30`) | ✅ FAILED after 30 s: "the repository did not answer within 30 s …: dial tcp 127.0.0.1:8000: connect: connection refused" |
| G. One byte of a source file changed after the backup, size and mtime restored | ✅ FAILED: "restored files differ from the source although unchanged since the snapshot: /source/f7.bin(restored dda5c4ef source 30ca76f9)" |
| G2. A source file appended to after the backup, all 56 files restored | ✅ PASSED: "55 match the source by sha256 (1 changed since the snapshot, not compared)" |
| H. 7 daily snapshots, `forget_policy: --keep-daily 3`, approved | ✅ "would remove 4 snapshot(s) and keep 3" → approved → "4 snapshot(s) forgotten and pruned"; 3 snapshots left |
| H2. Same, declined | ✅ "retention not applied (declined): all snapshots kept" |
| H3. Failing drill (`rpo_hours: 0`) with a `forget_policy` | ✅ FAILED at `snapshot_too_old`; no preview, no prune |
| I. Webhook | ✅ Key from the secret → HTTP 200, demo drill PASSED; wrong key → HTTP 404 |
| Demo mode | ✅ PASSED: "restored 20 of 31 files with --verify, 20 match the source by sha256" |
| H4. Retention approval not answered (`approval_timeout: PT10S`), run on its own | ✅ "retention not applied (no decision in time): all snapshots kept". See the note on `Pause` below |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/restic-backup-restore-drill/run-gantt.png" alt="Gantt view of a passing drill" width="800">

## Notes

- **Test setup.**
  - The repository was on `restic/rest-server`. MinIO, S3, B2 and SFTP were not tested; restic handles them the same way, but they need their credentials in the task's `env`.
  - The test copies used `networkMode: host` to reach the local rest-server; the blueprint does not set it.
  - The "2 h old" lock in case E was made by re-encrypting the real lock of a killed backup with an older `time`, using the repository key.
- **Restic's own stale rule.** `restic unlock` also removes a lock held by a PID that no longer exists on the same hostname. In one test the backup and drill containers shared the host's hostname (host networking), and the lock of a running backup was removed. Drill containers on Kestra's Docker runner get their own hostname.
- **Not tested:** very large repositories (`check` on a 1/7 subset reads one seventh of all packs), and restic versions other than 0.19.1.
- **Kestra `Pause` timeout, found while testing (2.0.1 and 2.0.6).**
  - In 7 of 16 approval-timeout runs across these four blueprints, the `Pause` stayed PAUSED after `pauseDuration` ran out.
  - Each stuck run started right after another run of the same flow had been resumed, and all four flows have `concurrency` limit 1.
  - A stuck run holds the flow's queue until someone answers or kills it. It changes nothing in the meantime.
  - A 2-task flow with `concurrency` and a `Pause` reproduced it once, but not on a clean repeat.
  - Run on their own, the timeout cases in the table passed on both versions. The docs tell users to answer or kill a waiting run before starting another.
- Tags: `Infrastructure`; the tag validator passes on this branch.
