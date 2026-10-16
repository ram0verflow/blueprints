## What

New blueprint `etcd-snapshot-restore-drill`: **Prove Your etcd Snapshots Restore, Revision for Revision.**

etcd backup jobs report success when a file reaches the bucket. That says nothing about whether the file restores. It can be:
- cut short by a failed upload;
- changed by a few bytes in storage;
- a raw copy of a member's `member/snap/db` with no hash;
- another cluster's snapshot after a wrong bucket path;
- too big for the backend quota;
- weeks old because the job stopped.

All of these show up on the day of the restore, when the Kubernetes control plane is already down.

This flow restores the snapshot every time, into a throwaway single-member etcd inside the task container, and compares it with the live cluster at the snapshot's revision using **HashKV**, etcd's own hash of every key revision. A pass means the restored keyspace is identical to what the cluster held when the snapshot was taken, not "about the same number of keys". It never writes to the live cluster.

## Why it is different

**The gap:** the catalog has two etcd blueprints, both monitors:
- `etcd-defrag-and-db-quota-sentinel`;
- `etcd-wal-fsync-latency-and-db-quota-backend-alarm-sentinel`, which itself lists "verify recent etcd snapshot integrity in S3 backup vaults" as a suggested extension.

No flow in main or in any open or closed PR saves, restores or verifies an etcd snapshot (checked 2026-10-16 for `etcdctl snapshot`, `etcdutl` and `hashkv`).

It is a day-2 job with checks a reader would not think of:
- **The file before anything parses it.** `etcdctl snapshot save` appends a sha256, and bbolt files are whole 512-byte pages, so the size alone separates a hashed snapshot, a raw `member/snap/db` copy and a file cut short (etcd uses the same rule). The hash is then verified.
- **HashKV at the snapshot's revision** on the restored member and on every live member. HashKV covers the revisions after the compaction point, so when the live cluster compacted after the snapshot, the disposable scratch member is compacted to the same point first.
- **Live members that disagree with each other** are reported as a cluster problem, separately from the backup.
- **A key sample** for when the live cluster has already compacted past the snapshot (kube-apiserver compacts every 5 minutes). If most sampled keys do not exist live, it is another cluster's snapshot.
- **The backend quota**: a snapshot bigger than `--quota-backend-bytes` restores into a member that starts in NOSPACE.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/etcd-snapshot-restore-drill/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `after_backup` (`Webhook`, key from a secret; the backup job sends `{"key": "..."}`) or `nightly` (`Schedule`, shipped disabled). `concurrency` limit 1.
2. `tools_image` (`If`) → `build_tools` (`docker.Build`):
   - Alpine plus the jq and etcd binaries copied from their official images. The etcd image is distroless, so script tasks cannot run in it.
   - No package mirror is needed, and `pull: false` reuses cached base images.
3. `cluster_status` (`shell.Commands`): status, leader, revision and alarms of every member. No leader stops the drill.
4. `fresh_snapshot` (`If`, off by default): `save_snapshot` from the leader → `upload_snapshot` (`aws.s3.Upload`, sha256 in the metadata). For teams that want the flow to be the backup job too.
5. `list_snapshots` (`aws.s3.List`) → `pick_snapshot` picks the requested key, else the newest by `lastModified`, with the `jq` Pebble filter. `snapshot_found` (`If`) → `Fail` when there is none.
6. `download_snapshot` (`aws.s3.Download`) → `drill` (`shell.Commands`):
   - RPO;
   - size and sha256;
   - `etcdutl snapshot status` and `restore`, then a scratch member on random local ports with the quota;
   - HashKV on every member and on the scratch member;
   - the key sample.

   It emits a structured result whether it passes or not.
7. `verdict` (`If`):
   - pass → `remember_good_drill` (`kv.Set`) → `report_pass` (Slack);
   - problems → `drill_failed` (`Fail`) with all of them.
8. `errors` → `alert_failure`: the task that failed, its reason, and the last good drill from the KV store.

## Error handling

- **Every finding is collected** before the verdict, so a stale *and* corrupt snapshot is reported in one alert. The run ends FAILED, and `outputs.result` stays machine-readable for CI.
- **Each failure says what happened in plain words**, e.g. "the file is 129040 bytes, not whole 512-byte pages plus etcd's 32-byte hash: it was cut short".
- **Infrastructure failures** fail the task that hit them, and the alert names that task:
  - no member answers (with a hint to set `tls` when the endpoints are https);
  - no leader;
  - S3 unreachable (after exponential retries);
  - the scratch member cannot start (it retries on another random port).
- **Read-only against the live cluster:** `endpoint status`, `alarm list`, `endpoint hashkv`, `get`. `snapshot save` runs only with `take_snapshot`.
- **Found while testing:**
  - etcdutl panics with a Go stack trace on a truncated or bit-flipped file before it reaches its own hash check. The size and hash check now runs first, so the alert explains the cause instead of quoting a stack frame.
  - Docker Hub answered 429 to `docker.Build`'s default pull of the base images on every run; `pull: false` fixed it.

