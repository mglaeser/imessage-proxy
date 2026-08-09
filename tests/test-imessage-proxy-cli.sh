#!/usr/bin/env bash
# Test doubles below are invoked indirectly through functions sourced from the CLI.
# shellcheck disable=SC2030,SC2031,SC2032,SC2329
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd -P)"
readonly REPO_ROOT
test_root="$(mktemp -d "${TMPDIR:-/tmp}/imessage-proxy-cli-test.XXXXXX")"
readonly test_root
trap 'rm -rf -- "${test_root}"' EXIT

unset \
  IMESSAGE_PROXY_API_HOST \
  IMESSAGE_PROXY_API_PORT \
  IMESSAGE_PROXY_BIND_IP \
  IMESSAGE_PROXY_BRIDGE_HOST \
  IMESSAGE_PROXY_BRIDGE_HOST_IP \
  IMESSAGE_PROXY_BRIDGE_PORT \
  IMESSAGE_PROXY_CADDY_IMAGE \
  IMESSAGE_PROXY_CONTAINER_NAME \
  IMESSAGE_PROXY_ENABLE_ALPHA \
  IMESSAGE_PROXY_HOME \
  IMESSAGE_PROXY_SOURCE_DIR \
  STELLA_API_HOST \
  STELLA_API_PORT \
  STELLA_BIND_IP \
  STELLA_BRIDGE_HOST \
  STELLA_BRIDGE_HOST_IP \
  STELLA_BRIDGE_PORT \
  STELLA_CADDY_IMAGE \
  STELLA_CONTAINER_NAME \
  STELLA_ENABLE_ALPHA \
  STELLA_HOME \
  STELLA_SOURCE_DIR

export HOME="${test_root}/home"
export IMESSAGE_PROXY_HOME="${test_root}/state"
export IMESSAGE_PROXY_BRIDGE_PORT=8765

# shellcheck source=../bin/imessage-proxy
source "${REPO_ROOT}/bin/imessage-proxy"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local expected="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  grep -Fq "${expected}" <<< "${output}" ||
    fail "failure did not contain expected text: ${expected}"
}

expect_status() {
  local expected="$1" status
  shift
  if "$@"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq "${expected}" ]] ||
    fail "expected status ${expected}, got ${status}: $*"
}

run_clean_cli() (
  unset \
    IMESSAGE_PROXY_API_HOST \
    IMESSAGE_PROXY_API_PORT \
    IMESSAGE_PROXY_BIND_IP \
    IMESSAGE_PROXY_BRIDGE_HOST \
    IMESSAGE_PROXY_BRIDGE_HOST_IP \
    IMESSAGE_PROXY_BRIDGE_PORT \
    IMESSAGE_PROXY_CADDY_IMAGE \
    IMESSAGE_PROXY_CONTAINER_NAME \
    IMESSAGE_PROXY_ENABLE_ALPHA \
    IMESSAGE_PROXY_HOME \
    IMESSAGE_PROXY_SOURCE_DIR \
    STELLA_API_HOST \
    STELLA_API_PORT \
    STELLA_BIND_IP \
    STELLA_BRIDGE_HOST \
    STELLA_BRIDGE_HOST_IP \
    STELLA_BRIDGE_PORT \
    STELLA_CADDY_IMAGE \
    STELLA_CONTAINER_NAME \
    STELLA_ENABLE_ALPHA \
    STELLA_HOME \
    STELLA_SOURCE_DIR
  "$@"
)

expected_version="$(< "${REPO_ROOT}/VERSION")"
readonly expected_version
canonical_version="$(
  run_clean_cli env \
    IMESSAGE_PROXY_SOURCE_DIR="${REPO_ROOT}" \
    "${REPO_ROOT}/bin/imessage-proxy" version
)"
[[ "${canonical_version}" == "${expected_version}" ]] ||
  fail 'canonical source-directory variable did not select the repository assets'
legacy_version="$(
  run_clean_cli env \
    STELLA_SOURCE_DIR="${REPO_ROOT}" \
    "${REPO_ROOT}/bin/imessage-proxy" version
)"
[[ "${legacy_version}" == "${expected_version}" ]] ||
  fail 'legacy source-directory alias did not select the repository assets'
matching_version="$(
  run_clean_cli env \
    IMESSAGE_PROXY_SOURCE_DIR="${REPO_ROOT}" \
    STELLA_SOURCE_DIR="${REPO_ROOT}" \
    "${REPO_ROOT}/bin/imessage-proxy" version
)"
[[ "${matching_version}" == "${expected_version}" ]] ||
  fail 'identical canonical and legacy source-directory values were rejected'
wrapper_version="$(run_clean_cli "${REPO_ROOT}/bin/stella" version)"
[[ "${wrapper_version}" == "${expected_version}" ]] ||
  fail 'deprecated stella command did not delegate to imessage-proxy'

expect_cli_alias_conflict() {
  local canonical_assignment="$1" legacy_assignment="$2"
  local canonical_name="${canonical_assignment%%=*}"
  local legacy_name="${legacy_assignment%%=*}"
  local output
  if output="$(
    run_clean_cli env \
      "$canonical_assignment" \
      "$legacy_assignment" \
      "${REPO_ROOT}/bin/imessage-proxy" version 2>&1
  )"; then
    fail "conflicting aliases were accepted: ${canonical_name} and ${legacy_name}"
  fi
  [[ "${output}" == \
    "ERROR: ${canonical_name} and ${legacy_name} disagree; unset one or make them identical" ]] ||
    fail "conflict output was not value-free for ${canonical_name} and ${legacy_name}"
}

expect_cli_alias_conflict \
  'IMESSAGE_PROXY_SOURCE_DIR=/canonical/source' \
  'STELLA_SOURCE_DIR=/legacy/source'
expect_cli_alias_conflict \
  'IMESSAGE_PROXY_SOURCE_DIR=' \
  'STELLA_SOURCE_DIR=/legacy/source'
expect_cli_alias_conflict \
  'IMESSAGE_PROXY_HOME=/canonical/state' \
  'STELLA_HOME=/legacy/state'
expect_cli_alias_conflict \
  'IMESSAGE_PROXY_CONTAINER_NAME=canonical-container' \
  'STELLA_CONTAINER_NAME=legacy-container'
expect_cli_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_HOST=canonical.invalid' \
  'STELLA_BRIDGE_HOST=legacy.invalid'
expect_cli_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_HOST_IP=192.0.2.10' \
  'STELLA_BRIDGE_HOST_IP=192.0.2.11'
expect_cli_alias_conflict \
  'IMESSAGE_PROXY_BRIDGE_PORT=8765' \
  'STELLA_BRIDGE_PORT=8766'

