#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

choose_loopback_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

make_create_body() {
  local output=$1 size=$2
  python3 - "$output" "$size" <<'PY'
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
size = int(sys.argv[2])
prefix = b'{"expires_in_days":90,"name":"'
suffix = b'","scopes":["messages:read"]}'
padding = size - len(prefix) - len(suffix)
if padding < 1:
    raise SystemExit("requested body is too small")
payload = prefix + (b"a" * padding) + suffix
if len(payload) != size:
    raise SystemExit("generated body has the wrong size")
output.write_bytes(payload)
PY
}

assert_status() {
  local expected=$1 actual=$2 description=$3
  [[ "$actual" == "$expected" ]] ||
    die "$description returned HTTP $actual, expected $expected"
}

response_header_values() {
  local requested_name=$1
  awk -v requested_name="$requested_name" '
    {
      sub(/\r$/, "")
      separator = index($0, ":")
      if (separator == 0) next
      name = substr($0, 1, separator - 1)
      if (tolower(name) != tolower(requested_name)) next
      value = substr($0, separator + 1)
      sub(/^[[:space:]]+/, "", value)
      print value
    }
  ' "$RESPONSE_HEADERS"
}

assert_single_header() {
  local name=$1 expected=$2 description=$3
  local -a values=()
  mapfile -t values < <(response_header_values "$name")
  [[ "${#values[@]}" -eq 1 && "${values[0]}" == "$expected" ]] ||
    die "$description did not set $name exactly once to the reviewed value"
}

assert_no_header() {
  local name=$1 description=$2
  local -a values=()
  mapfile -t values < <(response_header_values "$name")
  [[ "${#values[@]}" -eq 0 ]] || die "$description exposed $name"
}

assert_public_response_headers() {
  local description=$1
  assert_no_header Server "$description"
  assert_no_header Alt-Svc "$description"
  assert_no_header Access-Control-Allow-Credentials "$description"
  assert_no_header Access-Control-Allow-Headers "$description"
  assert_no_header Access-Control-Allow-Methods "$description"
  assert_no_header Access-Control-Allow-Origin "$description"
  assert_single_header Cache-Control no-store "$description"
  assert_single_header X-Content-Type-Options nosniff "$description"
  assert_single_header Referrer-Policy no-referrer "$description"
  assert_single_header Strict-Transport-Security 'max-age=31536000' "$description"
  assert_single_header X-Frame-Options DENY "$description"
  assert_single_header X-Robots-Tag 'noindex, nofollow, noarchive' "$description"
  assert_single_header \
    Content-Security-Policy \
    "default-src 'none'; base-uri 'none'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self'; script-src 'self'; style-src 'self'" \
    "$description"
  assert_single_header \
    Permissions-Policy \
    'accelerometer=(), autoplay=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), publickey-credentials-get=(), usb=()' \
    "$description"
}

require_command curl
require_command docker
require_command jq
require_command python3

case "$(uname -m)" in
  arm64 | aarch64) ;;
  *) die "this integration test must run natively on ARM64" ;;
esac
if [[ -n "${RUNNER_ARCH:-}" && "$RUNNER_ARCH" != ARM64 ]]; then
  die "GitHub runner architecture is $RUNNER_ARCH, expected ARM64"
fi
case "$(docker info --format '{{.Architecture}}')" in
  arm64 | aarch64) ;;
  *) die "Docker must run natively on ARM64" ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly REPOSITORY_ROOT
readonly CADDYFILE="$REPOSITORY_ROOT/config/Caddyfile"
readonly EDGE_PLIST="$REPOSITORY_ROOT/config/io.github.mglaeser.imessage-proxy.edge.plist.in"
readonly FAKE_API="$REPOSITORY_ROOT/tests/fixtures/fake-api.py"
readonly WEB_ROOT="$REPOSITORY_ROOT/web"
readonly CADDY_IMAGE="${CADDY_TEST_IMAGE:-docker.io/library/caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648}"
[[ "$CADDY_IMAGE" =~ ^docker\.io/library/caddy@sha256:[0-9a-f]{64}$ ]] ||
  die "the disposable Caddy test image is not pinned by digest"

