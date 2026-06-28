#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_PATH="${DESKTOP_E2E_EVIDENCE:-${1:-}}"
METADATA_PATH="${RELEASE_METADATA:-${PROMOTION_METADATA:-${2:-}}}"
MIN_TALOS_CERT_DAYS="${MIN_TALOS_CERT_DAYS:-14}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "desktop e2e evidence verification failed: $*" >&2
  exit 1
}

check_jq() {
  local message="$1"
  shift
  jq -e "$@" "$EVIDENCE_PATH" >/dev/null || fail "$message"
}

need jq

[[ -n "$EVIDENCE_PATH" ]] || fail "DESKTOP_E2E_EVIDENCE or first argument is required"
[[ -n "$METADATA_PATH" ]] || fail "RELEASE_METADATA/PROMOTION_METADATA or second argument is required"
[[ -f "$EVIDENCE_PATH" ]] || fail "evidence file not found: $EVIDENCE_PATH"
[[ -f "$METADATA_PATH" ]] || fail "release metadata not found: $METADATA_PATH"

jq -e . "$EVIDENCE_PATH" >/dev/null || fail "evidence file is not valid JSON"
jq -e . "$METADATA_PATH" >/dev/null || fail "release metadata is not valid JSON"

metadata_schema="$(jq -r '.schema_version // ""' "$METADATA_PATH")"
[[ "$metadata_schema" == "monarch-os-release-metadata/v1" ]] \
  || fail "release metadata schema unsupported: $metadata_schema"

metadata_base="$(basename "$METADATA_PATH")"
metadata_digest="$(jq -r '.sources.protocore_binary.sha256 // ""' "$METADATA_PATH" | tr '[:upper:]' '[:lower:]')"
metadata_chain_id="$(jq -r '.channel.chain.chain_id // ""' "$METADATA_PATH")"
metadata_raw_image="$(jq -r '.artifacts[]?.path | select(endswith(".raw.xz"))' "$METADATA_PATH" | head -n 1)"
metadata_raw_image="${metadata_raw_image%.xz}"

[[ "$metadata_digest" =~ ^[0-9a-f]{64}$ ]] \
  || fail "release metadata lacks concrete protocore digest"
[[ "$metadata_chain_id" =~ ^[0-9]+$ ]] \
  || fail "release metadata lacks numeric chain id"

check_jq "unsupported Desktop e2e evidence schema" \
  '.schema_version == "monarch-desktop-e2e-evidence/v1"'
check_jq "Desktop e2e evidence source is not Tauri GUI evidence" \
  '.source.kind == "tauri-gui-e2e"'
check_jq "Desktop e2e evidence generated_at is not an ISO UTC timestamp" \
  '(.source.generated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))'
check_jq "Desktop e2e evidence did not observe two Tauri windows" \
  '(.source.windows_observed // 0) >= 2'
