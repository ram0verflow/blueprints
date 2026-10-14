Follow-up to #693 (`openapi-breaking-change-gate`). One file changed.

## Fixes

### 1. A Pause timeout now blocks the release cleanly (found while testing)

The flow promises "no answer within 2 hours blocks the release". With `behavior: RESUME` and no answer, `onResume.decision` is not set, so the `approved` condition threw instead of evaluating to false. The run still ended `FAILED`, so nothing shipped, but it failed at `approved` with a Pebble error, not at `blocked` with the change that needed approval:

```
Unable to resolve state from the Flowable task: io.pebbletemplates.pebble.error.PebbleException:
Could not perform equals comparison ({{ outputs.wait_for_owner.onResume.decision == 'Approve these breaking changes' }}:1)
```

Change: `(outputs.wait_for_owner.onResume.decision ?? 'Block release') == 'Approve these breaking changes'`.

Tested on a copy of the flow with `pauseDuration` set to 10 s, otherwise identical, and a breaking release (4 breaking changes):
- before the fix (the flow on main): `FAILED` at `approved` with the error above, on Kestra 2.0.1 and 2.0.4;
- after: `FAILED` at `blocked`, alert "orders-api 9.9.9 blocked: 4 unapproved breaking change(s), for example GET /orders: the query request parameter limit became required", on both versions.

### 2. Webhook key read from a secret (follow-up from a review pass)

`key: openapi-gate-change-me` → `key: "{{ secret('OPENAPI_GATE_WEBHOOK_KEY') }}"`, so the webhook URL is not a guessable placeholder. The secret is listed under Secrets; the Quick start step that said "change the webhook key" now says to add the secret.

Tested: a webhook call with the secret's value returns HTTP 200 and the run (compatible release) succeeds; a call with the old `openapi-gate-change-me` key returns HTTP 404.

### 3. Nightly schedule shipped disabled (follow-up from a review pass)

`nightly_staging_check` now has `disabled: true`, because the default spec URLs are placeholders and the schedule would fail every weekday on a fresh import. Its description says to enable it once the URLs are yours. Tested: the flow API reports `nightly_staging_check` as disabled after import.

## Regression check

On Kestra 2.0.1 and 2.0.4, with `tufin/oasdiff`, a local spec server and a local Slack sink:
- the flow passes `POST /api/v1/flows/validate` (no constraints, warnings or deprecations);
- breaking release, approved with a note → `SUCCESS`, approval recorded, "breaking changes approved ("v2 path kept")";
- a later breaking change, blocked explicitly → `FAILED` at `blocked` with that change in the message.

Not changed: pinning the `tufin/oasdiff` image. The local image only reports a commit hash, not a release tag, so I left `latest` rather than guess a tag.
