## What

New blueprint `minio-bucket-replication-audit`. It audits bucket replication between two MinIO deployments (source and target) and reports the buckets that are not in sync, before the gap shows up in a restore. The flow:
- checks, per bucket, that a replication rule exists and is enabled, and that the target answers;
- reads the failed and pending object counts and bytes, and the time and key of the last failure;
- spot-checks source objects on the target by key, size and ETag, and lists the missing and mismatched keys;
- posts one Slack message per change in the set of problems, not one per run;
- with on-call approval, starts `mc replicate resync start` for the affected buckets, waits until the resync finishes, and checks the buckets again.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/minio-bucket-replication-audit/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `validate_inputs` and `invalid_bucket_name` (`If` + `Fail`) reject empty or negative inputs and invalid bucket names before any call to MinIO
2. `check_source` (`Commands`, `minio/mc`) fails fast when the source does not answer, with retries
3. `audit_buckets` (`Loop`, one `Sequential` per bucket with `allowFailure`) runs `replication_rules`, `replication_status`, `replication_backlog`, `list_objects` and `report` for each bucket. `report` is Python standard library only, in `python:3.12-slim`
4. `decide` compares the problems with the signature stored in the KV store. It alerts only when the set changed, and it offers a resync only for buckets that have missing, mismatched or failed objects while their rule is enabled and the target is online
5. `save_state` (`kv.Set`) writes the signature before any message or approval, so a retried run does not repeat an alert
6. `notify_change` (Slack) sends the change; `ask_resync` links to the execution page
7. `wait_for_decision` (`Pause`, 2 hours, `RESUME`) with a `SELECT` of `Start resync` or `Decline`. No answer changes nothing
8. `resync_buckets` (`Loop`, isolated per bucket) re-checks the rule, starts the resync for the rule's ARN, waits with `LoopUntil` (every 5 s, at most 15 min, `failOnMaxReached`) until the resync is `Completed` or `Failed` and nothing is pending, then runs `recheck`. `report_resync` posts the result

Triggers: `Webhook` (called from monitoring) and a `Schedule` that ships `disabled: true`.

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/minio-bucket-replication-audit/resume-dialog.png" alt="Pause resume dialog with the decision choice" width="480">

## Error handling

- **Source unreachable or credentials refused:** `check_source` retries three times with exponential backoff, then the `errors` block posts the failed task and the first `mc` error line.
- **Target down or missing the bucket is a finding, not a failure.** The spot check is skipped for that bucket, the replication health is still reported, and the alert says `target=offline` with the reason.
- **One broken bucket does not stop the others:** the per-bucket `Sequential` and the `Loop` both use `allowFailure`, and the report shows the bucket as an error.
- **A bucket without a replication rule** is a finding (`rule=missing`), not a failure.
- **Late approval is re-checked:** the rule is read again before the resync starts. If it was disabled meanwhile, the resync is refused, the run ends `WARNING`, and Slack says no resync was done.
- **A resync that never completes** fails its bucket after 15 minutes.
- **Nothing changes without an answer:** the pause resumes with no decision.
- **Credentials** go to `mc` through environment variables, never into files or logs.

## Why it is different

Nothing in `kestra-io/blueprints`, and no open PR (checked 2026-10-13), audits MinIO bucket replication. The closest entries are:
- `minio-cluster-disk-healing-sentinel`: reads cluster drive and healing metrics. It does not compare two deployments or look at objects.
- `minio-object-policy-compliance-gate`: checks object size and prefix rules on one bucket. It does not compare buckets across deployments.
- `s3-object-lock-retention-audit` (mine): object lock and versioning on one deployment. This blueprint covers replication, the state of the copy on the target.

This adds the cross-deployment view: the rule, the replication backlog with the last failure, an object-level comparison, and an approval-gated resync that is re-checked before it starts.

## Hacktober requirements

