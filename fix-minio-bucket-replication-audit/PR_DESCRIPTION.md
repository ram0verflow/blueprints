Follow-up to #1216 (`minio-bucket-replication-audit`). One file changed.

## Fix: webhook key read from a secret (follow-up from a review pass)

The Webhook trigger used the placeholder key `minio-replication-audit-change-me`. Anyone who knew the blueprint could guess the URL, and the docs relied on the reader remembering to change it.

- `key: minio-replication-audit-change-me` → `key: "{{ secret('MINIO_REPLICATION_WEBHOOK_KEY') }}"`
- the literal key is removed from the curl example (it now shows `$KEY`)
- `MINIO_REPLICATION_WEBHOOK_KEY` is listed under Secrets

## How it was tested

On Kestra 2.0.1 (`kestra/kestra:v2.0.1`), with the secret set:
- the flow passes `POST /api/v1/flows/validate` (no constraints, warnings or deprecations);
- `POST /api/v1/main/executions/webhook/company.team/minio-bucket-replication-audit/<secret value>` returns HTTP 200 and creates an execution started by the `webhook` trigger;
- the same call with the old `minio-replication-audit-change-me` key returns HTTP 404.

Nothing else in the flow changed.
