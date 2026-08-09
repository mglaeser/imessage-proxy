#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
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

make_rpc_body() {
  local output=$1 size=$2
  python3 - "$output" "$size" <<'PY'
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
size = int(sys.argv[2])
prefix = b'{"jsonrpc":"2.0","id":"limit","method":"test","params":{"padding":"'
suffix = b'"}}'
padding = size - len(prefix) - len(suffix)
if padding < 0:
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

assert_public_response_headers() {
  local -a values=()
  mapfile -t values < <(response_header_values Server)
  [[ "${#values[@]}" -eq 0 ]] || die "public response exposed a Server header"

  mapfile -t values < <(response_header_values Cache-Control)
  [[ "${#values[@]}" -eq 1 && "${values[0]}" == 'no-store' ]] ||
    die "public response did not set Cache-Control: no-store exactly once"

  mapfile -t values < <(response_header_values X-Content-Type-Options)
  [[ "${#values[@]}" -eq 1 && "${values[0]}" == 'nosniff' ]] ||
    die "public response did not set X-Content-Type-Options: nosniff exactly once"
}

copy_internal_root_certificate() {
  local container_name=$1 destination=$2 running
  for _ in {1..100}; do
    if docker exec "$container_name" \
      /bin/cat /data/caddy/pki/authorities/local/root.crt \
      > "$destination" 2>/dev/null && [[ -s "$destination" ]]; then
      return 0
    fi
    if ! running="$(docker inspect --format '{{.State.Running}}' "$container_name")"; then
      return 1
    fi
    [[ "$running" == true ]] || return 1
    sleep 0.1
  done
  return 1
}

require_command curl
require_command docker
require_command ip
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
readonly ENV_EXAMPLE="$REPOSITORY_ROOT/config/imessage-proxy.env.example"
readonly FAKE_BRIDGE="$REPOSITORY_ROOT/tests/fixtures/fake-bridge.py"

mapfile -t caddy_images < <(
  sed -n 's/^IMESSAGE_PROXY_CADDY_IMAGE=//p' "$ENV_EXAMPLE"
)
[[ "${#caddy_images[@]}" -eq 1 ]] ||
  die "expected exactly one IMESSAGE_PROXY_CADDY_IMAGE pin"
readonly CADDY_IMAGE="${caddy_images[0]}"
[[ "$CADDY_IMAGE" =~ ^docker\.io/library/caddy@sha256:[0-9a-f]{64}$ ]] ||
  die "Caddy image is not the exact official digest pin"

TEMPORARY="$(mktemp -d)"
readonly TEMPORARY
readonly RESOURCE_SUFFIX="${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}"
readonly CONTAINER_NAME="imessage-proxy-caddy-ci-$RESOURCE_SUFFIX"
readonly OUTSIDE_CONTAINER_NAME="imessage-proxy-caddy-outside-ci-$RESOURCE_SUFFIX"
readonly OUTSIDE_NETWORK_NAME="imessage-proxy-outside-ci-$RESOURCE_SUFFIX"
readonly CALLER='facade-ci'
readonly CALLER_PASSWORD='facade-ci-password'
BRIDGE_TOKEN="$(printf '%063d%s' 0 a)"
readonly BRIDGE_TOKEN
[[ "$BRIDGE_TOKEN" =~ ^[0-9a-f]{64}$ ]] ||
  die "deterministic bridge-token fixture has the wrong shape"
readonly API_HOST='imessage-proxy.test'
readonly USERS_FILE="$TEMPORARY/users.caddy"
readonly RESPONSE_BODY="$TEMPORARY/response.body"
readonly RESPONSE_HEADERS="$TEMPORARY/response.headers"
fake_bridge_pid=''
container_started=no
outside_container_started=no
outside_network_created=no

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ "$exit_status" -ne 0 && "$container_started" == yes ]]; then
    printf '%s\n' '--- Caddy container log ---' >&2
    docker logs "$CONTAINER_NAME" >&2 || true
  fi
  if [[ "$exit_status" -ne 0 && "$outside_container_started" == yes ]]; then
    printf '%s\n' '--- Outside-source Caddy container log ---' >&2
    docker logs "$OUTSIDE_CONTAINER_NAME" >&2 || true
  fi
  if [[ "$outside_container_started" == yes ]]; then
    docker container rm --force "$OUTSIDE_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "$container_started" == yes ]]; then
    docker container rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -n "$fake_bridge_pid" ]]; then
    kill "$fake_bridge_pid" >/dev/null 2>&1 || true
    wait "$fake_bridge_pid" 2>/dev/null || true
  fi
  if [[ "$outside_network_created" == yes ]]; then
    docker network rm "$OUTSIDE_NETWORK_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "$exit_status" -ne 0 && -s "$TEMPORARY/fake-bridge.log" ]]; then
    printf '%s\n' '--- Fake bridge log ---' >&2
    sed -n '1,200p' "$TEMPORARY/fake-bridge.log" >&2
  fi
  rm -rf -- "$TEMPORARY"
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker pull --platform linux/arm64 "$CADDY_IMAGE" >/dev/null
[[ "$(docker image inspect --format '{{.Architecture}}' "$CADDY_IMAGE")" == arm64 ]] ||
  die "the pinned Caddy image did not resolve to ARM64"

