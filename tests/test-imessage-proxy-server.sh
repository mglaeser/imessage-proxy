#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
readonly REPO_DIR
readonly FIXTURES="$TEST_DIR/fixtures"

for dependency in curl lsof mkfifo openssl sqlite3 xcrun; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'ERROR: required test dependency is missing: %s\n' "$dependency" >&2
    exit 127
  }
done

MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
readonly MACOS_SDK_PATH
[[ -d "$MACOS_SDK_PATH" ]]

temporary="$(mktemp -d "$HOME/imessage-proxy-server-test.XXXXXX")"
readonly temporary
chmod 0700 "$temporary"
readonly server_binary="$temporary/imessage-proxy-server"
readonly server_log="$temporary/server.log"
readonly bootstrap_log="$temporary/bootstrap.log"
readonly response_body="$temporary/response.json"
readonly response_headers="$temporary/response.headers"
# The listener is loopback TCP now, so the suite needs a free port rather than a
# socket path. Probe upward from a pseudo-random base so parallel runs do not
# collide, and fail loudly rather than silently testing nothing.
find_free_port() {
  local candidate
  for candidate in $(seq $((20000 + RANDOM % 20000)) 65535); do
    if ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf 'FAIL: no free TCP port for the test server\n' >&2
  exit 1
}
server_port="$(find_free_port)"
readonly server_port
readonly ui_dir="$temporary/web"
readonly database_path="$temporary/state/imessage-proxy.sqlite3"
readonly messages_database_path="$temporary/messages/chat.db"
readonly targets_path="$temporary/private/allowed-targets.txt"
readonly fake_imsg="$temporary/fake-imsg"
readonly fake_imsg_driver="$temporary/fake-imsg-driver.sh"
readonly fake_imsg_log="${fake_imsg}.log"
server_pid=''

# imsg ships as a payload: the executable plus a sidecar dylib and two SwiftPM
# resource bundles it loads from its own directory. A fake without them models
# the broken installation this project shipped, not a working one, and would let
# the payload guards pass vacuously.
write_fake_imsg_payload() {
  local directory="$1"
  install -d -m 700 "$directory/PhoneNumberKit_PhoneNumberKit.bundle/Contents/Resources"
  install -d -m 700 "$directory/SQLite.swift_SQLite.bundle/Contents/Resources"
  printf '%s\n' '{}' > "$directory/PhoneNumberKit_PhoneNumberKit.bundle/Contents/Resources/PhoneNumberMetadata.json"
  printf '%s\n' 'fixture' > "$directory/imsg-bridge-helper.dylib"
  chmod 600 "$directory/imsg-bridge-helper.dylib" \
    "$directory/PhoneNumberKit_PhoneNumberKit.bundle/Contents/Resources/PhoneNumberMetadata.json"
}

report_failure() {
  local exit_code="$1" line="$2"
  printf 'ERROR: native-server integration test failed with exit %s at line %s\n' \
    "$exit_code" "$line" >&2
  if [[ -s "$server_log" ]]; then
    printf '%s\n' 'Native server log:' >&2
    sed -n '1,240p' "$server_log" >&2
  fi
  return "$exit_code"
}

stop_server() {
  local _ failed=0 pid="$server_pid" timed_out=no wait_status=0
  server_pid=''
  if [[ -n "$pid" ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..100}; do
        if ! kill -0 "$pid" 2>/dev/null; then
          break
        fi
        sleep 0.05
      done
      if kill -0 "$pid" 2>/dev/null; then
        timed_out=yes
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
    if wait "$pid" 2>/dev/null; then
      wait_status=0
    else
      wait_status=$?
    fi
    if [[ "$timed_out" == yes ]]; then
      printf 'ERROR: native server did not stop after SIGTERM\n' >&2
      failed=1
    elif (( wait_status != 0 )); then
      printf 'ERROR: native server exited with status %s during shutdown\n' "$wait_status" >&2
      failed=1
    fi
  fi
  if lsof -nP -iTCP:"$server_port" -sTCP:LISTEN > /dev/null 2>&1; then
    printf 'ERROR: native server stopped but its port is still listening\n' >&2
    failed=1
  fi
  return "$failed"
}

cleanup() {
  stop_server || true
  case "$temporary" in
    "$HOME"/imessage-proxy-server-test.*) rm -rf -- "$temporary" ;;
    *) printf 'ERROR: refusing unsafe test cleanup path: %s\n' "$temporary" >&2 ;;
  esac
}

trap 'report_failure "$?" "$LINENO"' ERR
trap cleanup EXIT

install -d -m 0700 \
  "$temporary/run" \
  "$temporary/state" \
  "$temporary/messages" \
  "$temporary/private" \
  "$ui_dir"
# Keep fake behavior in the shell fixture, but pin and spawn a native executable
# so the test exercises the same verified native-path launch as production.
install -m 0400 "$FIXTURES/fake-imsg.sh" "$fake_imsg_driver"
xcrun clang \
  -isysroot "$MACOS_SDK_PATH" \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Wpedantic \
  -Werror \
  -o "$fake_imsg" \
  "$FIXTURES/fake-imsg-launcher.c"
chmod 0500 "$fake_imsg"
# The real dependency is a payload directory, so the fake carries the same
# siblings. Without them the CLI's payload guards would pass vacuously here while
# a real installation could not send - which is exactly what shipped.
write_fake_imsg_payload "$(dirname "$fake_imsg")"
fake_imsg_sha256="$(openssl dgst -sha256 "$fake_imsg" | awk '{print $NF}')"
readonly fake_imsg_sha256
[[ "$fake_imsg_sha256" =~ ^[0-9a-f]{64}$ ]]
: > "$fake_imsg_log"
chmod 0600 "$fake_imsg_log"
: > "$messages_database_path"
# macOS ships ~/Library/Messages/chat.db group/world readable inside a
# TCC-protected directory. Mirror Apple's real mode so this suite exercises what
# a stock Mac actually presents; a stricter fixture hid a defect that blocked
# every real installation.
chmod 0644 "$messages_database_path"
printf '%s\n' "$messages_database_path" > "${fake_imsg}.expected-db"
chmod 0600 "${fake_imsg}.expected-db"
printf '%s\n' '+15551234567' 'person@example.test' 'chat_id:42' 'chat_id:999' > "$targets_path"
chmod 0600 "$targets_path"

xcrun clang \
  -isysroot "$MACOS_SDK_PATH" \
  -fobjc-arc \
  -fblocks \
  -O2 \
  -Wall \
  -Wextra \
  -Wpedantic \
  -Wno-gnu-conditional-omitted-operand \
  -Wno-gnu-statement-expression-from-macro-expansion \
  -Werror \
  -DIMESSAGE_PROXY_VERSION=\"1.0.0-test\" \
  -framework Foundation \
  -framework Security \
  -lsqlite3 \
  -o "$server_binary" \
  "$REPO_DIR/src/imessage-proxy-server.m" \
  "$REPO_DIR/src/api-key-store.m"

[[ "$("$server_binary" version)" == '1.0.0-test' ]]

