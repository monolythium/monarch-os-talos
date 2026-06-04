#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${ENROLLMENT_MANIFEST:-${1:-}}"
EXPECTED_CHAIN_PROFILE="${EXPECTED_CHAIN_PROFILE:-}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-}"
REQUIRE_RELEASE_DIGEST="${REQUIRE_RELEASE_DIGEST:-false}"
REQUIRE_ON_CHAIN_REGISTRATION="${REQUIRE_ON_CHAIN_REGISTRATION:-false}"
ALLOW_PENDING_ON_CHAIN_REGISTRATION="${ALLOW_PENDING_ON_CHAIN_REGISTRATION:-false}"
REQUIRE_HARDWARE_TPM="${REQUIRE_HARDWARE_TPM:-false}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "enrollment-manifest: $*" >&2
  exit 1
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

field() {
  local path="$1"
  jq -r "$path // \"\"" "$MANIFEST"
}

validate_file_ref() {
  local label="$1"
  local path="$2"
  local prefix="${3:-/var/lib/protocore/}"

  [[ -n "$path" ]] || fail "$label is required"
  [[ "$path" == "$prefix"* ]] || fail "$label must be under $prefix: $path"
  if [[ "$path" == *"@"* ]]; then
    fail "$label must be a file path, not an inline credential: $path"
  fi
  if grep -Eiq '<replace|replace-with|changeme|placeholder|example-secret' <<<"$path"; then
    fail "$label contains a placeholder path: $path"
  fi
}

validate_tx_hash() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 0x-prefixed 32-byte transaction hash"
}

validate_selector() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{8}$ ]] \
    || fail "$label must be a 0x-prefixed 4-byte function selector"
}

validate_hash32() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] \
    || fail "$label must be a 32-byte hex digest"
}

hash32_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  local expected_norm actual_norm

  expected_norm="$(tr '[:upper:]' '[:lower:]' <<<"${expected#0x}")"
  actual_norm="$(tr '[:upper:]' '[:lower:]' <<<"${actual#0x}")"
  [[ "$expected_norm" == "$actual_norm" ]] \
    || fail "$label mismatch: expected=$expected actual=$actual"
}

canonical_attestation_payload_hash() {
  jq -cS '
    def norm_hash: ascii_downcase | ltrimstr("0x");
    def pcr_values:
      .attestation.tpm.pcr_values
      | to_entries
      | map({key: .key, value: (.value | norm_hash)})
      | from_entries;
    def quote_verification:
      if (.attestation.tpm | has("quote_verification")) then
        {
          tool: .attestation.tpm.quote_verification.tool,
          ak_public_sha256: (.attestation.tpm.quote_verification.ak_public_sha256 | norm_hash),
          quote_signature_sha256: (.attestation.tpm.quote_verification.quote_signature_sha256 | norm_hash),
          pcr_digest_sha256: (.attestation.tpm.quote_verification.pcr_digest_sha256 | norm_hash)
        }
      else
        null
      end;
    {
      schema_version: "monarch-protocore-operator-attestation-payload/v1",
      chain: {
        profile: .node.chain_profile,
        chain_id: (.node.chain_id | tostring)
      },
      registry: {
        contract: .on_chain_registration.registry_contract,
        registration_method: .on_chain_registration.registration_method,
        registration_function_selector: .on_chain_registration.registration_function_selector,
        attestation_embedded_in_registration: .on_chain_registration.attestation_embedded_in_registration
      },
      operator: {
        address: .operator.address,
        index: .operator.index,
        position: .operator.position
      },
      cluster: {
        id: (.cluster.id | tostring),
        size: .cluster.size,
        threshold: .cluster.threshold,
        active_members: .cluster.active_members,
        standby_members: .cluster.standby_members,
        dkg_epoch: (.cluster.dkg_epoch | tostring)
      },
      endpoint_policy: (.endpoint_policy // {}),
      release: {
        expected_digest: (.release.expected_digest | norm_hash)
      },
      tpm: {
        mode: .attestation.tpm.mode,
        pcr_bank: .attestation.tpm.pcr_bank,
        pcr_values: pcr_values,
        quote_sha256: (.attestation.tpm.quote_sha256 | norm_hash),
        event_log_sha256: (.attestation.tpm.event_log_sha256 | norm_hash),
        quote_nonce: (.attestation.tpm.quote_nonce | norm_hash),
        sealed_key_policy: {
          pcrs: .attestation.tpm.sealed_key_policy.pcrs,
          key_share_refs: .attestation.tpm.sealed_key_policy.key_share_refs,
          policy_digest: (.attestation.tpm.sealed_key_policy.policy_digest | norm_hash),
          dkg_transcript_sha256: (.attestation.tpm.sealed_key_policy.dkg_transcript_sha256 | norm_hash),
          sealed_share_sha256: (.attestation.tpm.sealed_key_policy.sealed_share_sha256 | norm_hash)
        },
        quote_verification: quote_verification
      }
    }
  ' "$MANIFEST" | sha256sum | awk '{print $1}'
}

need jq

[[ -n "$MANIFEST" ]] || fail "ENROLLMENT_MANIFEST or first argument is required"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null || fail "manifest is not valid JSON"

schema="$(field '.schema_version')"
role="$(field '.node.role')"
chain_profile="$(field '.node.chain_profile')"
chain_id="$(field '.node.chain_id')"
release_digest="$(field '.release.expected_digest')"

[[ "$schema" == "monarch-protocore-enrollment/v1" ]] \
  || fail "unsupported schema_version: $schema"
case "$role" in
  full|archive|operator-signing|bridge) ;;
  *) fail "node.role must be full, archive, operator-signing, or bridge: $role" ;;
