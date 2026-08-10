#!/usr/bin/env bash
#
# Behavior tests for the uninstaller. These exercise argument handling and the
# path guards that decide what may be deleted, so they stay portable across
# macOS and Linux and never touch real installation state.

set -Eeuo pipefail

REPOSITORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPOSITORY
readonly UNINSTALLER="$REPOSITORY/scripts/uninstall.sh"
readonly PURGE_PHRASE='DESTROY IMESSAGE PROXY STATE'
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

run_uninstaller() {
  bash "$UNINSTALLER" "$@"
}

# Evaluate one of the script's own predicates against a candidate path.
predicate_accepts() {
  local candidate="$3" home="$2" predicate="$1"
  HOME="$home" bash -c "source '$UNINSTALLER'; $predicate \"\$1\"" _ "$candidate"
}

[[ -x "$UNINSTALLER" ]] || fail 'uninstaller is not executable'
bash -n "$UNINSTALLER" || fail 'uninstaller is not valid bash'

# It must behave identically as a file and when piped to bash.
self_test_output="$(run_uninstaller --self-test 2>&1)" ||
  fail 'uninstaller self-test failed'
assert_contains 'uninstaller self-test passed' "$self_test_output"
piped_output="$(bash -s -- --self-test < "$UNINSTALLER" 2>&1)" ||
  fail 'uninstaller self-test failed when piped to bash'
assert_contains 'uninstaller self-test passed' "$piped_output"

help_text="$(run_uninstaller --help 2>&1)"
for expected in \
  '--dry-run' \
  '--purge' \
  '--confirm TEXT' \
  '--include-legacy' \
  '--prefix DIR' \
  '--yes' \
  '--self-test' \
  "$PURGE_PHRASE"; do
  assert_contains "$expected" "$help_text"
done

expect_failure 'unknown option: --wat' run_uninstaller --wat
expect_failure '--confirm requires a value' run_uninstaller --confirm
expect_failure '--prefix requires a directory' run_uninstaller --prefix

# Destroying state must require the exact confirmation, and the confirmation
# must be meaningless without it. These run before any host inspection.
expect_failure "--purge requires --confirm '$PURGE_PHRASE'" run_uninstaller --purge
expect_failure "--purge requires --confirm '$PURGE_PHRASE'" \
  run_uninstaller --purge --confirm 'destroy imessage proxy state'
expect_failure "--purge requires --confirm '$PURGE_PHRASE'" \
  run_uninstaller --purge --confirm 'yes'
expect_failure '--confirm is accepted only together with --purge' \
  run_uninstaller --confirm "$PURGE_PHRASE"
expect_failure '--prefix must be an absolute path' run_uninstaller --prefix relative/path

# A --purge run that passes validation still must not proceed without a
# platform check; on Linux that is the next gate.
if [[ "$(uname -s)" != Darwin ]]; then
  expect_failure 'iMessage Proxy runs only on macOS' \
    run_uninstaller --dry-run --yes
fi

# Only paths strictly below a sane HOME may ever be removed.
home_root="$temporary/home"
mkdir -p "$home_root/.local/bin" "$home_root/.local/libexec/imessage-proxy"
for allowed in \
  "$home_root/.local/bin/imessage-proxy" \
  "$home_root/.local/share/imessage-proxy" \
  "$home_root/.local/libexec/imessage-proxy" \
  "$home_root/.config/imessage-proxy" \
  "$home_root/Library/LaunchAgents/io.github.mglaeser.imessage-proxy.plist" \
  "$home_root/Library/Application Support/iMessage Proxy"; do
  predicate_accepts path_is_removable "$home_root" "$allowed" ||
    fail "uninstaller refuses a path it must be able to remove: $allowed"
done
for refused in \
  / \
  /etc \
  /etc/passwd \
  "$temporary/outside" \
  "$home_root" \
  "$home_root/../elsewhere" \
  "$home_root/.local/../../etc" \
  "$home_root/.local//bin" \
  "$home_root/.local/./bin" \
  "$home_root/.local/bin/"; do
  if predicate_accepts path_is_removable "$home_root" "$refused"; then
    fail "uninstaller would accept an unsafe removal target: $refused"
  fi
done

# Shared parents are never owned exclusively by this project.
for shared in \
  "$home_root" \
  "$home_root/Library" \
  "$home_root/Library/LaunchAgents" \
  "$home_root/Library/Application Support" \
  "$home_root/.config" \
  "$home_root/.local" \
  "$home_root/.local/bin" \
  "$home_root/.local/share" \
  "$home_root/.local/libexec" \
  "$home_root/.local/src"; do
  predicate_accepts path_is_protected "$home_root" "$shared" ||
    fail "uninstaller fails to protect a shared directory: $shared"