run_native_with_digest() {
  local dependency_digest="$1"
  local execution_mode="$2"
  local -a environment=(
    "HOME=$HOME"
    'LANG=en_US.UTF-8'
    'PATH=/usr/bin:/bin'
    "TMPDIR=$temporary"
    "IMESSAGE_PROXY_ALLOWED_TARGETS_FILE=$targets_path"
    "IMESSAGE_PROXY_DATABASE_PATH=$database_path"
    'IMESSAGE_PROXY_EXPECTED_IMSG_VERSION=0.13.4'
    "IMESSAGE_PROXY_IMSG_BIN=$fake_imsg"
    "IMESSAGE_PROXY_IMSG_SHA256=$dependency_digest"
    'IMESSAGE_PROXY_MAX_CONCURRENCY=4'
    "IMESSAGE_PROXY_MESSAGES_DATABASE_PATH=$messages_database_path"
    "IMESSAGE_PROXY_PORT=$server_port"
    'IMESSAGE_PROXY_READ_TIMEOUT_SECONDS=2'
    'IMESSAGE_PROXY_SEND_TIMEOUT_SECONDS=2'
    "IMESSAGE_PROXY_UI_DIR=$ui_dir"
    'IMESSAGE_PROXY_SOCKET_TIMEOUT_SECONDS=2'
  )
  shift 2
  if [[ "$execution_mode" == exec ]]; then
    exec env -i "${environment[@]}" "$server_binary" "$@"
  fi
  [[ "$execution_mode" == run ]]
  env -i "${environment[@]}" "$server_binary" "$@"
}

run_native() {
  run_native_with_digest "$fake_imsg_sha256" run "$@"
}

request() {
  local path="$1"
  shift
  : > "$response_body"
  : > "$response_headers"
  curl \
    --silent \
    --show-error \
    \
    --output "$response_body" \
    --dump-header "$response_headers" \
    --write-out '%{http_code}' \
    "$@" \
    "http://127.0.0.1:$server_port${path}"
}

assert_status() {
  local expected="$1" actual="$2"
  if [[ "$actual" != "$expected" ]]; then
    printf 'ERROR: expected HTTP %s, received %s\n' "$expected" "$actual" >&2
    sed -n '1,120p' "$response_headers" >&2
    sed -n '1,120p' "$response_body" >&2
    return 1
  fi
}

json_string_field() {
  local field="$1" file="$2"
  sed -n "s/.*\"${field}\":\"\([^\"]*\)\".*/\1/p" "$file" | sed -n '1p'
}

assert_problem() {
  local expected_status="$1"
  grep -Fq 'Content-Type: application/problem+json' "$response_headers"
  grep -Fq "\"status\":${expected_status}" "$response_body"
  grep -Eq '"request_id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"' \
    "$response_body"
}

assert_no_cors_header() {
  if grep -Eiq '^Access-Control-Allow-' "$response_headers"; then
    printf 'ERROR: native server emitted a CORS response header\n' >&2
    return 1
  fi
}

assert_no_private_fields() {
  if grep -Eq \
    'account_id|account_login|last_addressed_handle|destination_caller_id|original_path|converted_path|cache_path|watch_background_path|file_path|/Users/|/private/|~/Library/' \
    "$response_body"; then
    printf 'ERROR: response exposed a private routing or host-path field\n' >&2
    return 1
  fi
}

start_server() {
  if lsof -nP -iTCP:"$server_port" -sTCP:LISTEN > /dev/null 2>&1; then
    printf 'ERROR: the test port is already in use before startup\n' >&2
    return 1
  fi
  : > "$server_log"
  run_native_with_digest "$fake_imsg_sha256" exec serve >> "$server_log" 2>&1 &
  server_pid="$!"
  local ready='no'
  for _ in {1..100}; do
    if kill -0 "$server_pid" 2>/dev/null && \
      curl --silent --output /dev/null "http://127.0.0.1:$server_port/api/status"; then
      ready='yes'
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.05
  done
  if [[ "$ready" != yes ]]; then
    sed -n '1,160p' "$server_log" >&2
    return 1
  fi
}

# Configuration is exact, private, pinned, and fingerprinted without revealing values.
[[ "$(run_native check-config)" == ok ]]
fingerprint="$(run_native config-fingerprint)"
readonly fingerprint
[[ "$fingerprint" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$fingerprint" != *'+15551234567'* ]]

chmod 0700 "$fake_imsg"
if run_native check-config > "$temporary/writable-imsg.out" 2> "$temporary/writable-imsg.err"; then
  printf 'ERROR: an owner-writable imsg executable was accepted\n' >&2
  exit 1
fi
grep -Fqi 'non-writable' "$temporary/writable-imsg.err"
chmod 0500 "$fake_imsg"

if run_native_with_digest "$(printf '0%.0s' {1..64})" run check-config \
  > "$temporary/digest.out" 2> "$temporary/digest.err"; then
  printf 'ERROR: an unpinned imsg digest was accepted\n' >&2
  exit 1
fi
grep -Fqi 'does not match' "$temporary/digest.err"

chmod 0755 "$temporary"
if run_native check-config > "$temporary/imsg-parent.out" 2> "$temporary/imsg-parent.err"; then
  chmod 0700 "$temporary"
  printf 'ERROR: an imsg executable in a non-private parent was accepted\n' >&2
  exit 1
fi
chmod 0700 "$temporary"
grep -Fqi 'must be a private user-owned directory' "$temporary/imsg-parent.err"
# The rejection must name the exact offending directory, not an anonymous class
# of paths. An unnamed path cost a real operator a full build to diagnose.
grep -Fq "$temporary" "$temporary/imsg-parent.err"

# This server never opens the Messages database; it passes the path to the
# pinned dependency, which reads it under its own Full Disk Access grant. So no
# permission shape may decide whether the service runs. Every mode a real Mac
# can present, including the 0644 file and 0755 directory macOS actually ships,
# must be accepted.
for messages_mode in 0644 0600 0666 0664 0622 0640; do
  chmod "$messages_mode" "$messages_database_path"
  if [[ "$(run_native check-config)" != ok ]]; then
    chmod 0644 "$messages_database_path"
    printf 'ERROR: a Messages database mode decided whether the service runs: %s\n' \
      "$messages_mode" >&2
    exit 1
  fi
done
chmod 0644 "$messages_database_path"

for messages_directory_mode in 0755 0700 0757 0777; do
  chmod "$messages_directory_mode" "$temporary/messages"
  if [[ "$(run_native check-config)" != ok ]]; then
    chmod 0700 "$temporary/messages"
    printf 'ERROR: a Messages directory mode decided whether the service runs: %s\n' \
      "$messages_directory_mode" >&2
    exit 1
  fi
done
chmod 0700 "$temporary/messages"

# Shape still matters: a missing database is a real, actionable misconfiguration.
mv "$messages_database_path" "$temporary/messages/chat.db.moved"
if run_native check-config > "$temporary/messages-missing.out" 2> "$temporary/messages-missing.err"; then
  mv "$temporary/messages/chat.db.moved" "$messages_database_path"
  printf 'ERROR: a missing Messages database was accepted\n' >&2
  exit 1
fi
mv "$temporary/messages/chat.db.moved" "$messages_database_path"
grep -Fqi 'sign in to Messages' "$temporary/messages-missing.err"
grep -Fq "$messages_database_path" "$temporary/messages-missing.err"

install -m 0600 "$targets_path" "$temporary/allowed-targets.original"
printf '%s\n' '*' > "$targets_path"
if run_native check-config > "$temporary/wildcard.out" 2> "$temporary/wildcard.err"; then
  printf 'ERROR: wildcard send allowlist was accepted\n' >&2
  exit 1
fi
install -m 0600 "$temporary/allowed-targets.original" "$targets_path"
for invalid_target in \
  'Alice' \
  '+01234567' \
  'person @example.test' \
  $'person\001@example.test' \
  'chat_id:042'; do
  printf '%s\n' "$invalid_target" > "$targets_path"
  if run_native check-config > "$temporary/invalid-target.out" 2> "$temporary/invalid-target.err"; then
    printf 'ERROR: an unsafe send allowlist entry was accepted: %s\n' "$invalid_target" >&2
    exit 1
  fi
  grep -Fqi 'invalid entry' "$temporary/invalid-target.err"
done
install -m 0600 "$temporary/allowed-targets.original" "$targets_path"

printf '%s\n' '0.13.3' > "${fake_imsg}.version"
chmod 0600 "${fake_imsg}.version"
if run_native check-config > "$temporary/version.out" 2> "$temporary/version.err"; then
  printf 'ERROR: an unpinned imsg version was accepted\n' >&2
  exit 1
fi
rm -f -- "${fake_imsg}.version"

# The bootstrap read preflight exercises the exact pinned chats command, fixed
# Messages database, bounded parser, and public DTO projection without revealing
# any chat data. Dependency diagnostics remain private on failure.
[[ "$(run_native check-messages)" == ok ]]
grep -Fq "imsg chats --limit 1 --db $messages_database_path --json" "$fake_imsg_log"
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == 0 ]]
printf '%s\n' chats-failure > "${fake_imsg}.malformed"
chmod 0600 "${fake_imsg}.malformed"
if run_native check-messages \
  > "$temporary/messages-preflight.out" 2> "$temporary/messages-preflight.err"; then
  printf 'ERROR: Messages read preflight accepted a failed dependency command\n' >&2
  exit 1