password_hash="$(docker run --rm \
    --platform linux/arm64 \
    --pull=never \
    --entrypoint caddy \
    "$CADDY_IMAGE" \
    hash-password --plaintext "$CALLER_PASSWORD" \
    2>/dev/null)"
[[ "$password_hash" == \$2* ]] || die "Caddy did not produce a bcrypt password hash"
printf '%s %s\n' "$CALLER" "$password_hash" > "$USERS_FILE"
chmod 0600 "$USERS_FILE"

BRIDGE_PORT="$(choose_loopback_port)"
readonly BRIDGE_PORT
FAKE_BRIDGE_TOKEN="$BRIDGE_TOKEN" \
FAKE_BRIDGE_CALLER="$CALLER" \
  python3 -I "$FAKE_BRIDGE" --port "$BRIDGE_PORT" \
  > "$TEMPORARY/fake-bridge.log" 2>&1 &
fake_bridge_pid=$!

fake_bridge_ready=no
for _ in {1..50}; do
  if ! kill -0 "$fake_bridge_pid" 2>/dev/null; then
    die "fake bridge exited during startup"
  fi
  if curl \
    --fail \
    --noproxy '*' \
    --silent \
    --show-error \
    --header "Authorization: Bearer $BRIDGE_TOKEN" \
    --header "X-API-Client: $CALLER" \
    "http://127.0.0.1:$BRIDGE_PORT/healthz" \
    >/dev/null 2>&1; then
    fake_bridge_ready=yes
    break
  fi
  sleep 0.1
done
[[ "$fake_bridge_ready" == yes ]] || die "fake bridge did not become ready"

API_PORT="$(choose_loopback_port)"
readonly API_PORT
docker run --detach \
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
  --env "STELLA_API_HOST=$API_HOST" \
  --env "STELLA_API_PORT=$API_PORT" \
  --env STELLA_BRIDGE_HOST=127.0.0.1 \
  --env "STELLA_BRIDGE_PORT=$BRIDGE_PORT" \
  --env "STELLA_BRIDGE_TOKEN=$BRIDGE_TOKEN" \
  --env STELLA_USERS_FILE=/etc/caddy/users.caddy \
  --mount "type=bind,source=$CADDYFILE,target=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,source=$USERS_FILE,target=/etc/caddy/users.caddy,readonly" \
  --entrypoint caddy \
  "$CADDY_IMAGE" \
  run --config /etc/caddy/Caddyfile --adapter caddyfile \
  >/dev/null
container_started=yes

readonly ROOT_CERTIFICATE="$TEMPORARY/root.crt"
copy_internal_root_certificate "$CONTAINER_NAME" "$ROOT_CERTIFICATE" ||
  die "Caddy did not generate its internal CA"

