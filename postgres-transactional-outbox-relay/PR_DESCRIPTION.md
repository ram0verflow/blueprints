## What

New blueprint `postgres-transactional-outbox-relay`. It relays a transactional outbox table from PostgreSQL to a RabbitMQ exchange: the service writes its data and the event in one transaction, and this flow publishes the event. The flow then:
- leases batches with `FOR UPDATE SKIP LOCKED` + `claimed_until`, so overlapping runs never publish the same row;
- keeps per-aggregate order: an event is never published while an older event of its aggregate is pending or dead-lettered, while other aggregates keep flowing;
- uses the outbox id as the AMQP message id, so consumers can drop the rare redelivery;
- counts failed attempts, backs off exponentially, dead-letters after `max_attempts` and tells Slack exactly how to replay or discard;
- alerts once when the oldest unpublished event is older than a threshold, and once when it clears.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-transactional-outbox-relay/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `outbox_rows` (PostgreSQL `Trigger`, event-based): fires when an event is ready (pending, out of backoff, not leased, not waiting behind an older event). `after_commit` (`Webhook`) for a low-latency nudge after a commit; `backstop` (`Schedule`, disabled) runs the lag check when nothing is ready.
2. `ensure_outbox` creates the table, partial indexes and a one-row state table.
3. `check_exchange`, `check_bindings` (management API, retries) → `broker_guard` (`If` + `Fail`): nothing is claimed if the broker is down, the exchange is missing, or it has no bound queue (the AMQP `Publish` task has no mandatory flag, so such messages would vanish silently).
4. `claim_batch`: one `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED)` that leases the oldest ready events, skipping, per aggregate, everything after the first event that cannot go now.
5. `publish_each` (`Loop`, `concurrencyLimit: 1`) with one `Sequential` (`allowFailure`) per event:
   - `take_turn`: the ordering, fencing and circuit-breaker guard (still our lease? no older unpublished event? fewer than `stop_after_failures` failed events in this run, counted in Postgres because iterations cannot see each other's outputs?), renewing the lease or handing the row back without counting an attempt;
   - `its_turn` (`If`) → `publish` (AMQP, persistent, `messageId` = outbox id, routing key `<aggregate_type>.<event_type>`) → `mark_published` (only while the lease is ours);
   - local `errors`: `record_failure` (attempt + 1, backoff 30 s, 60 s, 120 s, …, `dead` after `max_attempts`) → `dead_lettered` (`If`) → Slack.
6. `release_unsent`, `check_lag` → `lag_changed` (`If`) → Slack, `prune_published`.
7. `circuit_open` (`If`): `FAILED` after `stop_after_failures` failed events (the broker is the likely cause), otherwise `WARNING` if any event failed.

Exactly-once is enforced in the database, not with Kestra `concurrency`: `Loop` iterations are sub-executions, and parallel runs are allowed on purpose.

## Error handling

- **No double publishing between runs.** Claims use `SKIP LOCKED` and a lease, and every later write checks `claimed_by` and `claimed_until`. A killed run's rows wait for the lease to expire and are then taken over.
- **Order survives failures.** If an event fails, its aggregate's later events wait (they are released without counting an attempt), and other aggregates are not affected.
- **Poison events are dead-lettered, not retried forever.** The alert names the event, its payload size, how many events wait behind it, and the exact `UPDATE` to replay or discard it.
- **Broker trouble does not burn attempts.** The pre-flight check fails before anything is claimed. A mid-batch outage stops the loop after `stop_after_failures` and releases the rest untouched.
- **Lag is visible.** One message when the oldest unpublished event passes `lag_alert_minutes`, saying why (held behind a dead letter, failing with its last error, or not tried yet), and one when it clears.
- **Everything else** releases the run's claims and alerts with the task and the cause.

## Why it is different

The catalog's `postgres-transactional-outbox-kafka-fanout` (#863) relays an outbox to Kafka. It serializes runs with `concurrency: 1`, a failed publish fails the whole batch until a 15-minute claim timeout, and dead-letter handling is listed only as an extension idea. This blueprint targets RabbitMQ and is built around the failure side:
- isolation per event, with attempt counting, exponential backoff and dead-lettering;
- order kept across failures;
- safe parallel runs;
- a circuit breaker for broker outages;
- pre-flight checks for exchanges that would silently drop messages;
- lag alerting;
- a JDBC trigger whose query matches exactly what the flow can process, so it never starts empty runs.

The other RabbitMQ blueprints (`rabbitmq-dlq-quarantine-and-replay`, `amqp-consumer-dead-letter-queue`, `produce-to-rabbitmq`) deal with the consumer or producer side, not with getting database events out reliably.

## Hacktober requirements

- **3+ runnable tasks:** `ensure_outbox`, `check_exchange`, `check_bindings`, `claim_batch`, `take_turn`, `publish`, `mark_published`, `record_failure`, `release_unsent`, `check_lag`, `prune_published`, Slack notifications
- **Flowable tasks:** `Loop` (ordered, `concurrencyLimit: 1`), `Sequential` (`allowFailure` + local `errors`), seven `If`s
- **Triggers:** PostgreSQL `Trigger` (event-based), `Webhook` (event-based) and `Schedule`
- **Non-core plugins:** `plugin-jdbc-postgres`, `plugin-amqp`, `plugin-slack`

## Testing

Tested on `kestra/kestra:v2.0.1` and `kestra/kestra:latest` (2.0.5 OSS) with `postgres:16` and `rabbitmq:3-management` (3.13.7, `max_message_size = 65536`), a topic exchange `domain-events` bound to a `consumer` queue, and a local Slack sink. A scripted harness drained the queue after each case and checked each message id and the per-aggregate order.

| Scenario | Result |
|---|---|
| JDBC trigger on, outbox empty for 35 s | ✅ 0 executions |
| JDBC trigger on, 120 events over 12 orders inserted | ✅ 3 trigger runs, all `SUCCESS`, 41–44 s; consumer got 120 messages, 120 distinct, none out of order; no Slack message |
| Two simultaneous runs, 10 rounds (batch 10, 200 events, 40 aggregates) | ✅ 20 runs `SUCCESS`, each published 10; 0 rows claimed by both runs of a pair; 200 messages, 200 distinct, in order |
| Run killed mid-batch (lease 20 s, 150 events) | ✅ 6–7 published, 43–44 still leased; an immediate rerun claimed 0; after the lease a rerun took them over; 150 distinct messages, in order (151 delivered: the event in flight when the run was killed was sent again with the same message id) |
| Poison event (100 KB payload vs 64 KB broker limit), `max_attempts` 3 | ✅ Runs `WARNING`, event dead after 3 attempts, its successor held, the other order published; one alert: "Outbox event 1 (order ORD-9, OrderPlaced) was dead-lettered after 3 attempts … 1 later event(s) of order ORD-9 are held back" with the replay and discard SQL |
| Replay after raising `max_message_size` | ✅ `SUCCESS`; consumer got event 1 then event 2 |
| Missing exchange | ✅ `FAILED` at `broker_not_ready`, 0 rows claimed: "Exchange 'does-not-exist' does not exist in vhost '/': declare it and bind the consumer queues. Nothing was claimed." |
| Exchange with no bound queue | ✅ `FAILED`, 0 rows claimed: "… has no bound queue and no alternate-exchange: the broker would drop every message without an error" |
| Broker stopped | ✅ `FAILED` at `check_exchange` after retries, 0 rows claimed or attempted, alert "Connect to http://localhost:15672 failed: Connection refused"; after the restart the next run published all 5 |
| AMQP refused mid-batch (`max-connections: 0` on the vhost, management API still up) | ✅ `FAILED` at `too_many_failures` after 3 failed events; the other 7 were handed back unsent with 0 attempts (attempts `1110000000`), 0 rows left leased, alert "3 events failed in this run, so it stopped early and handed back 7 unsent event(s)"; after clearing the limit all 10 arrived, in order |
| Lag: event 11 min old held behind a dead letter | ✅ One alert "Outbox lagging: event 2 (payment PAY-1, PaymentRefunded) has waited 11.0 min … held behind dead-lettered event 1"; no repeat on the next run; after discarding event 1: "Outbox back to normal" |
| Webhook | ✅ HTTP 200, run `SUCCESS` (trigger `after_commit`), 3 messages |

All 14 checks in these 12 scenarios passed in a full run of the matrix on the final revision, once on `v2.0.1` and once on `latest` (2.0.5). The flow also passes `/api/v1/flows/validate` on both. Throughput was about 5 events per second.

A run with one oversized event (`WARNING`: the event failed once and backs off, the other orders were published):

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-transactional-outbox-relay/run-gantt.png" alt="Gantt view of a relay run with one failed event" width="800">

## Notes

- Delivery is at-least-once. A crash between the publish and `mark_published` sends the event again after the lease, with the same message id, so consumers should deduplicate on it. The killed-run test shows it: the event in flight when the run was killed was delivered twice, with the same message id.
- The AMQP `Publish` task has no publisher confirms. The flow checks the exchange's bindings before claiming, but a topic binding that matches no routing key, or a queue that rejects publishes when full, can still drop a message. An alternate-exchange covers the first case.
- Per-aggregate order follows the outbox `id`. That matches commit order when writes to one aggregate are serialized (they lock the aggregate's row), which is the usual case.
- `errorLogs()` is empty inside `Loop` iterations in Kestra 2.0, so `last_error` names the failed step and the alert links to the run, where the broker's reason is in the `publish` log.
- Connection settings are repeated per task, because flow-level `pluginDefaults` is gone in 2.0.
- The JDBC trigger and the schedule ship `disabled: true`. The tests enabled the trigger in a copy that differed only in that flag.
- If **Validate Blueprint Tags** is red: it checks every file in `flows/`. This blueprint uses `Data, Infrastructure`, and the validator found no failing file on this branch.