fi
[[ ! -s "$temporary/messages-preflight.out" ]]
grep -Fqi 'read-path preflight failed' "$temporary/messages-preflight.err"
if grep -Fq 'private Messages read failure detail' "$temporary/messages-preflight.err"; then
  printf 'ERROR: Messages read preflight exposed private dependency diagnostics\n' >&2
  exit 1
fi
printf '%s\n' chat > "${fake_imsg}.malformed"
if run_native check-messages \
  > "$temporary/messages-preflight-invalid.out" 2> "$temporary/messages-preflight-invalid.err"; then
  printf 'ERROR: Messages read preflight accepted an invalid chat projection\n' >&2
  exit 1
fi
[[ ! -s "$temporary/messages-preflight-invalid.out" ]]
grep -Fqi 'returned invalid data' "$temporary/messages-preflight-invalid.err"
# An unavailable Messages read path is a readiness property, not a start-up
# precondition. Exiting here produced an invisible launchd crash loop whose only
# symptom was a socket that never appeared. The server must serve, say so on
# stderr, and let /api/status report the degradation.
printf '%s\n' chats-failure > "${fake_imsg}.malformed"
start_server
kill -0 "$server_pid"
[[ "$(request /api/status)" == 401 ]]
grep -Fqi 'degraded' "$server_log"
if grep -Fq 'private Messages read failure detail' "$server_log"; then
  printf 'ERROR: native-server startup exposed private dependency diagnostics\n' >&2
  exit 1
fi
stop_server
printf '%s\n' chats-timeout > "${fake_imsg}.malformed"
if run_native check-messages \
  > "$temporary/messages-preflight-timeout.out" 2> "$temporary/messages-preflight-timeout.err"; then
  printf 'ERROR: Messages read preflight ignored its configured timeout\n' >&2
  exit 1
fi
[[ ! -s "$temporary/messages-preflight-timeout.out" ]]
grep -Fqi 'timed out' "$temporary/messages-preflight-timeout.err"
printf '%s\n' chats-delay > "${fake_imsg}.malformed"
start_server
kill -0 "$server_pid"
stop_server
rm -f -- "${fake_imsg}.malformed"

# The read-only bootstrap preflight accepts the shared trimmed 80-byte name
# boundary and never creates or reveals a credential.
bootstrap_name="$(printf 'b%.0s' {1..80})"
readonly bootstrap_name
[[ "$(run_native check-bootstrap-admin "  $bootstrap_name  " 365)" == ok ]]
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == 0 ]]

invalid_bootstrap_name="$(printf 'n%.0s' {1..81})"
readonly invalid_bootstrap_name
if run_native check-bootstrap-admin "$invalid_bootstrap_name" 30 \
  > "$temporary/bootstrap-name.out" 2> "$temporary/bootstrap-name.err"; then
  printf 'ERROR: bootstrap preflight accepted an 81-byte name\n' >&2
  exit 1
fi
[[ ! -s "$temporary/bootstrap-name.out" ]]
grep -Fqi 'name is invalid' "$temporary/bootstrap-name.err"
if grep -Fq "$invalid_bootstrap_name" "$temporary/bootstrap-name.err"; then
  printf 'ERROR: bootstrap preflight reflected an invalid name\n' >&2
  exit 1
fi

if run_native check-bootstrap-admin $'control\001name' 30 \
  > "$temporary/bootstrap-control.out" 2> "$temporary/bootstrap-control.err"; then
  printf 'ERROR: bootstrap preflight accepted a control character\n' >&2
  exit 1
fi
[[ ! -s "$temporary/bootstrap-control.out" ]]
grep -Fqi 'name is invalid' "$temporary/bootstrap-control.err"

if run_native check-bootstrap-admin invalid-expiry 366 \
  > "$temporary/bootstrap-preflight-expiry.out" 2> "$temporary/bootstrap-preflight-expiry.err"; then
  printf 'ERROR: bootstrap preflight accepted an expiry beyond 365 days\n' >&2
  exit 1
fi
[[ ! -s "$temporary/bootstrap-preflight-expiry.out" ]]
grep -Fqi 'expiry is invalid' "$temporary/bootstrap-preflight-expiry.err"
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == 0 ]]

# Capacity checks account for the same bounded stale-row cleanup as the final
# bootstrap, but the preflight itself neither removes nor inserts rows.
sqlite3 "$database_path" \
  "WITH RECURSIVE sequence(value) AS (
     VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<1000
   )
   INSERT INTO api_keys(uuid,name,key_prefix,key_hash,scopes,sender_identifier,
                        sender_identifier_assigned,created_at)
   SELECT printf('00000000-0000-4000-8000-%012d',value),
          'capacity-fixture',printf('imp_%08d',value),
          CAST(printf('%032d',value) AS BLOB),'messages:read',
          char(97+((value-1)/676)%26, 97+((value-1)/26)%26, 97+(value-1)%26),1,
          1000000+value
   FROM sequence;"
if run_native check-bootstrap-admin capacity-admin 30 \
  > "$temporary/bootstrap-capacity.out" 2> "$temporary/bootstrap-capacity.err"; then
  printf 'ERROR: bootstrap preflight ignored a full key store\n' >&2
  exit 1
fi
[[ ! -s "$temporary/bootstrap-capacity.out" ]]
grep -Fqi 'retention limit' "$temporary/bootstrap-capacity.err"
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == 1000 ]]
sqlite3 "$database_path" \
  "UPDATE api_keys SET revoked_at=created_at
   WHERE uuid='00000000-0000-4000-8000-000000000001';"
[[ "$(run_native check-bootstrap-admin capacity-admin 30)" == ok ]]
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == 1000 ]]
sqlite3 "$database_path" "DELETE FROM api_keys WHERE name='capacity-fixture';"
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == 0 ]]

# A token that cannot be written completely rolls its transaction back before
# failure is reported, leaving unrelated keys intact and a clean retry path.
sqlite3 "$database_path" \
  "INSERT INTO api_keys(uuid,name,key_prefix,key_hash,scopes,sender_identifier,
                        sender_identifier_assigned,created_at)
   VALUES('11111111-1111-4111-8111-111111111111','cleanup-sentinel',
          'imp_sentinel',zeroblob(32),'messages:read','zzz',0,2000000);"
closed_pipe="$temporary/bootstrap-delivery.pipe"
mkfifo "$closed_pipe"
# Open the FIFO read-write first: that never blocks and makes fd 8 a reader, so
# the write-only open below completes immediately. Closing fd 8 then leaves fd 9
# as a writer with no readers. A backgrounded reader that opens and exits
# instead races the blocking write-only open, which either waits forever or
# fails with EINTR when the child's SIGCHLD interrupts it.
exec 8<> "$closed_pipe"
exec 9> "$closed_pipe"
exec 8>&-
closed_pipe_status=0
if run_native bootstrap-admin undelivered-admin 30 >&9 2> "$temporary/bootstrap-delivery.err"; then
  exec 9>&-
  printf 'ERROR: bootstrap accepted an undeliverable stdout token\n' >&2
  exit 1
