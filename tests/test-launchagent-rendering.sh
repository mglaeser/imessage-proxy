#!/usr/bin/env bash
#
# LaunchAgent template rendering, exercised on every bash this product can run
# under.
#
# The rendering helpers are pure shell, so unlike the rest of the CLI suite this
# runs anywhere. That matters: the defect these tests exist to prevent is a
# difference between bash releases, and it is invisible on the interpreter a
# developer or a macOS runner happens to have first in PATH. Every case below is
# repeated under BASH_COMPAT for each release whose expansion semantics differ,
# so a regression fails on Linux CI instead of on an operator's Mac.
#
# BASH_COMPAT is honoured from bash 4.3 onward. On 3.2 it is an inert variable
# and the interpreter already behaves as 3.2, so the loop is meaningful there
# too.

set -Eeuo pipefail

REPOSITORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPOSITORY
readonly CLI="$REPOSITORY/bin/imessage-proxy"
readonly SERVER_TEMPLATE="$REPOSITORY/config/io.github.mglaeser.imessage-proxy.plist.in"
readonly COMPAT_LEVELS=(3.2 4.0 4.1 4.2 4.3 4.4 5.0 5.1 5.2)

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equals() {
  local actual="$2" context="$3" expected="$1"
  [[ "$actual" == "$expected" ]] ||
    fail "$context
  expected: $expected
  actual:   $actual"
}

expect_failure() {
  local capture expected="$1"
  shift
  capture="$(mktemp "$temporary/failure.XXXXXX")"
  if ("$@") > "$capture" 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
  grep -Fq -- "$expected" "$capture" ||
    fail "expected failure containing '$expected', got: $(< "$capture")"
  rm -f -- "$capture"
}

export IMESSAGE_PROXY_SOURCE_DIR="$REPOSITORY"
export IMESSAGE_PROXY_HOME="$temporary/home/imessage-proxy"
HOME="$temporary/home"
export HOME
mkdir -p "$HOME"

# shellcheck source=../bin/imessage-proxy
source "$CLI"

# The default runtime root contains spaces, and macOS filenames may legally
# contain an ampersand. Both have to survive rendering unchanged, on every bash.
readonly SPACED_PATH='/Users/op/Library/Application Support/iMessage Proxy/state/bin/imessage-proxy-server'
readonly AMPERSAND_PATH='/Users/op/R&D/imessage-proxy/state/bin/srv'

for level in "${COMPAT_LEVELS[@]}"; do
  assert_equals "<a>$SPACED_PATH</a>" \
    "$(BASH_COMPAT="$level" substitute_all '<a>__V__</a>' '__V__' "$SPACED_PATH")" \
    "compat $level: a spaced value was not substituted literally"

  # bash 5.2 turns an unquoted "&" in a replacement into the matched text, and
  # bash <= 4.2 leaves quote characters around a quoted one. Neither may happen.
  assert_equals '<a>a&b</a>' \
    "$(BASH_COMPAT="$level" substitute_all '<a>__V__</a>' '__V__' 'a&b')" \
    "compat $level: an ampersand value was not substituted literally"

  assert_equals '<a>x__V__y</a>' \
    "$(BASH_COMPAT="$level" substitute_all '<a>__V__</a>' '__V__' 'x__V__y')" \
    "compat $level: a self-referential value was rescanned instead of emitted once"

  assert_equals '<a>1</a><b>1</b>' \
    "$(BASH_COMPAT="$level" substitute_all '<a>__V__</a><b>__V__</b>' '__V__' '1')" \
    "compat $level: not every occurrence of the token was replaced"

  assert_equals 'a&amp;b &lt;c&gt; &amp;amp;' \
    "$(BASH_COMPAT="$level" xml_escaped 'a&b <c> &amp;')" \
    "compat $level: XML escaping is wrong or double-escapes the ampersand"

  rendered="$temporary/rendered-$level.plist"
  BASH_COMPAT="$level" write_plist_from_template "$rendered" "$SERVER_TEMPLATE" \
    __SERVER_BIN__ "$SPACED_PATH" \
    __TARGETS_FILE__ "$AMPERSAND_PATH" \
    __DATABASE_PATH__ /db \
    __EXPECTED_IMSG_VERSION__ 0.13.4 \
    __IMSG_BIN__ /imsg \
    __IMSG_SHA256__ deadbeef \
    __MESSAGES_DATABASE_PATH__ /chat.db \
    __PUBLIC_ORIGIN__ https://messages.integration.dev \
    __SOCKET_PATH__ /server.sock \
    __SERVER_LOG__ /server.log
  require_no_unrendered_placeholders "$rendered"
  grep -Fqx "		<string>$SPACED_PATH</string>" "$rendered" ||
    fail "compat $level: the server binary is not rendered as one exact literal argument"
  grep -Fqx "		<string>serve</string>" "$rendered" ||
    fail "compat $level: the serve argument did not survive rendering"
  grep -Fq '/Users/op/R&amp;D/imessage-proxy/state/bin/srv' "$rendered" ||
    fail "compat $level: an ampersand value was not XML-escaped"
  # bash <= 4.2 leaves the quote characters of a quoted replacement operand in
  # the output, which yields <string>"/Users/..."</string>: still well-formed
  # XML, still lint-clean, and rejected by launchd only at run time.
  if grep -Fq '<string>"' "$rendered"; then
    fail "compat $level: rendering wrapped a value in literal quote characters"
  fi
done

# Negative cases. Each must fail closed at render time rather than produce a
# document that parses and misbehaves.
expect_failure 'contains a control character and was refused' \
  write_plist_from_template "$temporary/refused.plist" "$SERVER_TEMPLATE" \
  __SERVER_BIN__ "$(printf 'a\tb')"

expect_failure 'was passed with no value' \
  write_plist_from_template "$temporary/refused.plist" "$SERVER_TEMPLATE" \
  __SERVER_BIN__ /srv __TARGETS_FILE__

expect_failure 'no longer contains __NO_SUCH_TOKEN__' \
  write_plist_from_template "$temporary/refused.plist" "$SERVER_TEMPLATE" \
  __NO_SUCH_TOKEN__ value

# A value that reshapes the document is now escaped rather than refused, so the
# injected markup has to arrive as text and not as an extra argument.
injected="$temporary/injected.plist"
write_plist_from_template "$injected" "$SERVER_TEMPLATE" \
  __SERVER_BIN__ '/srv</string><string>--rogue'
grep -Fq '<string>/srv&lt;/string&gt;&lt;string&gt;--rogue</string>' "$injected" ||
  fail 'an injected element was not neutralised into text'
[[ "$(grep -c '<string>' "$injected")" -eq "$(grep -c '<string>' "$SERVER_TEMPLATE")" ]] ||
  fail 'rendering changed the number of elements in the document'

partial="$temporary/partial.plist"
write_plist_from_template "$partial" "$SERVER_TEMPLATE" __SERVER_BIN__ /srv
expect_failure 'still contains an unsubstituted placeholder' \
  require_no_unrendered_placeholders "$partial"

printf 'iMessage Proxy LaunchAgent rendering tests passed.\n'