expect_failure 'IMESSAGE_PROXY_SOURCE_DIR must not be empty' \
  run_clean_cli env IMESSAGE_PROXY_SOURCE_DIR= "${REPO_ROOT}/bin/imessage-proxy" version

IMESSAGE_PROXY_API_HOST=imessage-proxy.internal
IMESSAGE_PROXY_API_PORT=9443
export IMESSAGE_PROXY_API_HOST IMESSAGE_PROXY_API_PORT
require_api_settings
for valid_dns_name in \
  'imessage-proxy.internal' \
  'bridge-1.home.arpa' \
  'bridge_name.internal' \
  'A.example'; do
  dns_name_valid "$valid_dns_name" || fail "valid DNS name was rejected: $valid_dns_name"
done
for invalid_dns_name in \
  '' \
  '{}' \
  '.example.internal' \
  'example.internal.' \
  'example..internal' \
  '-bridge.internal' \
  'bridge-.internal' \
  "$(printf 'a%.0s' {1..64}).internal"; do
  if dns_name_valid "$invalid_dns_name"; then
    fail "invalid DNS name was accepted: $invalid_dns_name"
  fi
done
hostname_valid 'bridge-1.home.arpa' || fail 'valid hostname was rejected'
if hostname_valid 'bridge_name.internal'; then
  fail 'DNS-only underscore label was accepted as a hostname'
fi
lowercase_hostname_valid 'bridge-1.home.arpa' || fail 'valid lowercase hostname was rejected'
if lowercase_hostname_valid 'Bridge-1.home.arpa'; then
  fail 'uppercase host-route name was accepted'
fi
host_route_settings_valid 'bridge-1.home.arpa' '203.0.113.117' ||
  fail 'valid host-route settings were rejected'
if host_route_settings_valid 'Bridge-1.home.arpa' '203.0.113.117' ||
  host_route_settings_valid 'bridge-1.home.arpa' '999.0.0.1'; then
  fail 'invalid host-route settings were accepted'
fi
for valid_ipv4 in '0.0.0.0' '10.0.0.1' '100.64.0.1' '192.168.255.254' '255.255.255.255'; do
  ipv4_address_valid "$valid_ipv4" || fail "valid IPv4 address was rejected: $valid_ipv4"
done
for invalid_ipv4 in '' '1.2.3' '1.2.3.4.5' '01.2.3.4' '256.1.1.1' '1.2.3.-1' '{}'; do
  if ipv4_address_valid "$invalid_ipv4"; then
    fail "invalid IPv4 address was accepted: $invalid_ipv4"
  fi
done
for private_ipv4 in '10.0.0.1' '172.16.0.1' '172.31.255.254' '192.168.1.1' '100.64.0.1' '100.127.255.254'; do
  private_bind_ipv4_valid "$private_ipv4" || fail "private bind address was rejected: $private_ipv4"
done
for non_private_ipv4 in \
  '0.0.0.0' \
  '8.8.8.8' \
  '100.63.255.255' \
  '100.128.0.1' \
  '127.0.0.1' \
  '169.254.1.1' \
  '172.15.255.255' \
  '172.32.0.1' \
  '192.0.2.1'; do
  if private_bind_ipv4_valid "$non_private_ipv4"; then
    fail "non-private bind address was accepted: $non_private_ipv4"
  fi
done
IMESSAGE_PROXY_API_PORT=8765
expect_failure 'IMESSAGE_PROXY_API_PORT must differ from IMESSAGE_PROXY_BRIDGE_PORT' require_api_settings
IMESSAGE_PROXY_API_PORT=008765
expect_failure 'canonical base-10 in the range 1024-65535' require_api_settings
IMESSAGE_PROXY_API_PORT=18446744073709561059
expect_failure 'canonical base-10 in the range 1024-65535' require_api_settings
IMESSAGE_PROXY_API_PORT=9443

STELLA_API_HOST="${IMESSAGE_PROXY_API_HOST}"
STELLA_API_PORT="${IMESSAGE_PROXY_API_PORT}"
export STELLA_API_HOST STELLA_API_PORT
require_api_settings
STELLA_API_PORT=9444
expect_failure \
  'IMESSAGE_PROXY_API_PORT and STELLA_API_PORT disagree; unset one or make them identical' \
  require_api_settings
unset STELLA_API_HOST STELLA_API_PORT

legacy_api_host="${IMESSAGE_PROXY_API_HOST}"
legacy_api_port="${IMESSAGE_PROXY_API_PORT}"
unset IMESSAGE_PROXY_API_HOST IMESSAGE_PROXY_API_PORT
STELLA_API_HOST="${legacy_api_host}"
STELLA_API_PORT="${legacy_api_port}"
export STELLA_API_HOST STELLA_API_PORT
require_api_settings
unset STELLA_API_HOST STELLA_API_PORT
IMESSAGE_PROXY_API_HOST="${legacy_api_host}"
IMESSAGE_PROXY_API_PORT="${legacy_api_port}"
export IMESSAGE_PROXY_API_HOST IMESSAGE_PROXY_API_PORT

valid_container_inventory='[{"configuration":{"id":"stella"},"status":{"state":"stopped"}}]'
container_inventory_schema_valid "${valid_container_inventory}" ||
  fail 'valid structured Apple Container inventory was rejected'
container_inventory_schema_valid '[]' ||
  fail 'empty structured Apple Container inventory was rejected'
for invalid_inventory in \
  '{' \
  '[{}]' \
  '[{"configuration":{"id":"stella"},"status":{}}]' \
  '[{"configuration":{"id":"stella"},"status":{"state":"invalid"}}]' \
  '[{"configuration":{"id":"stella"},"status":{"state":"running"}},{"configuration":{"id":"stella"},"status":{"state":"stopped"}}]'; do
  if container_inventory_schema_valid "${invalid_inventory}"; then
    fail "malformed or ambiguous Apple Container inventory was accepted: ${invalid_inventory}"
  fi
done

(
  container() { printf '%s\n' "${valid_container_inventory}"; }
  [[ "$(container_state)" == stopped ]] ||
    fail 'known Apple Container state was not returned'
  expect_status 0 container_exists
)
(
  container() { printf '[]\n'; }
  expect_status 1 container_exists
)
(
  container() { printf 'container inventory failed\n' >&2; return 1; }
  expect_status 2 container_exists
)
(
  container() { printf '[{}]\n'; }
  expect_status 2 container_exists
)
(
  container() { printf '%s\n' "${valid_container_inventory}"; printf 'warning\n' >&2; }
  expect_status 2 container_exists
)
(
  container() { printf '[{"configuration":{"id":"stella"},"status":{"state":"unknown"}}]\n'; }
  [[ "$(container_state)" == unknown ]] ||
    fail 'Apple Container unknown state was not preserved'
  expect_status 0 container_exists
)

