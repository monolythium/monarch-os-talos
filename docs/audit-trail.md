# Operator Audit Trail

Monarch operator actions must leave a signed, hash-bound audit record before
they are treated as production actions. The local contract is versioned:

- schema id: `monarch-operator-audit-trail/v1`
- schema file: [`schemas/monarch-operator-audit-trail.schema.json`](../schemas/monarch-operator-audit-trail.schema.json)
- validator: [`scripts/validate-operator-audit-trail.sh`](../scripts/validate-operator-audit-trail.sh)
- signed payload id: `monarch-operator-audit-payload/v1`

Validate an audit record before publishing it or relying on it for release
promotion:

```bash
make validate-operator-audit-trail \
  OPERATOR_AUDIT_TRAIL=./operator-audit.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
  LOCAL_EVIDENCE_ROOT=./audit-bundle \
  VERIFY_LOCAL_FILES=true
```

The validator checks:

- action id, timestamp, reason, actor, chain, release digest, and subject;
- the intent summary, expected-state hash, and diff-vs-intent hash;
- at least one hash-bound evidence item;
- optional local evidence file hashes under `LOCAL_EVIDENCE_ROOT`;
- Desktop, Talos, on-chain, CI, or operator receipt metadata;
- Desktop operation receipts carrying `monarch-desktop-operation-receipt/v1`
  and a canonical audit payload hash;
- a canonical `monarch-operator-audit-payload/v1` hash signed by the approvals;
- two unique approvals for high-risk operator actions;
- two peer vouches for `freeze-admission` and `kill-switch-freeze` actions.

When a `receipt` evidence item declares
`schema_version: monarch-desktop-operation-receipt/v1` and local file checks are
enabled, the validator reads the Desktop receipt JSON, recomputes the canonical
Desktop audit hash, checks it against `auditPayloadHash`, and requires a
matching `receipts[]` entry with `source: desktop`, `audit_payload_schema`, and
`audit_payload_hash`. That gives OS audit bundles a direct hash link to the
approved Desktop operation result instead of only a loose file attachment.

The audit trail is a local, publishable contract. It does not execute the
operation and it does not replace the specific enrollment, TPM sealing,
key-share, incident-response, disaster-recovery, certificate-rotation, or
Desktop e2e validators. It binds those artifacts together with the operator's
reason, receipt set, and expected-state delta so reviewers can prove what was
intended, what was observed, and who approved the action.