readonly URL_ROOT="https://$API_HOST:$API_PORT"
curl_options=(
  --cacert "$ROOT_CERTIFICATE"
  --noproxy '*'
  --resolve "$API_HOST:$API_PORT:127.0.0.1"
  --silent
  --show-error
  --http1.1
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
    "$URL_ROOT$path"
}

caddy_ready=no
for _ in {1..100}; do
  if status="$(request GET /healthz \
    --user "$CALLER:$CALLER_PASSWORD" \
    --header 'X-API-Client: forged')" && [[ "$status" == 200 ]]; then
    caddy_ready=yes
    break
  fi
  sleep 0.1
done
[[ "$caddy_ready" == yes ]] || die "Caddy did not become ready"

status="$(request GET /healthz)"
assert_status 401 "$status" 'request without Basic Auth'
status="$(request GET /healthz --user "$CALLER:incorrect")"
assert_status 401 "$status" 'request with incorrect Basic Auth'

status="$(request GET /healthz \
  --user "$CALLER:$CALLER_PASSWORD" \
  --header 'X-API-Client: forged')"
assert_status 200 "$status" 'authenticated health request'
jq -e '.status == "ok" and .version == "facade-test"' \
  "$RESPONSE_BODY" >/dev/null
assert_public_response_headers

status="$(request POST /v1/rpc \
  --user "$CALLER:$CALLER_PASSWORD" \
  --header 'Content-Type: application/json' \
  --header 'X-API-Client: forged' \
  --data-binary '{"jsonrpc":"2.0","id":"rpc","method":"test"}')"
assert_status 200 "$status" 'authenticated JSON-RPC request'
jq -e '.jsonrpc == "2.0" and .id == "rpc" and .result.ok == true' \
  "$RESPONSE_BODY" >/dev/null

status="$(request POST /v2/sessions/sms \
  --user "$CALLER:$CALLER_PASSWORD" \
  --header 'Content-Type: application/json' \
  --header 'X-API-Client: forged' \
  --data-binary '{"smsId":"facade-test","recipient":"+15555550123","message":"hello"}')"
assert_status 204 "$status" 'authenticated SMS-style request'
[[ ! -s "$RESPONSE_BODY" ]] || die "SMS-style 204 response unexpectedly had a body"

while IFS='|' read -r method path; do
  request_arguments=(--user "$CALLER:$CALLER_PASSWORD")
  if [[ "$method" == POST ]]; then
    request_arguments+=(
      --header 'Content-Type: application/json'
      --data-binary '{}'
    )
  fi
  status="$(request "$method" "$path" "${request_arguments[@]}")"
  assert_status 404 "$status" "$method $path"
  [[ ! -s "$RESPONSE_BODY" ]] ||
    die "$method $path was answered by the fake bridge instead of Caddy"
done <<'EOF'
POST|/healthz
GET|/v1/rpc
GET|/v2/sessions/sms
GET|/healthz/
POST|/v1/rpc/
POST|/v2/sessions/sms/
POST|/v1/rpc/extra
GET|/_internal/configuration-fingerprint
GET|/not-a-route
EOF

readonly MAXIMUM_BODY="$TEMPORARY/body-65536.json"
readonly OVERSIZED_BODY="$TEMPORARY/body-65537.json"
make_rpc_body "$MAXIMUM_BODY" 65536
make_rpc_body "$OVERSIZED_BODY" 65537

status="$(request POST /v1/rpc \
  --user "$CALLER:$CALLER_PASSWORD" \
  --header 'Content-Type: application/json' \
  --data-binary "@$MAXIMUM_BODY")"
assert_status 200 "$status" '64 KiB request body'
status="$(request POST /v1/rpc \
  --user "$CALLER:$CALLER_PASSWORD" \
  --header 'Content-Type: application/json' \
  --data-binary "@$OVERSIZED_BODY")"
assert_status 413 "$status" '64 KiB plus one byte request body'