definition_token="$(printf '%063d%s' 0 a)"
[[ "$definition_token" =~ ^[0-9a-f]{64}$ ]] ||
  fail 'deterministic bridge-token fixture has the wrong shape'
definition_digest='sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648'
mkdir -p "$SECRETS" "$CADDY_DATA" "$CADDY_CONFIG"
printf '%s\n' "$definition_token" > "$TOKEN_FILE"
chmod 0600 "$TOKEN_FILE"
[[ "$(bridge_token_value "$TOKEN_FILE")" == "$definition_token" ]] ||
  fail 'bridge token reader rejected one trailing newline'
printf '%s' "$definition_token" > "$TOKEN_FILE"
[[ "$(bridge_token_value "$TOKEN_FILE")" == "$definition_token" ]] ||
  fail 'bridge token reader rejected the exact 64-byte form'
printf '%s\n\n' "$definition_token" > "$TOKEN_FILE"
expect_status 1 bridge_token_value "$TOKEN_FILE"
printf '%s\0' "$definition_token" > "$TOKEN_FILE"
expect_status 1 bridge_token_value "$TOKEN_FILE"
printf '%s\n' "${definition_token/a/A}" > "$TOKEN_FILE"
expect_status 1 bridge_token_value "$TOKEN_FILE"
printf '%s\n' "$definition_token" > "$TOKEN_FILE"
install -m 0600 "$REPO_ROOT/config/Caddyfile" "$CADDYFILE"
printf '%s\n' \
  "STELLA_API_HOST=${IMESSAGE_PROXY_API_HOST}" \
  "STELLA_API_PORT=${IMESSAGE_PROXY_API_PORT}" \
  "STELLA_BRIDGE_HOST=${HOST_DOMAIN}" \
  "STELLA_BRIDGE_PORT=${BRIDGE_PORT}" \
  "STELLA_BRIDGE_TOKEN=${definition_token}" \
  'STELLA_USERS_FILE=/etc/caddy/users.caddy' \
  > "$FACADE_ENV"
chmod 0600 "$FACADE_ENV"
valid_container_inspect="$(jq -cn \
  --arg name "$CONTAINER_NAME" \
  --arg digest "$definition_digest" \
  --arg host 192.168.1.10 \
  --arg caddyfile "$CADDYFILE" \
  --arg users "$USERS_FILE" \
  --arg data "$CADDY_DATA" \
  --arg config "$CADDY_CONFIG" \
  --arg api_host "$IMESSAGE_PROXY_API_HOST" \
  --arg api_port "$IMESSAGE_PROXY_API_PORT" \
  --arg bridge_host "$HOST_DOMAIN" \
  --arg bridge_port "$BRIDGE_PORT" \
  --arg token "$definition_token" '
  [{
    configuration: {
      id: $name,
      image: {descriptor: {digest: $digest}},
      mounts: [
        {type: {virtiofs: {}}, source: $caddyfile, destination: "/etc/caddy/Caddyfile", options: ["ro"]},
        {type: {virtiofs: {}}, source: $users, destination: "/etc/caddy/users.caddy", options: ["ro"]},
        {type: {virtiofs: {}}, source: $data, destination: "/data", options: []},
        {type: {virtiofs: {}}, source: $config, destination: "/config", options: []},
        {type: {tmpfs: {}}, source: "tmpfs", destination: "/tmp", options: []}
      ],
      publishedPorts: [{hostAddress: $host, hostPort: 9443, containerPort: 9443, proto: "tcp"}],
      publishedSockets: [],
      networks: [{network: "default", options: {hostname: "stella", macAddress: null, mtu: 1280}}],
      dns: {nameservers: [], searchDomains: [], options: []},
      labels: {},
      sysctls: {},
      rosetta: false,
      runtimeHandler: "container-runtime-linux",
      maskedPaths: null,
      readonlyPaths: null,
      platform: {os: "linux", architecture: "arm64"},
      initProcess: {
        executable: "caddy",
        arguments: ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"],
        environment: [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "CADDY_VERSION=v2.11.4",
          "XDG_CONFIG_HOME=/config",
          "XDG_DATA_HOME=/data",
          "STELLA_API_HOST=" + $api_host,
          "STELLA_API_PORT=" + $api_port,
          "STELLA_BRIDGE_HOST=" + $bridge_host,
          "STELLA_BRIDGE_PORT=" + $bridge_port,
          "STELLA_BRIDGE_TOKEN=" + $token,
          "STELLA_USERS_FILE=/etc/caddy/users.caddy"
        ],
        workingDirectory: "/srv",
        terminal: false,
        user: {id: {uid: 0, gid: 0}},
        supplementalGroups: [],
        rlimits: []
      },
      resources: {cpus: 1, memoryInBytes: 268435456, cpuOverhead: 1},
      virtualization: false,
      ssh: false,
      readOnly: true,
      useInit: false,
      capAdd: [],
      capDrop: []
    }
  }]
')"
container_inspect_schema_valid "$valid_container_inspect" ||
  fail 'valid Apple Container inspection schema was rejected'
for invalid_inspect in \
  '{}' \
  '[]' \
  '[{"configuration":{"id":"stella"}}]' \
  '[{"configuration":{"id":"stella","publishedPorts":[{}],"publishedSockets":[]}}]'; do
  if container_inspect_schema_valid "$invalid_inspect"; then
    fail "malformed Apple Container inspection schema was accepted: $invalid_inspect"
  fi
done
(
  IMESSAGE_PROXY_BIND_IP=192.168.1.10
  IMESSAGE_PROXY_CADDY_IMAGE="docker.io/library/caddy@${definition_digest}"
  export IMESSAGE_PROXY_BIND_IP
  export IMESSAGE_PROXY_CADDY_IMAGE
  container() { printf '%s\n' "$valid_container_inspect"; }
  expect_status 0 container_definition_matches
)

expect_container_definition_inspect_status() (
  local expected_status="$1" scenario="$2" inspect_json="$3" status
  IMESSAGE_PROXY_BIND_IP=192.168.1.10
  IMESSAGE_PROXY_CADDY_IMAGE="docker.io/library/caddy@${definition_digest}"
  export IMESSAGE_PROXY_BIND_IP
  export IMESSAGE_PROXY_CADDY_IMAGE
  container() { printf '%s\n' "$inspect_json"; }
  if container_definition_matches; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq "$expected_status" ]] ||
    fail "$scenario: expected definition status $expected_status, got $status"
)

