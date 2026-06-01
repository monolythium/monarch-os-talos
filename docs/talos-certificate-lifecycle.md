# Talos Certificate Lifecycle

Monarch Desktop controls Monarch OS through Talos API mTLS. A certificate
rotation must therefore be auditable before Desktop trusts a new `talosconfig`
for privileged actions.

The local rotation contract is versioned:

- schema id: `monarch-talos-certificate-rotation/v1`
- schema file: [`schemas/talos-certificate-rotation.schema.json`](../schemas/talos-certificate-rotation.schema.json)
- validator: [`scripts/validate-talos-certificate-rotation.sh`](../scripts/validate-talos-certificate-rotation.sh)
- signed payload id: `monarch-talos-certificate-rotation-payload/v1`

Validate a rotation bundle before distributing the next `talosconfig`:

```bash
make validate-talos-certificate-rotation \
  TALOS_CERTIFICATE_ROTATION=./talos-certificate-rotation.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
  REQUIRE_DESKTOP_EVIDENCE=true
```

The manifest binds:

- chain profile and chain id;
- rotation id, type, reason, runbook id, opened time, and approval threshold;
- node id, role, cluster id when relevant, current endpoint, and next endpoint;
- current and next Talos CA/client certificate SHA-256 fingerprints;
- current and next certificate expiry timestamps;
- current and next `talosconfig` file hashes and paths;
- optional post-rotation Desktop e2e evidence hash, next CA fingerprint, endpoint,
  CA pin state, and minimum certificate expiry horizon;
- ML-DSA-65 operator approvals over the canonical rotation payload hash.

The validator rejects rotations that do not actually change the required
identity material for their type, next certificates inside the minimum validity
window, duplicated or insufficient approvals, approval payload-hash mismatches,
Desktop evidence that does not bind the next CA/endpoint, and missing Desktop
evidence when `REQUIRE_DESKTOP_EVIDENCE=true`.

Rotation types:

| Type | Required change |
| --- | --- |
| `client-cert-renewal` | Client certificate fingerprint changes. |
| `ca-rotation` | Talos CA fingerprint changes. |
| `endpoint-change` | Talos endpoint changes. |
| `emergency-rekey` | Talos CA or client certificate fingerprint changes. |

This is a validation contract, not a Talos certificate issuer. Certificate
generation still happens through the approved Talos lifecycle, and Desktop must
still import/pin the resulting `talosconfig`, prove the CA pin matches, and keep
the CA/client certificates outside the release rotation window before privileged
operations are allowed.
