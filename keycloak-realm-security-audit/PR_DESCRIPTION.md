## What

New blueprint `keycloak-realm-security-audit`. A Keycloak realm drifts. An administrator gets the role through a group and never sets up OTP. A contractor leaves and their account stays enabled. A service client keeps the secret it was given two years ago. And a redirect URI typed as `https://app.example.com*` also matches `https://app.example.com.attacker.example`, so authorization codes can be sent to an attacker's site.

On a webhook call after a realm change, or once a day, this flow:
- reads the realm through the Admin REST API with a dedicated service account (read-only roles for the audit);
- finds administrators without a second factor (roles held directly, through a group or through a composite role), stale accounts (from login events and sessions), confidential clients whose secret is too old or was never rotated, risky redirect URIs, and clients that allow the password grant;
- reports only what is new or resolved since the last run, using the KV store;
- asks on-call, with one checkbox per client or account, whether to rotate old client secrets or disable stale accounts. Each item is re-checked just before anything changes. The new secret is never posted anywhere.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/keycloak-realm-security-audit/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `realm_changed` (`Webhook`, event-based, the body may name the realm) or `daily_audit` (`Schedule`, disabled)
2. `validate_realm` (`If`): the realm name must be a plain identifier, because a webhook body can set it
3. `check_realm` (HTTP, retried) on the public realm endpoint; `realm_reachable` (`If` + `Switch`) tells "realm not found" apart from "Keycloak unhealthy"
4. `audit` (Python, standard library only): users, effective role mappings, credentials, login events, sessions and clients, compared with the previous findings in the KV store
5. `save_state` (KV) saves the findings before anyone is asked; `report` (`If`) sends new and resolved findings to Slack
6. `propose` (`If`) → `ask_on_call` → `wait_for_approval` (`Pause`, 4 h, a `MULTISELECT` whose choices are built from the findings at run time)
7. `rotate_secrets` / `disable_users` (`Loop`, each item in a `Sequential` with `allowFailure`); `notify_outcome` reports each result; `any_failed` (`If`) ends the run `WARNING` if one item failed

`concurrency: QUEUE`, plus saving the state before the approval, means a burst of webhook calls produces one report.

The approval form. Kestra rejects any value that was not offered:

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/keycloak-realm-security-audit/resume-dialog.png" alt="Resume dialog with one checkbox per client or account" width="420">

## Error handling

- **Secrets and tokens never reach Kestra's outputs.** The token exchange and the rotation run inside scripts that output only what they choose. An HTTP task would store the token response, and the rotation response with the new secret, in the execution outputs. The client list that Keycloak returns contains secrets; the flow keeps only names and dates. In testing, neither new secret appeared in Slack, the execution logs or the Kestra container's files.
- **Rotation is honest about downtime.** Without a secret-rotation client policy, the old secret stops working at once, and the report says so. With one, the report gives the time until which the old secret is still accepted.
- **Actions only touch what was shown.** A secret is rotated only if its creation time is still the one shown in the proposal. An account is disabled only if it is still enabled, has had no login event since the cutoff and has no session. Otherwise it reports "skipped, signed in since the proposal" or "skipped, its secret was already changed since the proposal".
- **No false "stale" verdicts.** If login events are off, expire before `stale_user_days`, or were turned on too recently to cover the window, the stale check is skipped and reported as an info finding. It does not flag every user.
- **The flow cannot lock itself out.** Its own client is reported but never proposed for rotation.
- **Each item is isolated.** A rotation that fails (for example because `manage-clients` was removed) is reported as "old-batch: NOT rotated, see the execution logs", the other items still run, and the run ends `WARNING`.
- **Clear failures.** Unreachable Keycloak (3 attempts), realm not found (with a hint about the `/auth` path), rejected credentials and missing roles each fail with the fix in the Slack alert, which names the task.
- **No alert storms.** A finding is reported when it appears and when it is resolved. Declined or unanswered proposals are asked again only after `ask_again_hours`.

## Why it is different

No blueprint in the catalog, and no flow in any open or closed PR as of 2026-10-12, mentions Keycloak, apart from an image name in an end-of-life list. The nearest are cloud IAM audits (`aws-iam-credential-hygiene-audit`, `gcp-iam-service-account-key-expiry-guard`), an Okta SAML app probe, an LDAP stale-account lockout and a quarterly access review. This one audits the identity provider itself: effective admin roles through groups and composites, second factors, OAuth redirect URIs and grants, and client secret age. It then fixes the safe cases with approval, keeping the new secrets out of Kestra's outputs and logs.

## Hacktober requirements