TEMPORARY="$(mktemp -d)"
readonly TEMPORARY
readonly RESOURCE_SUFFIX="${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}"
readonly CONTAINER_NAME="imessage-proxy-caddy-ci-$RESOURCE_SUFFIX"
readonly API_KEY='imp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly CREATED_KEY='imp_ccccccccccccccccccccccccccccccccccccccccccc'
readonly EXPECTED_CLIENT_IP='127.0.0.1'
readonly SOCKET_DIRECTORY="$TEMPORARY/run"
readonly SOCKET_PATH="$SOCKET_DIRECTORY/server.sock"
readonly RESPONSE_BODY="$TEMPORARY/response.body"
readonly RESPONSE_HEADERS="$TEMPORARY/response.headers"
readonly ADAPTED_CONFIG="$TEMPORARY/adapted.json"
readonly ROOT_CERTIFICATE="$TEMPORARY/caddy-root.crt"
readonly PRIVATE_QUERY='SECRET_QUERY_VALUE_MUST_NOT_REACH_LOGS'
fake_api_pid=''
container_started=no

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ "$exit_status" -ne 0 && "$container_started" == yes ]]; then
    printf '%s\n' '--- Caddy container log ---' >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    printf '%s\n' '--- Caddy bounded runtime log ---' >&2
    docker exec "$CONTAINER_NAME" cat /tmp/edge.log >&2 || true
  fi
  if [[ "$container_started" == yes ]]; then
    docker container rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -n "$fake_api_pid" ]]; then
    kill "$fake_api_pid" >/dev/null 2>&1 || true
    wait "$fake_api_pid" 2>/dev/null || true
  fi
  if [[ "$exit_status" -ne 0 && -s "$TEMPORARY/fake-api.log" ]]; then
    printf '%s\n' '--- Fake API log ---' >&2
    sed -n '1,200p' "$TEMPORARY/fake-api.log" >&2
  fi
  rm -rf -- "$TEMPORARY"
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[[ -f "$WEB_ROOT/index.html" && -f "$WEB_ROOT/app.js" && -f "$WEB_ROOT/styles.css" ]] ||
  die "the complete static console is required"
grep -Fq '<form id="signin-form" action="/" method="get" novalidate>' \
  "$WEB_ROOT/index.html" ||
  die "the sign-in fallback must navigate only to the credential-free root"
if grep -Fq 'name="api_key"' "$WEB_ROOT/index.html"; then
  die "the API-key input must never participate in native form serialization"
fi
# These are literal Caddy placeholders.
# shellcheck disable=SC2016
grep -Fq 'https://{$IMESSAGE_PROXY_API_HOST}' "$CADDYFILE" ||
  die "Caddy must use the explicit API hostname for HTTPS"
# shellcheck disable=SC2016
grep -Fq 'https://{$IMESSAGE_PROXY_API_HOST}{uri} 308' "$CADDYFILE" ||
  die "Caddy must construct its explicit redirect from the reviewed API hostname"
grep -Fq 'auto_https disable_redirects' "$CADDYFILE" ||
  die "Caddy automatic redirects must be disabled"
grep -A1 -F '<key>IMESSAGE_PROXY_API_HOST</key>' "$EDGE_PLIST" |
  grep -Fq '<string>__API_HOST__</string>' ||
  die "the edge LaunchAgent must pass the explicit API hostname"
# shellcheck disable=SC2016
grep -Fq 'reverse_proxy "unix/{$IMESSAGE_PROXY_SOCKET_PATH}"' "$CADDYFILE" ||
  die "Caddy must use the configured Unix-socket upstream"

docker pull --platform linux/arm64 "$CADDY_IMAGE" >/dev/null
[[ "$(docker image inspect --format '{{.Architecture}}' "$CADDY_IMAGE")" == arm64 ]] ||
  die "the pinned Caddy image did not resolve to ARM64"
caddy_version="$(docker run --rm --platform linux/arm64 --pull=never --entrypoint caddy "$CADDY_IMAGE" version)"
[[ "${caddy_version%% *}" == v2.11.4 ]] ||
  die "the pinned Caddy image is not version 2.11.4"

mkdir -m 0700 "$SOCKET_DIRECTORY"
FAKE_API_KEY="$API_KEY" \
FAKE_API_CLIENT_IP="$EXPECTED_CLIENT_IP" \
  python3 -I "$FAKE_API" --socket "$SOCKET_PATH" \
  > "$TEMPORARY/fake-api.log" 2>&1 &
fake_api_pid=$!

fake_api_ready=no
for _ in {1..50}; do
  if ! kill -0 "$fake_api_pid" 2>/dev/null; then
    die "fake API exited during startup"
  fi
  if [[ -S "$SOCKET_PATH" ]] && curl \
    --fail \
    --unix-socket "$SOCKET_PATH" \
    --silent \
    --show-error \
    --header "Authorization: Bearer $API_KEY" \
    --header "X-API-Client-IP: $EXPECTED_CLIENT_IP" \
    http://localhost/api/status \
    >/dev/null 2>&1; then
    fake_api_ready=yes
    break
  fi
  sleep 0.1
