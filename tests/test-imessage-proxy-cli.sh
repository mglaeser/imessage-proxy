#!/usr/bin/env bash
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

require_macos() { :; }
require_container() { :; }
if [[ "$(uname -s)" != Darwin ]]; then
  require_private_file() {
    [[ -f "$1" && ! -L "$1" ]] || die "private file must be a regular non-symlink: $1"
  }
fi
agent_loaded() { return 1; }

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

printf 'operator-owned plist\n' > "${PLIST_TARGET}"
chmod 0600 "${PLIST_TARGET}"
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
host_domain_exists() { [[ "${mock_domain_exists}" == yes ]]; }
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

expect_failure 'exists but does not resolve only to' host_route_create
[[ ! -s "${sudo_log}" ]] || fail 'host-route-create mutated an unexpected existing route'

mock_resolution="$(printf 'name: %s\nip_address: %s' "${HOST_DOMAIN}" "${HOST_ALIAS_IP}")"
host_domain_resolves_to_alias || fail 'route parser rejected the exact configured alias'
mock_resolution="$(printf 'name: %s\nip_address: %s\nip_address: %s' \
  "${HOST_DOMAIN}" "${HOST_ALIAS_IP}" 192.0.2.55)"
if host_domain_resolves_to_alias; then
  fail 'route parser accepted multiple IPv4 results'
fi
mock_resolution="$(printf 'name: %s' "${HOST_DOMAIN}")"
if host_domain_resolves_to_alias; then
  fail 'route parser accepted a missing IPv4 result'
fi

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

printf 'iMessage Proxy CLI lifecycle tests passed.\n'
