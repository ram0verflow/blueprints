Follow-up to #411 (`embedding-model-migration-check`). One file changed.

## Fixes

### 1. Exact model name match (follow-up from a review pass, reproduced while testing)

`check_models` looked for `"name":"<model>` as a substring of Ollama's model list, so `all-mini` was accepted when `all-minilm:latest` was installed. The run then failed halfway, at `index_candidate`, with `{"error":"model 'all-mini' not found"}`, after the current model's index had already been built. A model now matches only if its name is followed by `"` or `:`. That still accepts `all-minilm` for `all-minilm:latest`, and `all-minilm:latest` itself.

Tested (Ollama with `all-minilm` and `nomic-embed-text` installed, candidate `all-mini`):
- on main: `check_models` passed, then `FAILED` at `index_candidate`;
- with the fix: `FAILED` at `models_missing` in seconds, with "Install it with: ollama pull all-mini".

### 2. A webhook body can name the models (follow-up from a review pass)

The webhook is meant to be called from CI for a pull request that changes the model, but it always compared the input defaults. Now `{"current_model": "...", "candidate_model": "..."}` in the body overrides them; missing fields fall back to the defaults. The models are resolved once in flow `variables` and used everywhere, including the searches inside the `probe` Loop.

Tested: a webhook call with both models set to `all-minilm` ran end to end with "all-minilm -> all-minilm passed: average top-5 overlap 1.0, top-1 agreement 1.0". The default pair (`all-minilm` → `nomic-embed-text`) gives 0.54 on the same corpus, so the Loop's searches used the models from the body, not the defaults.

### 3. Runs are queued (follow-up from a review pass)

Both indexes use fixed KV names (`<flow id>-current`, `<flow id>-candidate`) and each run drops and rebuilds them, so two overlapping runs could overwrite each other's index mid-comparison. The flow now has `concurrency: {limit: 1, behavior: QUEUE}`. I chose this over per-execution KV names, which would leave an index behind in the KV store for every run. Tested: a manual run started while a webhook run was indexing stayed `QUEUED`, then ran on its own and reported its own result (blocked at 0.54).

### 4. The failure alert no longer assumes an error log exists (follow-up from a review pass)

`errorLogs()[0]` was read without checking the list, so a failure that logs no error would break the alert itself. The alert now names the task and message when there is one, and says "no error message was logged, see the execution logs" otherwise. Tested: the alert still names the task and message for a real failure (`models_missing` above). The empty-log case was not reproduced.

### 5. Webhook key read from a secret (follow-up from a review pass)

`key: embedding-migration-check` → `key: "{{ secret('EMBEDDING_CHECK_WEBHOOK_KEY') }}"`, listed under Secrets, and the Quick start shows the CI call with the models in the body. Tested: the secret's value returns HTTP 200; the old key returns HTTP 404.

## How it was tested

Kestra 2.0.1 (`kestra/kestra:v2.0.1`) with Ollama (`all-minilm`, `nomic-embed-text`), the Kestra README as the corpus served locally, and a local Slack sink. The flow passes `POST /api/v1/flows/validate`. The default comparison still blocks with the same report: "average top-5 overlap 0.54 is below 0.6 (top-1 agreement 0.5)".
