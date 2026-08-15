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
  '--port N' \
  '--imsg PATH' \
  '--admin-name NAME' \
  '--expires-in-days N' \
  '--source DIR' \
  '--sha256 HEX' \
  '--send-test ADDRESS' \
  '--no-send-test' \
  '--messages-read' \
  '--no-messages-read' \
  '--self-test'; do
  assert_contains "$expected" "$help_text"
done

expect_failure 'unknown option: --wat' run_installer --wat
expect_failure '--port requires a number' run_installer --port
expect_failure '--sha256 requires a digest' run_installer --sha256
expect_failure '--expires-in-days requires a value' run_installer --expires-in-days
expect_failure '--send-test requires a number or email' run_installer --send-test

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
expect_failure '--port must be in the range 1024-65535' run_installer --port 80
expect_failure '--port must be in the range 1024-65535' run_installer --port 70000
expect_failure '--port must be in the range 1024-65535' run_installer --port eight
expect_failure '--imsg must be an absolute path' run_installer --imsg ./imsg
expect_failure '--prefix must be an absolute path' run_installer --prefix relative/path
expect_failure 'use either --source or --archive, not both' \
  run_installer --source "$REPOSITORY" --archive "$temporary/archive.tar.gz"
# A test-send address is refused while the operator is still at the prompt, not
# by the CLI two commands later.
for bad_target in nope 'chat_id:42' '+0155512345' 'a@b@c' 'has space@example.com'; do
  expect_failure '--send-test must be +digits' run_installer --send-test "$bad_target"
done
# A run that answered both questions on the command line must get past validation
# and fail only on the host check, which is what an unattended install does.
expect_failure 'iMessage Proxy runs only on macOS' \
  run_installer --no-send-test --no-messages-read
expect_failure 'iMessage Proxy runs only on macOS' \
  run_installer --send-test +15551234567 --messages-read

# The installer never enables public HTTPS on its own.
if grep -Eq -- '--public|ENABLE_PUBLIC_HTTPS=yes|EXPOSE IMESSAGE PROXY PUBLICLY' "$INSTALLER"; then
  fail 'installer must never enable or confirm public exposure'
fi

# The generated configuration must define exactly the keys the CLI allowlists,
# with the exposure gate closed.
for expected_key in \
  IMESSAGE_PROXY_PORT \
  IMESSAGE_PROXY_IMSG_BIN \
  IMESSAGE_PROXY_IMSG_SHA256; do
  grep -Fq "$expected_key=" "$INSTALLER" ||
    fail "installer never writes the required config key: $expected_key"
done

# The API key must stay on stdout only; the installer must not capture or store it.
# shellcheck disable=SC2016  # the pattern intentionally matches literal shell syntax
if grep -Eq '\$\("\$cli" bootstrap|key=\$\(' "$INSTALLER"; then
  fail 'installer must not capture the administrator key'
fi

# Pinned dependency expectations must match the product CLI.
pin="readonly EXPECTED_IMSG_VERSION='$(awk -F"'" '/^readonly EXPECTED_IMSG_VERSION=/ {print $2}' "$REPOSITORY/bin/imessage-proxy")'"
grep -Fq "$pin" "$INSTALLER" ||
  fail "installer dependency pin disagrees with the CLI: $pin"

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
# The public-HTTPS prompts are gone for good; the two questions that remain are
# about this Mac, not about publishing it.
if grep -Eq "prompt_for_value|Service hostname|Operator email" "$INSTALLER"; then
  fail 'installer still prompts for the removed public-HTTPS values'
fi

# The send target is validated by the same rule the CLI and the server use, so an
# address the installer accepts is one a send accepts.
for good_target in +15551234567 +447700900123 name@example.com; do
  bash -c "source '$INSTALLER'; send_target_valid \"\$1\"" _ "$good_target" ||
    fail "send_target_valid rejected a legitimate address: $good_target"
done
for bad_target in '' ' ' -15551234567 '+0155512345' '+15551' 'a@b@c' '@leading' 'trailing@' 'chat_id:42'; do
  bash -c "source '$INSTALLER'; send_target_valid \"\$1\"" _ "$bad_target" &&
    fail "send_target_valid accepted an invalid address: ${bad_target:-<empty>}"