expect_container_definition_inspect_status 0 'omitted default security-path fields' \
  "$(jq 'del(.[0].configuration.maskedPaths, .[0].configuration.readonlyPaths)' \
    <<< "$valid_container_inspect")"
expect_container_definition_inspect_status 0 'system-derived DNS domain' \
  "$(jq '
    .[0].configuration.dns.domain = "containers.internal" |
    .[0].configuration.networks[0].options.hostname = "stella.containers.internal."
  ' <<< "$valid_container_inspect")"

while IFS=$'\t' read -r scenario jq_filter; do
  expect_container_definition_inspect_status 1 "$scenario" \
    "$(jq "$jq_filter" <<< "$valid_container_inspect")"
done <<'EOF'
custom runtime handler	.[0].configuration.runtimeHandler = "custom-runtime"
masked-path override	.[0].configuration.maskedPaths = ["/proc/acpi"]
read-only-path override	.[0].configuration.readonlyPaths = ["/proc/bus"]
non-root init user	.[0].configuration.initProcess.user = {"raw": {"userString": "1000"}}
supplemental init group	.[0].configuration.initProcess.supplementalGroups = [1000]
init-process rlimit	.[0].configuration.initProcess.rlimits = [{"limit": "RLIMIT_NOFILE", "soft": 1024, "hard": 1024}]
explicit DNS nameserver	.[0].configuration.dns.nameservers = ["8.8.8.8"]
DNS search override	.[0].configuration.dns.searchDomains = ["example.test"]
DNS option override	.[0].configuration.dns.options = ["ndots:1"]
disabled DNS	.[0].configuration.dns = null
non-default network	.[0].configuration.networks[0].network = "custom"
non-generated network hostname	.[0].configuration.networks[0].options.hostname = "other"
custom network MAC	.[0].configuration.networks[0].options.macAddress = "02:42:ac:11:00:02"
custom network MTU	.[0].configuration.networks[0].options.mtu = 1500
bind mount type	.[0].configuration.mounts[0].type = {"tmpfs": {}}
bind mount options	.[0].configuration.mounts[0].options = ["ro", "exec"]
container platform	.[0].configuration.platform.architecture = "amd64"
shared-memory size	.[0].configuration.shmSize = 67108864
image stop signal	.[0].configuration.stopSignal = "SIGTERM"
storage quota	.[0].configuration.resources.storage = 1073741824
CPU overhead	.[0].configuration.resources.cpuOverhead = 2
Caddy image version	.[0].configuration.initProcess.environment |= map(if startswith("CADDY_VERSION=") then "CADDY_VERSION=v9.9.9" else . end)
EOF

(
  original_token="$(< "$TOKEN_FILE")"
  printf '%s\n' 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' > "$TOKEN_FILE"
  expect_status 1 prepared_facade_state_matches
  printf '%s\n' "$original_token" > "$TOKEN_FILE"
)
(
  printf '%s\n\n' "$definition_token" > "$TOKEN_FILE"
  expect_status 1 prepared_facade_state_matches
  printf '%s\n' "$definition_token" > "$TOKEN_FILE"
)
(
  printf '\n# drifted test configuration\n' >> "$CADDYFILE"
  expect_status 1 prepared_facade_state_matches
  install -m 0600 "$REPO_ROOT/config/Caddyfile" "$CADDYFILE"
)
(
  IMESSAGE_PROXY_BIND_IP=192.168.1.10
  IMESSAGE_PROXY_CADDY_IMAGE="docker.io/library/caddy@${definition_digest}"
  export IMESSAGE_PROXY_BIND_IP
  export IMESSAGE_PROXY_CADDY_IMAGE
  container() { jq '.[0].configuration.publishedPorts[0].hostAddress = "8.8.8.8"' <<< "$valid_container_inspect"; }
  expect_status 1 container_definition_matches
)
(
  IMESSAGE_PROXY_BIND_IP=192.168.1.10
  IMESSAGE_PROXY_CADDY_IMAGE="docker.io/library/caddy@${definition_digest}"
  export IMESSAGE_PROXY_BIND_IP
  export IMESSAGE_PROXY_CADDY_IMAGE
  container() { printf '{}\n'; }
  expect_status 2 container_definition_matches
)
(
  IMESSAGE_PROXY_BIND_IP=192.168.1.10
  IMESSAGE_PROXY_CADDY_IMAGE="docker.io/library/caddy@${definition_digest}"
  export IMESSAGE_PROXY_BIND_IP
  export IMESSAGE_PROXY_CADDY_IMAGE
  container() { printf '%s\n' "$valid_container_inspect"; printf 'warning\n' >&2; }
  expect_status 2 container_definition_matches
)

(
  launchctl() { printf 'service = { pid = 123; }\n'; }
  expect_status 0 agent_loaded
)
(
  launchctl() { printf 'Could not find service in domain\n' >&2; return 113; }
  expect_status 1 agent_loaded
)
(
  launchctl() { printf 'launchd inventory failed\n' >&2; return 1; }
  expect_status 2 agent_loaded
)
(
  launchctl() { :; }
  expect_status 2 agent_loaded
)

valid_agent_job="$(printf 'path = %s\nprogram = %s\nstate = running\npid = 4242\n' \
  "$PLIST_TARGET" "$BRIDGE_BIN")"
agent_job_identity_valid "$valid_agent_job" ||
  fail 'reviewed LaunchAgent identity was rejected'
[[ "$(agent_job_pid "$valid_agent_job")" == 4242 ]] ||
  fail 'reviewed LaunchAgent PID was rejected'
if agent_job_identity_valid "${valid_agent_job/$PLIST_TARGET/$HOME\/wrong.plist}"; then
  fail 'wrong LaunchAgent plist path was accepted'
fi
if agent_job_identity_valid "${valid_agent_job}"$'\npath = /duplicate.plist\n'; then
  fail 'duplicate LaunchAgent path was accepted'
fi
expect_status 1 agent_job_pid "${valid_agent_job/pid = 4242/}"
expect_status 2 agent_job_pid "${valid_agent_job}"$'\npid = 4243\n'
expect_status 2 agent_job_pid "${valid_agent_job/pid = 4242/pid = invalid}"

fake_tool_dir="$test_root/fake-agent-tools"
mkdir -p "$fake_tool_dir" "$BIN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$fake_tool_dir/imsg"
chmod 0700 "$fake_tool_dir/imsg"
# These literals are the body of a generated shell fixture and expand there.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/sh' \
  '[ "$1" = config-fingerprint ] || exit 1' \
  '[ -z "${IMESSAGE_PROXY_BRIDGE_PORT+x}" ] || exit 1' \
  '[ "${IMESSAGE_RPC_TIMEOUT_SECONDS-}" = 30 ] || exit 1' \
  '[ "${STELLA_BRIDGE_MAX_CONCURRENCY-}" = 8 ] || exit 1' \
  '[ "${STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS-}" = 10 ] || exit 1' \
  'printf "%s\n" sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  > "$BRIDGE_BIN"
