Follow-up to #1119 (`postgres-transactional-outbox-relay`). One file changed.

## Fix: webhook key read from a secret (follow-up from a review pass)

The Webhook trigger used the placeholder key `outbox-relay-change-me`. Anyone who knew the blueprint could guess the URL, and the docs relied on the reader remembering to change it.

- `key: outbox-relay-change-me` → `key: "{{ secret('OUTBOX_RELAY_WEBHOOK_KEY') }}"`
- the literal key is removed from the curl example (it now shows `$KEY`)
- `OUTBOX_RELAY_WEBHOOK_KEY` is listed under Secrets, and the Quick start step that said "change the webhook key" now says to add the secret

## How it was tested

On Kestra 2.0.1 (`kestra/kestra:v2.0.1`), with the secret set:
- the flow passes `POST /api/v1/flows/validate` (no constraints, warnings or deprecations);
- `POST /api/v1/main/executions/webhook/company.team/postgres-transactional-outbox-relay/<secret value>` returns HTTP 200 and creates an execution started by the `after_commit` trigger;
- the same call with the old `outbox-relay-change-me` key returns HTTP 404.

Nothing else in the flow changed. Not in this PR: adding `retry` to the Slack tasks (including the dead-letter alert in the loop's `errors` branch). That was a suggestion from the same review pass, and I would rather change it with a test that makes Slack fail inside the loop.