else
  closed_pipe_status="$?"
fi
exec 9>&-
[[ "$closed_pipe_status" == 1 ]]
grep -Fqi 'could not be delivered' "$temporary/bootstrap-delivery.err"
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM api_keys WHERE revoked_at IS NULL AND instr(','||scopes||',', ',admin,')>0;")" == 0 ]]
[[ "$(sqlite3 "$database_path" "SELECT count(*) FROM api_keys WHERE name='cleanup-sentinel';")" == 1 ]]
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == 1 ]]
sqlite3 "$database_path" "DELETE FROM api_keys WHERE name='cleanup-sentinel';"
[[ "$(run_native check-bootstrap-admin retry-admin 30)" == ok ]]

# Bootstrap reveals one key on stdout and refuses a second active administrator.
if run_native bootstrap-admin invalid-expiry 366 \
  > "$temporary/bootstrap-expiry.out" 2> "$temporary/bootstrap-expiry.err"; then
  printf 'ERROR: bootstrap accepted an expiry beyond 365 days\n' >&2
  exit 1
fi
[[ ! -s "$temporary/bootstrap-expiry.out" ]]
admin_key="$(run_native bootstrap-admin "$bootstrap_name" 365 2> "$bootstrap_log")"
readonly admin_key
[[ "$admin_key" =~ ^imp_[A-Za-z0-9_-]{43}$ ]]
if grep -Fq "$admin_key" "$bootstrap_log"; then
  printf 'ERROR: bootstrap log exposed the plaintext administrator key\n' >&2
  exit 1
fi
key_count_before_preflight="$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')"
if run_native check-bootstrap-admin another-bootstrap 30 \
  > "$temporary/active-admin-preflight.out" 2> "$temporary/active-admin-preflight.err"; then
  printf 'ERROR: bootstrap preflight ignored an active administrator\n' >&2
  exit 1
fi
[[ ! -s "$temporary/active-admin-preflight.out" ]]
grep -Fqi 'active administrator' "$temporary/active-admin-preflight.err"
[[ "$(sqlite3 "$database_path" 'SELECT count(*) FROM api_keys;')" == "$key_count_before_preflight" ]]
if run_native bootstrap-admin second-bootstrap 30 \
  > "$temporary/second-bootstrap.out" 2> "$temporary/second-bootstrap.err"; then
  printf 'ERROR: second administrator bootstrap unexpectedly succeeded\n' >&2
  exit 1
fi
[[ ! -s "$temporary/second-bootstrap.out" ]]
grep -Fqi 'active administrator' "$temporary/second-bootstrap.err"

start_server
kill -0 "$server_pid"
# The listener must be loopback and nothing else. This inverts the assertion the
# suite carried when the transport was a 0600 Unix socket: the server now does
# open a TCP listener, and the property worth pinning is that it can only ever be
# reachable from this machine. A wildcard bind would expose every message on the
# Mac to the local network, so it fails here rather than in the field.
listeners="$(lsof -nP -a -p "$server_pid" -iTCP -sTCP:LISTEN -Fn | grep '^n' || true)"
[[ -n "$listeners" ]] || {
  printf 'ERROR: native server opened no listener at all\n' >&2
  exit 1
}
while IFS= read -r listener; do
  [[ "$listener" == "n127.0.0.1:$server_port" ]] || {
    printf 'ERROR: native server listens somewhere other than loopback: %s\n' "$listener" >&2
    exit 1
  }
done <<< "$listeners"

# Console assets are served without a credential so a browser can load them,
# while every /api route still refuses one. Serving the console must not have
# opened an unauthenticated door.
printf '%s' '<!doctype html><title>console</title>' > "$ui_dir/index.html"
printf '%s' 'export const ok = true;' > "$ui_dir/app.js"
printf '%s' ':root{color:#000}' > "$ui_dir/styles.css"
for asset in / /index.html /app.js /styles.css; do
  assert_status 200 "$(request "$asset")"
done
grep -Fq 'Content-Security-Policy:' "$response_headers"
grep -Fq 'X-Frame-Options: DENY' "$response_headers"
grep -Fq 'Referrer-Policy: no-referrer' "$response_headers"
if grep -Fqi 'Strict-Transport-Security' "$response_headers"; then
  printf 'ERROR: the server asserted HSTS over plain loopback HTTP\n' >&2
  exit 1
fi
assert_status 401 "$(request /api/status)"
assert_status 401 "$(request /api/chats)"

# Traversal is unrepresentable rather than filtered: nothing outside the table of
# four request paths reaches a file at all.
printf '%s' 'SECRET' > "$temporary/outside.txt"
for probe in /../outside.txt /app.js/../../outside.txt /styles.css%2f..%2foutside.txt /web/app.js; do
  status="$(request "$probe")"
  [[ "$status" != 200 ]] || {
    printf 'ERROR: a path outside the console table was served: %s\n' "$probe" >&2
    exit 1
  }
done

# Every credential failure is the same 401 challenge apart from its unique request ID.
status="$(request /api/status)"
assert_status 401 "$status"
assert_problem 401
grep -Fq 'WWW-Authenticate: Bearer' "$response_headers"
cp "$response_body" "$temporary/missing-auth.json"
missing_request_id="$(json_string_field request_id "$response_body")"

status="$(request /api/status --header 'Authorization: Bearer malformed')"
assert_status 401 "$status"
assert_problem 401
malformed_request_id="$(json_string_field request_id "$response_body")"
[[ "$missing_request_id" != "$malformed_request_id" ]]
sed -E 's/"request_id":"[^"]+"/"request_id":"redacted"/' \
  "$temporary/missing-auth.json" > "$temporary/missing-auth.normalized"
sed -E 's/"request_id":"[^"]+"/"request_id":"redacted"/' \
  "$response_body" > "$temporary/malformed-auth.normalized"
cmp -s "$temporary/missing-auth.normalized" "$temporary/malformed-auth.normalized"

unknown_key="imp_$(printf 'A%.0s' {1..43})"
readonly unknown_key
status="$(request /api/status --header "Authorization: Bearer $unknown_key")"
assert_status 401 "$status"
assert_problem 401
sed -E 's/"request_id":"[^"]+"/"request_id":"redacted"/' \
  "$response_body" > "$temporary/unknown-auth.normalized"
cmp -s "$temporary/missing-auth.normalized" "$temporary/unknown-auth.normalized"

# Status exposes only the authenticated key's non-secret metadata.
status="$(request /api/status --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
grep -Fq 'Content-Type: application/json' "$response_headers"
grep -Fq '"status":"ok"' "$response_body"
grep -Fq '"dependency_version":"0.13.4"' "$response_body"
grep -Fq '"key":{' "$response_body"
grep -Fq "\"name\":\"$bootstrap_name\"" "$response_body"
if grep -Fq "$admin_key" "$response_body"; then
  printf 'ERROR: status response exposed the plaintext administrator key\n' >&2
  exit 1
fi
assert_no_cors_header

# A running server revalidates the exact executable before every dependency call.
install -m 0500 "$fake_imsg" "$temporary/fake-imsg.original"
install -m 0700 "$fake_imsg" "$temporary/fake-imsg.tampered"
printf '\0' >> "$temporary/fake-imsg.tampered"
chmod 0500 "$temporary/fake-imsg.tampered"
mv -f "$temporary/fake-imsg.tampered" "$fake_imsg"
imsg_invocations_before="$(wc -l < "$fake_imsg_log" | tr -d ' ')"
status="$(request /api/chats --header "Authorization: Bearer $admin_key")"
assert_status 502 "$status"
assert_problem 502
[[ "$(wc -l < "$fake_imsg_log" | tr -d ' ')" == "$imsg_invocations_before" ]]
mv -f "$temporary/fake-imsg.original" "$fake_imsg"
status="$(request /api/chats --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"