done

# Both questions must be answerable without a terminal, and a run that still has
# one to ask must say which flags answer it rather than dying on a bare tty test.
answered="$(
  bash -c "
    source '$INSTALLER'
    terminal_available() { return 1; }
    send_test=no
    messages_read=disabled
    require_terminal
    printf 'no terminal needed\n'
  "
)" || fail 'an answered run refused to install without a terminal'
[[ "$answered" == 'no terminal needed' ]] ||
  fail "an answered run still demanded a terminal: $answered"
unanswered="$(
  bash -c "
    source '$INSTALLER'
    terminal_available() { return 1; }
    require_terminal
  " 2>&1 || true
)"
assert_contains '--send-test' "$unanswered"
assert_contains '--no-messages-read' "$unanswered"

# A stub CLI records what the installer asks of it, so the order of the send
# proof and the send-only rollout can be asserted off a Mac.
stub_cli="$temporary/imessage-proxy"
cat > "$stub_cli" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 ${2:-}" in
  'targets list') printf '%s\n' "${STUB_TARGETS:-}" ;;
  'send-test '*) exit "${STUB_SEND_STATUS:-0}" ;;
  'server-status '*|'server-status') exit "${STUB_STATUS_STATUS:-0}" ;;
esac
exit 0
STUB
chmod +x "$stub_cli"

stub_log() {
  : > "$temporary/stub.log"
  printf '%s\n' "$temporary/stub.log"
}

# The address is put on the send allowlist first: the service refuses every
# target that is not on it, so the one command meant to prove the install works
# would otherwise be the one that fails.
log="$(stub_log)"
STUB_LOG="$log" bash -c "
  source '$INSTALLER'
  send_test=yes
  send_test_target=+15551234567
  offer_test_send '$stub_cli'
" > /dev/null 2>&1 || fail 'a requested test send did not complete'
[[ "$(< "$log")" == $'targets list\ntargets add +15551234567\nsend-test +15551234567' ]] ||
  fail "the test send did not allow the address before sending: $(< "$log")"

# An address already on the allowlist must not be added again: `targets add`
# refuses a duplicate, and that refusal is not a failed install.
log="$(stub_log)"
STUB_LOG="$log" STUB_TARGETS='+15551234567' bash -c "
  source '$INSTALLER'
  send_test=yes
  send_test_target=+15551234567
  offer_test_send '$stub_cli'
" > /dev/null 2>&1 || fail 'a test send to an already allowed address failed'
[[ "$(< "$log")" == $'targets list\nsend-test +15551234567' ]] ||
  fail "an already allowed address was added again: $(< "$log")"

# A refused Messages prompt is a fact about this Mac, not a broken install: the
# run reports it, names the retry, and finishes.
log="$(stub_log)"
send_failure="$(
  STUB_LOG="$log" STUB_SEND_STATUS=1 bash -c "
    source '$INSTALLER'
    send_test=yes
    send_test_target=+15551234567
    offer_test_send '$stub_cli'
  " 2>&1
)" || fail 'a failed test send aborted the installation'
assert_contains 'imessage-proxy send-test +15551234567' "$send_failure"

# --no-send-test must skip without touching the CLI at all.
log="$(stub_log)"
skipped="$(
  STUB_LOG="$log" bash -c "
    source '$INSTALLER'
    send_test=no
    offer_test_send '$stub_cli'
  " 2>&1
)" || fail 'skipping the test send failed'
[[ ! -s "$log" ]] || fail "a skipped test send still called the CLI: $(< "$log")"
assert_contains 'imessage-proxy send-test YOUR-NUMBER-OR-EMAIL' "$skipped"