done
for owned in \
  "$home_root/.local/bin/imessage-proxy" \
  "$home_root/.local/share/imessage-proxy" \
  "$home_root/.local/libexec/imessage-proxy" \
  "$home_root/.config/imessage-proxy"; do
  if predicate_accepts path_is_protected "$home_root" "$owned"; then
    fail "uninstaller over-protects a path it installed: $owned"
  fi
done

# A purge must refuse a runtime root that is not the documented one, so a
# stray IMESSAGE_PROXY_HOME cannot redirect the deletion.
for expected_root in \
  '/Users/example/Library/Application Support/iMessage Proxy' \
  '/Users/example/state/imessage-proxy'; do
  HOME="$home_root" bash -c \
    "source '$UNINSTALLER'; runtime_root_is_expected \"\$1\"" _ "$expected_root" ||
    fail "uninstaller rejects a documented runtime root: $expected_root"
done
for unexpected_root in \
  '/Users/example' \
  '/Users/example/Documents' \
  '/Users/example/Library/Application Support'; do
  if HOME="$home_root" bash -c \
    "source '$UNINSTALLER'; runtime_root_is_expected \"\$1\"" _ "$unexpected_root"; then
    fail "uninstaller accepts an unexpected runtime root: $unexpected_root"
  fi
done

# ~/.local/bin/imsg is removed only when it points into our own payload.
ln -sfn "$home_root/.local/libexec/imessage-proxy/imsg-0.13.4/imsg" "$home_root/.local/bin/imsg"
HOME="$home_root" bash -c \
  "source '$UNINSTALLER'; imsg_link_is_managed \"\$1\" \"\$2\"" \
  _ "$home_root/.local/bin/imsg" "$home_root/.local" ||
  fail 'uninstaller does not recognize the imsg link it created'
ln -sfn /opt/homebrew/bin/imsg "$home_root/.local/bin/imsg"
if HOME="$home_root" bash -c \
  "source '$UNINSTALLER'; imsg_link_is_managed \"\$1\" \"\$2\"" \
  _ "$home_root/.local/bin/imsg" "$home_root/.local"; then
  fail 'uninstaller claims an imsg link it did not create'
fi
printf 'x' > "$home_root/.local/bin/plain-imsg"
if HOME="$home_root" bash -c \
  "source '$UNINSTALLER'; imsg_link_is_managed \"\$1\" \"\$2\"" \
  _ "$home_root/.local/bin/plain-imsg" "$home_root/.local"; then
  fail 'uninstaller claims a regular file as its own link'
fi

# Deletion must flow through the guarded helper, never a bare recursive remove.
while IFS= read -r line; do
  # shellcheck disable=SC2016  # these patterns match literal shell source text
  case "$line" in
    *'rm -rf -- "$target"'* | *'rm -rf -- "$probe"'*) ;;
    *) fail "uninstaller contains an unguarded recursive remove: $line" ;;
  esac
done < <(grep -n 'rm -rf' "$UNINSTALLER" | cut -d: -f2-)

# A stopped service leaves a persistent launchd disable record; removing the
# label without clearing it silently blocks a later reinstall.
grep -Fq 'launchctl enable' "$UNINSTALLER" ||
  fail 'uninstaller never clears the launchd disable record'

# Both 1.0 identities must be handled, and the legacy ones only on request.
for label in \
  'io.github.mglaeser.imessage-proxy' \
  'io.github.mglaeser.imessage-proxy.edge' \
  'io.github.mglaeser.stella.bridge'; do
  grep -Fq "$label" "$UNINSTALLER" ||
    fail "uninstaller ignores a known launchd label: $label"
done
for cli_label in SERVER_LABEL EDGE_LABEL; do
  grep -Fq "readonly $cli_label='$(awk -F"'" \
    "/^readonly $cli_label=/ {print \$2}" "$REPOSITORY/bin/imessage-proxy")'" \
    "$UNINSTALLER" ||
    fail "uninstaller launchd label disagrees with the CLI: $cli_label"
done

# The product CLI must keep exposing no state-removal action of its own.
if grep -Eq '^[[:space:]]+(uninstall|purge|reset)\)' "$REPOSITORY/bin/imessage-proxy"; then
  fail 'the product CLI must not gain a state-removal action'
fi

# The uninstaller must be documented where an operator will look for it.
grep -Fq 'scripts/uninstall.sh' "$REPOSITORY/README.md" ||
  fail 'README does not document the uninstaller'
grep -Fq 'scripts/uninstall.sh' "$REPOSITORY/docs/operations.md" ||
  fail 'operations guide does not document the uninstaller'

printf '%s\n' 'iMessage Proxy uninstaller tests passed.'