check_jq "Desktop e2e evidence lacks required GUI routes" \
  '["/home", "/hardware", "/operations", "/chat"] as $required
   | (.source.routes_visited // []) as $visited
   | all($required[]; . as $route | $visited | index($route))'
check_jq "Desktop e2e evidence lacks required Tauri commands" \
  '[
     "talos_config_info",
     "talos_protocore_readiness",
     "talos_service_action:restart",
     "chat_initialize",
     "chat_subscribe_channel",
     "chat_send_message"
   ] as $required
   | (.source.commands_observed // []) as $observed
   | all($required[]; . as $cmd | $observed | index($cmd))'

check_jq "Desktop e2e OS smoke proof does not match release metadata" \
  --arg metadata "$metadata_base" \
  --arg digest "$metadata_digest" \
  --arg raw_image "$metadata_raw_image" \
  'def normdigest:
     if type == "string" then ascii_downcase | sub("^sha256:"; "") | sub("^0x"; "")
     else "" end;
   .os_smoke.status == "ok"
   and (.os_smoke.release_metadata == $metadata)
   and (($raw_image == "") or (.os_smoke.raw_image == $raw_image))
   and ((.os_smoke.expected_protocore_digest | normdigest) == $digest)
   and (.os_smoke.talos_api_probe == "talosctl_ok" or .os_smoke.talos_api_probe == "talosctl_secure_ok")
   and (.os_smoke.machine_config_applied == true or .os_smoke.machine_config_applied == "true")
   and .os_smoke.extension_service_name == "ext-protocore"
   and .os_smoke.extension_service_check == "ok"
   and .os_smoke.protocore_rpc_probe == "ok"
   and .os_smoke.substrate_runtime_proof == "ok"'

check_jq "Desktop Talos identity evidence is incomplete or inside rotation window" \
  --argjson min_days "$MIN_TALOS_CERT_DAYS" \
  'def trim_endpoint: if type == "string" then sub("/+$"; "") else "" end;
   .desktop_readiness.talosConfig as $config
   | .desktop_readiness.talosStatus as $status
   | ($config.caPinStatus == "matched")
   and (($config.certificates // []) | length > 0)
   and all($config.certificates[]; (.expired != true)
       and (.notYetValid != true)
       and (.expiresInDays | type == "number" and . >= $min_days))
   and (($config.endpoint | trim_endpoint) as $endpoint
       | ([($config.endpoints // [])[], ($config.nodes // [])[]] | map(trim_endpoint) | index($endpoint)) != null)
   and ($status.reachable == true)
   and ((($status.endpoint // "") | trim_endpoint) == "" or (($status.endpoint // "") | trim_endpoint) == ($config.endpoint | trim_endpoint))'

check_jq "Desktop Protocore readiness does not match release channel" \
  --arg chain_id "$metadata_chain_id" \
  '.desktop_readiness.protocore as $p
   | ($p.service.id == "ext-protocore")
   and ($p.service.severity == "ok")
   and ($p.displayState == "serving-rpc")
   and ($p.severity == "ok")
   and (($p.chainId | tostring) == $chain_id)
   and ($p.blockNumber | type == "number" and . >= 0)
   and ($p.clientVersion | type == "string" and length > 0)
   and ($p.listening == true)
   and ($p.syncing == false)'

check_jq "Desktop release attestation is not bound to OS metadata digest" \
  --arg digest "$metadata_digest" \
  'def normdigest:
     if type == "string" then ascii_downcase | sub("^sha256:"; "") | sub("^0x"; "")
     else "" end;
   .desktop_readiness.releaseAttestation as $a
   | ($a.className | type == "string" and contains("halo--ok"))
   and ($a.text | type == "string" and test("matched"; "i"))
   and (($a.expectedDigest | normdigest) == $digest)
   and (($a.liveDigest | normdigest) == $digest)'

check_jq "Desktop operation evidence lacks a successful Talos restart receipt" \
  'any(.desktop_readiness.operationReceipts[]?;
     .kind == "operator-restart"
     and .status == "ok"
     and .transport == "talos"
     and .service == "ext-protocore"
     and .action == "restart"
     and (.endpoint | type == "string" and length > 0)
     and (.nodeAddress | type == "string" and length > 0)
     and .auditPayloadSchema == "monarch-desktop-operation-receipt/v1"
     and ((.auditPayloadHash // "") | if type == "string" then ascii_downcase | test("^[0-9a-f]{64}$") else false end))'

check_jq "Desktop chat evidence is not a verified two-identity exchange" \
  'def clean_hex: ascii_downcase | sub("^0x"; "");
   def hex_bytes($n): type == "string" and (clean_hex | test("^[0-9a-f]{" + (($n * 2) | tostring) + "}$"));
   def hex_any: type == "string" and (clean_hex | test("^[0-9a-f]+$")) and ((clean_hex | length) % 2 == 0);
   def address: type == "string" and (clean_hex | test("^[0-9a-f]{40}$"));
   def iso_utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$");
   def sender_membership($cluster_id; $senders):
     .source == "lyth_clusterStatus+lyth_operatorInfo"
     and .clusterId == $cluster_id
     and (.checkedAt | iso_utc)
     and (.membersChecked | type == "number" and . >= ($senders | length))
     and ((.proofs // []) as $proofs
       | all($senders[]; . as $sender
           | any($proofs[]?;
               .source == "lyth_clusterStatus+lyth_operatorInfo"
               and .clusterId == $cluster_id
               and (.operatorId | hex_bytes(32))
               and ((.senderAddress | clean_hex) == $sender)
               and ((.chainAddressHex | clean_hex) == $sender))));
   .desktop_readiness.chat as $chat
   | ($chat.activeChannelId // "") as $active
   | ($chat.channels // []) as $channels
   | ($chat.messages // []) as $messages
   | ([ $channels[]
        | select(.channel_id == $active
            and .subscribed == true
            and .kind == "cluster"
            and .channel_id == ("cluster-" + (.cluster_id | tostring))) ] | first) as $active_channel
   | (($chat.init.address_hex | address) and ($chat.init.public_key_hex | hex_any))
   and (($chat.bootstrapPeers // []) | length > 0)
   and ($active_channel != null)
   and all($messages[];
       .channel_id == $active
       and .verified == true
       and (.msg_id | hex_bytes(32))
       and (.signature_hex | hex_any)
       and (.sender_address | address)
       and (.timestamp_ms | type == "number"))
   and ([ $messages[] | select(.from_me == true) | .sender_address | clean_hex ] | unique) as $own
   | ([ $messages[] | select(.from_me == false) | .sender_address | clean_hex ] | unique) as $peer
   | ([ $messages[] | .sender_address | clean_hex ] | unique) as $senders
   | ($messages | length >= 2)
   and ($own | length > 0)
   and ($peer | length > 0)
   and ($senders | length >= 2)
   and ((($own + $peer) | unique | length) == (($own | length) + ($peer | length)))
   and ($chat.membership | sender_membership($active_channel.cluster_id; $senders))'

jq -n \
  --arg evidence "$(basename "$EVIDENCE_PATH")" \
  --arg metadata "$metadata_base" \
  --arg digest "$metadata_digest" \
  '{
    ok: true,
    evidence: $evidence,
    release_metadata: $metadata,
    expected_protocore_digest: $digest
  }'