esac
[[ -n "$chain_profile" ]] || fail "node.chain_profile is required"
[[ "$chain_id" =~ ^[0-9]+$ ]] || fail "node.chain_id must be numeric: $chain_id"

if [[ -n "$EXPECTED_CHAIN_PROFILE" ]]; then
  [[ "$chain_profile" == "$EXPECTED_CHAIN_PROFILE" ]] \
    || fail "chain profile mismatch: expected=$EXPECTED_CHAIN_PROFILE actual=$chain_profile"
fi
if [[ -n "$EXPECTED_CHAIN_ID" ]]; then
  [[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] \
    || fail "chain id mismatch: expected=$EXPECTED_CHAIN_ID actual=$chain_id"
fi

if jq -e '
  .. | strings
  | select(test("(?i)(<replace|replace-with|changeme|placeholder|example-secret)"))
' "$MANIFEST" >/dev/null; then
  fail "manifest contains placeholder string values"
fi

if jq -e '
  paths(scalars) as $p
  | ($p | map(tostring) | join(".")) as $path
  | select(
      ($path | test("(?i)(mnemonic|private_key|passphrase|key_share|cluster_key_share|bls_share)"))
      and (($path | startswith("secret_files.")) | not)
      and (($path | startswith("attestation.tpm.sealed_key_policy.key_share_refs")) | not)
    )
' "$MANIFEST" >/dev/null; then
  fail "secret-like fields must be file references under secret_files"
fi

secret_count="$(jq -r '(.secret_files // {}) | length' "$MANIFEST")"

if [[ "$REQUIRE_RELEASE_DIGEST" == "true" || "$role" == "operator-signing" ]]; then
  [[ "$release_digest" =~ ^[0-9a-fA-F]{64}$ ]] \
    || fail "release.expected_digest must be a 64-character SHA-256 hex digest"
fi

if [[ "$role" == "operator-signing" ]]; then
  operator_address="$(field '.operator.address')"
  operator_position="$(field '.operator.position')"
  operator_index="$(field '.operator.index')"
  cluster_size="$(field '.cluster.size')"
  cluster_threshold="$(field '.cluster.threshold')"
  cluster_active="$(field '.cluster.active_members')"
  cluster_standby="$(field '.cluster.standby_members')"
  dkg_epoch="$(field '.cluster.dkg_epoch')"
  tpm_mode="$(field '.attestation.tpm.mode')"
  pcr_bank="$(field '.attestation.tpm.pcr_bank')"
  quote_file="$(field '.attestation.tpm.quote_file')"
  event_log_file="$(field '.attestation.tpm.event_log_file')"
  quote_sha256="$(field '.attestation.tpm.quote_sha256')"
  event_log_sha256="$(field '.attestation.tpm.event_log_sha256')"
  quote_nonce="$(field '.attestation.tpm.quote_nonce')"
  pcr_policy_hash="$(field '.attestation.tpm.sealed_key_policy.policy_digest')"
  dkg_transcript_sha256="$(field '.attestation.tpm.sealed_key_policy.dkg_transcript_sha256')"
  sealed_share_sha256="$(field '.attestation.tpm.sealed_key_policy.sealed_share_sha256')"
  quote_verification_present="$(jq -r '.attestation.tpm | has("quote_verification")' "$MANIFEST")"
  on_chain_present="$(jq -r 'has("on_chain_registration")' "$MANIFEST")"

  [[ "$operator_address" =~ ^(mono1[0-9a-z]+|0x[0-9a-fA-F]{40})$ ]] \
    || fail "operator.address must be mono1... or 0x-prefixed 20-byte hex"
  case "$operator_position" in
    active|standby) ;;
    *) fail "operator.position must be active or standby for operator-signing" ;;
  esac
  [[ "$operator_index" =~ ^[0-9]+$ && "$operator_index" -ge 0 && "$operator_index" -le 9 ]] \
    || fail "operator.index must be an integer from 0 to 9"
  [[ "$(field '.cluster.id')" =~ ^[0-9]+$ ]] || fail "cluster.id is required for operator-signing"
  [[ "$cluster_size" == "10" ]] || fail "cluster.size must be 10 for 7-of-10 clusters"
  [[ "$cluster_threshold" == "7" ]] || fail "cluster.threshold must be 7 for 7-of-10 clusters"
  [[ "$cluster_active" == "7" ]] || fail "cluster.active_members must be 7"
  [[ "$cluster_standby" == "3" ]] || fail "cluster.standby_members must be 3"
  [[ "$dkg_epoch" =~ ^[0-9]+$ ]] || fail "cluster.dkg_epoch is required and must be numeric"

  case "$tpm_mode" in
    hardware-tpm2|vtpm-testnet) ;;
    *) fail "attestation.tpm.mode must be hardware-tpm2 or vtpm-testnet" ;;
  esac
  if bool_true "$REQUIRE_HARDWARE_TPM" && [[ "$tpm_mode" != "hardware-tpm2" ]]; then
    fail "operator-signing manifests must use hardware-tpm2 when REQUIRE_HARDWARE_TPM=true"
  fi
  if [[ "$chain_profile" == "mainnet" && "$tpm_mode" != "hardware-tpm2" ]]; then
    fail "mainnet operator-signing manifests must use hardware-tpm2"
  fi
  case "$pcr_bank" in
    sha256|sha384) ;;
    *) fail "attestation.tpm.pcr_bank must be sha256 or sha384" ;;
  esac
  validate_file_ref "attestation.tpm.quote_file" "$quote_file" "/var/lib/protocore/attestation/"
  validate_file_ref "attestation.tpm.event_log_file" "$event_log_file" "/var/lib/protocore/attestation/"
  validate_hash32 "attestation.tpm.quote_sha256" "$quote_sha256"
  validate_hash32 "attestation.tpm.event_log_sha256" "$event_log_sha256"
  validate_hash32 "attestation.tpm.quote_nonce" "$quote_nonce"
  validate_hash32 "attestation.tpm.sealed_key_policy.policy_digest" "$pcr_policy_hash"
  validate_hash32 "attestation.tpm.sealed_key_policy.dkg_transcript_sha256" "$dkg_transcript_sha256"
  validate_hash32 "attestation.tpm.sealed_key_policy.sealed_share_sha256" "$sealed_share_sha256"

  for pcr in 0 2 4 7; do
    jq -e --arg pcr "$pcr" '
      (.attestation.tpm.pcr_values[$pcr] // "")
      | test("^[0-9a-fA-F]{64}([0-9a-fA-F]{32})?$")
    ' "$MANIFEST" >/dev/null \
      || fail "attestation.tpm.pcr_values.$pcr must be a sha256/sha384 hex PCR value"
    jq -e --argjson pcr "$pcr" '
      (.attestation.tpm.sealed_key_policy.pcrs // []) | index($pcr)
    ' "$MANIFEST" >/dev/null \
      || fail "attestation.tpm.sealed_key_policy.pcrs must include PCR $pcr"
  done
  jq -e '
    (.attestation.tpm.sealed_key_policy.key_share_refs // [])
    | index("lythiumseal_operator_key")
  ' "$MANIFEST" >/dev/null \
    || fail "attestation.tpm.sealed_key_policy.key_share_refs must include lythiumseal_operator_key"

  if [[ "$tpm_mode" == "hardware-tpm2" ]]; then
    [[ "$quote_verification_present" == "true" ]] \
      || fail "hardware-tpm2 manifests must include attestation.tpm.quote_verification"
    quote_tool="$(field '.attestation.tpm.quote_verification.tool')"
    ak_public_file="$(field '.attestation.tpm.quote_verification.ak_public_file')"
    quote_signature_file="$(field '.attestation.tpm.quote_verification.quote_signature_file')"
    pcr_digest_file="$(field '.attestation.tpm.quote_verification.pcr_digest_file')"
    ak_public_sha256="$(field '.attestation.tpm.quote_verification.ak_public_sha256')"
    quote_signature_sha256="$(field '.attestation.tpm.quote_verification.quote_signature_sha256')"
    pcr_digest_sha256="$(field '.attestation.tpm.quote_verification.pcr_digest_sha256')"

    [[ "$quote_tool" == "tpm2_checkquote" ]] \
      || fail "attestation.tpm.quote_verification.tool must be tpm2_checkquote for hardware-tpm2"
    validate_file_ref "attestation.tpm.quote_verification.ak_public_file" "$ak_public_file" "/var/lib/protocore/attestation/"
    validate_file_ref "attestation.tpm.quote_verification.quote_signature_file" "$quote_signature_file" "/var/lib/protocore/attestation/"
    validate_file_ref "attestation.tpm.quote_verification.pcr_digest_file" "$pcr_digest_file" "/var/lib/protocore/attestation/"
    validate_hash32 "attestation.tpm.quote_verification.ak_public_sha256" "$ak_public_sha256"
    validate_hash32 "attestation.tpm.quote_verification.quote_signature_sha256" "$quote_signature_sha256"
    validate_hash32 "attestation.tpm.quote_verification.pcr_digest_sha256" "$pcr_digest_sha256"
  elif [[ "$quote_verification_present" == "true" ]]; then
    fail "attestation.tpm.quote_verification is only allowed with hardware-tpm2"
  fi

  for key in operator_identity_key bls_share cluster_key_share dkg_transcript lythiumseal_operator_key tpm_sealed_bls_share; do
    path="$(jq -r --arg key "$key" '.secret_files[$key] // ""' "$MANIFEST")"
    validate_file_ref "secret_files.$key" "$path"
  done

  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    jq -e --arg ref "$ref" '.secret_files[$ref] // empty' "$MANIFEST" >/dev/null \
      || fail "attestation.tpm.sealed_key_policy.key_share_refs references missing secret_files.$ref"
  done < <(jq -r '.attestation.tpm.sealed_key_policy.key_share_refs[]?' "$MANIFEST")

  if [[ "$on_chain_present" == "true" ]]; then
    registration_contract="$(field '.on_chain_registration.registry_contract')"
    registration_operator="$(field '.on_chain_registration.operator_address')"
    registration_cluster="$(field '.on_chain_registration.cluster_id')"
    registration_index="$(field '.on_chain_registration.operator_index')"
    registration_tx="$(field '.on_chain_registration.registration_tx_hash')"
    dag_round="$(field '.on_chain_registration.dag_round')"
    quorum_hash="$(field '.on_chain_registration.quorum_certificate_hash')"
    registration_method="$(field '.on_chain_registration.registration_method')"
    registration_selector="$(field '.on_chain_registration.registration_function_selector')"
    registration_calldata_hash="$(field '.on_chain_registration.registration_calldata_hash')"
    attestation_embedded="$(field '.on_chain_registration.attestation_embedded_in_registration')"
    registration_release_digest="$(field '.on_chain_registration.release_expected_digest')"
    registration_quote_hash="$(field '.on_chain_registration.quote_sha256')"
    registration_event_log_hash="$(field '.on_chain_registration.event_log_sha256')"
    registration_pcr_policy_hash="$(field '.on_chain_registration.pcr_policy_hash')"
    registration_dkg_transcript_hash="$(field '.on_chain_registration.dkg_transcript_sha256')"
    registration_sealed_share_hash="$(field '.on_chain_registration.sealed_share_sha256')"
    registration_payload_hash="$(field '.on_chain_registration.attestation_payload_hash')"

    [[ "$registration_contract" =~ ^0x[0-9a-fA-F]{40}$ ]] \
      || fail "on_chain_registration.registry_contract must be a 0x-prefixed 20-byte address"
    [[ "$registration_operator" == "$operator_address" ]] \
      || fail "on_chain_registration.operator_address must match operator.address"
    [[ "$registration_cluster" == "$(field '.cluster.id')" ]] \
      || fail "on_chain_registration.cluster_id must match cluster.id"
    [[ "$registration_index" == "$operator_index" ]] \
      || fail "on_chain_registration.operator_index must match operator.index"
    validate_tx_hash "on_chain_registration.registration_tx_hash" "$registration_tx"
    [[ "$dag_round" =~ ^[0-9]+$ ]] \
      || fail "on_chain_registration.dag_round must be numeric"
    validate_hash32 "on_chain_registration.quorum_certificate_hash" "$quorum_hash"
    [[ "$registration_method" == "register" ]] \
      || fail "on_chain_registration.registration_method must be register"
    [[ "$registration_selector" == "0xf4896df2" || "$registration_selector" == "0xF4896DF2" ]] \
      || fail "on_chain_registration.registration_function_selector must be node-registry register(...) selector 0xf4896df2"
    validate_selector "on_chain_registration.registration_function_selector" "$registration_selector"
    validate_hash32 "on_chain_registration.registration_calldata_hash" "$registration_calldata_hash"
    [[ "$attestation_embedded" == "true" ]] \
      || fail "on_chain_registration.attestation_embedded_in_registration must be true"
    validate_hash32 "on_chain_registration.release_expected_digest" "$registration_release_digest"
    validate_hash32 "on_chain_registration.quote_sha256" "$registration_quote_hash"
    validate_hash32 "on_chain_registration.event_log_sha256" "$registration_event_log_hash"
    validate_hash32 "on_chain_registration.pcr_policy_hash" "$registration_pcr_policy_hash"
    validate_hash32 "on_chain_registration.dkg_transcript_sha256" "$registration_dkg_transcript_hash"
    validate_hash32 "on_chain_registration.sealed_share_sha256" "$registration_sealed_share_hash"
    validate_hash32 "on_chain_registration.attestation_payload_hash" "$registration_payload_hash"
    hash32_equals "on_chain_registration.release_expected_digest" "$release_digest" "$registration_release_digest"
    hash32_equals "on_chain_registration.quote_sha256" "$quote_sha256" "$registration_quote_hash"
    hash32_equals "on_chain_registration.event_log_sha256" "$event_log_sha256" "$registration_event_log_hash"
    hash32_equals "on_chain_registration.pcr_policy_hash" "$pcr_policy_hash" "$registration_pcr_policy_hash"
    hash32_equals "on_chain_registration.dkg_transcript_sha256" "$dkg_transcript_sha256" "$registration_dkg_transcript_hash"
    hash32_equals "on_chain_registration.sealed_share_sha256" "$sealed_share_sha256" "$registration_sealed_share_hash"
    hash32_equals "on_chain_registration.attestation_payload_hash" \
      "$(canonical_attestation_payload_hash)" \
      "$registration_payload_hash"
  elif bool_true "$REQUIRE_ON_CHAIN_REGISTRATION"; then
    fail "operator-signing manifests must include on_chain_registration when REQUIRE_ON_CHAIN_REGISTRATION=true"
  elif [[ "$chain_profile" == "mainnet" ]] && ! bool_true "$ALLOW_PENDING_ON_CHAIN_REGISTRATION"; then
    fail "mainnet operator-signing manifests must include on_chain_registration"
  fi
fi

if [[ "$role" == "operator-signing" && "$secret_count" == "0" ]]; then
  fail "operator-signing manifests must reference secret_files"
fi

while IFS=$'\t' read -r key path; do
  [[ -n "$key" ]] || continue
  validate_file_ref "secret_files.$key" "$path"
done < <(jq -r '.secret_files // {} | to_entries[]? | [.key, .value] | @tsv' "$MANIFEST")

rpc_listen="$(field '.endpoint_policy.rpc_listen')"
p2p_listen="$(field '.endpoint_policy.p2p_listen')"
if [[ -n "$rpc_listen" && ! "$rpc_listen" =~ ^[0-9A-Za-z_.:-]+:[0-9]+$ ]]; then
  fail "endpoint_policy.rpc_listen must be host:port: $rpc_listen"
fi
if [[ -n "$p2p_listen" && ! "$p2p_listen" =~ ^/ip[46]/.+/tcp/[0-9]+$ ]]; then
  fail "endpoint_policy.p2p_listen must be a tcp multiaddr: $p2p_listen"
fi

jq -n \
  --arg manifest "$(basename "$MANIFEST")" \
  --arg role "$role" \
  --arg chain_profile "$chain_profile" \
  --arg chain_id "$chain_id" \
  --argjson secret_file_count "$secret_count" \
  '{
    ok: true,
    manifest: $manifest,
    role: $role,
    chain: {profile: $chain_profile, chain_id: $chain_id},
    secret_file_count: $secret_file_count
  }'