status="$(request /api/messages \
  --request POST \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Length: 65537')"
assert_status 413 "$status"
assert_problem 413

oversized_header="$(printf 'h%.0s' {1..17000})"
status="$(request /api/status \
  --header "Authorization: Bearer $admin_key" \
  --header "X-Oversized-Test: $oversized_header")"
assert_status 431 "$status"
assert_problem 431

# Create least-privilege keys and enforce the public name/expiry bounds.
status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"name":"read-only","scopes":["messages:read"],"expires_in_days":30}')"
assert_status 201 "$status"
read_key="$(json_string_field key "$response_body")"
read_id="$(json_string_field id "$response_body")"
readonly read_key read_id
[[ "$read_key" =~ ^imp_[A-Za-z0-9_-]{43}$ ]]
[[ "$read_id" =~ ^[0-9a-f-]{36}$ ]]
grep -Fq "Location: /api/keys/$read_id" "$response_headers"

status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"name":"send-only","scopes":["messages:send"],"expires_in_days":30}')"
assert_status 201 "$status"
send_key="$(json_string_field key "$response_body")"
send_id="$(json_string_field id "$response_body")"
readonly send_key send_id

status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"name":"second-admin","scopes":["admin"],"expires_in_days":30}')"
assert_status 201 "$status"
second_admin_key="$(json_string_field key "$response_body")"
second_admin_id="$(json_string_field id "$response_body")"
readonly second_admin_key second_admin_id

status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"name":"expires-now","scopes":["messages:read"],"expires_in_days":1}')"
assert_status 201 "$status"
expiring_key="$(json_string_field key "$response_body")"
expiring_id="$(json_string_field id "$response_body")"
readonly expiring_key expiring_id

long_name="$(printf 'n%.0s' {1..81})"
status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data "{\"name\":\"${long_name}\",\"scopes\":[\"messages:read\"],\"expires_in_days\":30}")"
assert_status 400 "$status"
assert_problem 400

unicode_name="$(printf 'é%.0s' {1..40})"
readonly unicode_name
status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data "{\"name\":\"${unicode_name}\",\"scopes\":[\"messages:read\"],\"expires_in_days\":30}")"
assert_status 201 "$status"
unicode_key="$(json_string_field key "$response_body")"
unicode_id="$(json_string_field id "$response_body")"
readonly unicode_key unicode_id
[[ "$unicode_key" =~ ^imp_[A-Za-z0-9_-]{43}$ ]]
[[ "$unicode_id" =~ ^[0-9a-f-]{36}$ ]]

too_long_unicode_name="$(printf 'é%.0s' {1..41})"
status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data "{\"name\":\"${too_long_unicode_name}\",\"scopes\":[\"messages:read\"],\"expires_in_days\":30}")"
assert_status 400 "$status"
assert_problem 400
status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"name":"control\nname","scopes":["messages:read"],"expires_in_days":30}')"
assert_status 400 "$status"
assert_problem 400

status="$(request /api/keys \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"name":"too-long","scopes":["messages:read"],"expires_in_days":366}')"
assert_status 400 "$status"
assert_problem 400
for invalid_expiry in '"90"' null '[]'; do
  status="$(request /api/keys \
    --header "Authorization: Bearer $admin_key" \
    --header 'Content-Type: application/json' \
    --data "{\"name\":\"wrong-expiry-type\",\"scopes\":[\"messages:read\"],\"expires_in_days\":${invalid_expiry}}")"
  assert_status 400 "$status"
  assert_problem 400
done

# The creation Location identifies a readable metadata resource, never a credential.
status="$(request "/api/keys/$read_id" --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
grep -Fq '"name":"read-only"' "$response_body"
grep -Fq '"scopes":["messages:read"]' "$response_body"
if grep -Fq "$read_key" "$response_body" || grep -Fq 'key_hash' "$response_body"; then
  printf 'ERROR: API-key detail exposed a credential or digest\n' >&2
  exit 1
fi
status="$(request '/api/keys/00000000-0000-4000-8000-000000000000' \
  --header "Authorization: Bearer $admin_key")"
assert_status 404 "$status"
assert_problem 404

# Expiry is immediate, generic, and indistinguishable from another invalid key.
sqlite3 "$database_path" \
  "UPDATE api_keys SET expires_at=created_at+1 WHERE uuid='$expiring_id';"
status="$(request /api/status --header "Authorization: Bearer $expiring_key")"
assert_status 401 "$status"
assert_problem 401
sed -E 's/"request_id":"[^"]+"/"request_id":"redacted"/' \
  "$response_body" > "$temporary/expired-auth.normalized"
cmp -s "$temporary/missing-auth.normalized" "$temporary/expired-auth.normalized"

# Read, send, and administration scopes are independent; admin implies all three.
status="$(request /api/chats --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
status="$(request /api/messages \
  --header "Authorization: Bearer $read_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: read-key-cannot-send' \
  --data '{"recipient":"+15551234567","text":"blocked"}')"
assert_status 403 "$status"
assert_problem 403
status="$(request /api/keys --header "Authorization: Bearer $read_key")"
assert_status 403 "$status"
assert_problem 403
status="$(request "/api/keys/$read_id" --header "Authorization: Bearer $read_key")"
assert_status 403 "$status"
assert_problem 403
status="$(request '/api/audit-events?limit=1' --header "Authorization: Bearer $read_key")"
assert_status 403 "$status"
assert_problem 403

status="$(request /api/chats --header "Authorization: Bearer $send_key")"
assert_status 403 "$status"
assert_problem 403
status="$(request /api/keys --header "Authorization: Bearer $send_key")"
assert_status 403 "$status"
assert_problem 403
status="$(request /api/chats --header "Authorization: Bearer $second_admin_key")"
assert_status 200 "$status"

# All bounded read adapters return explicit DTOs with routing data and host paths removed.
status="$(request '/api/chats?limit=1&unread_only=true' \
  --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"chats":[' "$response_body"
assert_no_private_fields

status="$(request /api/chats/42 --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"participants":["+15551234567"]' "$response_body"
assert_no_private_fields
status="$(request /api/chats/999 --header "Authorization: Bearer $read_key")"
assert_status 404 "$status"
assert_problem 404

status="$(request /api/chats/42/background --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"background_set":true' "$response_body"
grep -Fq '"cache_exists":true' "$response_body"
grep -Fq '"file_size":2048' "$response_body"
grep -Fq '"latest_event":{"action":"set","date":"2026-08-09T12:03:00.000Z"}' "$response_body"
grep -Fq '"watch_background_exists":false' "$response_body"
for omitted_background_field in \
  asset_id \
  asset_url \
  background_channel_guid \
  chat_guid \
  communication_safety_state \
  object_id \
  poster_version \
  version \
  row_id \
  private-background-event-guid; do
  if grep -Fq "$omitted_background_field" "$response_body"; then
    printf 'ERROR: chat background response exposed private or unstable field: %s\n' \
      "$omitted_background_field" >&2
    exit 1
  fi
done
assert_no_private_fields
status="$(request /api/chats/999/background --header "Authorization: Bearer $read_key")"
assert_status 404 "$status"
assert_problem 404
background_count_before="$(grep -c '^imsg chat-background ' "$fake_imsg_log")"
status="$(request '/api/chats/42/background?unexpected=true' \
  --header "Authorization: Bearer $read_key")"
assert_status 400 "$status"
assert_problem 400
[[ "$(grep -c '^imsg chat-background ' "$fake_imsg_log")" == "$background_count_before" ]]

status="$(request \
  '/api/chats/42/messages?participant=%2B15551234567&participant=me%40example.test&limit=2&start=2026-08-09T11:59:00Z&end=2026-08-09T12:02:00Z' \
  --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"messages":[' "$response_body"
