#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
readonly REPO_DIR
readonly FIXTURES="$TEST_DIR/fixtures"
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
readonly MACOS_SDK_PATH
[[ -d "$MACOS_SDK_PATH" ]]
choose_test_port() {
  local candidate
  for _ in {1..40}; do
    candidate="$((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 30000))"
    if ! lsof -nP -iTCP:"${candidate}" -sTCP:LISTEN 2>/dev/null | sed -n '2p' | grep -q .; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  printf 'ERROR: could not select a free loopback test port\n' >&2
  return 1
}
readonly TEST_PORT="${IMESSAGE_PROXY_TEST_PORT:-${IMESSAGE_TEST_PORT:-$(choose_test_port)}}"
TOKEN="$(openssl rand -hex 32)"
readonly TOKEN
temporary="$(mktemp -d /tmp/imessage-proxy-bridge-test.XXXXXX)"
server_pid=""

unset \
  IMESSAGE_ALLOWED_TARGETS_FILE \
  IMESSAGE_BRIDGE_PORT \
  IMESSAGE_BRIDGE_TOKEN_FILE \
  IMESSAGE_PROXY_ALLOWED_TARGETS_FILE \
  IMESSAGE_PROXY_BRIDGE_MAX_CONCURRENCY \
  IMESSAGE_PROXY_BRIDGE_PORT \
  IMESSAGE_PROXY_BRIDGE_SOCKET_TIMEOUT_SECONDS \
  IMESSAGE_PROXY_BRIDGE_TOKEN_FILE \
  IMESSAGE_PROXY_IMSG_BIN \
  IMESSAGE_PROXY_RPC_TIMEOUT_SECONDS \
  IMESSAGE_RPC_TIMEOUT_SECONDS \
  IMSG_BIN \
  STELLA_BRIDGE_MAX_CONCURRENCY \
  STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS

report_failure() {
  local exit_code="$1" line="$2"
  printf 'ERROR: integration test failed with exit %s at line %s\n' "$exit_code" "$line" >&2
  if [[ -s "$temporary/server.log" ]]; then
    printf '%s\n' 'Bridge log:' >&2
    sed -n '1,200p' "$temporary/server.log" >&2
  fi
  return "$exit_code"
}

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid"
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f \
    "$temporary/allowed-targets.txt" \
    "$temporary/allowed-targets.original" \
    "$temporary/body.json" \
    "$temporary/bridge" \
    "$temporary/server.log" \
    "$temporary/test-token.txt" \
    "$temporary/timeout-a.json" \
    "$temporary/timeout-b.json"
  rmdir "$temporary"
}
trap 'report_failure "$?" "$LINENO"' ERR
trap cleanup EXIT

xcrun clang \
  -isysroot "$MACOS_SDK_PATH" \
  -fobjc-arc \
  -O2 \
  -Wall \
  -Wextra \
  -framework Foundation \
  -o "$temporary/bridge" \
  "$REPO_DIR/src/imessage-proxy-bridge.m"

printf '%s\n' "$TOKEN" > "$temporary/test-token.txt"
chmod 600 "$temporary/test-token.txt"
install -m 0600 "$FIXTURES/allowed-targets.txt" "$temporary/allowed-targets.txt"
unicode_identifier="$(printf '😀%.0s' {1..256})"
readonly unicode_identifier
printf 'chat_identifier:%s\n' "$unicode_identifier" >> "$temporary/allowed-targets.txt"
install -m 0600 "$temporary/allowed-targets.txt" "$temporary/allowed-targets.original"

configuration_fingerprint() {
  IMESSAGE_PROXY_BRIDGE_PORT="$TEST_PORT" \
  IMESSAGE_PROXY_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
  IMESSAGE_PROXY_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
  IMESSAGE_PROXY_IMSG_BIN="$FIXTURES/fake-imsg.sh" \
  IMESSAGE_PROXY_RPC_TIMEOUT_SECONDS=2 \
  IMESSAGE_PROXY_BRIDGE_MAX_CONCURRENCY=2 \
  IMESSAGE_PROXY_BRIDGE_SOCKET_TIMEOUT_SECONDS=2 \
    "$temporary/bridge" config-fingerprint
}