## Hacktober requirements

- **3+ runnable tasks:** `build_tools`, `cluster_status`, `save_snapshot`, `upload_snapshot`, `list_snapshots`, `download_snapshot`, `drill`, `remember_good_drill`, `report_pass`, `alert_failure`
- **Flowable tasks:** `If` (`tools_image`, `fresh_snapshot`, `snapshot_found`, `verdict`), `concurrency`
- **Triggers:** `Webhook` (event-based, called by the backup job with the key it wrote) and `Schedule` (shipped disabled)
- **Non-core plugins:** `plugin-aws` (S3), `plugin-docker` (Build), `plugin-script-shell` with the Docker task runner, `plugin-slack`

## Testing

Every case ran on the final flow on `kestra/kestra:latest` (2.0.6) and on `kestra/kestra:v2.0.1`. The tasks are identical in both runs; only the `extend` text changed after the 2.0.1 run. The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations. The two versions gave the same results; the numbers below are from 2.0.6.

Setup, all real, in Docker:
- A three-member etcd v3.5.17 cluster with 1,800 Kubernetes-style keys, plus a TLS member that requires client certificates.
- SeaweedFS as the S3 store.
- A local Slack sink.
- The Quick start commands in the docs were run verbatim to build this setup.

| Case | Result |
|---|---|
| Quick start: empty bucket, `take_snapshot` | ✅ The image built in the flow, the snapshot was saved from the leader and uploaded, then PASSED: "1800 keys … restored and serving in 1 s … HashKV at revision 1801 is identical on the restored member and the 3 live members" |
| B. 40 keys updated and 25 deleted after the snapshot | ✅ PASSED, "65 revisions behind the live cluster", HashKV identical, "194 of 200 keys identical, 5 changed and 1 deleted since the snapshot" |
| C. Live cluster compacted past the snapshot's revision | ✅ PASSED in sample mode: "The live cluster has compacted past revision 1866, so no HashKV comparison: keys checked one by one" |
| D. Live compacted after the snapshot, below its revision | ✅ The scratch member was compacted to the same point; HashKV identical |
| E. RPO (`rpo_hours: 0`) | ✅ FAILED: "the snapshot is 0.0 h old, over the 0 h RPO: the backup job has stopped writing new snapshots" |
| F. Half of a snapshot uploaded | ✅ FAILED: "the file is 129040 bytes, not whole 512-byte pages plus etcd's 32-byte hash: it was cut short …" |
| G. 16 bytes flipped, same size | ✅ FAILED: "the sha256 etcd appended does not match the content (258080 bytes): bytes changed after etcd wrote the file …" |
| H. A copy of `member/snap/db` | ✅ FAILED: "the file carries no sha256, so it is a copy of a member's member/snap/db …"; with `skip_hash_check` ✅ PASSED, HashKV identical |
| K. The same 16 MiB copy with `quota_backend_mb: 8` | ✅ FAILED: "the restored database is 16.0 MiB, at or above the 8 MiB backend quota: a member restored from it starts in the NOSPACE alarm …" |
| I. Another cluster's snapshot under the prefix | ✅ FAILED: "200 of 200 sampled keys do not exist in the live cluster: the snapshot is probably from another cluster …" |
| L. Empty prefix / M. unknown `snapshot_key` | ✅ FAILED at `no_snapshot`: "no snapshot is in s3://etcd-backups/nothing-here/ …" / "snapshots/etcd-missing.db is not in …" |
| O. One member stopped | ✅ PASSED: "identical on the restored member and the 2 live members that answered … Only 2 of 3 members answered" |
| N. All members stopped | ✅ FAILED at `cluster_status`: "no member of … answered" |
| P. S3 stopped | ✅ FAILED at `list_snapshots` after 4 attempts: "Connection refused" |
| Q. Webhook with the key the backup job just wrote | ✅ HTTP 200, that exact key drilled, PASSED; wrong webhook key → HTTP 404 |
| T1. TLS member, `tls: true`, `take_snapshot` | ✅ PASSED with the client certificate from the `ETCD_*_PEM` secrets |
| T2. TLS member, `tls: false` | ✅ FAILED: "… (context deadline exceeded). The endpoints use https: if the cluster requires client certificates, set tls …" |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/etcd-snapshot-restore-drill/run-gantt.png" alt="Gantt view of a passing drill" width="800">

## Notes

- **Test setup.**
  - S3 was SeaweedFS. AWS S3, MinIO and R2 were not tested; they use the same `aws.s3` tasks with `endpointOverride` and `forcePathStyle`.
  - The shell tasks use `networkMode: host` in the blueprint itself, so they reach the etcd endpoints the worker host reaches.
- **Not tested:**
  - the "live members disagree" check, since I could not make one member's data diverge on purpose;
  - very large keyspaces;
  - etcd 3.4 and 3.6 (`etcd_version` selects the binaries).
- **No model, Pause or approval** in this flow; it only reads from the cluster unless `take_snapshot` is set.
- Tags: `Infrastructure`; the tag validator passes on this branch.
