## What

New blueprint `kafka-throttled-partition-reassignment`: **Move Kafka Partitions Safely with a Minimal Plan, a Throttle and a Rollback.**

Draining a Kafka broker before decommissioning it, or filling a new one, is a routine job that goes wrong in well-known ways:
- `kafka-reassign-partitions --generate` reshuffles replicas that never needed to move;
- an unthrottled move saturates the network and starves producers and consumers;
- a move started while partitions are under-replicated can remove the only in-sync copy;
- the throttle is only removed by a `--verify` run after the move completes. Forget it, and replication on those brokers stays throttled until someone notices.

This flow runs the whole procedure with the stock Kafka tools and a small Python planner:
1. It plans the smallest move.
2. It refuses to start on an unhealthy cluster.
3. It saves the current assignment for rollback.
4. A person approves the numbers (replicas, MiB per broker, estimated time).
5. It runs the move under a throttle and follows it with `--verify` until it is done or a time limit is reached; then it cancels and rolls back, or leaves the move running, as configured.
6. A `finally` step makes sure no throttle is left behind.

## Why it is different

**The gap:** main has 26 Kafka flows:
- monitoring of lag, replication and under-replicated partitions;
- ACLs, quotas and topic configs;
- Connect and Schema Registry;
- a consumer-offset rewind and DLQ replay.

None of them moves partitions between brokers. No flow in main or in any open or closed PR runs `kafka-reassign-partitions` (checked 2026-10-16); the only mention is an "extend" suggestion in PR 1934.

It is a day-2 job with the safety mechanics people learn the hard way:
- **The smallest move.** A replica stays where it is if its broker is a target; only replicas on other brokers are replaced, in place, by the least loaded target broker. In the tests this moved 7 replicas where `--generate` proposed 7 to 11 for the same request (its plan is random).
- **The throttle never outlives the move.** `--verify` removes it on completion. After a cancel, a failed task or a dead worker, the flow-level `finally` removes it once nothing is moving, and names any broker it could not reach.
- **`--cancel` is not a full rollback.** It restores each partition's replica set but not always the order, which moves the preferred leader: in the tests, 4 of 7 partitions came back reordered. The flow re-applies the saved assignment after a cancel (no data is copied for that).
- **Checks before and after the approval.** The approval can come hours later, so "no other move is running" is checked again right before `--execute`.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/kafka-throttled-partition-reassignment/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `move_request` (`Webhook`, body `{"topics": "...", "target_brokers": "..."}`, key from a secret) or a manual run. `concurrency` limit 1.
2. `inspect` (`shell.Commands`, `apache/kafka` image, read-only) saves the raw tool output as files:
   - brokers, and a check that every target broker is one of them;
   - the current assignment and a `--generate` proposal;
   - under-replicated and leaderless partitions, running reassignments;
   - partition sizes and broker throttle configs.
3. `plan` (`python.Script`) reads those files and works out:
   - the smallest move;
   - the preconditions;
   - MiB per receiving broker and the time at the throttle;
   - leftover throttles from an earlier move nobody verified.
4. `preflight` (`If` + `Fail`); `anything_to_move` (`If` + `Exit` when the topics are already on the target brokers).
5. `save_rollback` (`kv.Set`) → `request_approval` (Slack) → `approve_move` (`Pause`, 4 h, BOOL `onResume`; no decision means no move).
6. `approval_gate` (`If`):
   - `move`: re-check, `--execute --throttle`, then `--verify` every 10 s. At `max_minutes`, `--cancel --preserve-throttles` and re-apply the saved assignment, or leave the move running.
   - `after_move`: every partition has the planned replicas (or the original ones after a cancel); preferred leader election for the moved partitions.
   - `report` (`Switch` on `done` / `cancelled` / `running`).
7. `finally` → `throttle_guard` after every approved move → Slack only when it had to act.
8. `errors` → one Slack alert with the failing task, the reason and the KV key of the rollback assignment.

## Error handling

- **Nothing changes until a person approves**, and the flow refuses before that when any of these hold:
  - the cluster is unreachable;
  - a topic is unknown, or a target broker is not in the cluster;
  - partitions are under-replicated or leaderless;
  - a reassignment is already running.
- **Time limit:**
  - `cancel` stops the move and restores the original replicas and their order;
  - `keep_running` says that the throttle stays until someone runs `--verify`, and the test proves it does.
- **Found while testing:**
  - Kestra runs shell commands with `set -e`, and `grep -c` exits 1 when it counts zero, which killed the first `move` right after `--execute`. The move kept running in Kafka with throttles on all four brokers. That is why the throttle clean-up now lives in `finally` and not in a task after the move.
  - `--cancel` clears throttles on every broker, and timed out when the destination broker was down. It now runs with `--preserve-throttles`, and `finally` removes them.
  - A broker that is down does not appear in `kafka-configs --describe`, so its throttle is invisible; the guard compares the brokers that answered at the start and names the missing one.
  - The `apache/kafka` image runs as a non-root user, so the Kafka tasks run with `user: root` to write their output files.