expected_fingerprint="$(configuration_fingerprint)"
readonly expected_fingerprint
[[ "$expected_fingerprint" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$expected_fingerprint" != *"$TOKEN"* &&
  "$expected_fingerprint" != *'+15551234567'* ]]

printf '# exact-byte fingerprint regression\n' >> "$temporary/allowed-targets.txt"
changed_targets_fingerprint="$(configuration_fingerprint)"
[[ "$changed_targets_fingerprint" =~ ^sha256:[0-9a-f]{64}$ &&
  "$changed_targets_fingerprint" != "$expected_fingerprint" ]]
install -m 0600 "$temporary/allowed-targets.original" "$temporary/allowed-targets.txt"

printf '%064d\n' 0 > "$temporary/test-token.txt"
changed_token_fingerprint="$(configuration_fingerprint)"
[[ "$changed_token_fingerprint" =~ ^sha256:[0-9a-f]{64}$ &&
  "$changed_token_fingerprint" != "$expected_fingerprint" ]]

printf '%s' "$TOKEN" > "$temporary/test-token.txt"
changed_token_bytes_fingerprint="$(configuration_fingerprint)"
[[ "$changed_token_bytes_fingerprint" =~ ^sha256:[0-9a-f]{64}$ &&
  "$changed_token_bytes_fingerprint" != "$expected_fingerprint" ]]
printf '%s\n' "$TOKEN" > "$temporary/test-token.txt"
chmod 0600 "$temporary/test-token.txt"

IMESSAGE_PROXY_BRIDGE_PORT="$TEST_PORT" \
IMESSAGE_PROXY_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
IMESSAGE_PROXY_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
IMESSAGE_PROXY_IMSG_BIN="$FIXTURES/fake-imsg.sh" \
IMESSAGE_PROXY_RPC_TIMEOUT_SECONDS=2 \
IMESSAGE_PROXY_BRIDGE_MAX_CONCURRENCY=2 \
IMESSAGE_PROXY_BRIDGE_SOCKET_TIMEOUT_SECONDS=2 \
  "$temporary/bridge" serve > "$temporary/server.log" 2>&1 &
server_pid="$!"

for _ in {1..50}; do
  if curl --silent --output /dev/null "http://127.0.0.1:$TEST_PORT/healthz"; then
    break
  fi
  sleep 0.1
done
kill -0 "$server_pid" 2>/dev/null || {
  sed -n '1,120p' "$temporary/server.log" >&2
  exit 1
}

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' "http://127.0.0.1:$TEST_PORT/healthz")"
[[ "$status" == "401" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  "http://127.0.0.1:$TEST_PORT/_internal/configuration-fingerprint")"
[[ "$status" == "401" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --request POST \
  "http://127.0.0.1:$TEST_PORT/_internal/configuration-fingerprint")"
[[ "$status" == "404" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$TEST_PORT/_internal/configuration-fingerprint")"
[[ "$status" == "200" ]]
[[ "$(< "$temporary/body.json")" == \
  "{\"configurationFingerprint\":\"$expected_fingerprint\"}" ]]
if grep -Fq "$TOKEN" "$temporary/body.json" ||
  grep -Fq '+15551234567' "$temporary/body.json"; then
  printf 'ERROR: internal configuration fingerprint exposed configuration values\n' >&2
  exit 1
fi

# The server fingerprint represents its startup snapshot, not later file drift.
printf '# drift after bridge startup\n' >> "$temporary/allowed-targets.txt"
[[ "$(configuration_fingerprint)" != "$expected_fingerprint" ]]
status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$TEST_PORT/_internal/configuration-fingerprint")"
[[ "$status" == "200" ]]
[[ "$(< "$temporary/body.json")" == \
  "{\"configurationFingerprint\":\"$expected_fingerprint\"}" ]]
install -m 0600 "$temporary/allowed-targets.original" "$temporary/allowed-targets.txt"

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header "X-API-Client: test-client" \
  "http://127.0.0.1:$TEST_PORT/healthz")"
[[ "$status" == "200" ]]
grep -Fq '"status":"ok"' "$temporary/body.json"

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"read","method":"messages.after","params":{"since_rowid":0,"limit":20}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "200" ]]
grep -Fq '"id":"read"' "$temporary/body.json"
grep -Fq '"ok":true' "$temporary/body.json"

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":\"unicode-allowlist\",\"method\":\"send\",\"params\":{\"chat_identifier\":\"${unicode_identifier}\",\"text\":\"test\"}}" \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "200" ]]
grep -Fq '"ok":true' "$temporary/body.json"

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"send","method":"send","params":{"to":"+15551234567","text":"test"}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "200" ]]
grep -Fq '"ok":true' "$temporary/body.json"

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"send","method":"send","params":{"to":"+15550000000","text":"blocked"}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "403" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"smsId":"s0","recipient":"+15551234567","message":"SMS-style endpoint test","sendAt":-1}' \
  "http://127.0.0.1:$TEST_PORT/v2/sessions/sms")"