chmod 0700 "$BRIDGE_BIN"
valid_agent_plist_json="$(jq -cn \
  --arg launch_label "$LAUNCH_LABEL" \
  --arg bridge "$BRIDGE_BIN" \
  --arg targets "$TARGETS_FILE" \
  --arg token "$TOKEN_FILE" \
  --arg port "$BRIDGE_PORT" \
  --arg imsg "$fake_tool_dir/imsg" \
  --arg error_log "$LOG_DIR/bridge.err.log" \
  --arg output_log "$LOG_DIR/bridge.out.log" '
    {
      Label: $launch_label,
      ProgramArguments: [$bridge, "serve"],
      EnvironmentVariables: {
        IMESSAGE_ALLOWED_TARGETS_FILE: $targets,
        IMESSAGE_BRIDGE_PORT: $port,
        IMESSAGE_BRIDGE_TOKEN_FILE: $token,
        IMESSAGE_RPC_TIMEOUT_SECONDS: "30",
        STELLA_BRIDGE_MAX_CONCURRENCY: "8",
        STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS: "10",
        IMSG_BIN: $imsg
      },
      KeepAlive: true,
      ProcessType: "Background",
      RunAtLoad: true,
      StandardErrorPath: $error_log,
      StandardOutPath: $output_log,
      ThrottleInterval: 10
    }
  ')"
(
  PATH="$fake_tool_dir:$PATH"
  export PATH
  plutil() { printf '%s\n' "$valid_agent_plist_json"; }
  expect_status 0 prepared_agent_plist_valid
)
(
  PATH="$fake_tool_dir:$PATH"
  export PATH
  plutil() { jq '.KeepAlive = false' <<< "$valid_agent_plist_json"; }
  expect_status 1 prepared_agent_plist_valid
)
(
  PATH="$fake_tool_dir:$PATH"
  export PATH
  plutil() { printf '{\n'; }
  expect_status 2 prepared_agent_plist_valid
)
(
  PATH="$fake_tool_dir:$PATH"
  export PATH
  plutil() { return 1; }
  expect_status 2 prepared_agent_plist_valid
)

valid_configuration_fingerprint='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
drifted_configuration_fingerprint='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
(
  PATH="$fake_tool_dir:$PATH"
  export PATH
  [[ "$(expected_agent_configuration_fingerprint)" == "$valid_configuration_fingerprint" ]] ||
    fail 'isolated expected LaunchAgent configuration fingerprint was rejected'
)
(
  curl() {
    local curl_config
    IFS= read -r curl_config
    [[ "$curl_config" == "header = \"Authorization: Bearer $definition_token\"" ]] || return 2
    [[ "$*" != *"$definition_token"* ]] || return 2
    printf '{"configurationFingerprint":"%s"}\n200' "$valid_configuration_fingerprint"
  }
  [[ "$(live_agent_configuration_fingerprint)" == "$valid_configuration_fingerprint" ]] ||
    fail 'authenticated live LaunchAgent configuration fingerprint was rejected'
)
(
  curl() {
    IFS= read -r _curl_config
    printf '{"error":"unauthorized"}\n401'
  }
  expect_status 1 live_agent_configuration_fingerprint
)
(
  curl() {
    IFS= read -r _curl_config
    printf 'connection failed\n' >&2
    return 7
  }
  expect_status 2 live_agent_configuration_fingerprint
)
(
  curl() {
    IFS= read -r _curl_config
    printf '{"configurationFingerprint":"malformed"}\n200'
  }
  expect_status 2 live_agent_configuration_fingerprint
)
(
  expected_agent_configuration_fingerprint() { printf '%s\n' "$valid_configuration_fingerprint"; }
  live_agent_configuration_fingerprint() { printf '%s\n' "$valid_configuration_fingerprint"; }
  expect_status 0 agent_configuration_fingerprint_matches
)
(
  expected_agent_configuration_fingerprint() { printf '%s\n' "$valid_configuration_fingerprint"; }
  live_agent_configuration_fingerprint() { printf '%s\n' "$drifted_configuration_fingerprint"; }
  expect_status 1 agent_configuration_fingerprint_matches
)
(
  fingerprint_count_file="$test_root/fingerprint-count"
  printf '0\n' > "$fingerprint_count_file"
  expected_agent_configuration_fingerprint() {
    local count
    count="$(< "$fingerprint_count_file")"
    ((count += 1))
    printf '%s\n' "$count" > "$fingerprint_count_file"
    if [[ "$count" -eq 1 ]]; then
      printf '%s\n' "$valid_configuration_fingerprint"
    else
      printf '%s\n' "$drifted_configuration_fingerprint"
    fi
  }
  live_agent_configuration_fingerprint() { printf '%s\n' "$valid_configuration_fingerprint"; }
  expect_status 1 agent_configuration_fingerprint_matches
  [[ "$(< "$fingerprint_count_file")" == 2 ]] ||
    fail 'configuration fingerprint comparison did not double-sample expected state'
)

valid_bridge_listener_lsof=$'p4242\nf10\ntIPv4\nPTCP\nn127.0.0.1:8765'
(
  launchctl() { printf '%s\n' "$valid_agent_job"; }
  lsof() { printf '%s\n' "$valid_bridge_listener_lsof"; }
  agent_configuration_fingerprint_matches() { return 0; }
  expect_status 0 agent_ready
)
(
  launchctl() { printf '%s\n' "${valid_agent_job/state = running/state = waiting}"; }
  lsof() { printf '%s\n' "$valid_bridge_listener_lsof"; }
  agent_configuration_fingerprint_matches() { return 0; }
  expect_status 1 agent_ready
)
(
  launchctl() { printf '%s\n' "$valid_agent_job"; }
  lsof() { return 1; }
  agent_configuration_fingerprint_matches() { return 0; }
  expect_status 1 agent_ready
)
(
  launchctl() { printf '%s\n' "${valid_agent_job}"$'\npid = 4243\n'; }
  lsof() { printf '%s\n' "$valid_bridge_listener_lsof"; }
  agent_configuration_fingerprint_matches() { return 0; }
  expect_status 2 agent_ready
)
(
  launchctl() { printf '%s\n' "$valid_agent_job"; }
  lsof() { printf 'listener inventory failed\n' >&2; return 1; }
  agent_configuration_fingerprint_matches() { return 0; }
  expect_status 2 agent_ready
)
(
  launchctl() { printf '%s\n' "$valid_agent_job"; }
  lsof() { printf '%s\n' "$valid_bridge_listener_lsof"; }
  agent_configuration_fingerprint_matches() { return 1; }
  expect_status 1 agent_ready
)
(
  launchctl() { printf '%s\n' "$valid_agent_job"; }
  lsof() { printf '%s\n' "$valid_bridge_listener_lsof"; }
  agent_configuration_fingerprint_matches() { return 2; }
  expect_status 2 agent_ready
)

