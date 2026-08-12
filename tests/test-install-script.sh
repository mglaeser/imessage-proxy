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

# By default the installer must install the branch carrying the 1.0
# architecture, not a published release that predates it.
resolved_endpoint="$(bash -c "source '$INSTALLER'; printf '%s' \"\$REPOSITORY_API\"")"
[[ "$resolved_endpoint" == 'https://api.github.com/repos/mglaeser/imessage-proxy' ]] ||
  fail "installer resolves an unexpected repository endpoint: $resolved_endpoint"
resolved_endpoint="$(bash -c "source '$INSTALLER'; printf '%s' \"\$SOURCE_ARCHIVE_BASE_URL\"")"
[[ "$resolved_endpoint" == 'https://codeload.github.com/mglaeser/imessage-proxy/tar.gz' ]] ||
  fail "installer resolves an unexpected source-archive endpoint: $resolved_endpoint"
[[ "$(bash -c "source '$INSTALLER'; printf '%s' \"\$SOURCE_BRANCH\"")" == main ]] ||
  fail 'installer does not default to the main branch'
if grep -q 'DEFAULT_RELEASE_TAG' "$INSTALLER"; then
  fail 'installer must not hard-code a default release tag'
fi

# The JSON field parser must accept real GitHub metadata and invent nothing.
parsed_sha="$(printf '%s' '{"sha":"0123456789abcdef0123456789abcdef01234567","x":1}' |
  bash -c "source '$INSTALLER'; parse_json_string_field sha")"
[[ "$parsed_sha" == 0123456789abcdef0123456789abcdef01234567 ]] ||
  fail "commit parser returned: $parsed_sha"
parsed_sha="$(printf '%s' '{"name":"no sha"}' |
  bash -c "source '$INSTALLER'; parse_json_string_field sha")"
[[ -z "$parsed_sha" ]] || fail 'commit parser invented a value'

# The downloaded tree must be proven to be the resolved commit, and releases
# without the bootstrap action must be refused rather than half-installed.
grep -Fq 'REVISION' "$INSTALLER" ||
  fail 'installer does not verify the archive REVISION against the resolved commit'
grep -Fq 'require_bootstrap_capable_cli' "$INSTALLER" ||
  fail 'installer does not reject releases lacking the bootstrap action'

# imsg must be installed automatically, pinned by digest, with its full payload.
grep -Fq 'install_pinned_imsg' "$INSTALLER" ||
  fail 'installer does not install imsg automatically'
imsg_digest="$(bash -c "source '$INSTALLER'; printf '%s' \"\$IMSG_ARCHIVE_SHA256\"")"
[[ "$imsg_digest" =~ ^[0-9a-f]{64}$ ]] ||
  fail "pinned imsg digest is not a SHA-256: $imsg_digest"
imsg_expected_version="$(bash -c "source '$INSTALLER'; printf '%s' \"\$EXPECTED_IMSG_VERSION\"")"
grep -Fq "readonly EXPECTED_IMSG_VERSION='$imsg_expected_version'" "$REPOSITORY/bin/imessage-proxy" ||
  fail 'installer imsg version pin disagrees with the CLI'

# A symlinked imsg (for example a Homebrew shim) must resolve, not be rejected.
grep -Fq 'resolve_real_path' "$INSTALLER" ||
  fail 'installer does not resolve a symlinked --imsg to its real target'
ln -sf /bin/sh "$temporary/imsg-shim"
resolved_link="$(bash -c "source '$INSTALLER'; resolve_real_path '$temporary/imsg-shim'")"
[[ -n "$resolved_link" && ! -L "$resolved_link" ]] ||
  fail "symlink resolution returned an unusable path: $resolved_link"

