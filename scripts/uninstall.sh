#!/usr/bin/env bash
#
# iMessage Proxy uninstaller.
#
# Removes what scripts/install.sh created: both LaunchAgents, the lifecycle CLI,
# the installed read-only assets, the pinned native dependencies, and the
# private configuration file.
#
# Runtime state — API keys, the send allowlist, certificates, and logs — is
# preserved unless --purge is given together with its exact confirmation.
#
# The product CLI deliberately exposes no reset or state-removal action, so this
# stays a separate script: a running service can never destroy its own
# credentials. Removing state is an explicit operator decision made from outside
# the service.

set -Eeuo pipefail
export PATH='/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin'
export LC_ALL=C

readonly PROJECT_URL='https://github.com/mglaeser/imessage-proxy'
readonly PURGE_CONFIRMATION='DESTROY IMESSAGE PROXY STATE'
readonly SERVER_LABEL='io.github.mglaeser.imessage-proxy'
readonly EDGE_LABEL='io.github.mglaeser.imessage-proxy.edge'
# Identities from releases published before the 1.0 rename. They are removed
# only on request, because an operator may still be running that older service.
readonly LEGACY_LABEL='io.github.mglaeser.stella.bridge'
readonly LEGACY_RUNTIME_DIRECTORY='Stella'
readonly LEGACY_CLI_NAME='stella'

action='uninstall'
assume_yes='no'
dry_run='no'
include_legacy='no'
install_prefix="${HOME:-}/.local"
purge='no'
purge_confirmation=''
removed_count=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

step() {
  printf '\n==> %s\n' "$*" >&2
}

usage() {
  cat >&2 <<'USAGE'
Usage: uninstall.sh [options]

Removes the iMessage Proxy installation from this Mac. Runtime state is kept
unless you explicitly purge it.

Options:
  --dry-run              Show exactly what would be removed, change nothing
  --purge                Also destroy runtime state: API keys, the send
                         allowlist, certificates, and logs
  --confirm TEXT         Required with --purge:
                         'DESTROY IMESSAGE PROXY STATE'
  --include-legacy       Also remove pre-1.0 Stella-era artifacts
  --prefix DIR           Installation prefix to clean (default: $HOME/.local)
  --yes                  Do not ask for interactive confirmation
  --self-test            Validate this script's own logic and exit
  -h, --help             Show this help and exit

Without --purge your API keys and allowlist survive, so a later reinstall
adopts the existing state instead of issuing new credentials.
USAGE
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run='yes'
        shift
        ;;
      --purge)
        purge='yes'
        shift
        ;;
      --confirm)
        [[ $# -ge 2 ]] || die '--confirm requires a value'
        purge_confirmation="$2"
        shift 2
        ;;
      --include-legacy)
        include_legacy='yes'
        shift
        ;;
      --prefix)
        [[ $# -ge 2 ]] || die '--prefix requires a directory'
        install_prefix="$2"
        shift 2
        ;;
      --yes)
        assume_yes='yes'
        shift
        ;;
      --self-test)
        action='self-test'
        shift
        ;;
      -h | --help)
        action='usage'
        shift
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_arguments() {
  [[ "$install_prefix" == /* ]] || die '--prefix must be an absolute path'
  if [[ "$purge" == yes ]]; then
    [[ "$purge_confirmation" == "$PURGE_CONFIRMATION" ]] ||
      die "--purge requires --confirm '$PURGE_CONFIRMATION'"
  else
    [[ -z "$purge_confirmation" ]] ||
      die '--confirm is accepted only together with --purge'
  fi
}

require_supported_host() {
  [[ "$(uname -s)" == Darwin ]] || die 'iMessage Proxy runs only on macOS'
  [[ "$EUID" -ne 0 ]] || die 'run the uninstaller as the Messages.app user, not root'
  home_is_safe || die 'HOME must be a real, normalized, absolute user directory'
  command -v launchctl >/dev/null 2>&1 || die 'required command is missing: launchctl'
}

home_is_safe() {
  [[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != / && "$HOME" != */ &&
    "$HOME" != *//* && "$HOME" != *'/./'* && "$HOME" != */. &&
    "$HOME" != *'/../'* && "$HOME" != */.. ]] || return 1
  [[ -d "$HOME" && ! -L "$HOME" ]]
}

