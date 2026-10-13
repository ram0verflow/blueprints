## What

New blueprint `postgres-grant-drift-reconciler`. PostgreSQL privileges drift: a migration forgets a grant, someone runs a manual `GRANT` during an incident and never removes it, or a role ends up `SUPERUSER`. This flow compares the live catalog with a YAML spec and acts on the difference:
- applies missing table, sequence and default privileges, and missing memberships, in one transaction;
- shows extra privileges to an approver as a multi-select of their labels, and revokes only the chosen ones, after reading the catalog again;
- reports roles that are SUPERUSER or BYPASSRLS without approval, and roles the spec forbids;
- sends each change to Slack once.

## Flow

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-grant-drift-reconciler/topology.png" alt="Topology of the flow in the Kestra UI" width="300">

1. `after_migration` (`Webhook`, run after a migration) or `hourly_drift_check` (`Schedule`, shipped disabled)
2. `parse_spec` (`Script`, Python with PyYAML for the YAML only) and `spec_guard` (`If`): invalid YAML or unknown keys fail before any database call
3. `check_server` (retries) and `check_objects` (every role and schema in the spec must exist), with `objects_guard` (`If`)
4. `diff` reads `aclexplode(relacl)`, `pg_default_acl`, `pg_auth_members` and `pg_roles`, and classifies each difference as `apply`, `approve` or `report`
5. `state_check` decides what is new since the last run (fingerprints in the KV store); `apply_gate` → `apply_missing` (`Queries`, one transaction) → `notify_applied`
6. `report_gate` → `notify_report`; `approval_gate` → `ask_on_call` → `wait_for_decision` (`Pause`, 2 h, `MULTISELECT` whose choices are an `expression` built by `diff`) → `reread` → `revoke_gate` → `revoke_extras` (`Loop` with a `Sequential` per revoke, `allowFailure`)
7. `recheck` reads the catalog again, `state_after` and two `kv.Set` tasks store the new state, `notify_outcome` reports revoked, already gone and still present, and `partial_gate` ends the run `WARNING` if an approved revoke did not happen

The approval form (the choices are the labels in the Slack message):

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-grant-drift-reconciler/resume-dialog.png" alt="Resume dialog with a multi-select showing the extra as a label" width="420">

## Error handling

- **Invalid input fails before the database.** Bad YAML, unknown keys, unknown privilege names, and roles or schemas used in a grant without being listed fail at `spec_guard`. Roles and schemas that do not exist fail at `objects_guard`. The flow never creates roles.
- **Missing grants are atomic.** All `GRANT`, `ALTER DEFAULT PRIVILEGES` and `GRANT role TO role` statements run in one `Queries` transaction. A permission error in one of them rolls back all of them (scenario 11).
- **Revokes are isolated.** Each `REVOKE` runs in its own `Sequential` with `allowFailure`. A revoke that does not stick is reported as "Still present", and the run ends `WARNING`.
- **Approval never acts on stale data.** The chosen labels are checked against a fresh read after the approval. An extra someone removed while the approval waited is reported as "Already gone", not touched (scenario 5). Kestra also rejects any answer that was not offered.
- **Quoted names.** Every identifier in a generated statement is quoted by PostgreSQL with `format('%I')`. No name is concatenated.
- **Alert once per change.** The report and the extras are fingerprinted. A declined set is not offered again until it changes (scenario 4). An unchanged report is silent (scenario 6).
- **Failures name the task.** The `errors` alert names the failing task and its error.

## Why it is different

The nearest blueprint is `postgres-role-privilege-hygiene-guard`. It audits roles for expired logins, unexpected superusers and CREATEROLE, PUBLIC grants, and it can run generated `REVOKE`/`ALTER ROLE` fixes. It has no desired state to compare with, so it cannot tell a grant that was wanted from one that was not, and it never adds a missing grant. This blueprint is the other half: a spec file (or input) is the source of truth, missing grants are applied, and extras go through an approval. No open PR adds a Postgres grant reconciler (checked 2026-10-13).

## Hacktober requirements