(
  container() { printf '%s\n' "${HOST_DOMAIN}"; }
  expect_status 0 host_domain_exists
)
(
  container() { printf '{}\n'; }
  expect_status 2 host_domain_exists
)
(
  container() { printf '%s\n%s\n' "${HOST_DOMAIN}" "${HOST_DOMAIN}"; }
  expect_status 2 host_domain_exists
)
(
  container() { :; }
  expect_status 1 host_domain_exists
)
(
  container() { printf 'DNS inventory failed\n' >&2; return 1; }
  expect_status 2 host_domain_exists
)
(
  container() { printf '%s\n%s\n' "${HOST_DOMAIN}" 'malformed route'; }
  expect_status 2 host_domain_exists
)
(
  dscacheutil() { printf 'resolver inventory failed\n' >&2; return 1; }
  expect_status 2 host_domain_resolves_to_alias
)

(
  lsof() { return 1; }
  expect_status 1 port_listener_pids 9443
  expect_status 0 port_is_free 9443
  require_port_free 9443
)
(
  lsof() {
    printf '%s\n' \
      'p123' \
      'f10' \
      'tIPv4' \
      'PTCP' \
      'n127.0.0.1:9443' \
      'f11' \
      'tIPv4' \
      'PTCP' \
      'n*:9443' \
      'p456' \
      'f12' \
      'tIPv6' \
      'PTCP' \
      'n[::1]:9443'
  }
  [[ "$(port_listener_pids 9443)" == $'123\n456' ]] ||
    fail 'machine-readable listener inventory was parsed incorrectly'
  expect_status 1 port_is_free 9443
  expect_failure 'TCP port 9443 is already listening' require_port_free 9443
)
(
  lsof() { printf 'lsof inventory failed\n' >&2; return 1; }
  expect_status 2 port_listener_pids 9443
  expect_status 2 port_is_free 9443
  expect_failure 'could not inventory TCP port 9443; refusing container create' \
    require_port_free 9443
)
(
  lsof() { printf 'COMMAND PID USER\n'; }
  expect_status 2 port_listener_pids 9443
)
(
  lsof() { :; }
  expect_status 2 port_listener_pids 9443
)
(
  lsof() { printf '%s\n' "$valid_bridge_listener_lsof"; }
  expect_status 0 reviewed_bridge_listener_owned_by 4242
)
for unexpected_listener in \
  $'p4242\nf10\ntIPv4\nPTCP\nn*:8765' \
  $'p4242\nf10\ntIPv4\nPTCP\nn0.0.0.0:8765' \
  $'p4242\nf10\ntIPv6\nPTCP\nn[::1]:8765' \
  $'p4243\nf10\ntIPv4\nPTCP\nn127.0.0.1:8765' \
  $'p4242\nf10\ntIPv4\nPTCP\nn127.0.0.1:8765\nf11\ntIPv4\nPTCP\nn*:8765'; do
  (
    lsof() { printf '%s\n' "$unexpected_listener"; }
    expect_status 1 reviewed_bridge_listener_owned_by 4242
  )
done
(
  lsof() {
    case " $* " in
      *' -p 4242 -iTCP '*)
        printf '%s\n%s\n' \
          "$valid_bridge_listener_lsof" \
          $'f11\ntIPv4\nPTCP\nn127.0.0.1:9000'
        ;;
      *) printf '%s\n' "$valid_bridge_listener_lsof" ;;
    esac
  }
  expect_status 1 reviewed_bridge_listener_owned_by 4242
)
for malformed_listener in \
  $'p4242\nf10\nPTCP\nn127.0.0.1:8765' \
  $'p4242\nf10\ntIPv4\nn127.0.0.1:8765' \
  $'p4242\nf10\ntIPv4\ntIPv4\nPTCP\nn127.0.0.1:8765' \
  $'p4242\nfnetwork\ntIPv4\nPTCP\nn127.0.0.1:8765' \
  $'p4242\nf10\ntIPv4\nPTCP\nn127.0.0.1:8765\nunexpected'; do
  (
    lsof() { printf '%s\n' "$malformed_listener"; }
    expect_status 2 tcp_listener_inventory 8765
  )
done

require_macos() { :; }
require_container() { :; }
if [[ "$(uname -s)" != Darwin ]]; then
  require_private_file() {
    [[ -f "$1" && ! -L "$1" ]] || die "private file must be a regular non-symlink: $1"
  }
fi
agent_loaded() { return 1; }
prepared_agent_plist_valid() { return 0; }
wait_for_agent_ready() { return 0; }

(
  secret_value='do-not-print-this-bridge-token'
  container() {
    printf '[{"configuration":{"id":"stella","initProcess":{"environment":["STELLA_BRIDGE_TOKEN=%s"]},"publishedPorts":[{"hostAddress":"192.168.1.10","hostPort":9443,"containerPort":9443,"proto":"tcp"}]},"status":{"state":"running"}}]\n' \
      "$secret_value"
  }
  status_output="$(container_status)"
  [[ "$status_output" != *"$secret_value"* && "$status_output" != *'environment'* &&
    "$status_output" != *'BRIDGE_TOKEN'* ]] ||
    fail 'container status exposed environment or secret fields'
  jq -e '
    . == [{
      "name": "stella",
      "state": "running",
      "publishedPorts": [{
        "hostAddress": "192.168.1.10",
        "hostPort": 9443,
        "containerPort": 9443,
        "proto": "tcp"
      }]
    }]
  ' <<< "$status_output" >/dev/null || fail 'container status projection is incomplete or unstable'
)

mkdir -p "${BIN_DIR}" "$(dirname "${PLIST_TARGET}")"
printf '#!/bin/sh\nexit 0\n' > "${BRIDGE_BIN}"
chmod 0700 "${BRIDGE_BIN}"
printf 'generated plist\n' > "${PLIST_STATE}"
chmod 0600 "${PLIST_STATE}"
launchctl_log="${test_root}/launchctl.log"
: > "${launchctl_log}"
launchctl() {
  printf '%s\n' "$*" >> "${launchctl_log}"
}

(
  prepared_agent_plist_valid() { return 1; }
  expect_failure 'prepared LaunchAgent plist differs from the complete reviewed definition' agent_install
)
[[ ! -e "${PLIST_TARGET}" && ! -L "${PLIST_TARGET}" ]] ||
  fail 'agent-install created a target plist from a drifted prepared definition'