# Every removal target must be a normalized path strictly below HOME. This is
# the outer guard: a surprising environment can never widen a deletion.
path_is_removable() {
  local target="$1"
  home_is_safe || return 1
  [[ "$target" == "$HOME"/* ]] || return 1
  [[ "$target" != */ && "$target" != *//* && "$target" != *'/./'* &&
    "$target" != */. && "$target" != *'/../'* && "$target" != */.. ]] || return 1
}

# Shared parents that this project never owns exclusively. Removing one would
# take unrelated user data with it.
path_is_protected() {
  local target="$1"
  case "$target" in
    "$HOME" | \
      "$HOME/Library" | \
      "$HOME/Library/LaunchAgents" | \
      "$HOME/Library/Application Support" | \
      "$HOME/.config" | \
      "$HOME/.local" | \
      "$HOME/.local/bin" | \
      "$HOME/.local/libexec" | \
      "$HOME/.local/share" | \
      "$HOME/.local/src") return 0 ;;
  esac
  return 1
}

remove_target() {
  local description="${2:-}" target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  path_is_removable "$target" ||
    die "refusing to remove a path outside your home directory: $target"
  if path_is_protected "$target"; then
    die "refusing to remove a shared directory: $target"
  fi
  if [[ "$dry_run" == yes ]]; then
    note "  would remove  $target${description:+  ($description)}"
    return 0
  fi
  rm -rf -- "$target"
  [[ ! -e "$target" && ! -L "$target" ]] || die "could not remove: $target"
  removed_count=$((removed_count + 1))
  note "  removed       $target"
}

remove_empty_directory() {
  local target="$1"
  [[ -d "$target" && ! -L "$target" ]] || return 0
  path_is_removable "$target" || return 0
  [[ "$dry_run" == yes ]] && return 0
  rmdir "$target" 2>/dev/null || true
}

launchd_domain() {
  printf 'gui/%s/%s' "$(id -u)" "$1"
}

stop_launch_agent() {
  local domain label="$1"
  domain="$(launchd_domain "$label")"
  if launchctl print "$domain" >/dev/null 2>&1; then
    if [[ "$dry_run" == yes ]]; then
      note "  would stop    $label"
    else
      launchctl bootout "$domain" >/dev/null 2>&1 || true
      note "  stopped       $label"
    fi
  fi
  # server-stop and edge-stop deliberately write a persistent launchd disable
  # record so a stopped service stays stopped across reboots. Clear it here, or
  # a later reinstall of the same label is silently refused.
  if [[ "$dry_run" == yes ]]; then
    note "  would clear   launchd disable record for $label"
  else
    launchctl enable "$domain" >/dev/null 2>&1 || true
  fi
}

# ~/.local/bin/imsg belongs to this project only when it points into our own
# libexec payload. An operator's own executable there is left untouched.
imsg_link_is_managed() {
  local link="$1" prefix="$2" target
  [[ -L "$link" ]] || return 1
  target="$(readlink "$link")" || return 1
  case "$target" in
    "$prefix/libexec/imessage-proxy/"*) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_root_path() {
  printf '%s\n' "${IMESSAGE_PROXY_HOME:-$HOME/Library/Application Support/iMessage Proxy}"
}

# Mirrors the CLI's runtime-root contract, so --purge can never be aimed at an
# unrelated directory through IMESSAGE_PROXY_HOME.
runtime_root_is_expected() {
  local base root="$1"
  base="${root##*/}"
  [[ "$base" == 'iMessage Proxy' || "$base" == 'imessage-proxy' ]]
}

