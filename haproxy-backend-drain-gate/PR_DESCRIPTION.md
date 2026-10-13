## What

New blueprint `haproxy-backend-drain-gate`. It takes one server out of an HAProxy backend for maintenance without cutting its live sessions, and puts it back once its health check passes. The drain mode:
- refuses before anyone is asked if the other servers cannot carry the traffic (`min_healthy`), and checks again after the approval;
- asks on-call to approve in the Kestra UI;
- sets the server to `drain`, waits until its sessions reach 0, and sets `maint` only then. If sessions remain at the timeout, the server stays in `DRAIN` and the run fails;
- confirms the status HAProxy reports at the end.

The enable mode sets `ready` and waits until HAProxy reports `UP`. It talks to the HAProxy runtime API over the stats socket on TCP.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/haproxy-backend-drain-gate/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `haproxy_change` (`Webhook`, event-based) and `nightly_reenable` (`Schedule`, shipped disabled) start a run
2. `validate_input` (`If`) rejects bad names or modes before any socket use. `read_pool` reads `show stat` for the backend. `target_check` (`If`) stops on an unknown server
3. Drain: `precheck` (`If`) → `ask_approval` (Slack) → `wait_for_decision` (`Pause`, one hour) → `decision_gate` (`If`) → `recheck_pool` and `recheck_gate` (`If`) → `start_drain` → `wait_drain` (`LoopUntil`) → `confirm_drained` → `drain_gate` (`If`) → `set_maint` → `confirm_maint` → `maint_gate` (`If`) → `notify_drained`
4. Enable: `if_enable` (`If`) → `set_ready` → `wait_health` (`LoopUntil`) → `confirm_health` → `health_gate` (`If`) → `notify_enabled`

The approval form (the `decision` select defaults to `decline`):

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/haproxy-backend-drain-gate/resume-dialog.png" alt="Resume dialog with the decision select" width="420">

`concurrency` is `limit: 1` with `QUEUE`, so a second run waits while a drain is awaiting approval. Two drains of different servers could otherwise each pass the capacity check.

## Error handling

- **Bad input changes nothing.** Names may contain only letters, digits, dot, dash and underscore. Anything else stops at `reject_input` before the socket is opened. Names reach the shell only through environment variables.
- **Capacity is checked twice.** Before the approval request and after it. The second check decides.
- **Timeouts never reach `maint` with sessions open.** `drain_timed_out` fails the run and the server stays in `DRAIN`. It takes no new sessions and the open ones continue.
- **HAProxy's replies are checked.** Errors such as "No such server." come back as text and are turned into a failed task.
- **Retries** with exponential backoff on every socket call.
- **Errors name the task.** The `errors` alert gives the failing task and its cause, for example `read_pool`: "HAProxy runtime socket not reachable at 127.0.0.1:9990", or `not_up` when an enabled server does not pass its health check.
- **Nobody answering is a decline.** A `Pause` with `RESUME` after an hour leaves the decision empty, which counts as a decline.

## Why it is different

No blueprint in `kestra-io/blueprints` main drives HAProxy's runtime API. The three catalog matches for HAProxy are TLS certificate and reverse-proxy reload flows: they reload the daemon but do not drain a server, so they cannot protect live sessions. The open PR #1150 (HAProxy backend server down/flapping sentinel) watches for servers that go down; this blueprint is the planned-maintenance side: a capacity-checked, approved drain that waits for sessions to close, and a health-checked return to rotation.

## Hacktober requirements

- **3+ runnable tasks:** `read_pool`, `start_drain`, `wait_drain`, `set_maint`, `set_ready`, `confirm_*`, and the Slack notifications
- **Flowable tasks:** `If` (×10), `Pause`, `LoopUntil` (×2), `Exit` (×3), `Fail` (×5)
- **Triggers:** `Webhook` (event-based) and `Schedule` (disabled)
- **Non-core plugins:** `plugin-script-shell` (`Commands`, Process runner), `plugin-slack`

## Testing

Tested on `kestra/kestra:v2.0.1` and on `kestra/kestra:latest` (2.0.5), with HAProxy 2.9.15 in front of three backend containers, a Slack sink on localhost and a real long-lived client connection to every server. Both versions passed all 12 scenarios of a scripted matrix on the final revision.

| Scenario | Result (2.0.5 run; 2.0.1 identical unless noted) |
|---|---|
| 1 Drain happy path: 6 live connections, approved | ✅ SUCCESS in 60–64 s; web1 went from 2 sessions to 0, HAProxy `MAINT`; one maintenance message |
| 2 Drain timeout: a session still open after 25 s | ✅ FAILED at `drain_timed_out`; web1 `DRAIN` with 1 session open; alert names the task |
| 3 Refuse: `min_healthy` 3 with 3 servers | ✅ FAILED at `refuse_drain` before any approval; web1 `UP`; one refusal message |
| 4 Another server DOWN while the approval waits | ✅ web3 DOWN; FAILED at `refuse_late`; web1 still `UP`; one message |
| 5 Decline at the approval | ✅ SUCCESS via `end_declined`; web1 `UP`; no drain task ran |
| 6 Enable a server in MAINT | ✅ SUCCESS in 12 s; web1 `UP`; "back in rotation" message |
| 7 Enable while the health check keeps failing | ✅ FAILED at `not_up` after 12 s; web2 stays `DOWN`; alert names `not_up` |
| 8 Unknown server `web9` | ✅ FAILED at `unknown_server`; alert lists web1, web2, web3 |
| 9 HAProxy stopped | ✅ FAILED at `read_pool` after 3 attempts; alert: "HAProxy runtime socket not reachable at 127.0.0.1:9990" |
| 10 Webhook: `?action=enable&server=web2` | ✅ SUCCESS; web2 `UP`; the run was started by the Webhook trigger |
| 11 Server `web1;rm` | ✅ FAILED at `reject_input`; HAProxy not touched |
| 12 Second run while a drain waits for approval | ✅ second run `QUEUED`, then both SUCCESS |

Also checked on 2.0.1 with a temporary variant that changes only the approval pause to 20 s and the schedule to every minute, then restored: an unanswered approval ended SUCCESS via `end_declined`, and the scheduled run fired with `action=enable` and SUCCESS.

A run with the drain:

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/haproxy-backend-drain-gate/run-gantt.png" alt="Gantt view of a drain run: the drain loop waits about a minute, then set_maint" width="800">

## Notes

- The stats socket has no authentication. Bind it to loopback or a management network.
- The shell tasks need `bash`, `awk` and `date` on the worker. They use the Process runner, so no Docker is needed.
- The nightly schedule is shipped disabled. Do not enable it for a server that is in maintenance on purpose; it sets `ready`.
- Not tested: the shipped one-hour approval timeout and the shipped disabled schedule. Both were tested through the variant above, which changes only those two values.
- The approvals in the matrix were answered through the API. The resume dialog screenshot was taken without submitting it.
- Validate Blueprint Tags: the branch was checked locally against all flows with the validator script. Zero failures.