grep -Fq '"attachments":[{' "$response_body"
grep -Fq '"filename":"secret.jpg"' "$response_body"
grep -Fq '"filename":null' "$response_body"
grep -Fq '"byte_size":123' "$response_body"
history_body="$(< "$response_body")"
[[ "$history_body" == *'"guid":"message-guid-100"'*'"guid":"message-guid-101"'* ]]
assert_no_private_fields

# imsg 0.13.4 emits empty strings when an attachment has no stored or transfer name.
# Every missing form in the public contract projects to an explicit JSON null.
printf '%s\n' missing-attachment-filenames > "${fake_imsg}.malformed"
chmod 0600 "${fake_imsg}.malformed"
status="$(request '/api/chats/42/messages?limit=1' --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"byte_size":0,"filename":null,"is_sticker":false,"mime_type":"","uti":""' \
  "$response_body"
[[ "$(grep -oF '"filename":null' "$response_body" | wc -l | tr -d ' ')" == 3 ]]
assert_no_private_fields
rm -f -- "${fake_imsg}.malformed"

history_count_before="$(grep -c '^imsg history ' "$fake_imsg_log")"
for invalid_history_path in \
  '/api/chats/42/messages?start=2026-02-30T00:00:00Z' \
  '/api/chats/42/messages?start=2026-08-09T00:00:00' \
  '/api/chats/42/messages?start=2026-08-10T00:00:00Z&end=2026-08-09T00:00:00Z' \
  '/api/chats/42/messages?start=2026-08-09T00:00:00Z&end=2026-08-09T00:00:00Z'; do
  status="$(request "$invalid_history_path" --header "Authorization: Bearer $read_key")"
  assert_status 400 "$status"
  assert_problem 400
done
[[ "$(grep -c '^imsg history ' "$fake_imsg_log")" == "$history_count_before" ]]
status="$(request '/api/chats/42/messages?participant=--convert-attachments' \
  --header "Authorization: Bearer $read_key")"
assert_status 400 "$status"
assert_problem 400
[[ "$(grep -c '^imsg history ' "$fake_imsg_log")" == "$history_count_before" ]]

search_count_before="$(grep -c '^imsg search ' "$fake_imsg_log" || true)"
status="$(request '/api/messages?query=pizza' --header "Authorization: Bearer $read_key")"
assert_status 404 "$status"
assert_problem 404
[[ "$(grep -c '^imsg search ' "$fake_imsg_log" || true)" == "$search_count_before" ]]

status="$(request '/api/scheduled-messages?limit=1' \
  --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"messages":[' "$response_body"
assert_no_private_fields

status="$(request '/api/statistics/messages?chat_id=42&time_zone=UTC&include_media=true' \
  --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"total_messages":2' "$response_body"
grep -Fq '"identifier":"iMessage;-;+15551234567"' "$response_body"
grep -Fq '"media":{"chats":[{' "$response_body"
grep -Fq '"total_attachments":1' "$response_body"
grep -Fq '"attachment_count":1' "$response_body"
grep -Fq '"truncated_dimensions":[]' "$response_body"
assert_no_private_fields

status="$(request '/api/statistics/messages?chat_id=999' \
  --header "Authorization: Bearer $read_key")"
assert_status 404 "$status"
assert_problem 404

stats_count_before="$(grep -c '^imsg stats ' "$fake_imsg_log")"
for invalid_time_zone in '' 'Mars%2FOlympus' 'utc'; do
  status="$(request "/api/statistics/messages?time_zone=${invalid_time_zone}" \
    --header "Authorization: Bearer $read_key")"
  assert_status 400 "$status"
  assert_problem 400
done
[[ "$(grep -c '^imsg stats ' "$fake_imsg_log")" == "$stats_count_before" ]]

# Statistics keep global totals while explicitly identifying every capped, ordered breakdown.
printf '%s\n' statistics-overflow > "${fake_imsg}.malformed"
chmod 0600 "${fake_imsg}.malformed"
status="$(request '/api/statistics/messages?include_media=true' \
  --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
grep -Fq '"total_messages":101' "$response_body"
grep -Fq '"truncated_dimensions":["chats","senders","services","dates","media.types","media.chats"]' \
  "$response_body"
for retained in \
  '"identifier":"chat-099"' \
  '"handle":"sender-099"' \
  '"service":"service-099"' \
  '"date":"1999-01-01"' \
  '"uti":"uti-099"' \
  '"identifier":"media-chat-099"'; do
  grep -Fq "$retained" "$response_body"
done
for omitted in \
  '"identifier":"chat-100"' \
  '"handle":"sender-100"' \
  '"service":"service-100"' \
  '"date":"2000-01-01"' \
  '"uti":"uti-100"' \
  '"identifier":"media-chat-100"'; do
  if grep -Fq "$omitted" "$response_body"; then
    printf 'ERROR: statistics response exceeded a 100-row dimension cap\n' >&2
    exit 1
  fi
done
rm -f -- "${fake_imsg}.malformed"

# Every projected optional field and formatted date is checked; malformed upstream DTOs fail closed.
for malformed_kind in chat attachment message reaction background scheduled statistics-date; do
  printf '%s\n' "$malformed_kind" > "${fake_imsg}.malformed"
  chmod 0600 "${fake_imsg}.malformed"
  case "$malformed_kind" in
    chat)
      status="$(request '/api/chats?limit=1' --header "Authorization: Bearer $read_key")"
      ;;
    background)
      status="$(request '/api/chats/42/background' --header "Authorization: Bearer $read_key")"
      ;;
    scheduled)
      status="$(request '/api/scheduled-messages?limit=1' --header "Authorization: Bearer $read_key")"
      ;;
    statistics-date)
      status="$(request '/api/statistics/messages' --header "Authorization: Bearer $read_key")"
      ;;
    *)
      status="$(request '/api/chats/42/messages?limit=2' --header "Authorization: Bearer $read_key")"
      ;;
  esac
  assert_status 502 "$status"
  assert_problem 502
done
rm -f -- "${fake_imsg}.malformed"

# A descendant that inherits an output pipe cannot defeat the absolute read deadline.
printf '%s\n' statistics-pipe-holder > "${fake_imsg}.malformed"
chmod 0600 "${fake_imsg}.malformed"
status="$(request '/api/statistics/messages' --header "Authorization: Bearer $read_key")"
assert_status 504 "$status"
assert_problem 504
rm -f -- "${fake_imsg}.malformed"

# The allowed origin is derived from the port the server bound, not configured,
# so the console's origin and the check cannot drift apart. Both loopback
# spellings are accepted; nothing else is, and no ACAO header is ever emitted.
for allowed_origin in "http://127.0.0.1:$server_port" "http://localhost:$server_port"; do
  status="$(request /api/status \
    --header "Authorization: Bearer $read_key" \
    --header "Origin: $allowed_origin")"
  assert_status 200 "$status"
  assert_no_cors_header
done
for refused_origin in \
  'https://evil.example.test' \
  "http://127.0.0.1:$((server_port + 1))" \
  "https://127.0.0.1:$server_port" \
  "http://127.0.0.1.evil.example.test:$server_port"; do
  status="$(request /api/status \
    --header "Authorization: Bearer $read_key" \
    --header "Origin: $refused_origin")"
  assert_status 403 "$status"
  assert_problem 403
  assert_no_cors_header
done

# last_used_at is useful metadata without forcing a SQLite write on every request.
last_used_before="$(sqlite3 "$database_path" \
  "SELECT last_used_at FROM api_keys WHERE uuid='$read_id';")"
status="$(request /api/status --header "Authorization: Bearer $read_key")"
assert_status 200 "$status"
last_used_after="$(sqlite3 "$database_path" \
  "SELECT last_used_at FROM api_keys WHERE uuid='$read_id';")"