[[ ! -s "${launchctl_log}" ]] ||
  fail 'agent-install called launchctl for a drifted prepared definition'

(
  agent_loaded() { return 2; }
  expect_failure 'could not prove the LaunchAgent is absent; refusing agent install' agent_install
)
[[ ! -e "${PLIST_TARGET}" && ! -L "${PLIST_TARGET}" ]] ||
  fail 'agent-install created a target plist after a LaunchAgent inventory error'
[[ ! -s "${launchctl_log}" ]] ||
  fail 'agent-install called launchctl after a LaunchAgent inventory error'

printf 'operator-owned plist\n' > "${PLIST_TARGET}"
chmod 0600 "${PLIST_TARGET}"
(
  launchctl_job_snapshot() { return 2; }
  expect_failure 'could not inventory the LaunchAgent; refusing agent reload' \
    agent_reload 'RELOAD IMESSAGE HOST BRIDGE'
)
grep -Fxq 'operator-owned plist' "${PLIST_TARGET}" ||
  fail 'agent-reload changed its target after a LaunchAgent inventory error'
[[ ! -s "${launchctl_log}" ]] ||
  fail 'agent-reload called launchctl after a LaunchAgent inventory error'

(
  launchctl_job_snapshot() {
    printf 'path = %s\nprogram = %s\nstate = running\npid = 4242\n' \
      "$HOME/wrong.plist" "$BRIDGE_BIN"
  }
  expect_failure 'loaded same-label LaunchAgent has an unexpected plist or executable' \
    agent_reload 'RELOAD IMESSAGE HOST BRIDGE'
)
grep -Fxq 'operator-owned plist' "${PLIST_TARGET}" ||
  fail 'agent-reload changed its target for an unowned same-label job'
[[ ! -s "${launchctl_log}" ]] ||
  fail 'agent-reload called launchctl for an unowned same-label job'

snapshot_count_file="$test_root/reload-snapshot-count"
printf '0\n' > "$snapshot_count_file"
(
  agent_plist_valid() { return 1; }
  launchctl_job_snapshot() {
    local count
    count="$(< "$snapshot_count_file")"
    ((count += 1))
    printf '%s\n' "$count" > "$snapshot_count_file"
    if [[ "$count" -eq 1 ]]; then
      printf '%s\n' "$valid_agent_job"
    else
      return 1
    fi
  }
  launchctl() {
    printf '%s\n' "$*" >> "$launchctl_log"
    [[ "$1" != bootstrap ]]
  }
  expect_failure 'unreviewed previous plist will not be executed automatically' \
    agent_reload 'RELOAD IMESSAGE HOST BRIDGE'
)
cmp -s "$PLIST_STATE" "$PLIST_TARGET" ||
  fail 'agent-reload replaced the reviewed target after refusing an unreviewed rollback'
preserved_agent_backups=()
for preserved_agent_backup in "$STATE"/launch-agent-backup.*; do
  [[ -f "$preserved_agent_backup" && ! -L "$preserved_agent_backup" ]] || continue
  preserved_agent_backups+=("$preserved_agent_backup")
done
[[ "${#preserved_agent_backups[@]}" -eq 1 ]] ||
  fail 'agent-reload did not preserve exactly one unreviewed prior-plist backup'
grep -Fxq 'operator-owned plist' "${preserved_agent_backups[0]}" ||
  fail 'agent-reload preserved the wrong prior-plist backup content'
[[ "$(grep -c '^bootstrap ' "$launchctl_log")" -eq 1 ]] ||
  fail 'agent-reload tried to bootstrap an unreviewed prior plist'
rm -f -- "${preserved_agent_backups[0]}"
printf 'operator-owned plist\n' > "$PLIST_TARGET"
: > "$launchctl_log"

expect_failure 'agent plist already exists with different content' agent_install
grep -Fxq 'operator-owned plist' "${PLIST_TARGET}" ||
  fail 'agent-install changed a drifted target plist'
[[ ! -s "${launchctl_log}" ]] || fail 'agent-install bootstrapped a drifted target plist'

rm -f "${PLIST_TARGET}"
ln -s "${PLIST_STATE}" "${PLIST_TARGET}"
expect_failure 'agent plist target is not a regular file' agent_install
expect_failure 'private file must be a regular non-symlink' \
  agent_reload 'RELOAD IMESSAGE HOST BRIDGE'

rm -f "${PLIST_TARGET}"
agent_install >/dev/null
cmp -s "${PLIST_STATE}" "${PLIST_TARGET}" ||
  fail 'agent-install did not install the generated plist into an absent target'
grep -Fq "bootstrap gui/$(id -u) ${PLIST_TARGET}" "${launchctl_log}" ||
  fail 'agent-install did not bootstrap a newly installed target plist'

: > "${launchctl_log}"
agent_install >/dev/null
cmp -s "${PLIST_STATE}" "${PLIST_TARGET}" ||
  fail 'agent-install changed an exact existing target plist'
grep -Fq "bootstrap gui/$(id -u) ${PLIST_TARGET}" "${launchctl_log}" ||
  fail 'agent-install did not bootstrap the exact existing target plist'

sudo_log="${test_root}/sudo.log"
: > "${sudo_log}"
mock_domain_exists=yes
mock_resolution=$'name: stella-host.container.internal\nip_address: 192.0.2.55'
host_domain_exists() {
  case "${mock_domain_exists}" in
    yes) return 0 ;;
    no) return 1 ;;
    *) return 2 ;;
  esac
}
dscacheutil() { printf '%s\n' "${mock_resolution}"; }
sudo() {
  printf '%s\n' "$*" >> "${sudo_log}"
  case "$*" in
    *' system dns delete '*)
      mock_domain_exists=no
      mock_resolution=''
      ;;
    *' system dns create '*)
      mock_domain_exists=yes
      mock_resolution="$(printf 'name: %s\nip_address: %s' "${HOST_DOMAIN}" "${HOST_ALIAS_IP}")"
      ;;
  esac
}

mock_domain_exists="inventory-error"
expect_failure 'could not inventory Apple Container host routes; refusing host-route create' \
  host_route_create
expect_failure 'could not inventory Apple Container host routes; refusing host-route refresh' \
  host_route_refresh 'REFRESH IMESSAGE HOST ROUTE'
[[ ! -s "${sudo_log}" ]] || fail 'host-route actions mutated DNS after an inventory error'

mock_domain_exists=yes
expect_failure 'exists but does not resolve only to' host_route_create
[[ ! -s "${sudo_log}" ]] || fail 'host-route-create mutated an unexpected existing route'