done
[[ "$fake_api_ready" == yes ]] || die "fake Unix-socket API did not become ready"

HTTP_PORT="$(choose_loopback_port)"
HTTPS_PORT="$(choose_loopback_port)"
while [[ "$HTTPS_PORT" == "$HTTP_PORT" ]]; do
  HTTPS_PORT="$(choose_loopback_port)"
done
readonly HTTP_PORT HTTPS_PORT
readonly PRODUCTION_API_HOST=messages.integration.dev
readonly API_HOST=localhost
readonly HTTP_ORIGIN="http://$API_HOST:$HTTP_PORT"
readonly HTTPS_ORIGIN="https://$API_HOST:$HTTPS_PORT"

docker run --rm \
  --platform linux/arm64 \
  --pull=never \
  --env "IMESSAGE_PROXY_API_HOST=$PRODUCTION_API_HOST" \
  --env IMESSAGE_PROXY_ACME_EMAIL=ci@example.invalid \
  --env IMESSAGE_PROXY_EDGE_LOG_PATH=/tmp/edge.log \
  --env "IMESSAGE_PROXY_HTTP_PORT=$HTTP_PORT" \
  --env "IMESSAGE_PROXY_HTTPS_PORT=$HTTPS_PORT" \
  --env IMESSAGE_PROXY_PUBLIC_BIND=127.0.0.1 \
  --env IMESSAGE_PROXY_SOCKET_PATH=/run/imessage-proxy/server.sock \
  --env IMESSAGE_PROXY_UI_DIR=/srv/ui \
  --mount "type=bind,source=$CADDYFILE,target=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,source=$WEB_ROOT,target=/srv/ui,readonly" \
  --mount "type=bind,source=$SOCKET_DIRECTORY,target=/run/imessage-proxy,readonly" \
  --tmpfs /config \
  --tmpfs /data \
  --entrypoint caddy \
  "$CADDY_IMAGE" \
  adapt --config /etc/caddy/Caddyfile --adapter caddyfile --validate \
  > "$ADAPTED_CONFIG"