[[ -n "$last_used_before" && "$last_used_before" == "$last_used_after" ]]

# Sends require exact targets and durable idempotency, and normalize the upstream result.
send_payload='{"recipient":"+15551234567","text":"hello from integration test"}'
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: send-once-0001' \
  --data "$send_payload")"
assert_status 202 "$status"
grep -Fq '"state":"accepted"' "$response_body"
grep -Fq '"message_id":300' "$response_body"
grep -Fq '"guid":"sent-guid-300"' "$response_body"
operation_id="$(json_string_field operation_id "$response_body")"
readonly operation_id
[[ "$operation_id" =~ ^[0-9a-f-]{36}$ ]]
cp "$response_body" "$temporary/send-first.json"

status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: send-once-0001' \
  --data "$send_payload")"
assert_status 202 "$status"
cmp -s "$temporary/send-first.json" "$response_body"
grep -Fq 'Idempotent-Replayed: true' "$response_headers"
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT operation_uuid FROM idempotency_records WHERE principal_uuid='$send_id' AND idempotency_key='send-once-0001';")" == \
  "$operation_id" ]]

status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: send-once-0001' \
  --data '{"recipient":"+15551234567","text":"different"}')"
assert_status 409 "$status"
assert_problem 409
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 1 ]]

status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --data "$send_payload")"
assert_status 400 "$status"
assert_problem 400

# The target schema is closed: a present second target is invalid even when unusable.
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: invalid-target-0002' \
  --data '{"recipient":"+15551234567","chat_id":0,"text":"must reject both fields"}')"
assert_status 400 "$status"
assert_problem 400
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: invalid-target-0003' \
  --data '{"recipient":"","chat_id":42,"text":"must reject both fields"}')"
assert_status 400 "$status"
assert_problem 400
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: contact-name-0004' \
  --data '{"recipient":"Alice","text":"must reject contact lookup"}')"
assert_status 400 "$status"
assert_problem 400
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: typed-target-0005' \
  --data '{"recipient":"chat_id:42","text":"must not borrow chat authorization"}')"
assert_status 400 "$status"
assert_problem 400
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: leading-option-0006' \
  --data '{"recipient":"+15551234567","text":"--convert-attachments"}')"
assert_status 400 "$status"
assert_problem 400
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 1 ]]

# Newlines and tabs are valid message text; other control characters remain invalid.
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: multiline-0002' \
  --data '{"recipient":"person@example.test","text":"line one\nline two\tok"}')"
assert_status 202 "$status"
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 2 ]]

# Chat sends resolve the service first and still force iMessage with SMS fallback disabled.
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: chat-send-0003' \
  --data '{"chat_id":42,"text":"chat send"}')"
assert_status 202 "$status"
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 3 ]]

status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: missing-chat-0007' \
  --data '{"chat_id":999,"text":"must not execute"}')"
assert_status 404 "$status"
assert_problem 404
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 3 ]]

status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: forbidden-0004' \
  --data '{"recipient":"+15550000000","text":"must not execute"}')"
assert_status 403 "$status"
assert_problem 403
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 3 ]]

# A timed-out send is durable and ambiguous; replay never invokes imsg again.
: > "${fake_imsg}.send-timeout"
chmod 0600 "${fake_imsg}.send-timeout"
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: ambiguous-0005' \
  --data '{"recipient":"+15551234567","text":"ambiguous test"}')"
assert_status 504 "$status"
assert_problem 504
rm -f -- "${fake_imsg}.send-timeout"
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 4 ]]
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: ambiguous-0005' \
  --data '{"recipient":"+15551234567","text":"ambiguous test"}')"
assert_status 504 "$status"
assert_problem 504
grep -Fq 'Idempotent-Replayed: true' "$response_headers"
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == 4 ]]

# Chat validation and execution consume one send deadline, not two independent budgets.
: > "${fake_imsg}.shared-send-deadline"
chmod 0600 "${fake_imsg}.shared-send-deadline"
send_count_before="$(grep -c '^imsg send ' "$fake_imsg_log")"
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: shared-deadline-0008' \
  --data '{"chat_id":42,"text":"shared deadline test"}')"
assert_status 504 "$status"
assert_problem 504
rm -f -- "${fake_imsg}.shared-send-deadline"
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == "$((send_count_before + 1))" ]]

# Key listing never reveals plaintext/digests; revocation is immediate and idempotent.
status="$(request /api/keys --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
grep -Fq '"keys":[' "$response_body"
if grep -Fq "$read_key" "$response_body" || grep -Fq 'key_hash' "$response_body"; then
  printf 'ERROR: API-key listing exposed a credential or digest\n' >&2
  exit 1
fi

status="$(request "/api/keys/$read_id" \
  --request DELETE \
  --header "Authorization: Bearer $admin_key")"
assert_status 204 "$status"
[[ ! -s "$response_body" ]]
status="$(request "/api/keys/$read_id" \
  --request DELETE \
  --header "Authorization: Bearer $admin_key")"
assert_status 204 "$status"
status="$(request /api/status --header "Authorization: Bearer $read_key")"
assert_status 401 "$status"
assert_problem 401
sed -E 's/"request_id":"[^"]+"/"request_id":"redacted"/' \
  "$response_body" > "$temporary/revoked-auth.normalized"
cmp -s "$temporary/missing-auth.normalized" "$temporary/revoked-auth.normalized"

status="$(request "/api/keys/$read_id" --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
grep -Eq '"revoked_at":"[^"]+"' "$response_body"

# One administrator may be revoked, but the final active administrator may not.
status="$(request "/api/keys/$second_admin_id" \
  --request DELETE \
  --header "Authorization: Bearer $admin_key")"
assert_status 204 "$status"
admin_id="$(sqlite3 "$database_path" \
  "SELECT uuid FROM api_keys WHERE key_prefix='${admin_key:0:12}';")"
readonly admin_id
[[ "$admin_id" =~ ^[0-9a-f-]{36}$ ]]
status="$(request "/api/keys/$admin_id" \
  --request DELETE \
  --header "Authorization: Bearer $admin_key")"
assert_status 409 "$status"
assert_problem 409
grep -Fq 'last-admin' "$response_body"

# Admins can inspect bounded, privacy-safe audit metadata for incident response.
status="$(request '/api/audit-events?limit=1000' --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
grep -Fq '"events":[' "$response_body"
grep -Fq '"action":"keys.revoke"' "$response_body"
grep -Fq '"phase":"final"' "$response_body"
grep -Fq '"source":"local"' "$response_body"
if grep -Fq "$read_key" "$response_body" || grep -Fq 'key_hash' "$response_body" ||
  grep -Fq 'hello from integration test' "$response_body"; then
  printf 'ERROR: audit API exposed a credential, hash, or message body\n' >&2
  exit 1
fi
status="$(request '/api/audit-events?limit=0' --header "Authorization: Bearer $admin_key")"
assert_status 400 "$status"
assert_problem 400

# The allowlist decides who this machine may message, so reading and changing it
# both require admin. A key that can send must not be able to widen the set of
# people it may send to; that is the whole point of the allowlist existing.
status="$(request /api/targets --header "Authorization: Bearer $send_key")"
assert_status 403 "$status"
assert_problem 403
status="$(request /api/targets \
  --request PUT \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --data '{"targets":["attacker@example.test"]}')"
assert_status 403 "$status"
assert_problem 403
if grep -Fq 'attacker@example.test' "$targets_path"; then
  printf 'ERROR: a non-admin key changed the recipient allowlist\n' >&2
  exit 1
fi

status="$(request /api/targets --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
grep -Fq '"targets":[' "$response_body"
grep -Fq '"person@example.test"' "$response_body"