## Hacktober requirements

- **3+ runnable tasks:** `inspect`, `plan`, `save_rollback`, `request_approval`, `move`, `after_move`, `report_done`, `throttle_guard`, `alert_failure`
- **Flowable tasks:** `If` (`preflight`, `anything_to_move`, `approval_gate`, `check_result`, `after_approved_move`, `guard_report`), `Switch` (`report`), `Pause`, `Exit`, `finally`, `concurrency`
- **Trigger:** `Webhook` (event-based, called by a capacity or decommissioning runbook with the topics and target brokers)
- **Non-core plugins:** `plugin-script-shell` and `plugin-script-python` with the Docker task runner, `plugin-slack`

## Testing

Every case ran on the final flow on `kestra/kestra:latest` (2.0.6) and `kestra/kestra:v2.0.1`. The flow passes `POST /api/v1/flows/validate` on both with no constraints, warnings or deprecations. Both versions gave the same results. The numbers below are from 2.0.6, except case N's guard message, whose spacing was fixed after that run and checked on 2.0.1.

Setup:
- A real four-broker KRaft cluster on Kafka 3.9.1 (nodes 1 to 3 are also controllers), built with the Quick start commands from the docs, run verbatim.
- `orders` (6 partitions, RF 2, about 200 MB) and `payments` (3 partitions, RF 3), both on brokers 1 to 3.
- A local Slack sink.
- Each case started from the original layout.

| Case | Result |
|---|---|
| A. Drain broker 3 onto 1, 2, 4 at 10 MiB/s, approved | ✅ "7 replica(s) of 7 partition(s) … (the random plan of `--generate` for the same request moved 11)" → "154.1 MiB in 28 s under a 10 MiB/s throttle. Throttle removed by --verify; preferred leaders elected; 0 under-replicated"; no throttle config left on any broker or topic |
| B. Declined | ✅ "not started (declined). Nothing was changed."; layout unchanged |
| C. No decision (`pauseDuration` PT20S in the test copy) | ✅ "not started (no decision …). Nothing was changed." |
| D. Topics already on the target brokers | ✅ "every partition … already lives on brokers 1,2,3. Nothing to move." (`Exit` SUCCESS) |
| E. Target broker 7 | ✅ FAILED at `inspect`: "target broker(s) 7 are not in the cluster (brokers answering: 1,2,3,4). Nothing was changed" |
| F. Broker 2 stopped | ✅ FAILED at `refuse`: "7 partition(s) are under-replicated (orders-0, …): moving data now removes a replica that may be the only in-sync copy" |
| G. Another reassignment running | ✅ FAILED at `refuse`: "a reassignment is already running (orders-1): Kafka would merge both moves" |
| H. Leftover 1 MiB/s throttle on broker 2 | ✅ The approval message notes it, the move replaces it, and nothing is left afterwards |
| I. Time limit (1 MiB/s, `max_minutes: 1`), `cancel` | ✅ FAILED: "not finished within 1 min (3 of 7 partitions had moved). Cancelled: every partition is back on its original replicas in the original order"; layout and leaders as before; no throttle left |
| J. Time limit, `keep_running` | ✅ "still running … It continues under the 1 MiB/s throttle"; once the move finished by itself, the throttle was still set on all 4 brokers, as the message says |
| N. Destination broker 4 stopped mid-move, `cancel` | ✅ Cancelled and restored with broker 4 down; the guard names it: "Could not check or remove the throttle on broker 4 (not answering) …". When broker 4 came back, its throttle was indeed still there |
| K. Wrong bootstrap address | ✅ FAILED at `inspect`: "cannot reach 127.0.0.1:9999 …" |
| L. Unknown topic | ✅ FAILED at `inspect`: "… Topic invoices not found." |
| M. Webhook `{"topics":"payments","target_brokers":"1,2,4"}` | ✅ HTTP 200, only `payments` moved: "3 partition(s) … 19.3 MiB in 16 s"; wrong key → HTTP 404 |

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/kafka-throttled-partition-reassignment/run-gantt.png" alt="Gantt view of an approved move" width="800">

## Notes

- **The approval timeout is a constant (`PT4H`), not an input.** On Kestra 2.0.x a templated `pauseDuration` can carry one execution's value into the next ([kestra-io/kestra#18581](https://github.com/kestra-io/kestra/issues/18581), fixed on develop).
- **Not tested:**
  - ZooKeeper-mode clusters (the tools are the same);
  - rack-aware placement (the planner ignores racks; see "How to extend");
  - JBOD log-dir moves;
  - SASL/TLS clusters, which need a client properties file passed with `--command-config`.
- The Kafka tasks use `networkMode: host` to reach the brokers the worker host reaches.
- Tags: `Infrastructure`; the tag validator passes on this branch.