- **3+ runnable tasks:** `check_source`, `replication_rules`, `replication_backlog`, `list_objects`, `report`, `decide`, `recheck`, `poll_resync`, `start_resync`
- **Flowable tasks:** `Loop` (two), `LoopUntil`, `Sequential` with `allowFailure`, `If` (five), `Pause`, `Fail`
- **Triggers:** `Webhook` (event-based) and `Schedule` (disabled)
- **Non-core plugins:** `plugin-script-shell` (`Commands` with the Docker task runner), `plugin-slack`

## Testing

Tested on `kestra/kestra:v2.0.1` and `kestra/kestra:latest` (2.0.5), with two real MinIO servers with versioning enabled and a bucket replication rule from source to target. A local HTTP sink receives the Slack messages. No mocks. The same final flow passed all 13 scenarios on both versions.

| Case | Result |
|---|---|
| 01 Healthy, first run | ✅ SUCCESS, no message |
| 02 Healthy, repeat | ✅ SUCCESS, no message |
| 03 Target stopped while writing (3 objects) | ✅ SUCCESS, one alert: target offline and "3 object(s) failed" |
| 04 Same outage, repeat run | ✅ SUCCESS, no message |
| 05 Target back, approve resync for the failed objects | ✅ PAUSED with two messages; after Start resync the 3 objects are on the target, report "Fixed." |
| 06 Recovery, then repeat | ✅ one "all 1 bucket(s) are healthy again" message; next run silent |
| 07 Missing and mismatched objects, approve resync | ✅ missing keys restored; mismatched key reported as "Still short" with the reason |
| 08 Same kind of gap, decline | ✅ PAUSED, resumed with Decline: `resync_buckets` did not run, target unchanged |
| 09 Replication rule disabled | ✅ one alert naming the disabled rule, no resync offer; repeat silent |
| 10 Approval after the rule was disabled | ✅ run ends WARNING; the re-check refused the resync; object still missing; report says no resync was done |
| 11 Source unreachable | ✅ FAILED at `check_source`; one errors alert naming it |
| 12 Webhook trigger | ✅ run started by a real HTTP POST; trigger type `Webhook`; SUCCESS |
| 13 Invalid bucket name (`Bad_Name`) | ✅ FAILED at `invalid_bucket_name`, before any MinIO call; one errors alert |

Also verified against the MinIO API directly, not only through the flow: replicated objects have the same size and ETag on both sides, and `mc replicate backlog --full --json` shows FAILED entries while the target is down.

Gantt of run 05 (approve resync for failed objects, `Completed` resync, `recheck` and `report_resync`):

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/minio-bucket-replication-audit/run-gantt.png" alt="Gantt view of a successful execution with the resync loop" width="800">

**Not tested:** the 2-hour pause expiry, the hourly `Schedule` (shipped disabled), and sampling on a bucket above the 200-object sample size.

**Test environment:** Docker Hub refused the `minio/minio` and `minio/mc` pulls in the test sandbox, so the MinIO server and `mc` were built from their Go sources and the `minio/mc:latest` tag was built locally from that `mc` binary. The flow names the official `minio/mc` image, which is what users should run.

## Notes

- Resync limits found while testing, and documented in the flow: a plain `mc rm` on a versioned target leaves a delete marker, and resync does not bring that object back. A mismatched object (a newer version written directly on the target) is not replaced by resync; the Slack report says so and asks for a manual decision.
- Failed objects did not retry by themselves once the target was back (observed for more than 60 seconds), which is why the flow offers a resync for them.
- There is no flow-level `concurrency`, so a run waiting on approval does not block monitoring. The KV state keeps it to one message per change in practice.
- Secrets: `MINIO_SOURCE_ENDPOINT`, `MINIO_SOURCE_ACCESS_KEY`, `MINIO_SOURCE_SECRET_KEY`, `MINIO_TARGET_ENDPOINT`, `MINIO_TARGET_ACCESS_KEY`, `MINIO_TARGET_SECRET_KEY`, `SLACK_WEBHOOK_URL`.
- Tags: `Infrastructure`, `Data`; the tag validator passes for this file.