# Every rejected list must leave the file exactly as it was: a partially applied
# allowlist is the one outcome an operator cannot detect by reading the console.
install -m 0600 "$targets_path" "$temporary/allowed-targets.before-api"
for invalid_body in \
  '{"targets":["Alice"]}' \
  '{"targets":["+01234567"]}' \
  '{"targets":["chat_id:042"]}' \
  '{"targets":["person @example.test"]}' \
  '{"targets":["a@example.test","a@example.test"]}' \
  '{"targets":["#person@example.test"]}' \
  '{"targets":["a@example.test\nb@example.test"]}' \
  '{"targets":[42]}' \
  '{"targets":"person@example.test"}' \
  '{"targets":[],"extra":1}' \
  '{}'; do
  status="$(request /api/targets \
    --request PUT \
    --header "Authorization: Bearer $admin_key" \
    --header 'Content-Type: application/json' \
    --data "$invalid_body")"
  assert_status 400 "$status"
  assert_problem 400
  cmp -s "$targets_path" "$temporary/allowed-targets.before-api" || {
    printf 'ERROR: a rejected allowlist still changed the file: %s\n' "$invalid_body" >&2
    exit 1
  }
done

# A replacement takes effect on the next send with no restart, in both directions.
status="$(request /api/targets \
  --request PUT \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"targets":["+15550000000"]}')"
assert_status 200 "$status"
grep -Fq '"+15550000000"' "$response_body"
[[ "$(stat -f '%Lp' "$targets_path")" == 600 ]]
sends_before="$(grep -c '^imsg send ' "$fake_imsg_log")"
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: revoked-target-0001' \
  --data '{"recipient":"person@example.test","text":"must not execute"}')"
assert_status 403 "$status"
assert_problem 403
grep -Fq 'target-forbidden' "$response_body"
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == "$sends_before" ]]

status="$(request /api/targets \
  --request PUT \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"targets":[]}')"
assert_status 200 "$status"
status="$(request /api/messages \
  --header "Authorization: Bearer $send_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: empty-allowlist-0001' \
  --data '{"recipient":"+15550000000","text":"must not execute"}')"
assert_status 403 "$status"
assert_problem 403
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == "$sends_before" ]]

# The CLI and the API must agree, so a list written by one is served by the other.
install -m 0600 "$temporary/allowed-targets.before-api" "$targets_path"
status="$(request /api/targets --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
grep -Fq '"person@example.test"' "$response_body"

status="$(request /api/targets \
  --request POST \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --data '{"targets":[]}')"
assert_status 405 "$status"
assert_problem 405

# Audit persistence has request correlation and attempted/final mutation rows only.
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE request_uuid='$missing_request_id' AND action='auth.reject' AND phase='final' AND status=401;")" == 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='messages.send' AND phase='attempted';")" -ge 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='messages.send' AND phase='final';")" -ge 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='keys.create' AND phase='attempted';")" -ge 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='background.read' AND phase='final' AND status=200;")" -ge 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='keys.read' AND phase='final' AND status=200 AND target_key_uuid='$read_id';")" -ge 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='audit.list' AND phase='final' AND status=200;")" -ge 1 ]]
# A mutation that is not audited is worse than one that is refused: these two
# actions were added to the schema's action constraint in version 6, and a
# missing row here means the constraint and the server disagree.
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='targets.read' AND phase='final' AND status=200;")" -ge 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='targets.replace' AND phase='final' AND status=200;")" -ge 1 ]]
[[ "$(sqlite3 "$database_path" \
  "SELECT count(*) FROM audit_records WHERE action='targets.read' AND phase='final' AND status=403;")" -ge 1 ]]

# Plaintext credentials and request content never enter SQLite or native logs.
for secret in "$admin_key" "$read_key" "$send_key" "$second_admin_key" "$expiring_key" "$unicode_key"; do
  for database_file in "$database_path" "${database_path}-wal" "${database_path}-shm"; do
    if [[ -f "$database_file" ]] && grep -aFq "$secret" "$database_file"; then
      printf 'ERROR: plaintext API key was persisted in SQLite\n' >&2
      exit 1
    fi
  done
  if grep -Fq "$secret" "$server_log"; then
    printf 'ERROR: native log exposed a plaintext API key\n' >&2
    exit 1
  fi
done
for private_value in \
  'hello from integration test' \
  'ambiguous test' \
  '+15551234567' \
  'person@example.test'; do
  if grep -Fq "$private_value" "$server_log"; then
    printf 'ERROR: native log exposed message or recipient content\n' >&2
    exit 1
  fi
  for database_file in "$database_path" "${database_path}-wal" "${database_path}-shm"; do
    if [[ -f "$database_file" ]] && grep -aFq "$private_value" "$database_file"; then
      printf 'ERROR: private message or recipient content was persisted in SQLite\n' >&2
      exit 1
    fi
  done
done

# The fake argv proves fixed direct commands, one database, no files, and no SMS fallback.
#
# Every grep over this log runs byte-oriented. The log now contains the sender
# identifier marker, and BSD grep stops matching a file whose bytes are not valid
# in the current locale - so these assertions failed on macOS against a log that
# plainly contained what they were looking for, while passing on Linux.
argv_contains() {
  LC_ALL=C grep -Fq -- "$1" "$fake_imsg_log"
}

if ! argv_contains '--service imessage'; then
  printf 'ERROR: no iMessage send reached the dependency\n' >&2
  grep -F -- 'imsg send' "$fake_imsg_log" | head -3 >&2
  exit 1
fi
argv_contains '--no-sms-fallback'
# Every send carries the sending key's identifier: a message that reached imsg
# without it would be unattributable to its recipient, which is the whole point.
# bash renders the marker as raw UTF-8 or as an escape depending on the build,
# so both spellings count and nothing else does.
if ! LC_ALL=C grep -Eq -- "--text .*($(printf '\U0001F516')|\\\\U0001[fF]516)[a-z]{2,8}" "$fake_imsg_log"; then
  printf 'ERROR: a send reached imsg without the sender identifier\n' >&2
  grep -F -- '--text' "$fake_imsg_log" | head -3 >&2
  exit 1
fi
argv_contains "--db $messages_database_path --json"
argv_contains 'imsg chat-background status --chat-id 42'
grep -Fq -- '--participants +15551234567\,me@example.test' "$fake_imsg_log"
grep -Fq -- '--start 2026-08-09T11:59:00Z --end 2026-08-09T12:02:00Z' "$fake_imsg_log"
if grep -Eiq -- '--file|--transport|--region' "$fake_imsg_log"; then
  printf 'ERROR: server invoked an unsafe imsg option\n' >&2
  exit 1
fi

# An empty allowlist still permits reads/admin but disables every send target.
stop_server
: > "$targets_path"
chmod 0600 "$targets_path"
start_server
status="$(request /api/chats --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
status="$(request /api/keys --header "Authorization: Bearer $admin_key")"
assert_status 200 "$status"
send_count_before="$(grep -c '^imsg send ' "$fake_imsg_log")"
status="$(request /api/messages \
  --header "Authorization: Bearer $admin_key" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: empty-allowlist-0006' \
  --data '{"recipient":"+15551234567","text":"blocked by empty allowlist"}')"
assert_status 403 "$status"
assert_problem 403
[[ "$(grep -c '^imsg send ' "$fake_imsg_log")" == "$send_count_before" ]]

# A self-labeled but altered current schema is rejected before the server accepts traffic.
stop_server
sqlite3 "$database_path" \
  'DROP INDEX api_keys_active_idx; CREATE INDEX api_keys_active_idx ON api_keys(created_at);'
if run_native serve > "$temporary/altered-schema.out" 2> "$temporary/altered-schema.err"; then
  printf 'ERROR: server accepted an altered schema with a current version label\n' >&2
  exit 1
fi
grep -Fqi 'schema does not match this release' "$temporary/altered-schema.err"

printf '%s\n' 'Native server integration tests passed.'
