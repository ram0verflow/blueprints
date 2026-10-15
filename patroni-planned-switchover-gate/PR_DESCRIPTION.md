## What

New blueprint `patroni-planned-switchover-gate`: **Patroni Planned Switchover with Pre-Checks, Approval and Verification.**

Planned maintenance (OS patching, a minor upgrade, moving the primary to another zone) on a Patroni cluster starts with a switchover. The command is one line. The checks around it are what prevent an incident:
- is the candidate streaming, on the leader's timeline, and caught up?
- is the DCS healthy?
- is the cluster still in the same state an hour after the plan was approved?
- afterwards, did the timeline move and do the replicas follow the new leader?

This flow does all of that through the Patroni REST API, with a person approving the switch.

## Why it is different

**The gap:** the catalog has nothing for PostgreSQL high availability. No blueprint reads a Patroni cluster, performs a switchover or verifies a topology change, and no open or closed PR does (checked 2026-10-15).

It is a day-2 operation with its safety steps:
- pre-checks that refuse before anyone is asked;
- an approval;
- the same checks again after the approval, including "the leader is still the one we planned to move";
- Patroni's own answer reported when it refuses;
- a convergence check (`LoopUntil`) rather than "the API said 200".

The jq rules engine (one program, run on two API responses) is a reusable pattern for any API-driven gate.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/patroni-planned-switchover-gate/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `maintenance_window` (`Webhook`, key from a secret). `concurrency` limit 1.
2. `read_cluster` (`GET /cluster`) → `plan` (`OutputValues`, jq):
   - picks the leader and a candidate (input, or the streaming replica with the least lag);
   - lists every problem: no leader, cluster paused, switchover already scheduled, candidate not streaming, unknown or too much lag, other timeline, `nofailover` tag.
3. `precheck` (`If`) → `refuse` (`Fail`) if anything is wrong.
4. `request_approval` (Slack) → `approve` (`Pause`, BOOL + note).
5. `decision` (`If`):
   - `read_cluster_again` → `plan_again` → `recheck`: same rules, same leader, or `refuse_after_approval`;
   - `switchover` (`POST /switchover`, basic auth from secrets, `allowFailed`) → `switchover_answer`: if not 200, `who_leads_now` + `switchover_failed` quote Patroni and the current topology;
   - `verify` (`LoopUntil`, every 3 s, up to `verify_timeout`): the candidate leads on timeline + 1 and every other member streams on that timeline;
   - `record` (`kv.Set`) → `report_done`, or `report_not_approved`.
6. `errors` → `alert_failure`. When `read_cluster` fails, a hint says whether it looks like the DCS or an unreachable API.

## Error handling

- **Refusals happen before the approval, then again after it.** The cluster can change while a person decides, so a stopped, lagging or demoted member, or a new leader, cancels the switch.
- **Patroni's own refusal is reported.** In a test, the candidate froze right after the re-check. Patroni answered 412 "switchover is not possible: no good candidates have been found", the old leader stayed, and the alert listed the cluster.
- **DCS outage.** `GET /cluster` is served from the DCS, so the flow stops at the first task. The alert explains why.
- **Lag uses Patroni's own figure.** Found while testing: Patroni's `lag` counts received WAL, not replayed WAL. A replica with replay paused shows 0 lag, and Patroni switched over to it, finishing the replay during promotion. A replica that stops receiving WAL (case B) is caught.
- **A topology that does not settle** (a replica that does not reconnect) fails `verify` with every member's role, state and timeline.

## Hacktober requirements

- **3+ runnable tasks:** `read_cluster`, `request_approval`, `switchover`, `read_topology`, `record`, `report_done`, `alert_failure`
- **Flowable tasks:** `If` (×4), `Pause`, `LoopUntil`, `concurrency`
- **Triggers:** `Webhook` (event-based, from a change-management tool)
- **Non-core plugins:** `plugin-slack`

## Testing

Every case ran on the final revision on both `kestra/kestra:v2.0.1` and `kestra/kestra:latest` (2.0.6). The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations. The numbers below are from 2.0.1. On 2.0.6 only the lag figures, timelines and the transport error in case C differed.

Test cluster:
- etcd 3.5.17 and three Patroni 4.1.5 / PostgreSQL 16 nodes.
- `restapi.authentication` set, so the POST endpoints need the secrets.
- A local Slack sink.

| Case | Result |
|---|---|
| A. No candidate given, approved | ✅ Plan "pg1 -> pg2 (candidate lag 0 bytes, timeline 4)"; approved; "Patroni switchover DONE: pg1 -> pg2, timeline 4 -> 5, 2 of 2 replicas streaming from the new leader. Successfully switched over to "pg2""; KV `patroni_last_switchover` written |
| G. Declined | ✅ "NOT done (declined: peak traffic, try tonight). pg2 is still the leader." |
| F. `approval_timeout: PT15S` | ✅ Run on its own: "NOT done (no decision within the approval window). pg2 is still the leader." See the note on `Pause` below |
| B. Candidate's container frozen (`docker pause`) while the leader writes 300,000 rows | ✅ "SWITCHOVER REFUSED before approval: candidate pg1 is 28917792 bytes behind the leader (limit 1048576)" |
| D. Candidate stopped after the approval | ✅ "SWITCHOVER REFUSED after approval, the cluster changed while waiting: candidate pg3 is stopped, not streaming"; no POST sent |
| E. Candidate frozen between the approval and the POST | ✅ "SWITCHOVER FAILED: Patroni answered HTTP 412: switchover is not possible: no good candidates have been found. Leader now: pg1 replica …, pg2 leader running tl 5 …"; pg2 stayed leader |
| C. etcd stopped | ✅ Stopped at `read_cluster`, nothing attempted, with the DCS hint. 2.0.1 reports "Read timed out" and 2.0.6 "failed to respond"; found while testing, the hint first covered only the first. When etcd came back, Patroni had demoted and re-promoted the leader (timeline + 1), as it does without `failsafe_mode` |
| I. `patronictl pause` | ✅ "SWITCHOVER REFUSED before approval: the cluster is paused (maintenance mode) …" |
| H. Webhook | ✅ Key from the secret → HTTP 200 (the default `patroni_url` does not resolve here, and the alert says the API could not be reached); wrong key → HTTP 404 |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/patroni-planned-switchover-gate/run-gantt.png" alt="Gantt view of an approved switchover and its verification" width="800">

## Notes

- **Test setup.** All nodes ran with host networking on one machine, with different ports. "Frozen VM" means `docker pause` on the member's container.
- **`max_lag_bytes`** should be at or below Patroni's `maximum_lag_on_failover`, which Patroni also applies when it chooses a switchover candidate.
- **Not tested:** Consul or ZooKeeper as the DCS, synchronous replication (`synchronous_mode`), standby clusters, and Patroni 3.x.
- **Kestra `Pause` timeout, found while testing (2.0.1 and 2.0.6).**
  - In 7 of 16 approval-timeout runs across these four blueprints, the `Pause` stayed PAUSED after `pauseDuration` ran out.
  - Each stuck run started right after another run of the same flow had been resumed, and all four flows have `concurrency` limit 1.
  - A stuck run holds the flow's queue until someone answers or kills it. It changes nothing in the meantime.
  - A 2-task flow with `concurrency` and a `Pause` reproduced it once, but not on a clean repeat.
  - Run on their own, the timeout cases in the table passed on both versions. The docs tell users to answer or kill a waiting run before starting another.
- Tags: `Infrastructure`; the tag validator passes on this branch.