# A private install must be able to decline public identity, and the placeholder
# it records must be the exact value the CLI accepts while the gate is closed.
# If these two drift, the installer writes a config its own product refuses.
for placeholder in PLACEHOLDER_API_HOST PLACEHOLDER_ACME_EMAIL; do
  installer_value="$(bash -c "source '$INSTALLER'; printf '%s' \"\$$placeholder\"")"
  [[ -n "$installer_value" ]] || fail "installer does not define $placeholder"
  [[ "$installer_value" == *.invalid ]] ||
    fail "$placeholder must sit in the reserved .invalid namespace: $installer_value"
  grep -Fq "readonly $placeholder='$installer_value'" "$REPOSITORY/bin/imessage-proxy" ||
    fail "installer $placeholder disagrees with the CLI"
done
grep -Fq 'Enter to skip' "$INSTALLER" ||
  fail 'installer does not offer to skip the public identity prompts'

# Build noise must be collapsible, and recoverable when a step fails.
grep -Fq 'run_quietly' "$INSTALLER" ||
  fail 'installer does not group build output behind progress lines'
grep -Fq -- '--verbose' "$INSTALLER" ||
  fail 'installer does not offer --verbose'
for quiet_step in 'Compiling the native server' 'Installing the CLI and reviewed assets'; do
  grep -Fq "$quiet_step" "$INSTALLER" || fail "installer does not announce: $quiet_step"
done

# The completion summary has to carry the facts an operator needs next.
for summary in 'ADMINISTRATOR KEY' 'WHERE THINGS ARE' 'HOW TO REACH IT' 'NEXT' 'UNINSTALL' 'YOUR PATH'; do
  grep -Fq "$summary" "$INSTALLER" || fail "completion summary omits: $summary"
done
grep -Fq 'scripts/uninstall.sh | bash' "$INSTALLER" ||
  fail 'completion summary does not offer the uninstall one-liner'
grep -Fq 'ensure_path_entry' "$INSTALLER" ||
  fail 'installer does not add its own prefix to PATH'

# PATH handling must be idempotent: a second install must not append again.
path_probe="$temporary/path-probe"
mkdir -p "$path_probe"
printf '%s\n' '# existing profile' > "$path_probe/.zshrc"
path_script="$(
  cat <<'PROBE'
source "$INSTALLER_PATH"
HOME="$PROBE_HOME"
SHELL=/bin/zsh
install_prefix="$PROBE_HOME/.local"
PATH=/usr/bin:/bin
ensure_path_entry
printf '%s\n' "$path_result"
ensure_path_entry
printf '%s\n' "$path_result"
PROBE
)"
path_output="$(INSTALLER_PATH="$INSTALLER" PROBE_HOME="$path_probe" bash -c "$path_script")"
[[ "$path_output" == $'added\npending' ]] ||
  fail "PATH handling is not idempotent, got: ${path_output//$'\n'/ }"
[[ "$(grep -c 'export PATH=' "$path_probe/.zshrc")" -eq 1 ]] ||
  fail 'a second install appended a duplicate PATH line'

# The installer replaces PATH with a hardened list for its own subprocesses, so
# the prefix check has to consult the operator's inherited PATH. Reading the
# hardened value instead makes "already on your PATH" unreachable for the default
# prefix and writes an export to a startup file that did not need one.
grep -Fq 'OPERATOR_PATH' "$INSTALLER" ||
  fail 'installer does not capture the operator PATH before hardening its own'

# The prefix is written into a shell startup file, where it outlives the
# installer and is re-evaluated by every later shell. A quote there stops being a
# path and becomes code that runs forever, so it must be refused at parse time
# and quoted at write time.
# These are literal injection payloads, not expressions to expand.
# shellcheck disable=SC2016
for unsafe_prefix in '/tmp/a";touch /tmp/pwned;"' "/tmp/a';id;'" '/tmp/a$(id)' '/tmp/a`id`' '/tmp/a;id' '/tmp/a\b'; do
  bash -c "source '$INSTALLER'; prefix_is_safe \"\$1\"" _ "$unsafe_prefix" &&
    fail "prefix_is_safe accepted an injectable prefix: $unsafe_prefix"
