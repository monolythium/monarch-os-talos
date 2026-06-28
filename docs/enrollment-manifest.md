# Enrollment Manifest

`PROTOCORE_REQUIRE_ENROLLMENT=true` makes the `protocore` entrypoint fail closed
unless an enrollment manifest exists at
`/var/lib/protocore/enrollment/enrollment.json` and a release digest is provided.

The manifest contract is local and versioned:

- schema id: `monarch-protocore-enrollment/v1`
- schema file: [`schemas/protocore-enrollment-manifest.schema.json`](../schemas/protocore-enrollment-manifest.schema.json)
- validator: [`scripts/validate-enrollment-manifest.sh`](../scripts/validate-enrollment-manifest.sh)

Validate a manifest before placing it on a node:

```bash
make validate-enrollment-manifest \
  ENROLLMENT_MANIFEST=./enrollment.json \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420 \
  REQUIRE_RELEASE_DIGEST=true
```

Validate the referenced TPM/key evidence files from an offline bundle:

```bash
make validate-tpm-attestation-evidence \
  ENROLLMENT_MANIFEST=./enrollment.json \
  LOCAL_EVIDENCE_ROOT=./attestation-bundle \
  EXPECTED_CHAIN_PROFILE=testnet \
  EXPECTED_CHAIN_ID=69420
```

Operator-signing manifests must include:

- `node.role = "operator-signing"`
- `node.chain_profile` and `node.chain_id`
- `operator.address`
- `operator.position` (`active` or `standby`) and `operator.index` (`0`-`9`)
- `cluster.id`, `cluster.size = 10`, `cluster.threshold = 7`,
  `cluster.active_members = 7`, `cluster.standby_members = 3`, and
  `cluster.roster_epoch`
- `release.expected_digest`
- `attestation.tpm`, including TPM mode, PCR bank, PCR values for PCRs
  `0`, `2`, `4`, and `7`, quote/event-log file paths, quote/event-log
  SHA-256 hashes, a quote nonce, and the PCR policy digest used to seal the
  operator key
- `attestation.tpm.sealed_key_policy`, including `lythiumseal_operator_key`
  in `operator_key_refs`, the PCR policy digest, and the staged, TPM-sealed
  operator-key hash (`sealed_operator_key_sha256`)
- `attestation.tpm.quote_verification` for hardware TPM nodes, including the
  `tpm2_checkquote` tool binding, AK public key file, quote-signature file,
  PCR digest file, and SHA-256 hashes for those verifier inputs
- `secret_files.operator_consensus_key` (or `operator_identity_key`),
  `secret_files.lythiumseal_operator_key`, and
  `secret_files.tpm_sealed_operator_key`, all as file paths under
  `/var/lib/protocore`. Each operator holds its own ML-DSA-65 key.

The manifest must not carry inline mnemonics, private keys, passphrases, or key
material. Those values must be delivered as files under the node data partition
and referenced by path. Mainnet operator-signing manifests
must use `attestation.tpm.mode = "hardware-tpm2"`; `vtpm-testnet` is only for
testnet/cloud rehearsal. Mainnet operator-signing manifests must also include
`on_chain_registration` with the registry contract address, operator address,
cluster id, operator index, registration transaction hash, DAG round, quorum
certificate hash, `registration_method = "register"`, the node-registry
`register(bytes32,string,bytes32,uint32,uint32,bytes,bytes,bytes)` selector
`0xf4896df2`, registration calldata hash,
`attestation_embedded_in_registration = true`, and the exact release digest,
TPM quote hash, event-log hash, PCR policy hash, sealed operator-key hash,
and attestation payload hash submitted to the registry. The
local validator checks that the on-chain cluster/operator fields and
attestation evidence hashes match the rest of the manifest, recomputes the canonical
`monarch-protocore-operator-attestation-payload/v1` SHA-256 hash, and checks
that the transaction evidence is bound to the live mono-core registry call.

## On-chain enrollment runner

Use `make run-on-chain-enrollment` when a pre-registration manifest needs to be
submitted to the node registry and turned into a final enrollment manifest:

```bash
make run-on-chain-enrollment \
  ENROLLMENT_MANIFEST=./enrollment.pending.json \
  ENROLLMENT_ON_CHAIN_COMMAND='./ops/register-operator.sh' \
  ENROLLMENT_ON_CHAIN_OUTPUT_DIR=./enrollment-run \
  LOCAL_EVIDENCE_ROOT=./attestation-bundle \
  EXPECTED_CHAIN_PROFILE=mainnet \
  EXPECTED_CHAIN_ID=69420
```

