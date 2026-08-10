#!/usr/bin/env bash
#
# Behavior tests for the one-command installer. These exercise argument
# handling, validation, and the fail-closed paths that run before any host
# state changes, so they stay portable across macOS and Linux.

set -Eeuo pipefail

REPOSITORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPOSITORY
readonly INSTALLER="$REPOSITORY/scripts/install.sh"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$2" needle="$1"
  [[ "$haystack" == *"$needle"* ]] || fail "output does not contain: $needle"
}

expect_failure() {
  local expected="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  assert_contains "$expected" "$output"
}

run_installer() {
  bash "$INSTALLER" "$@"
}

[[ -x "$INSTALLER" ]] || fail 'installer is not executable'
bash -n "$INSTALLER" || fail 'installer is not valid bash'

# The installer must run identically as a file and as `curl ... | bash`, where
# BASH_SOURCE is unset.
self_test_output="$(run_installer --self-test 2>&1)" ||
  fail 'installer self-test failed'
assert_contains 'installer self-test passed' "$self_test_output"
piped_output="$(bash -s -- --self-test < "$INSTALLER" 2>&1)" ||
  fail 'installer self-test failed when piped to bash'
assert_contains 'installer self-test passed' "$piped_output"

help_text="$(run_installer --help 2>&1)"
for expected in \
  '--host HOSTNAME' \
  '--imsg PATH' \
  '--caddy PATH' \
  '--admin-name NAME' \
  '--expires-in-days N' \
  '--source DIR' \
  '--sha256 HEX' \
  '--self-test'; do
  assert_contains "$expected" "$help_text"
done

expect_failure 'unknown option: --wat' run_installer --wat
expect_failure '--host requires a hostname' run_installer --host
expect_failure '--sha256 requires a digest' run_installer --sha256
expect_failure '--expires-in-days requires a value' run_installer --expires-in-days

# Argument validation must fail before the installer touches the host.
expect_failure '--admin-name must contain 1-80 printable ASCII bytes' \
  run_installer --admin-name ' leading'
expect_failure '--expires-in-days must be in the range 1-365' \
  run_installer --expires-in-days 0
expect_failure '--expires-in-days must be in the range 1-365' \
  run_installer --expires-in-days 366
expect_failure '--tag must have the form vMAJOR.MINOR.PATCH' \
  run_installer --tag latest
expect_failure '--sha256 must be a 64-character lowercase SHA-256 digest' \
  run_installer --sha256 deadbeef
expect_failure '--host must be an explicit lowercase public DNS hostname' \
  run_installer --host localhost
expect_failure '--host must be an explicit lowercase public DNS hostname' \
  run_installer --host messages.example.com
expect_failure '--email must be a valid operator address on a public domain' \
  run_installer --email operator@localhost
expect_failure '--imsg must be an absolute path' run_installer --imsg ./imsg
expect_failure '--caddy must be an absolute path' run_installer --caddy ../caddy
expect_failure '--prefix must be an absolute path' run_installer --prefix relative/path
expect_failure 'use either --source or --archive, not both' \
  run_installer --source "$REPOSITORY" --archive "$temporary/archive.tar.gz"

# The installer never enables public HTTPS on its own.
if grep -Eq -- '--public|ENABLE_PUBLIC_HTTPS=yes|EXPOSE IMESSAGE PROXY PUBLICLY' "$INSTALLER"; then
  fail 'installer must never enable or confirm public exposure'
fi

# The generated configuration must define exactly the keys the CLI allowlists,
# with the exposure gate closed.
for expected_key in \
  IMESSAGE_PROXY_API_HOST \
  IMESSAGE_PROXY_ACME_EMAIL \
  IMESSAGE_PROXY_PUBLIC_BIND \
  IMESSAGE_PROXY_HTTP_PORT \
  IMESSAGE_PROXY_HTTPS_PORT \
  IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS \
  IMESSAGE_PROXY_IMSG_BIN \
  IMESSAGE_PROXY_IMSG_SHA256 \
  IMESSAGE_PROXY_CADDY_BIN \
  IMESSAGE_PROXY_CADDY_SHA256; do
  grep -Fq "$expected_key=" "$INSTALLER" ||
    fail "installer never writes the required config key: $expected_key"
done
grep -Fq 'IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no' "$INSTALLER" ||
  fail 'installer must write a closed public-exposure gate'

# The API key must stay on stdout only; the installer must not capture or store it.
# shellcheck disable=SC2016  # the pattern intentionally matches literal shell syntax
if grep -Eq '\$\("\$cli" bootstrap|key=\$\(' "$INSTALLER"; then
  fail 'installer must not capture the administrator key'
fi

# Pinned dependency expectations must match the product CLI.
for pin in \
  "readonly EXPECTED_IMSG_VERSION='$(awk -F"'" '/^readonly EXPECTED_IMSG_VERSION=/ {print $2}' "$REPOSITORY/bin/imessage-proxy")'" \
  "readonly EXPECTED_CADDY_VERSION='$(awk -F"'" '/^readonly EXPECTED_CADDY_VERSION=/ {print $2}' "$REPOSITORY/bin/imessage-proxy")'"; do
  grep -Fq "$pin" "$INSTALLER" ||
    fail "installer dependency pin disagrees with the CLI: $pin"
done

# The advertised default release must track VERSION.
grep -Fq "readonly DEFAULT_RELEASE_TAG='v$(< "$REPOSITORY/VERSION")'" "$INSTALLER" ||
  fail 'installer default release tag does not match VERSION'

# README must advertise the one-liner before any manual instructions.
readme_oneliner="$(grep -n 'scripts/install.sh | bash' "$REPOSITORY/README.md" | head -1 | cut -d: -f1)"
readme_manual="$(grep -n '^## Install and run manually' "$REPOSITORY/README.md" | head -1 | cut -d: -f1)"
[[ -n "$readme_oneliner" ]] || fail 'README does not advertise the installer one-liner'
[[ -n "$readme_manual" ]] || fail 'README is missing the manual installation section'
((readme_oneliner < readme_manual)) ||
  fail 'README must present the one-liner before the manual instructions'

printf '%s\n' 'iMessage Proxy installer tests passed.'
