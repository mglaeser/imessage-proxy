#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd -P)"
readonly REPO_ROOT
test_root="$(mktemp -d "${TMPDIR:-/tmp}/stella-cli-test.XXXXXX")"
readonly test_root
trap 'rm -rf -- "${test_root}"' EXIT

export HOME="${test_root}/home"
export STELLA_HOME="${test_root}/state"
export STELLA_BRIDGE_PORT=8765

# shellcheck source=../bin/stella
source "${REPO_ROOT}/bin/stella"

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

STELLA_API_HOST=stella.internal
STELLA_API_PORT=9443
export STELLA_API_HOST STELLA_API_PORT
require_api_settings
STELLA_API_PORT=8765
expect_failure 'STELLA_API_PORT must differ from STELLA_BRIDGE_PORT' require_api_settings
STELLA_API_PORT=008765
expect_failure 'canonical base-10 in the range 1024-65535' require_api_settings
STELLA_API_PORT=18446744073709561059
expect_failure 'canonical base-10 in the range 1024-65535' require_api_settings
STELLA_API_PORT=9443

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

printf 'Stella CLI lifecycle tests passed.\n'
