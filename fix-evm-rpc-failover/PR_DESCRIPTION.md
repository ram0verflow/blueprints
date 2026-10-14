Follow-up to #692 (`evm-rpc-failover`). One file changed.

## Fixes

### 1. A malformed answer from one provider no longer crashes the whole probe (follow-up from a review pass, reproduced while testing)

`call()` assumed every batch entry was an object with a `result`, and `head_probe` assumed hex strings. One provider answering HTTP 200 with a malformed body raised inside the thread pool. That killed the `probe` task, so the run failed with a Python traceback and the healthy providers were not compared or published. Reproduced on main by making one of three providers return each case through a fault-injecting proxy:

| Malformed answer from Backup | Flow on main | With this fix |
|---|---|---|
| `eth_blockNumber` with `"result": null` | `probe` crashes: `TypeError: int() can't convert non-string with explicit base` | Backup `error`: "malformed answer: no result for eth_blockNumber" |
| `eth_blockNumber` with neither `result` nor `error` | `KeyError: 'result'` | same message |
| `eth_chainId` = `"mainnet"` | `ValueError: invalid literal for int() with base 16: 'mainnet'` | "malformed answer: expected hex quantities, got 'mainnet'" |
| a batch entry that is a bare string | `AttributeError: 'str' object has no attribute 'get'` | "answer is not a JSON-RPC batch: [\"unexpected\", …]" |
| `eth_getBlockByNumber` = `null` (fork check) | `TypeError: 'NoneType' object is not subscriptable` | "malformed answer: no result for eth_getBlockByNumber" |

With the fix, each case marks only Backup as failing, the Slack change message says why ("Backup: error, malformed answer: … was ok"), and the run succeeds with Primary still active.

Changes in the probe script:
- `call()` checks that every batch entry is an object and that every requested id has a non-null `result`;
- quantities go through a small `quantity()` helper that only accepts `0x…` strings;
- the fork check treats a missing block hash as an error for that provider.

Also tested:
- **Failover:** Primary answering a non-hex `eth_chainId` for 2 checks (`fail_after: 2`) fails over to Backup ("FAILOVER: … switched from Primary to Backup (Primary: malformed answer: expected hex quantities, got 'mainnet' for 2 checks)").
- **All providers malformed:** the active provider is left unchanged and the run fails at `no_healthy_provider`, listing every provider's reason.

### 2. Every-minute schedule shipped disabled (follow-up from a review pass)

`every_minute` now has `disabled: true` and a description saying to enable it once the provider secrets are set. Before, a fresh import started failing every minute. Tested: after import the flow API reports `every_minute` as disabled.

### 3. Webhook key read from a secret (follow-up from a review pass)

`key: rpc-failover-change-me` → `key: "{{ secret('RPC_FAILOVER_WEBHOOK_KEY') }}"`, and the secret is listed under Secrets. Tested: the secret's value returns HTTP 200 and starts a check; the old placeholder returns HTTP 404.

## How it was tested

Kestra 2.0.1 (`kestra/kestra:v2.0.1`), three anvil chains (two with chain id 1, one with chain id 5) behind a fault-injecting JSON-RPC proxy per provider, and a local Slack sink. The flow passes `POST /api/v1/flows/validate` (no constraints, warnings or deprecations). The original flow from main ran first for the reproductions above.