confirm_interactively() {
  local reply=''
  [[ "$dry_run" == yes || "$assume_yes" == yes ]] && return 0
  [[ -r /dev/tty && -w /dev/tty ]] ||
    die 'no terminal is available to confirm; re-run with --yes or --dry-run'
  if [[ "$purge" == yes ]]; then
    printf 'Permanently destroy API keys, allowlist, certificates, and logs? [y/N] ' >&2
  else
    printf 'Remove the iMessage Proxy installation? [y/N] ' >&2
  fi
  IFS= read -r reply < /dev/tty || die 'could not read the confirmation'
  [[ "$reply" == y || "$reply" == Y ]] || die 'aborted; nothing was changed'
}

remove_services() {
  step 'Stopping and removing LaunchAgents'
  stop_launch_agent "$EDGE_LABEL"
  stop_launch_agent "$SERVER_LABEL"
  remove_target "$HOME/Library/LaunchAgents/$EDGE_LABEL.plist" 'public edge agent'
  remove_target "$HOME/Library/LaunchAgents/$SERVER_LABEL.plist" 'native server agent'
}

remove_installation() {
  local imsg_link="$install_prefix/bin/imsg"
  step 'Removing installed files'
  if imsg_link_is_managed "$imsg_link" "$install_prefix"; then
    remove_target "$imsg_link" 'pinned imsg link'
  elif [[ -e "$imsg_link" || -L "$imsg_link" ]]; then
    note "  kept          $imsg_link (not installed by iMessage Proxy)"
  fi
  remove_target "$install_prefix/bin/imessage-proxy" 'lifecycle CLI'
  remove_target "$install_prefix/share/imessage-proxy" 'installed assets'
  remove_target "$install_prefix/libexec/imessage-proxy" 'pinned dependencies'
  remove_target "$HOME/.config/imessage-proxy" 'private configuration'
  remove_empty_directory "$install_prefix/libexec"
}

handle_runtime_state() {
  local root
  root="$(runtime_root_path)"
  if [[ "$purge" != yes ]]; then
    if [[ -d "$root" ]]; then
      note ''
      note "Kept runtime state: $root"
      note '  API keys, the send allowlist, certificates, and logs are intact.'
      note "  Remove them with: --purge --confirm '$PURGE_CONFIRMATION'"
    fi
    return
  fi
  step 'Destroying runtime state'
  runtime_root_is_expected "$root" ||
    die "refusing to purge an unexpected runtime root: $root"
  remove_target "$root" 'API keys, allowlist, certificates, logs'
}

remove_legacy() {
  [[ "$include_legacy" == yes ]] || return 0
  step 'Removing pre-1.0 Stella-era artifacts'
  stop_launch_agent "$LEGACY_LABEL"
  remove_target "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist" 'legacy bridge agent'
  remove_target "$install_prefix/bin/$LEGACY_CLI_NAME" 'legacy CLI'
  if [[ "$purge" == yes ]]; then
    remove_target "$HOME/Library/Application Support/$LEGACY_RUNTIME_DIRECTORY" \
      'legacy runtime state'
  elif [[ -d "$HOME/Library/Application Support/$LEGACY_RUNTIME_DIRECTORY" ]]; then
    note "  kept          $HOME/Library/Application Support/$LEGACY_RUNTIME_DIRECTORY (state; use --purge)"
  fi
}

print_manual_steps() {
  note ''
  if [[ "$dry_run" == yes ]]; then
    note 'Dry run complete. Nothing was changed.'
  else
    note "Removed $removed_count item(s)."
  fi
  note ''
  note 'macOS does not allow a script to revoke these; remove them by hand:'
  note '  System Settings > Privacy & Security > Full Disk Access'
  note '    Delete the entry for imessage-proxy-server. A stale entry points at'
  note '    a binary that no longer exists and confuses a later reinstall.'
  note '  System Settings > Privacy & Security > Automation'
  note '    Only if you ever sent a message: delete the Messages entry for the'
  note '    same binary. Automation is requested at the first intentional send,'
  note '    never during installation, so an install that never sent anything'
  note '    leaves no entry here.'
  note "  Your shell startup file, if it adds $install_prefix/bin to PATH."
  note ''
  note "Reinstall any time: $PROJECT_URL"
}