# The operator must be warned about the Messages permission before being asked
# for an address, not after they have already committed one.
log="$(stub_log)"
warning_first="$(
  STUB_LOG="$log" bash -c "
    source '$INSTALLER'
    ask_line() { printf '  %s' \"\$1\" >&2; printf '\n'; }
    send_test=ask
    offer_test_send '$stub_cli'
  " 2>&1
)"
# Tolerant of a missing line on purpose: pipefail would otherwise abort the whole
# suite here with no message, exactly when this assertion has something to say.
warning_line="$(printf '%s\n' "$warning_first" | grep -n 'allow control of Messages' | head -1 | cut -d: -f1 || true)"
address_line="$(printf '%s\n' "$warning_first" | grep -n 'for a test message' | head -1 | cut -d: -f1 || true)"
[[ -n "$warning_line" && -n "$address_line" ]] ||
  fail 'the test send offer no longer warns about the Messages permission'
((warning_line < address_line)) ||
  fail 'the installer asks for an address before warning about the permission prompt'

# Enter, or no terminal at all, leaves reading off. Reading is a broad grant and
# is never taken by default.
for stubbed_answer in '' n no; do
  resolved="$(
    bash -c "
      source '$INSTALLER'
      ask_line() { printf '%s\n' '$stubbed_answer'; }
      messages_read=ask
      offer_messages_read > /dev/null 2>&1
      printf '%s\n' \"\$messages_read\"
    "
  )"
  [[ "$resolved" == disabled ]] ||
    fail "answering '${stubbed_answer:-<empty>}' left reading $resolved"
done
for stubbed_answer in y Y yes YES; do
  resolved="$(
    bash -c "
      source '$INSTALLER'
      ask_line() { printf '%s\n' '$stubbed_answer'; }
      terminal_available() { return 1; }
      messages_read=ask
      offer_messages_read > /dev/null 2>&1
      printf '%s\n' \"\$messages_read\"
    "
  )"
  [[ "$resolved" == enabled ]] ||
    fail "answering '$stubbed_answer' left reading $resolved"
done

# The Full Disk Access grant belongs to the binary launchd runs. Naming a
# terminal instead would send the operator to grant a process that never opens
# the database.
grant_text="$(
  bash -c "
    source '$INSTALLER'
    terminal_available() { return 1; }
    HOME=/Users/probe
    print_full_disk_access_instructions
  " 2>&1
)"
# shellcheck disable=SC2088  # the tilde is printed to the operator, not expanded
assert_contains '~/Library/Messages/chat.db' "$grant_text"
assert_contains 'System Settings > Privacy & Security > Full Disk Access' "$grant_text"
assert_contains '/Users/probe/Library/Application Support/iMessage Proxy/state/bin/imessage-proxy-server' \
  "$grant_text"
if printf '%s\n' "$grant_text" | grep -Eqi 'add your terminal|Terminal\.app|parent launcher'; then
  fail 'the Full Disk Access instructions send the operator to grant a terminal'
fi

# The grant checkpoint pauses for somebody who is reading it, and only for them:
# a run that answered with --messages-read has nobody at the terminal to press
# Enter, and must not wait for one.
checkpoint_skipped="$(
  bash -c "
    source '$INSTALLER'
    terminal_available() { return 0; }
    ask_line() { printf 'PAUSED\n' >&2; printf '\n'; }
    messages_read=enabled
    offer_messages_read
  " 2>&1
)"
if printf '%s\n' "$checkpoint_skipped" | grep -Fq PAUSED; then
  fail 'a flag-answered run still waited at the Full Disk Access checkpoint'
fi
assert_contains 'Full Disk Access' "$checkpoint_skipped"
checkpoint_shown="$(
  bash -c "
    source '$INSTALLER'
    terminal_available() { return 0; }
    ask_line() { printf 'ASKED:%s\n' \"\$1\" >&2; printf 'y\n'; }
    messages_read=ask
    offer_messages_read
  " 2>&1
)"
assert_contains 'ASKED:Press Enter when you have added it' "$checkpoint_shown"

# Declining reading is a complete installation. The service reads the switch once
# at start from the plist its LaunchAgent carries, so the setting has to be
# recorded, the plist rendered again and the service brought back up - and
# prepare refuses to render while it is loaded.
log="$(stub_log)"
STUB_LOG="$log" bash -c "
  source '$INSTALLER'
  apply_send_only '$stub_cli'