[[ "$status" == "204" ]]
[[ ! -s "$temporary/body.json" ]]

sms_message_at_limit="$(printf '😀%.0s' {1..460})"
status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data "{\"smsId\":\"unicode-limit\",\"recipient\":\"+15551234567\",\"message\":\"${sms_message_at_limit}\"}" \
  "http://127.0.0.1:$TEST_PORT/v2/sessions/sms")"
[[ "$status" == "204" ]]

sms_message_over_limit="${sms_message_at_limit}😀"
status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data "{\"smsId\":\"unicode-over-limit\",\"recipient\":\"+15551234567\",\"message\":\"${sms_message_over_limit}\"}" \
  "http://127.0.0.1:$TEST_PORT/v2/sessions/sms")"
[[ "$status" == "400" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"smsId":"s0","recipient":"+15550000000","message":"blocked"}' \
  "http://127.0.0.1:$TEST_PORT/v2/sessions/sms")"
[[ "$status" == "403" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"smsId":"s0","recipient":"+15551234567","message":"not scheduled","sendAt":1893456000}' \
  "http://127.0.0.1:$TEST_PORT/v2/sessions/sms")"
[[ "$status" == "400" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --data-binary '{"smsId":"s0","recipient":"+15551234567","message":"wrong content type"}' \
  --header 'Content-Type: text/plain' \
  "http://127.0.0.1:$TEST_PORT/v2/sessions/sms")"
[[ "$status" == "415" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/jsonp' \
  --data '{"jsonrpc":"2.0","id":"jsonp","method":"messages.after","params":{"since_rowid":0}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "415" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"bad","method":"watch.subscribe","params":{}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "403" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"reactions","method":"messages.after","params":{"since_rowid":0,"include_reactions":true}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "403" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"force-wrong-id","method":"messages.after","params":{"since_rowid":0}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "502" ]]

status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"oversize","method":"messages.after","params":{"since_rowid":0}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc")"
[[ "$status" == "502" ]]

curl --silent --output "$temporary/timeout-a.json" \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"timeout","method":"messages.after","params":{"since_rowid":0}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc" &
timeout_a_pid="$!"
curl --silent --output "$temporary/timeout-b.json" \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"timeout","method":"messages.after","params":{"since_rowid":0}}' \
  "http://127.0.0.1:$TEST_PORT/v1/rpc" &
timeout_b_pid="$!"
sleep 0.25
status="$(curl --silent --output "$temporary/body.json" --write-out '%{http_code}' \
  --header "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$TEST_PORT/healthz")"
[[ "$status" == "503" ]]
wait "$timeout_a_pid"
wait "$timeout_b_pid"

if IMESSAGE_PROXY_BRIDGE_PORT="$TEST_PORT" \
  IMESSAGE_PROXY_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
  IMESSAGE_PROXY_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
  IMESSAGE_PROXY_IMSG_BIN="$FIXTURES/fake-imsg.sh" \
  IMESSAGE_PROXY_RPC_TIMEOUT_SECONDS=30junk \
    "$temporary/bridge" check-config >/dev/null 2>&1; then
  printf 'ERROR: malformed RPC timeout was accepted\n' >&2
  exit 1
fi

chmod 0644 "$temporary/test-token.txt"
if IMESSAGE_PROXY_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
  IMESSAGE_PROXY_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
  IMESSAGE_PROXY_IMSG_BIN="$FIXTURES/fake-imsg.sh" \
    "$temporary/bridge" check-config >/dev/null 2>&1; then
  printf 'ERROR: insecure token permissions were accepted\n' >&2
  exit 1
fi
chmod 0600 "$temporary/test-token.txt"

# Every pre-rename bridge variable remains a supported alias for one
# transition release. A complete legacy-only configuration must still work.
IMESSAGE_BRIDGE_PORT="$TEST_PORT" \
IMESSAGE_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
IMESSAGE_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
IMSG_BIN="$FIXTURES/fake-imsg.sh" \
IMESSAGE_RPC_TIMEOUT_SECONDS=2 \
STELLA_BRIDGE_MAX_CONCURRENCY=2 \
STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS=2 \
  "$temporary/bridge" check-config >/dev/null

# Identical canonical and legacy definitions are unambiguous and accepted.
IMESSAGE_PROXY_BRIDGE_PORT="$TEST_PORT" \
IMESSAGE_BRIDGE_PORT="$TEST_PORT" \
IMESSAGE_PROXY_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
IMESSAGE_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
IMESSAGE_PROXY_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
IMESSAGE_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
IMESSAGE_PROXY_IMSG_BIN="$FIXTURES/fake-imsg.sh" \
IMSG_BIN="$FIXTURES/fake-imsg.sh" \
IMESSAGE_PROXY_RPC_TIMEOUT_SECONDS=2 \
IMESSAGE_RPC_TIMEOUT_SECONDS=2 \
IMESSAGE_PROXY_BRIDGE_MAX_CONCURRENCY=2 \
STELLA_BRIDGE_MAX_CONCURRENCY=2 \
IMESSAGE_PROXY_BRIDGE_SOCKET_TIMEOUT_SECONDS=2 \
STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS=2 \
  "$temporary/bridge" check-config >/dev/null

expect_alias_conflict() {
  local canonical_assignment="$1" legacy_assignment="$2"
  local canonical_name="${canonical_assignment%%=*}"
  local legacy_name="${legacy_assignment%%=*}"
  local output
  if output="$(
    env \
      IMESSAGE_PROXY_BRIDGE_PORT="$TEST_PORT" \
      IMESSAGE_PROXY_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
      IMESSAGE_PROXY_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
      IMESSAGE_PROXY_IMSG_BIN="$FIXTURES/fake-imsg.sh" \
      IMESSAGE_PROXY_RPC_TIMEOUT_SECONDS=2 \
      IMESSAGE_PROXY_BRIDGE_MAX_CONCURRENCY=2 \
      IMESSAGE_PROXY_BRIDGE_SOCKET_TIMEOUT_SECONDS=2 \
      "$canonical_assignment" \
      "$legacy_assignment" \
      "$temporary/bridge" check-config 2>&1
  )"; then
    printf 'ERROR: conflicting aliases were accepted: %s and %s\n' \
      "$canonical_name" "$legacy_name" >&2
    return 1
  fi
  [[ "$output" == \
    "ERROR: $canonical_name and $legacy_name disagree; unset one or make them identical" ]] || {
    printf 'ERROR: conflict output was not value-free for %s and %s\n' \
      "$canonical_name" "$legacy_name" >&2
    return 1
  }
}

expect_alias_conflict \
  'IMESSAGE_PROXY_ALLOWED_TARGETS_FILE=/canonical/allowed-targets' \
  'IMESSAGE_ALLOWED_TARGETS_FILE=/legacy/allowed-targets'
expect_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_PORT=8765' \
  'IMESSAGE_BRIDGE_PORT=8766'
expect_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_TOKEN_FILE=/canonical/token' \
  'IMESSAGE_BRIDGE_TOKEN_FILE=/legacy/token'
expect_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_TOKEN_FILE=' \
  'IMESSAGE_BRIDGE_TOKEN_FILE=/legacy/token'
expect_alias_conflict \
  'IMESSAGE_PROXY_RPC_TIMEOUT_SECONDS=2' \
  'IMESSAGE_RPC_TIMEOUT_SECONDS=3'
expect_alias_conflict \
  'IMESSAGE_PROXY_IMSG_BIN=/canonical/imsg' \
  'IMSG_BIN=/legacy/imsg'
expect_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_MAX_CONCURRENCY=2' \
  'STELLA_BRIDGE_MAX_CONCURRENCY=3'
expect_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_SOCKET_TIMEOUT_SECONDS=2' \
  'STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS=3'

if "$temporary/bridge" unknown-command >/dev/null 2>&1; then
  printf 'ERROR: unknown command returned success\n' >&2
  exit 1
fi

printf 'iMessage Proxy bridge tests passed.\n'