The runner validates the input manifest with pending on-chain registration
allowed, then exports these variables to the external command:

- `MONARCH_ENROLLMENT_ROOT_DIR`
- `MONARCH_ENROLLMENT_INPUT_MANIFEST`
- `MONARCH_ENROLLMENT_OUTPUT_DIR`
- `MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST`
- `MONARCH_ENROLLMENT_EVIDENCE_ROOT`
- `MONARCH_ENROLLMENT_REGISTRY_CONTRACT`
- `MONARCH_ENROLLMENT_EXPECTED_CHAIN_PROFILE`
- `MONARCH_ENROLLMENT_EXPECTED_CHAIN_ID`

The external command must perform the real registry submission and write
`MONARCH_ENROLLMENT_ON_CHAIN_MANIFEST` with `on_chain_registration`. The runner
then requires that proof, recomputes the canonical attestation payload hash,
validates the transaction evidence, optionally validates local TPM evidence, and
writes `monarch-on-chain-enrollment-run/v1`. With the default
`ENROLLMENT_ON_CHAIN_STRICT=true`, the output path requires hardware TPM,
release digest evidence, on-chain registration proof, and local TPM evidence.
Set strict mode to `false` only for testnet rehearsals.

`make validate-tpm-attestation-evidence` resolves each `/var/lib/protocore/...`
path under `LOCAL_EVIDENCE_ROOT`, verifies that the quote, event log,
LythiumSeal operator key, and hardware quote verifier files hash to
the manifest values, and runs `tpm2_checkquote` for `hardware-tpm2` manifests by
default. Set `REQUIRE_TPM2_CHECKQUOTE=false` only for synthetic rehearsal
bundles that do not contain a real TPM quote signature. The sealed operator key
is each operator's own ML-DSA-65 key, sealed to the node TPM policy.

The extension entrypoint also supports a fail-closed runtime switch for
operator-signing nodes:

```yaml
- PROTOCORE_REQUIRE_TPM_BINDING=true
- PROTOCORE_TPM_QUOTE_FILE=/var/lib/protocore/attestation/quote.bin
- PROTOCORE_TPM_EVENT_LOG_FILE=/var/lib/protocore/attestation/eventlog.bin
- PROTOCORE_TPM_SEALED_OPERATOR_KEY_FILE=/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc
- PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE=/var/lib/protocore/operator/threshold/lythiumseal-operator-key.bin.enc
```

When enabled, startup requires enrollment, release digest evidence, TPM quote
evidence, and a staged, TPM-sealed LythiumSeal operator key. Final key
rotation and recovery flows are still tracked in the readiness docs.

For images that should mint the LythiumSeal operator key on first boot instead
of staging it in the enrollment bundle, provide the non-secret seal-seat
metadata:

```yaml
- PROTOCORE_GENERATE_LYTHIUMSEAL_OPERATOR_KEY=true
- PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX=1
- PROTOCORE_LYTHIUMSEAL_OPERATOR_EPOCH=0
```

`PROTOCORE_LYTHIUMSEAL_OPERATOR_INDEX` is 1-based and must match the
cluster seal-recipient slot. The generated key is sealed to the canonical
`PROTOCORE_LYTHIUMSEAL_OPERATOR_KEY_FILE` path and the emitted public
encapsulation key is also written to
`/var/lib/protocore/operator/threshold/lythiumseal-operator-key.ek`; that public
sidecar must be captured into the cluster/genesis roster material.

The QEMU release smoke path exercises the same file contract. When
`PROTOCORE_REQUIRE_ENROLLMENT=true`, `make smoke-qemu-config` writes a
QEMU-only `enrollment-bundle/` under `_out/smoke-qemu-config/`, stages it into
the generated Talos machine config, and `smoke-qemu` can be run with
`REQUIRE_ENROLLMENT_RUNTIME_PROOF=true` and
`REQUIRE_TPM_BINDING_RUNTIME_PROOF=true`. Those gates prove, through Talos API
reads from the booted node, that the manifest, release digest, TPM quote/event
log, and TPM-sealed LythiumSeal operator key are present before the release
artifact verifier accepts the smoke result.