" > /dev/null 2>&1 || fail 'declining to read Messages did not complete'
[[ "$(< "$log")" == $'disable-messages-read --confirm DISABLE MESSAGES READ\nserver-stop --confirm STOP IMESSAGE PROXY SERVER\nprepare\nserver-install' ]] ||
  fail "the send-only rollout is in the wrong order: $(< "$log")"


# Build noise must be collapsible, and recoverable when a step fails.
grep -Fq 'run_quietly' "$INSTALLER" ||
  fail 'installer does not group build output behind progress lines'
grep -Fq -- '--verbose' "$INSTALLER" ||
  fail 'installer does not offer --verbose'
for quiet_step in 'Compiling the native server' 'Installing the CLI and reviewed assets'; do
  grep -Fq "$quiet_step" "$INSTALLER" || fail "installer does not announce: $quiet_step"
done

# The completion summary has to carry the facts an operator needs next.
for summary in 'OPEN THE CONSOLE' 'OR CALL THE API' 'UNINSTALL' 'READING YOUR MESSAGES' 'YOUR PATH' \
  'YOUR ADMINISTRATOR KEY'; do
  grep -Fq "$summary" "$INSTALLER" || fail "completion summary omits: $summary"
done
# Declining reading must finish as a supported configuration, naming what is off
# and the one command that turns it on, not as a warning about a broken install.
grep -Fq 'imessage-proxy enable-messages-read' "$INSTALLER" ||
  fail 'the summary never names the command that turns reading on'
grep -Fq 'messages-read-disabled' "$INSTALLER" ||
  fail 'the summary never names what a send-only installation refuses'
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

# The README leads with the one-liner and delegates the long form to docs, so
# that the front page stays short enough to actually be read.
readme_oneliner="$(grep -n 'scripts/install.sh | bash' "$REPOSITORY/README.md" | head -1 | cut -d: -f1)"
[[ -n "$readme_oneliner" ]] || fail 'README does not advertise the installer one-liner'
((readme_oneliner < 60)) ||
  fail "README buries the one-liner at line $readme_oneliner"
grep -Fq 'docs/install.md' "$REPOSITORY/README.md" ||
  fail 'README does not link to the install guide'
[[ "$(grep -c '' "$REPOSITORY/README.md")" -le 220 ]] ||
  fail "README has grown back to $(grep -c '' "$REPOSITORY/README.md") lines"

# Re-running the installer over a live service refreshes the CLI in place and
# returns early without rendering the LaunchAgent. When the refreshed CLI would
# render a different one - this release adds an environment key to it - every
# lifecycle command refuses until it is staged again, so the report must not
# send the operator to a command that is about to fail on a healthy service.
log="$(stub_log)"
current="$(
  STUB_LOG="$log" bash -c "
    source '$INSTALLER'
    report_existing_installation '$stub_cli'
  " 2>&1
)" || fail 'reporting an existing installation failed'
assert_contains 'server-status' "$current"
if [[ "$current" == *'no longer matches'* ]]; then
  fail "a current installation was reported as needing a re-render: $current"
fi

log="$(stub_log)"
stale="$(
  STUB_LOG="$log" STUB_STATUS_STATUS=1 bash -c "
    source '$INSTALLER'
    report_existing_installation '$stub_cli'
  " 2>&1
)" || fail 'reporting a stale LaunchAgent failed the installation'
assert_contains 'no longer matches' "$stale"
for expected in \
  "server-stop --confirm 'STOP IMESSAGE PROXY SERVER'" \
  'imessage-proxy prepare' \
  'imessage-proxy server-install'; do
  assert_contains "$expected" "$stale"
done
# The command that cannot work must not also be recommended.
if [[ "$stale" == *'Check it, or create more keys'* ]]; then
  fail "a stale LaunchAgent was still reported with the server-status suggestion: $stale"
fi
[[ "$(< "$log")" == 'server-status' ]] ||
  fail "the report must ask the CLI rather than guess: $(< "$log")"

printf '%s\n' 'iMessage Proxy installer tests passed.'
