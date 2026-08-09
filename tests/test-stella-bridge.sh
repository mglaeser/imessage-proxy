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
readonly TEST_PORT="${IMESSAGE_TEST_PORT:-$(choose_test_port)}"
TOKEN="$(openssl rand -hex 32)"
readonly TOKEN
temporary="$(mktemp -d /tmp/stella-bridge-test.XXXXXX)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid"
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f \
    "$temporary/allowed-targets.txt" \
    "$temporary/body.json" \
    "$temporary/bridge" \
    "$temporary/server.log" \
    "$temporary/test-token.txt" \
    "$temporary/timeout-a.json" \
    "$temporary/timeout-b.json"
  rmdir "$temporary"
}
trap cleanup EXIT

xcrun clang \
  -isysroot "$MACOS_SDK_PATH" \
  -fobjc-arc \
  -O2 \
  -Wall \
  -Wextra \
  -framework Foundation \
  -o "$temporary/bridge" \
  "$REPO_DIR/src/stella-bridge.m"

printf '%s\n' "$TOKEN" > "$temporary/test-token.txt"
chmod 600 "$temporary/test-token.txt"
install -m 0600 "$FIXTURES/allowed-targets.txt" "$temporary/allowed-targets.txt"

IMESSAGE_BRIDGE_PORT="$TEST_PORT" \
IMESSAGE_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
IMESSAGE_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
IMSG_BIN="$FIXTURES/fake-imsg.sh" \
IMESSAGE_RPC_TIMEOUT_SECONDS=2 \
STELLA_BRIDGE_MAX_CONCURRENCY=2 \
STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS=2 \
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
  --data '{"smsId":"s0","recipient":"+15551234567","message":"Sipgate-compatible test","sendAt":-1}' \
  "http://127.0.0.1:$TEST_PORT/v2/sessions/sms")"
[[ "$status" == "204" ]]
[[ ! -s "$temporary/body.json" ]]

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

if IMESSAGE_BRIDGE_PORT="$TEST_PORT" \
  IMESSAGE_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
  IMESSAGE_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
  IMSG_BIN="$FIXTURES/fake-imsg.sh" \
  IMESSAGE_RPC_TIMEOUT_SECONDS=30junk \
    "$temporary/bridge" check-config >/dev/null 2>&1; then
  printf 'ERROR: malformed RPC timeout was accepted\n' >&2
  exit 1
fi

chmod 0644 "$temporary/test-token.txt"
if IMESSAGE_BRIDGE_TOKEN_FILE="$temporary/test-token.txt" \
  IMESSAGE_ALLOWED_TARGETS_FILE="$temporary/allowed-targets.txt" \
  IMSG_BIN="$FIXTURES/fake-imsg.sh" \
    "$temporary/bridge" check-config >/dev/null 2>&1; then
  printf 'ERROR: insecure token permissions were accepted\n' >&2
  exit 1
fi
chmod 0600 "$temporary/test-token.txt"

if "$temporary/bridge" unknown-command >/dev/null 2>&1; then
  printf 'ERROR: unknown command returned success\n' >&2
  exit 1
fi

printf 'iMessage host bridge tests passed.\n'