mock_resolution="$(printf 'name: %s\nip_address: %s' "${HOST_DOMAIN}" "${HOST_ALIAS_IP}")"
resolver_inventory_schema_valid "$mock_resolution" ||
  fail 'valid resolver inventory schema was rejected'
host_domain_resolves_to_alias || fail 'route parser rejected the exact configured alias'
mock_resolution="$(printf 'name: %s\nip_address: %s\nip_address: %s' \
  "${HOST_DOMAIN}" "${HOST_ALIAS_IP}" 192.0.2.55)"
resolver_inventory_schema_valid "$mock_resolution" ||
  fail 'valid multi-address resolver inventory schema was rejected'
expect_status 1 host_domain_resolves_to_alias
mock_resolution="$(printf 'name: %s' "${HOST_DOMAIN}")"
expect_status 2 host_domain_resolves_to_alias
mock_resolution="$(printf 'name: %s\nip_address: %s' "${HOST_DOMAIN}" 192.0.2.55)"
expect_status 1 host_domain_resolves_to_alias
for malformed_resolution in \
  '{}' \
  "$(printf 'name: %s\nip_address: {}' "${HOST_DOMAIN}")" \
  "$(printf 'name: {}\nip_address: %s' "${HOST_ALIAS_IP}")" \
  "$(printf 'name: %s\nip_address: %s\nunexpected: value' "${HOST_DOMAIN}" "${HOST_ALIAS_IP}")"; do
  mock_resolution="$malformed_resolution"
  if resolver_inventory_schema_valid "$mock_resolution"; then
    fail "malformed resolver inventory schema was accepted: $mock_resolution"
  fi
  expect_status 2 host_domain_resolves_to_alias
done

mock_resolution="$(printf 'name: %s\nip_address: %s' "${HOST_DOMAIN}" "${HOST_ALIAS_IP}")"
host_route_create >/dev/null
[[ ! -s "${sudo_log}" ]] || fail 'host-route-create recreated an already-correct route'

mock_domain_exists=no
mock_resolution=''
host_route_create >/dev/null
grep -Fxq "container system dns create ${HOST_DOMAIN} --localhost ${HOST_ALIAS_IP}" "${sudo_log}" ||
  fail 'host-route-create did not create the exact configured route'

: > "${sudo_log}"
mock_domain_exists=yes
mock_resolution=$'name: stella-host.container.internal\nip_address: 192.0.2.55'
host_route_refresh 'REFRESH IMESSAGE HOST ROUTE' >/dev/null
grep -Fxq "container system dns delete ${HOST_DOMAIN}" "${sudo_log}" ||
  fail 'host-route-refresh did not delete only the configured route'
grep -Fxq "container system dns create ${HOST_DOMAIN} --localhost ${HOST_ALIAS_IP}" "${sudo_log}" ||
  fail 'host-route-refresh did not recreate the exact configured route'

container_mutation_log="${test_root}/container-mutations.log"
: > "${container_mutation_log}"
containment_log="${test_root}/container-containment.log"
: > "${containment_log}"
(
  IMESSAGE_PROXY_BIND_IP=192.0.2.10
  IMESSAGE_PROXY_CADDY_IMAGE=fixture-image
  export IMESSAGE_PROXY_BIND_IP IMESSAGE_PROXY_CADDY_IMAGE
  require_create_inputs() { :; }
  container_exists() { return 1; }
  wait_for_created_container_definition() { return 1; }
  container() { printf '%s\n' "$*" >> "$containment_log"; }
  expect_failure 'the exact new container was stopped and left intact for inspection' create
)
grep -Fxq 'stop stella' "$containment_log" ||
  fail 'create did not stop its exact new container after post-create validation failed'
(
  IMESSAGE_PROXY_BIND_IP=192.0.2.10
  IMESSAGE_PROXY_CADDY_IMAGE=fixture-image
  export IMESSAGE_PROXY_BIND_IP IMESSAGE_PROXY_CADDY_IMAGE
  require_create_inputs() { :; }
  container_exists() { return 2; }
  container() { printf '%s\n' "$*" >> "${container_mutation_log}"; }
  expect_failure 'could not prove Apple Container stella is absent; refusing container create' create
)
(
  container_exists() { return 2; }
  container() { printf '%s\n' "$*" >> "${container_mutation_log}"; }
  expect_failure 'could not inventory Apple Container stella' require_existing
)
(
  container_state() { printf 'stopped\n'; }
  require_private_bind_ip() { :; }
  require_private_file() { :; }
  container_definition_matches() { return 1; }
  container() { printf '%s\n' "$*" >> "${container_mutation_log}"; }
  expect_failure 'definition does not match the reviewed image, environment, mounts, resources, and private publication' start_facade
)
(
  container_state() { printf 'stopped\n'; }
  require_private_bind_ip() { :; }
  require_private_file() { :; }
  container_definition_matches() { return 2; }
  container() { printf '%s\n' "$*" >> "${container_mutation_log}"; }
  expect_failure 'could not inventory Apple Container stella definition' start_facade
)
(
  container_state() { printf 'unknown\n'; }
  container() { printf '%s\n' "$*" >> "${container_mutation_log}"; }
  expect_failure 'Apple Container stella is unknown; refusing container start' start_facade
  expect_failure 'Apple Container stella is unknown; refusing container stop' stop_facade
)
(
  container_state() { return 2; }
  container() { printf '%s\n' "$*" >> "${container_mutation_log}"; }
  expect_failure 'could not inventory Apple Container stella' start_facade
  expect_failure 'could not inventory Apple Container stella' stop_facade
)
[[ ! -s "${container_mutation_log}" ]] ||
  fail 'container create/start/stop mutated runtime state after an inventory error'

doctor_output=''
if doctor_output="$(
  IMESSAGE_PROXY_API_PORT=invalid \
  IMESSAGE_PROXY_BIND_IP=8.8.8.8 \
  IMESSAGE_PROXY_CADDY_IMAGE=unpinned \
  IMESSAGE_PROXY_ENABLE_ALPHA=invalid \
    doctor 2>&1
)"; then
  fail 'doctor accepted multiple invalid settings'
fi
for expected_diagnostic in \
  'FAIL API or route settings are invalid' \
  'FAIL pinned Caddy image setting is invalid' \
  'FAIL private bind setting or interface assignment is invalid' \
  'FAIL IMESSAGE_PROXY_ENABLE_ALPHA must be yes or no'; do
  grep -Fq "$expected_diagnostic" <<< "$doctor_output" ||
    fail "doctor did not aggregate diagnostic: $expected_diagnostic"
done

printf 'iMessage Proxy CLI lifecycle tests passed.\n'
