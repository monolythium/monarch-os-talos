# Incident Response

Incident handling is a typed, signed, evidence-bearing workflow. The contract is
versioned:

- schema id: `monarch-incident-response/v1`
- schema file: [`schemas/monarch-incident-response.schema.json`](../schemas/monarch-incident-response.schema.json)
- validator: [`scripts/validate-incident-response.sh`](../scripts/validate-incident-response.sh)

Validate an incident bundle before publishing or acting on it:

```bash
make validate-incident-response \
  INCIDENT_RESPONSE=./incident-response.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

Every incident bundle must include:

- incident id, type, severity, status, timestamp, and summary;
- chain profile and chain id;
- a scoped response action with operator instructions;
- a signed runbook reference, schema hash, payload hash, and Foundation or
  authorized runbook signature;
- release metadata digest and at least one evidence file hash.

The emergency freeze mechanism is intentionally narrow. `freeze-admission` is
valid only for `cryptographic-break` and `adversarial-fork` incidents and must
use global scope. Bridge incidents use `pause-bridge-route` or `rollback-bridge`
with bridge-route scope. The validator rejects emergency-mechanism misuse for
routine upgrades, parameter changes, protocol-direction decisions, account
censorship, asset confiscation, and ongoing supervision.

Mainnet emergency actions require Foundation authorization and on-chain action
evidence. The bundle must include the published signer-set hash, threshold,
ratification deadline, threshold signatures, transaction hash, DAG round, quorum
certificate hash, executor contract address, action-specific executor method,
function selector, and calldata hash. The validator requires the canonical
executor binding for each action:

| Action | Contract | Method | Selector |
| --- | --- | --- | --- |
| `freeze-admission` | `0x0000000000000000000000000000000000001005` | `freezeAdmission` | `0x7a2605cd` |
| `emergency-key-rotation` | `0x0000000000000000000000000000000000001005` | `emergencyKeyRotation` | `0x0aeeafbf` |
| `pause-bridge-route` | `0x0000000000000000000000000000000000001008` | `pauseBridgeRoute` | `0x11a2dc64` |
| `rollback-bridge` | `0x0000000000000000000000000000000000001008` | `rollbackBridge` | `0x059a1b5c` |

Testnet rehearsals can force the same checks with:

```bash
REQUIRE_FOUNDATION_AUTHORIZATION=true \
REQUIRE_ON_CHAIN_ACTION=true \
make validate-incident-response INCIDENT_RESPONSE=./incident-response.json
```

This validator does not execute the freeze, bridge pause, rollback, or emergency
key rotation. It makes the action and exact executor call reviewable before
execution and makes the post-incident record machine-checkable after execution.