done
for safe_prefix in /Users/kleo/.local '/Users/first last/.local' /opt/imessage-proxy; do
  bash -c "source '$INSTALLER'; prefix_is_safe \"\$1\"" _ "$safe_prefix" ||
    fail "prefix_is_safe rejected a legitimate prefix: $safe_prefix"
done
# ensure_path_entry must refuse an injectable prefix itself, so no future caller
# that skips validate_arguments can write one, and must leave the file untouched.
injection_probe="$temporary/injection"
mkdir -p "$injection_probe"
: > "$injection_probe/.zshrc"
injection_result="$(
  INSTALLER_PATH="$INSTALLER" PROBE_HOME="$injection_probe" bash -c '
    source "$INSTALLER_PATH"
    HOME="$PROBE_HOME"
    SHELL=/bin/zsh
    install_prefix="/tmp/evil\";/usr/bin/touch $PROBE_HOME/PWNED;\""
    ensure_path_entry
    printf "%s\n" "$path_result"
  '
)"
[[ "$injection_result" == unsafe-prefix ]] ||
  fail "ensure_path_entry accepted an injectable prefix: $injection_result"
[[ ! -s "$injection_probe/.zshrc" ]] ||
  fail "an injectable prefix was written to a startup file: $(< "$injection_probe/.zshrc")"

# A legitimate prefix containing a space must still be written, and what lands in
# the startup file must parse as shell and expand to the intended directory.
space_probe="$temporary/path-space"
mkdir -p "$space_probe"
: > "$space_probe/.zshrc"
INSTALLER_PATH="$INSTALLER" PROBE_HOME="$space_probe" bash -c '
  source "$INSTALLER_PATH"
  HOME="$PROBE_HOME"
  SHELL=/bin/zsh
  install_prefix="/opt/first last"
  ensure_path_entry
' > /dev/null
bash -n "$space_probe/.zshrc" ||
  fail 'the PATH line written to a startup file is not valid shell'
expanded="$(PATH=/usr/bin:/bin bash -c "source '$space_probe/.zshrc'; printf '%s' \"\$PATH\"")"
[[ "$expanded" == '/opt/first last/bin:/usr/bin:/bin' ]] ||
  fail "the written PATH line does not expand to the install prefix: $expanded"
path_already_probe="$temporary/path-already"
mkdir -p "$path_already_probe"
: > "$path_already_probe/.zshrc"
path_already_output="$(
  INSTALLER_PATH="$INSTALLER" PROBE_HOME="$path_already_probe" \
    PATH="$path_already_probe/.local/bin:/usr/bin:/bin" bash -c '
      source "$INSTALLER_PATH"
      HOME="$PROBE_HOME"
      SHELL=/bin/zsh
      install_prefix="$PROBE_HOME/.local"
      ensure_path_entry
      printf "%s\n" "$path_result"
    '
)"
[[ "$path_already_output" == already ]] ||
  fail "an operator PATH already containing the prefix reported: $path_already_output"
[[ ! -s "$path_already_probe/.zshrc" ]] ||
  fail 'the installer edited a startup file that already had the prefix on PATH'

# README must advertise the one-liner before any manual instructions.
readme_oneliner="$(grep -n 'scripts/install.sh | bash' "$REPOSITORY/README.md" | head -1 | cut -d: -f1)"
readme_manual="$(grep -n '^## Install and run manually' "$REPOSITORY/README.md" | head -1 | cut -d: -f1)"
[[ -n "$readme_oneliner" ]] || fail 'README does not advertise the installer one-liner'
[[ -n "$readme_manual" ]] || fail 'README is missing the manual installation section'
((readme_oneliner < readme_manual)) ||
  fail 'README must present the one-liner before the manual instructions'

printf '%s\n' 'iMessage Proxy installer tests passed.'