jq -e --arg http_listener "127.0.0.1:$HTTP_PORT" \
  --arg https_listener "127.0.0.1:$HTTPS_PORT" \
  --arg production_host "$PRODUCTION_API_HOST" \
  --argjson http_port "$HTTP_PORT" \
  --argjson https_port "$HTTPS_PORT" '
  .admin.disabled == true and
  .logging.logs.default.encoder.fields.request.filter == "delete" and
  .logging.logs.default.encoder.fields.uri.filter == "delete" and
  .logging.logs.default.writer.output == "file" and
  .logging.logs.default.writer.filename == "/tmp/edge.log" and
  .logging.logs.default.writer.mode == "0600" and
  .logging.logs.default.writer.roll_size_mb == 10 and
  .logging.logs.default.writer.roll_keep == 5 and
  .logging.logs.default.writer.roll_keep_days == 30 and
  ([.apps.http.servers[].listen[]] | sort) == ([$http_listener, $https_listener] | sort) and
  all(.apps.http.servers[];
    .automatic_https.disable_redirects == true and
    .max_header_bytes == 12288 and
    .read_timeout == 15000000000 and
    .read_header_timeout == 5000000000 and
    .write_timeout == 200000000000 and
    .idle_timeout == 60000000000 and
    .protocols == ["h1", "h2"]) and
  ([.. | objects | .response_header_timeout? // empty] == [195000000000]) and
  ([.. | objects |
    select(.handler? == "headers" and .request.delete? == ["Cookie"])] | length) == 1 and
  ([.. | objects |
    select(.handler? == "headers" and .request.delete? == ["X-API-*"])] | length) == 1 and
  ([.. | objects | select(.handler? == "reverse_proxy") |
    .headers.request.set."X-Api-Client-Ip"] == [["{http.request.remote.host}"]]) and
  ([.apps.tls.automation.policies[] |
    select(.subjects == [$production_host]) |
    .issuers[] |
    select(.module == "acme" and
      .challenges.http.alternate_port == $http_port and
      .challenges."tls-alpn".alternate_port == $https_port)] | length) == 2 and
  ([.. | objects |
    select(.handler? == "static_response" and .status_code? == 308 and
      .headers.Location? == ["https://messages.integration.dev{http.request.uri}"])] | length) == 1 and
  ([.. | objects |
    select(.handler? == "static_response" and .status_code? == 421)] | length) == 1
' "$ADAPTED_CONFIG" >/dev/null ||
  die "adapted Caddy configuration did not retain the explicit edge and privacy limits"

docker run --detach \
  --init \
  --name "$CONTAINER_NAME" \
  --platform linux/arm64 \
  --pull=never \
  --cpus 1 \
  --memory 256m \
  --network host \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /config \
  --tmpfs /data \
  --env "IMESSAGE_PROXY_API_HOST=$API_HOST" \
  --env IMESSAGE_PROXY_ACME_EMAIL=ci@example.invalid \
  --env IMESSAGE_PROXY_EDGE_LOG_PATH=/tmp/edge.log \
  --env "IMESSAGE_PROXY_HTTP_PORT=$HTTP_PORT" \
  --env "IMESSAGE_PROXY_HTTPS_PORT=$HTTPS_PORT" \
  --env IMESSAGE_PROXY_PUBLIC_BIND=127.0.0.1 \
  --env IMESSAGE_PROXY_SOCKET_PATH=/run/imessage-proxy/server.sock \
  --env IMESSAGE_PROXY_UI_DIR=/srv/ui \
  --mount "type=bind,source=$CADDYFILE,target=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,source=$WEB_ROOT,target=/srv/ui,readonly" \
  --mount "type=bind,source=$SOCKET_DIRECTORY,target=/run/imessage-proxy,readonly" \
  --entrypoint caddy \
  "$CADDY_IMAGE" \
  run --config /etc/caddy/Caddyfile --adapter caddyfile \
  >/dev/null
container_started=yes

curl_options=(
  --noproxy '*'
  --silent
  --show-error
  --http1.1
  --max-time 10
  --resolve "$API_HOST:$HTTPS_PORT:127.0.0.1"
  --cacert "$ROOT_CERTIFICATE"
)

request() {
  local method=$1 path=$2
  shift 2
  : > "$RESPONSE_BODY"
  : > "$RESPONSE_HEADERS"
  curl "${curl_options[@]}" \
    --request "$method" \
    --dump-header "$RESPONSE_HEADERS" \
    --output "$RESPONSE_BODY" \
    --write-out '%{http_code}' \
    "$@" \
    "$HTTPS_ORIGIN$path"
}

http_request() {
  local method=$1 path=$2
  shift 2
  : > "$RESPONSE_BODY"
  : > "$RESPONSE_HEADERS"
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --http1.1 \
    --max-time 10 \
    --resolve "$API_HOST:$HTTP_PORT:127.0.0.1" \
    --request "$method" \
    --dump-header "$RESPONSE_HEADERS" \
    --output "$RESPONSE_BODY" \
    --write-out '%{http_code}' \
    "$@" \
    "$HTTP_ORIGIN$path"
}

certificate_ready=no
for _ in {1..100}; do
  if docker exec "$CONTAINER_NAME" \
    cat /data/caddy/pki/authorities/local/root.crt \
    > "$ROOT_CERTIFICATE" 2>/dev/null &&
    [[ -s "$ROOT_CERTIFICATE" ]]; then
    certificate_ready=yes
    break
  fi
  sleep 0.1
done
[[ "$certificate_ready" == yes ]] || die "Caddy did not create its disposable test CA"

caddy_ready=no
for _ in {1..100}; do
  if status="$(request GET /)" && [[ "$status" == 200 ]]; then
    caddy_ready=yes
    break
  fi
  sleep 0.1
done
[[ "$caddy_ready" == yes ]] || die "Caddy did not become ready"

status="$(http_request GET '/api/status?redirect_probe=preserved')"
assert_status 308 "$status" 'canonical HTTP request'
assert_single_header \
  Location \
  'https://localhost/api/status?redirect_probe=preserved' \
  'canonical HTTP redirect'
assert_public_response_headers 'canonical HTTP redirect'
[[ ! -s "$RESPONSE_BODY" ]] || die 'canonical HTTP redirect returned an unexpected body'

status="$(http_request GET '/must-not-be-reflected?private=value' \
  --header "Host: attacker.invalid:$HTTP_PORT")"
assert_status 421 "$status" 'HTTP request with an unrecognized Host'
assert_no_header Location 'unrecognized-host HTTP response'
assert_public_response_headers 'unrecognized-host HTTP response'
[[ ! -s "$RESPONSE_BODY" ]] || die 'unrecognized-host HTTP response returned an unexpected body'

status="$(request GET /)"
assert_status 200 "$status" 'console index'
grep -Fq '<title>iMessage Proxy Console</title>' "$RESPONSE_BODY" ||
  die "console index did not contain its product title"
assert_public_response_headers 'console index'

status="$(request GET /app.js)"
assert_status 200 "$status" 'console script'
grep -Fq 'sessionStorage' "$RESPONSE_BODY" ||
  die "console script did not use tab-scoped credential storage"
assert_public_response_headers 'console script'

status="$(request GET /styles.css)"
assert_status 200 "$status" 'console stylesheet'
grep -Fq '.workspace-grid' "$RESPONSE_BODY" ||
  die "console stylesheet was incomplete"
assert_public_response_headers 'console stylesheet'

status="$(request GET /missing-asset)"
assert_status 404 "$status" 'unknown static asset'
assert_public_response_headers 'unknown static asset'

status="$(request GET /api/status)"
assert_status 401 "$status" 'API request without a bearer key'
assert_public_response_headers 'unauthenticated API response'
assert_single_header WWW-Authenticate 'Bearer realm="imessage-proxy"' 'unauthenticated API response'
assert_single_header Content-Type application/problem+json 'unauthenticated API response'
jq -e '
  .type == "about:blank" and .title == "Unauthorized" and .status == 401 and
  (.detail | type == "string" and length > 0) and
  (.request_id | type == "string" and length > 0)
' "$RESPONSE_BODY" >/dev/null || die 'unauthenticated API response was not a problem document'

status="$(request GET /api/status \
  --header 'Authorization: Bearer imp_test_wrong' \
  --header 'Origin: https://untrusted.example')"
assert_status 401 "$status" 'API request with an invalid bearer key'
assert_public_response_headers 'invalid-key API response'
assert_single_header Content-Type application/problem+json 'invalid-key API response'

status="$(request GET /api/status \
  --header "Authorization: Bearer $API_KEY" \
  --header 'Cookie: session=forged' \
  --header 'X-API-Client: forged' \
  --header 'X-API-Key-ID: forged' \
  --header 'X-API-Client-IP: 203.0.113.9')"
assert_status 200 "$status" 'authenticated status request'
jq -e '
  .status == "ok" and
  .messages.status == "ready" and
  .messages.dependency_version == "0.13.4" and
  .version == "edge-test" and
  .uptime_seconds == 7322 and
  .key.scopes == ["admin"]
' "$RESPONSE_BODY" >/dev/null
assert_public_response_headers 'authenticated status response'

status="$(request GET /api/keys \
  --header "Authorization: Bearer $API_KEY" \
  --header 'X-API-Caller: forged')"
assert_status 200 "$status" 'authenticated key list'
jq -e '
  (.keys | length) == 1 and
  .keys[0].id == "11111111-1111-4111-8111-111111111111" and
  .keys[0].scopes == ["admin"] and
  .keys[0].created_at == "2026-08-09T12:00:00Z" and
  (.keys[0] | has("key") | not)
' "$RESPONSE_BODY" >/dev/null
assert_public_response_headers 'authenticated key-list response'

status="$(request GET /api/keys/11111111-1111-4111-8111-111111111111 \
  --header "Authorization: Bearer $API_KEY")"
assert_status 200 "$status" 'authenticated key detail'
jq -e '
  .id == "11111111-1111-4111-8111-111111111111" and
  .name == "Edge test administrator" and
  .scopes == ["admin"] and
  (has("key") | not)
' "$RESPONSE_BODY" >/dev/null
assert_public_response_headers 'authenticated key-detail response'

status="$(request GET /api/chats/42/background \
  --header "Authorization: Bearer $API_KEY")"
assert_status 200 "$status" 'authenticated chat-background detail'
jq -e '
  .chat_id == 42 and .background_set == true and .cache_exists == true and
  .watch_background_exists == false and .latest_event.action == "set"
' "$RESPONSE_BODY" >/dev/null
assert_public_response_headers 'authenticated chat-background response'

status="$(request GET '/api/audit-events?limit=1' \
  --header "Authorization: Bearer $API_KEY")"
assert_status 200 "$status" 'authenticated audit-event list'
jq -e '
  (.events | length) == 1 and .events[0].action == "status.read" and
  .events[0].phase == "final" and .events[0].status == 200
' "$RESPONSE_BODY" >/dev/null
assert_public_response_headers 'authenticated audit-event response'

status="$(request POST /api/keys \
  --header "Authorization: Bearer $API_KEY" \
  --header 'Content-Type: application/json' \
  --data-binary '{"expires_in_days":90,"name":"Edge test","scopes":["messages:read"]}')"
assert_status 201 "$status" 'authenticated key creation'
assert_single_header \
  Location \
  '/api/keys/22222222-2222-4222-8222-222222222222' \
  'authenticated key creation'
jq -e '
  .id == "22222222-2222-4222-8222-222222222222" and
  .key == "imp_ccccccccccccccccccccccccccccccccccccccccccc" and
  .name == "Edge test" and
  .created_at == "2026-08-09T12:10:00Z" and
  .scopes == ["messages:read"]
' "$RESPONSE_BODY" >/dev/null
assert_public_response_headers 'authenticated key-creation response'

status="$(request DELETE /api/keys/22222222-2222-4222-8222-222222222222 \
  --header "Authorization: Bearer $API_KEY")"
assert_status 204 "$status" 'authenticated key revocation'
[[ ! -s "$RESPONSE_BODY" ]] || die "key revocation returned an unexpected body"
assert_public_response_headers 'authenticated key-revocation response'

status="$(request OPTIONS /api/status \
  --header 'Origin: https://untrusted.example' \
  --header 'Access-Control-Request-Method: GET' \
  --header 'Access-Control-Request-Headers: Authorization')"
assert_status 401 "$status" 'cross-origin preflight without a key'
assert_public_response_headers 'cross-origin preflight response'

status="$(request POST /unknown-resource \
  --header "Authorization: Bearer $API_KEY" \
  --header 'Content-Type: application/json' \
  --data-binary '{}')"
assert_status 404 "$status" 'unknown resource'
[[ ! -s "$RESPONSE_BODY" ]] || die 'unknown resource returned an unexpected body'
assert_public_response_headers 'unknown resource'

readonly MAXIMUM_BODY="$TEMPORARY/body-65536.json"
readonly OVERSIZED_BODY="$TEMPORARY/body-65537.json"
make_create_body "$MAXIMUM_BODY" 65536
make_create_body "$OVERSIZED_BODY" 65537

status="$(request POST /api/keys \
  --header "Authorization: Bearer $API_KEY" \
  --header 'Content-Type: application/json' \
  --data-binary "@$MAXIMUM_BODY")"
assert_status 400 "$status" '64 KiB contract-invalid request body'
assert_public_response_headers '64 KiB contract-invalid response'
assert_single_header Content-Type application/problem+json '64 KiB contract-invalid response'

status="$(request POST /api/keys \
  --header "Authorization: Bearer $API_KEY" \
  --header 'Content-Type: application/json' \
  --data-binary "@$OVERSIZED_BODY")"
assert_status 413 "$status" '64 KiB plus one byte request body'
assert_public_response_headers 'oversized request response'

large_header="$(python3 - <<'PY'
print("a" * 17000)
PY
)"
status="$(request GET /api/status \
  --header "Authorization: Bearer $API_KEY" \
  --header "X-Oversized-Test: $large_header")"
assert_status 431 "$status" 'request headers over 16 KiB'

kill "$fake_api_pid"
wait "$fake_api_pid" 2>/dev/null || true
fake_api_pid=''

status="$(request GET "/api/privacy-probe?probe=$PRIVATE_QUERY" \
  --header "Authorization: Bearer $API_KEY")"
assert_status 502 "$status" 'unavailable native API'
assert_public_response_headers 'unavailable native API response'
assert_single_header Content-Type application/problem+json 'unavailable native API response'
jq -e '
  .type == "about:blank" and
  .title == "Edge request failed" and
  .status == 502 and
  (.detail | type == "string" and length > 0) and
  (.request_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
' "$RESPONSE_BODY" >/dev/null ||
  die "edge-generated API error did not match the privacy-safe problem contract"

container_log="$(docker logs "$CONTAINER_NAME" 2>&1)"
runtime_log="$(docker exec "$CONTAINER_NAME" sh -c 'test -s /tmp/edge.log && cat /tmp/edge.log')"
combined_log="${container_log}"$'\n'"${runtime_log}"
[[ "$combined_log" != *"$API_KEY"* && "$combined_log" != *"$CREATED_KEY"* ]] ||
  die "Caddy logs exposed credential material"
[[ "$combined_log" != *"$PRIVATE_QUERY"* ]] ||
  die "Caddy logs exposed an API query value"

printf '%s\n' 'Caddy Unix-socket edge integration test passed.'