- **3+ runnable tasks:** `check_server`, `check_objects`, `diff`, `state_check`, `apply_missing`, `reread`, `revoke`, `recheck`, notifications
- **Flowable tasks:** `Pause` (multi-select), `Loop`, `Sequential` (`allowFailure`), `If` gates (`spec_guard`, `objects_guard`, `apply_gate`, `report_gate`, `approval_gate`, `revoke_gate`, `partial_gate`, `outcome_gate`)
- **Triggers:** `Webhook` (event-based, after a migration) and `Schedule` (shipped disabled)
- **Non-core plugins:** `plugin-jdbc-postgres`, `plugin-slack`, `plugin-script-python`

## Testing

Tested on `kestra/kestra:v2.0.1` and `kestra/kestra:latest` (2.0.5), against PostgreSQL 16. The flow runs as a non-superuser role (`flow_admin`, member of the owning role `app_migrator`). Services were real: a Postgres container, the Kestra container, PyYAML installed by the task, and a local HTTP sink for Slack. Nothing was mocked. All 12 scenarios ran on the final revision on both versions, with the same results:

| Case / Step | Result |
|---|---|
| 1. In sync (defaults) | ✅ SUCCESS, no Slack message, no pause, `findings: []` |
| 2. Two grants and one default privilege removed by hand | ✅ SUCCESS; one message "applied 3 missing grant(s) in one transaction"; grants restored in the catalog; the next run is silent |
| 3. Manual `GRANT DELETE` on a table and a manual membership, both chosen | ✅ Paused; both offered by label; DELETE revoked; the membership was granted by the superuser and could not be revoked by this role, so it is reported "Still present, not revoked" and the run ends WARNING |
| 4. Declined (empty answer) | ✅ Nothing revoked; the next run neither pauses nor messages |
| 5. Extra removed by someone during the approval | ✅ SUCCESS; "Already gone before the revoke: app_reader DELETE on table app.orders" |
| 6. Unexpected `SUPERUSER` and `BYPASSRLS` roles | ✅ One message: "rogue_admin is SUPERUSER", "svc_bypass is BYPASSRLS"; nothing changed; the repeat run is silent |
| 7. Mixed-case role and schema, a space in a table name, a `;` in a table name | ✅ Two `SELECT` grants applied in one transaction (quoted labels); the extra `UPDATE` revoked after approval, chosen by its quoted label |
| 8. Invalid YAML | ✅ FAILED at `invalid_spec`; no database task ran; alert: "failed in execution … at `invalid_spec`: desired_grants is not valid YAML" |
| 9. Database stopped | ✅ FAILED; `check_server` failed 3 attempts (connection timeouts); alert names `check_server`; `diff` did not run |
| 10. Webhook after a migration | ✅ Started by trigger `after_migration`; missing grant restored; one message |
| 11. One grant fails (table owned by another role) | ✅ `apply_missing` FAILED with "permission denied for table z_foreign"; the earlier grant on `a_orders` was rolled back (0 grants added) |
| 12. Extra default privilege for new tables, approved | ✅ Removed; a table created afterwards gets no DELETE for the role |

Not tested: the 2-hour approval timeout (it takes the same path as an empty answer), PostgreSQL versions other than 16, and views and functions, which the flow does not manage.

<img src="https://raw.githubusercontent.com/ram0verflow/blueprints/pr-assets/postgres-grant-drift-reconciler/run-gantt.png" alt="Gantt view of a run that paused for approval, revoked one extra and finished" width="800">

## Notes

- **Python only for YAML.** PyYAML is installed by the task on first run, so the worker needs network access to PyPI. Pebble has no YAML filter.
- **Least privilege.** Run as a non-superuser role that owns or is a member of the owning roles. A role cannot grant what it does not own or hold with grant option. The revoke of a membership fails if a different role granted it.
- **Concurrency.** `concurrency: QUEUE` with limit 1, so a run waits while another is paused for approval (up to 2 hours).
- Only the spec's listed schemas and grantees are managed. Anything else in the database is out of scope, including PUBLIC grants and views.
- Tags: `Data, Infrastructure`; the tag validator passes on this branch.