self_test() {
  local probe
  probe="$(mktemp -d)"
  mkdir -p "$probe/home/.local/bin" "$probe/home/.local/libexec/imessage-proxy"

  (
    HOME="$probe/home"
    home_is_safe || die 'self-test rejected a valid HOME'
    path_is_removable "$HOME/.local/bin/imessage-proxy" ||
      die 'self-test rejected a valid removal target'
    path_is_removable "$HOME/Library/Application Support/iMessage Proxy" ||
      die 'self-test rejected a valid runtime root'
    for candidate in \
      /etc/passwd \
      "$probe/outside" \
      "$HOME" \
      "$HOME/../elsewhere" \
      "$HOME/.local/../../etc" \
      "$HOME/.local/bin/"; do
      ! path_is_removable "$candidate" ||
        die "self-test accepted an unsafe removal target: $candidate"
    done
    for candidate in \
      "$HOME" \
      "$HOME/Library" \
      "$HOME/Library/LaunchAgents" \
      "$HOME/Library/Application Support" \
      "$HOME/.config" \
      "$HOME/.local" \
      "$HOME/.local/bin" \
      "$HOME/.local/share" \
      "$HOME/.local/libexec"; do
      path_is_protected "$candidate" ||
        die "self-test failed to protect a shared directory: $candidate"
    done
    for candidate in \
      "$HOME/.local/bin/imessage-proxy" \
      "$HOME/.local/share/imessage-proxy" \
      "$HOME/.config/imessage-proxy"; do
      ! path_is_protected "$candidate" ||
        die "self-test over-protected an owned path: $candidate"
    done

    ln -sf "$HOME/.local/libexec/imessage-proxy/imsg-0.13.4/imsg" "$HOME/.local/bin/imsg"
    imsg_link_is_managed "$HOME/.local/bin/imsg" "$HOME/.local" ||
      die 'self-test did not recognize its own imsg link'
    ln -sf /opt/homebrew/bin/imsg "$HOME/.local/bin/imsg"
    ! imsg_link_is_managed "$HOME/.local/bin/imsg" "$HOME/.local" ||
      die 'self-test claimed an unrelated imsg link'
    printf 'x' > "$HOME/.local/bin/plain-imsg"
    ! imsg_link_is_managed "$HOME/.local/bin/plain-imsg" "$HOME/.local" ||
      die 'self-test claimed a regular file as its own link'
  )

  runtime_root_is_expected '/Users/example/Library/Application Support/iMessage Proxy' ||
    die 'self-test rejected the documented runtime root'
  runtime_root_is_expected '/Users/example/somewhere/imessage-proxy' ||
    die 'self-test rejected the alternate runtime root name'
  for candidate in /Users/example /Users/example/Documents /Users/example/Library; do
    ! runtime_root_is_expected "$candidate" ||
      die "self-test accepted an unexpected runtime root: $candidate"
  done

  [[ "$PURGE_CONFIRMATION" == 'DESTROY IMESSAGE PROXY STATE' ]] ||
    die 'the purge confirmation phrase changed unexpectedly'

  rm -rf -- "$probe"
  printf 'uninstaller self-test passed\n' >&2
}

main() {
  parse_arguments "$@"
  case "$action" in
    usage)
      usage
      return 0
      ;;
    self-test)
      self_test
      return 0
      ;;
  esac

  validate_arguments
  require_supported_host

  note 'iMessage Proxy uninstaller'
  if [[ "$dry_run" == yes ]]; then
    note 'Dry run: nothing will be changed.'
  fi
  if [[ "$purge" == yes ]]; then
    note 'PURGE: API keys, the send allowlist, certificates, and logs will be'
    note 'destroyed permanently. This cannot be undone.'
  else
    note 'Runtime state is preserved. Pass --purge to destroy it as well.'
  fi
  confirm_interactively

  remove_services
  remove_installation
  handle_runtime_state
  remove_legacy
  print_manual_steps
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