- **3+ runnable tasks:** `check_realm`, `audit`, `save_state`, `notify_changes`, `ask_on_call`, `approved`, `rotate_secret`, `disable_user`, `notify_outcome`, `alert_failure`
- **Flowable tasks:** `Pause` (dynamic `MULTISELECT`), `Loop` (×2), `Sequential` (×2), `Switch`, seven `If`s
- **Triggers:** `Webhook` (event-based) and `Schedule`
- **Non-core plugins:** `plugin-script-python`, `plugin-slack`

## Testing

Tested on `kestra/kestra:latest` (2.0.5 OSS) against Keycloak 26.4 (`quay.io/keycloak/keycloak:26.4`, `start-dev` on PostgreSQL 16, with the `client-secret-rotation` preview feature on), with Slack pointed at a local sink. A seed script built the realm `acme` through the admin API: admins holding their role directly, through a group, through a composite role and through `realm-management/realm-admin`; one admin with a real OTP credential; users created 2 to 400 days ago; real logins (password grant, with a TOTP code for the OTP user); and confidential, public, wildcard and password-grant clients. Keycloak's API cannot backdate everything, so the harness did these directly: account creation dates through the API, `client.secret.creation.time` through a client update, and one LOGIN event written 100 days back into Keycloak's database to give the realm 100 days of history.

The matrix is a script (12 scenarios, 36 assertions on Slack messages, Keycloak state and execution state). It was rerun in full on the final revision:

| Scenario | Result |
|---|---|
| First audit, defaults | ✅ "first audit, 12 findings (5 high, 6 medium, 1 low)"; bob "holds admin through a group or composite role"; carol "OTP setup is pending"; the OTP user and recently active users are not flagged; dave "last sign-in 2026-07-04"; 4 proposals |
| Approve all four while gina signs in | ✅ dave disabled; "gina: skipped, signed in since the proposal"; billing-api and reporting-job rotated. The old secret gets 401 and the new one gets 200. The new secret is not in Slack or the Kestra logs |
| Next two runs | ✅ "0 new, 4 resolved, 8 unchanged", no new question; then no message at all |
| Three webhook calls at once after adding a client | ✅ 3 runs SUCCESS, exactly one report: "NEW HIGH: client partner-sso redirect URI https://partner.example.com* has a wildcard in the host part" |
| Login events switched off, then on | ✅ "NEW INFO: login events are not saved, so stale accounts cannot be detected", then "RESOLVED" |
| Rotation under a secret-rotation client policy | ✅ "the old secret keeps working until 2026-10-14 11:09 UTC"; old and new secret both accepted |
| On-call approves nothing | ✅ "nothing approved, nothing was changed"; the next run asks nothing |
| `manage-clients` removed while the approval waits | ✅ "judy: disabled", "old-batch: NOT rotated, see the execution logs", run `WARNING` |
| Wrong client secret; `view-events` removed | ✅ Alerts: "at `audit`: Keycloak rejected client kestra-auditor in realm acme (HTTP 401: Invalid client or Invalid client credentials)" and "may not GET /events/config (HTTP 403): give it the realm-management roles …" |
| Webhook with an unknown realm; with `../master` | ✅ "at `realm_not_found`: Realm nope does not exist … may need the /auth path"; "at `invalid_realm`", no request sent |
| Keycloak stopped | ✅ `check_realm` fails after 3 attempts; "at `check_realm`: Connect to **** failed: Connection refused" |
| Keycloak back | ✅ Only the real change is reported: "0 new, 1 resolved"; the state survived the failed runs |

All 12 scenarios (36 checks) passed on the final revision.

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/keycloak-realm-security-audit/run-gantt.png" alt="Gantt view of a run that rotated two secrets and disabled an account" width="800">

## Notes

- Least privilege: the audit needs `view-users`, `view-clients` and `view-events` on `realm-management`; the actions add `manage-users` and `manage-clients`.
- The new secret stays in Keycloak; the client's owner copies it from the admin console. Pushing it to Vault or a cloud secret manager is listed under "How to extend".
- Not tested: the 4-hour approval timeout (the same `RESUME` path as an empty answer, which was tested), and realms with more than a few dozen users (each user costs two API calls; `max_users` caps it, 5000 by default).
- Connection settings are repeated per script task, because Kestra 2.0 has no flow-level `pluginDefaults`. The shared Keycloak client code lives once, in a flow variable passed through `inputFiles`.
- If **Validate Blueprint Tags** is red, it is because that check reads every file in `flows/`. This blueprint uses `Infrastructure, System`, and the validator finds no file in the current main with invalid tags.
