Follow-up to #1120 (`keycloak-realm-security-audit`). One file changed.

## Fixes

### 1. `.` and `..` are rejected as realm names (follow-up from a review pass, reproduced while testing)

The realm name comes from the webhook body and ends up in Admin API paths (`/admin/realms/<realm>/…`) and in the KV state key. The validation regex `^[A-Za-z0-9._-]{1,255}$` allowed `.` and `..`, which are path segments, not realm names. `validate_realm` now also rejects them: "Realm name '..' is not valid: use letters, digits, dot, dash and underscore only, and not '.' or '..'".

Tested on Kestra 2.0.1:
- the flow on main with realm `..` or `.` passed `validate_realm` and went on to `check_realm`, which sent the request;
- with the fix, both fail at `invalid_realm` before any request, and the alert names the task;
- `acme` still passes the validation.

### 2. Queued runs behind an approval are documented (follow-up from a review pass)

`concurrency` (limit 1, `QUEUE`) keeps a burst of webhook calls to one report, but with the 4-hour approval `Pause` it also means a second realm's audit waits until the first realm's approval is answered. "How to extend" now says so and suggests one flow copy per realm, or a shorter `pauseDuration`. Documentation only.

### 3. Webhook key read from a secret (follow-up from a review pass)

`key: keycloak-audit-change-me` → `key: "{{ secret('KEYCLOAK_AUDIT_WEBHOOK_KEY') }}"`. The literal key is removed from the trigger's curl example, and the secret is listed under Secrets. Tested: the secret's value returns HTTP 200 and starts a run (trigger `realm_changed`); the old placeholder returns HTTP 404.

## Validation

The flow passes `POST /api/v1/flows/validate` on Kestra 2.0.1 (no constraints, warnings or deprecations). The full Keycloak scenario matrix from #1120 was not rerun: the changes touch only the realm check, the webhook key and the docs.