readonly OUTSIDE_SUBNET='198.18.0.0/24'
readonly OUTSIDE_GATEWAY='198.18.0.1'
readonly OUTSIDE_CONTAINER_IP='198.18.0.2'
docker network create \
  --driver bridge \
  --subnet "$OUTSIDE_SUBNET" \
  --gateway "$OUTSIDE_GATEWAY" \
  "$OUTSIDE_NETWORK_NAME" >/dev/null
outside_network_created=yes

route_to_outside="$(ip -4 route get "$OUTSIDE_CONTAINER_IP")"
[[ " $route_to_outside " == *" src $OUTSIDE_GATEWAY "* ]] ||
  die "host route to outside-source Caddy does not use $OUTSIDE_GATEWAY"

docker run --detach \
  --name "$OUTSIDE_CONTAINER_NAME" \
  --platform linux/arm64 \
  --pull=never \
  --cpus 1 \
  --memory 256m \
  --network "$OUTSIDE_NETWORK_NAME" \
  --ip "$OUTSIDE_CONTAINER_IP" \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /config \
  --tmpfs /data \
  --env "STELLA_API_HOST=$API_HOST" \
  --env "STELLA_API_PORT=$API_PORT" \
  --env STELLA_BRIDGE_HOST=127.0.0.1 \
  --env "STELLA_BRIDGE_PORT=$BRIDGE_PORT" \
  --env "STELLA_BRIDGE_TOKEN=$BRIDGE_TOKEN" \
  --env STELLA_USERS_FILE=/etc/caddy/users.caddy \
  --mount "type=bind,source=$CADDYFILE,target=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,source=$USERS_FILE,target=/etc/caddy/users.caddy,readonly" \
  --entrypoint caddy \
  "$CADDY_IMAGE" \
  run --config /etc/caddy/Caddyfile --adapter caddyfile \
  >/dev/null
outside_container_started=yes

readonly OUTSIDE_ROOT_CERTIFICATE="$TEMPORARY/outside-root.crt"
copy_internal_root_certificate \
  "$OUTSIDE_CONTAINER_NAME" \
  "$OUTSIDE_ROOT_CERTIFICATE" ||
  die "outside-source Caddy did not generate its internal CA"

outside_curl_options=(
  --cacert "$OUTSIDE_ROOT_CERTIFICATE"
  --noproxy '*'
  --resolve "$API_HOST:$API_PORT:$OUTSIDE_CONTAINER_IP"
  --silent
  --show-error
  --http1.1
)
readonly OUTSIDE_CURL_ERROR="$TEMPORARY/outside-curl.error"

assert_outside_request_aborted() {
  local credentials=$1 description=$2 curl_exit status
  for _ in {1..50}; do
    : > "$RESPONSE_BODY"
    : > "$RESPONSE_HEADERS"
    : > "$OUTSIDE_CURL_ERROR"
    if status="$(curl "${outside_curl_options[@]}" \
      --user "$credentials" \
      --output "$RESPONSE_BODY" \
      --dump-header "$RESPONSE_HEADERS" \
      --write-out '%{http_code}' \
      "$URL_ROOT/healthz" \
      2> "$OUTSIDE_CURL_ERROR")"; then
      die "$description returned HTTP $status instead of aborting"
    else
      curl_exit=$?
    fi
    case "$curl_exit" in
      52 | 56)
        [[ "$status" == 000 && ! -s "$RESPONSE_HEADERS" ]] ||
          die "$description exposed an HTTP response before aborting"
        return
        ;;
      7) sleep 0.1 ;;
      *)
        die "$description failed with unexpected curl exit $curl_exit: $(< "$OUTSIDE_CURL_ERROR")"
        ;;
    esac
  done
  die "$description did not reach the outside-source Caddy listener"
}

assert_outside_request_aborted \
  "$CALLER:incorrect" \
  'outside-source request before Basic Auth'
assert_outside_request_aborted \
  "$CALLER:$CALLER_PASSWORD" \
  'outside-source request before upstream proxying'

printf '%s\n' 'Caddy facade integration test passed.'
