# Release Channels

Monarch OS release promotion is controlled by [`channel-policy.json`](../channel-policy.json).
The policy is intentionally machine-checkable: a release cannot be promoted by
copying files alone; its `*.release.json`, adjacent artifacts, smoke evidence,
signatures, and channel compatibility must satisfy the policy.

## Channels

| Channel | Current stage | Promotion status |
| --- | --- | --- |
| `dev` | Development | Enabled for signed or unsigned development artifacts, but still requires channel metadata, substrate proof, network policy, provisioning policy, clean sources, and concrete `protocore` provenance. |
| `testnet` | Operator preview | Enabled. Requires signed complete artifact set, configured QEMU smoke with machine-config apply, real `talosctl ext-protocore` service evidence, Protocore RPC evidence, enrollment runtime proof, TPM/LythiumSeal operator-key fixture proof, Desktop GUI/Tauri e2e evidence with two-party chat and sender membership proof, runtime substrate proof from `talosctl read`, kernel/rootfs baseline match, no SSH listener on TCP port 22, channel metadata, substrate proof, network policy, provisioning policy, audit-trail policy, clean sources, concrete `protocore` provenance, raw image, extension tarball, SBOMs, cosign signature verification, GitHub SLSA attestation verification, exported offline attestation bundles, and a signed/attested deterministic extension rebuild witness. The release workflow now extracts dm-verity root hashes from smoke evidence and pins them in metadata when the booted artifact exposes active/root-hash evidence; testnet still does not require active dm-verity until that evidence is stable. |
| `mainnet` | Blocked | Disabled until mainnet genesis/operator roster, enrollment and operator-key lifecycle, configured QEMU e2e, Desktop e2e, signed/attested full-release rebuild witness, metadata-pinned active dm-verity rootfs/root-hash attestation, and final operator incident runbooks are published. Mainnet policy sets `REQUIRE_RELEASE_REBUILD_WITNESS=true`, `RUN_REBUILD=true`, `REQUIRE_REBUILD_ALL=true`, and `REQUIRE_DM_VERITY_ACTIVE=true` before it can be enabled, so extracted smoke root hashes must be present in release metadata and match runtime proof. |

## Promotion Check

Run the policy check against a built release metadata file:

```bash
make check-channel-promotion \
  PROMOTION_METADATA=_out/monarch-os-talos-v1.13.0-amd64.release.json
```

The script reads the metadata channel, loads the matching policy, verifies
channel-specific invariants, then runs `scripts/verify-release-artifacts.sh` and
`scripts/verify-release-provenance.sh` with the verifier flags required by that
channel. Testnet and mainnet require Desktop GUI/Tauri evidence. Set
`DESKTOP_E2E_EVIDENCE` directly, or use `scripts/resolve-desktop-e2e-evidence.sh`
with `DESKTOP_E2E_RELEASE_TAG`, `DESKTOP_E2E_ARTIFACT_RUN_ID`, or
`DESKTOP_E2E_EVIDENCE_URL` to fetch `monarch-desktop-e2e-evidence/v1` from the
Monarch Desktop release workflow. Promotion then runs
`scripts/verify-desktop-e2e-evidence.sh` and binds Desktop readiness, Talos
identity, Protocore RPC state, release digest, operation receipt, and two-party
cluster-member chat back to this OS metadata digest. For testnet, the artifact verifier also requires
`smoke-qemu` enrollment proof that the booted node saw an operator-signing
manifest, release digest file, 7-of-10 cluster shape, TPM quote/event-log,
and TPM-sealed LythiumSeal operator key through Talos API, with
file hashes bound back to the enrollment manifest before accepting the same
run's Protocore RPC evidence. Hardware TPM enrollment bundles must also pass the local
`tpm2_checkquote` attestation verifier before production use. The provenance verifier also requires
`monarch-protocore-<arch>.rebuild-witness.json`, verifies its signature and
attestation, and downloads GitHub attestation bundles plus `trusted_root.jsonl`
under `_out/attestations/` so operators can repeat attestation verification
offline. Mainnet adds
`monarch-os-talos-<talos-version>-<arch>.rebuild-witness.json`, which records a
clean rebuild hash/size comparison for every artifact listed in release metadata
and must also be signed and attested.

To include Desktop e2e evidence in a testnet dry run:

```bash
make check-channel-promotion \
  PROMOTION_METADATA=_out/monarch-os-talos-v1.13.0-amd64.release.json \
  DESKTOP_E2E_EVIDENCE=../monarch-desktop/_out/monarch-desktop-e2e-evidence.json
```

To fetch the evidence from a Monarch Desktop release before promotion:

```bash
DESKTOP_E2E_RELEASE_TAG=v0.0.20 \
  make resolve-desktop-e2e \
    PROMOTION_METADATA=_out/monarch-os-talos-v1.13.0-amd64.release.json
```

For a local metadata-only dry run, either use a `dev` metadata file or still
provide Desktop e2e evidence for `testnet`:

```bash
make check-channel-promotion \
  PROMOTION_METADATA=_out/monarch-os-talos-v1.13.0-amd64-dev.release.json \
  RUN_ARTIFACT_VERIFIER=false \
  RUN_PROVENANCE_VERIFIER=false
```

Dry runs do not prove artifact signatures, smoke evidence, Desktop evidence, or
attestations. They are useful only while authoring metadata or policy changes.
