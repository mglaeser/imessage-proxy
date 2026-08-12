#!/usr/bin/env bash
#
# Interpreter-compatibility guard for every shell source in the product.
#
# macOS ships bash 3.2.57 as /bin/bash, and every script here starts with
# "#!/usr/bin/env bash", so the interpreter is whatever the operator's PATH
# resolves first: 3.2 on a stock Mac, 5.x where a newer bash was installed. The
# product is written to run on both, but nothing verified that, and a defect of
# exactly this shape reached a real installation: a pattern substitution whose
# replacement operand is quoted behaves differently before and after bash 4.3,
# and one whose replacement is unquoted behaves differently again from 5.2,
# where patsub_replacement makes a bare "&" expand to the matched text. The
# result lints, parses, and passes review; it only misbehaves on the half of the
# fleet the author did not run.
#
# This suite is pure shell and runs anywhere, so a regression fails on Linux CI
# rather than on an operator's Mac. It does two things:
#
#   1. Refuses syntax that does not exist in bash 3.2.
#   2. Runs every pure-shell helper under each BASH_COMPAT level whose expansion
#      semantics differ, and asserts identical answers.
#
# BASH_COMPAT is honoured from bash 4.3 onward. On 3.2 it is an inert variable
# and the interpreter already behaves as 3.2, so the sweep is meaningful there.

set -Eeuo pipefail

REPOSITORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPOSITORY
readonly CLI="$REPOSITORY/bin/imessage-proxy"
readonly COMPAT_LEVELS=(3.2 4.0 4.1 4.2 4.3 4.4 5.0 5.1 5.2)
readonly SHELL_SOURCES=(
  "bin/imessage-proxy"
  "scripts/install.sh"
  "scripts/uninstall.sh"
)

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Constructs bash 3.2 does not have. A match is not necessarily wrong - it is a
# deliberate decision to drop stock macOS, which belongs in review and in the
# documented requirements, not in an unnoticed diff.
readonly BASH4_CONSTRUCTS='declare -A|local -A|mapfile|readarray|coproc|local -n|declare -n|\[\[ +-v |;;&|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*,,|&>>|\|&|wait -n|\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAaKk]\}'
for source in "${SHELL_SOURCES[@]}"; do
  if grep -nE "$BASH4_CONSTRUCTS" "$REPOSITORY/$source"; then
    fail "$source uses syntax bash 3.2 does not support (see the matches above)"
  fi
done

# A quoted replacement operand in a pattern substitution is the specific defect
# that reached an installation. Flag the construct wherever it appears, in any
# shell source, so the next one cannot arrive silently.
for source in "${SHELL_SOURCES[@]}"; do
  if grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?/[/#%]?[^}]*/"' "$REPOSITORY/$source"; then
    fail "$source substitutes with a quoted replacement operand, which bash <= 4.2 does not unquote"
  fi
done

# Every source must load under each compatibility level. Sourcing runs the
# top-level code, which is where a version-sensitive expansion would first bite.
export IMESSAGE_PROXY_SOURCE_DIR="$REPOSITORY"
export IMESSAGE_PROXY_HOME="$temporary/home/imessage-proxy"
mkdir -p "$temporary/home"

for level in "${COMPAT_LEVELS[@]}"; do
  for source in "${SHELL_SOURCES[@]}"; do
    HOME="$temporary/home" BASH_COMPAT="$level" \
      bash -c 'source "$1" >/dev/null 2>&1' _ "$REPOSITORY/$source" ||
      fail "compat $level: $source does not load"
  done
done

# The pure-shell validators are the product's security-relevant string handling:
# which hostnames, addresses, ports and confirmations are accepted. Their answers
# must not depend on the interpreter.
# The CLI and the installer each define their own readonly constants, some under
# the same names, so they are probed in separate shells rather than sourced
# together.
probe_cli() {
  HOME="$temporary/home" BASH_COMPAT="$1" bash -s -- "$CLI" <<'PROBE'
source "$1" >/dev/null 2>&1
report() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then printf '%s=yes\n' "$name"; else printf '%s=no\n' "$name"; fi
}
report host_public   hostname_valid messages.integration.dev
report host_upper    hostname_valid Messages.integration.dev
report host_local    hostname_valid messages.local
report host_invalid  hostname_valid imessage-proxy.invalid
report host_ip       hostname_valid 203.0.113.10
report host_empty    hostname_valid ''
report mail_public   email_valid operator@integration.dev
report mail_example  email_valid operator@example.com
report mail_amp      email_valid 'ops&alerts@integration.dev'
report ipv4_ok       ipv4_address_valid 203.0.113.10
report ipv4_bad      ipv4_address_valid 203.0.113.999
report port_ok       unprivileged_port_valid 8080
report port_priv     unprivileged_port_valid 443
report port_pad      unprivileged_port_valid 08080
report fda_exact     full_disk_access_acknowledgement_matches 'FULL DISK ACCESS GRANTED'
report fda_spaced    full_disk_access_acknowledgement_matches '  full disk access granted  '
report fda_wrong     full_disk_access_acknowledgement_matches 'FULL DISK ACCESS'
printf 'config_path=%s\n' "$(service_config_path)"
PROBE
}

probe_installer() {
  HOME="$temporary/home" BASH_COMPAT="$1" bash -s -- "$REPOSITORY/scripts/install.sh" <<'PROBE'
source "$1" >/dev/null 2>&1
report() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then printf '%s=yes\n' "$name"; else printf '%s=no\n' "$name"; fi
}
report host_public   hostname_valid messages.integration.dev
report host_invalid  hostname_valid imessage-proxy.invalid
report mail_public   email_valid operator@integration.dev
report admin_ok      admin_name_valid first-admin
report admin_space   admin_name_valid ' leading'
report expiry_ok     expires_days_valid 30
report expiry_pad    expires_days_valid 007
report tag_ok        release_tag_valid v1.0.0
report tag_bad       release_tag_valid 1.0.0
printf 'placeholder=%s|%s\n' "$PLACEHOLDER_API_HOST" "$PLACEHOLDER_ACME_EMAIL"
PROBE
}

for prober in probe_cli probe_installer; do
  reference="$("$prober" "${COMPAT_LEVELS[0]}")"
  [[ -n "$reference" ]] || fail "$prober produced no output"
  grep -q 'host_public=yes' <<< "$reference" || fail "$prober did not exercise the validators"
  grep -q 'host_invalid=no' <<< "$reference" ||
    fail "$prober expected the reserved .invalid namespace to be rejected as a public hostname"
  for level in "${COMPAT_LEVELS[@]:1}"; do
    current="$("$prober" "$level")"
    if [[ "$current" != "$reference" ]]; then
      printf '%s: compat %s differs from %s:\n' "$prober" "$level" "${COMPAT_LEVELS[0]}" >&2
      diff <(printf '%s\n' "$reference") <(printf '%s\n' "$current") >&2 || true
      fail "validator behaviour depends on the bash version ($prober, compat $level)"
    fi
  done
done

printf 'iMessage Proxy bash-compatibility tests passed (%s levels).\n' "${#COMPAT_LEVELS[@]}"
