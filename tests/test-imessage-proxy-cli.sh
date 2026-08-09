#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPOSITORY
readonly CLI="$REPOSITORY/bin/imessage-proxy"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1" path="$2"
  grep -Fq -- "$needle" "$path" || fail "$path does not contain: $needle"
}

assert_not_contains() {
  local needle="$1" path="$2"
  ! grep -Fq -- "$needle" "$path" || fail "$path unexpectedly contains: $needle"
}

expect_failure() {
  local capture expected="$1"
  shift
  capture="$(mktemp "$temporary/failure.XXXXXX")"
  if ("$@") > "$capture" 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
  assert_contains "$expected" "$capture"
  rm -f -- "$capture"
}

expect_status() {
  local actual=0 expected="$1"
  shift
  if ("$@") >/dev/null 2>&1; then
    actual=0
  else
    actual=$?
  fi
  [[ "$actual" -eq "$expected" ]] ||
    fail "expected status $expected, got $actual from: $*"
}

assert_rollback() {
  local domain label="$1" path="$2"
  domain="gui/$(id -u)/$label"
  assert_contains "disable $domain" "$path"
  assert_contains "bootout $domain" "$path"
}

[[ -x "$CLI" ]] || fail 'CLI is not executable'
[[ "$($CLI version)" == "$(< "$REPOSITORY/VERSION")" ]] ||
  fail 'version action disagrees with VERSION'
help_text="$($CLI --help)"
for expected in \
  'api-key bootstrap-admin' \
  'server-install' \
  'RESTART IMESSAGE PROXY SERVER' \
  'edge-install' \
  'EXPOSE IMESSAGE PROXY PUBLICLY' \
  'RESTART IMESSAGE PROXY EDGE'; do
  grep -Fq "$expected" <<< "$help_text" || fail "help omits: $expected"
done

mkdir -p "$temporary/home" "$temporary/outside"
ln -s "$temporary/outside" "$temporary/home/linked-runtime"

assert_runtime_root_rejected() {
  local candidate=$1
  if HOME="$temporary/home" \
    IMESSAGE_PROXY_HOME="$candidate" \
    IMESSAGE_PROXY_SOURCE_DIR="$REPOSITORY" \
    bash -c 'source "$1"; require_safe_runtime_root' _ "$CLI" >/dev/null 2>&1; then
    fail "unsafe runtime root was accepted: $candidate"
  fi
}

HOME="$temporary/home" \
  IMESSAGE_PROXY_HOME="$temporary/home/review/imessage-proxy" \
  IMESSAGE_PROXY_SOURCE_DIR="$REPOSITORY" \
  bash -c 'source "$1"; require_safe_runtime_root' _ "$CLI" ||
  fail 'a dedicated normalized runtime root below HOME was rejected'
assert_runtime_root_rejected "$temporary/home"
assert_runtime_root_rejected "$temporary/outside/imessage-proxy"
assert_runtime_root_rejected "$temporary/home/review/../imessage-proxy"
assert_runtime_root_rejected "$temporary/home/linked-runtime/imessage-proxy"
assert_runtime_root_rejected "$temporary/home/not-the-product"

# Test doubles below are intentionally invoked through functions sourced from the CLI.
# shellcheck disable=SC2329
(
  export HOME="$temporary/home"
  export TMPDIR="$temporary/tmp"
  export IMESSAGE_PROXY_SOURCE_DIR="$REPOSITORY"
  export IMESSAGE_PROXY_HOME="$HOME/imessage-proxy"
  export IMESSAGE_PROXY_API_HOST='messages.integration.dev'
  export IMESSAGE_PROXY_ACME_EMAIL='operator@integration.dev'
  export IMESSAGE_PROXY_PUBLIC_BIND='0.0.0.0'
  export IMESSAGE_PROXY_HTTP_PORT='8080'
  export IMESSAGE_PROXY_HTTPS_PORT='8443'
  export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS='yes'
  mkdir -p "$HOME" "$TMPDIR" "$temporary/tools"

  fake_caddy="$temporary/tools/caddy"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # This writes a literal script expression.
    # shellcheck disable=SC2016
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' "  version) printf '%s\\n' 'v2.11.4 test-build' ;;"
    printf '%s\n' '  validate) exit 0 ;;'
    printf '%s\n' '  *) exit 64 ;;'
    printf '%s\n' 'esac'
  } > "$fake_caddy"
  chmod 700 "$fake_caddy"
  export IMESSAGE_PROXY_CADDY_BIN="$fake_caddy"
  export IMESSAGE_PROXY_CADDY_SHA256
  IMESSAGE_PROXY_CADDY_SHA256="$(shasum -a 256 "$fake_caddy" | awk '{print $1}')"

  fake_imsg="$temporary/tools/imsg"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # This writes a literal script expression.
    # shellcheck disable=SC2016
    printf '%s\n' '[[ "${1:-}" == --version ]] || exit 64'
    printf '%s\n' "printf '%s\\n' '0.13.4'"
  } > "$fake_imsg"
  chmod 700 "$fake_imsg"
  export IMESSAGE_PROXY_IMSG_BIN="$fake_imsg"
  export IMESSAGE_PROXY_IMSG_SHA256
  IMESSAGE_PROXY_IMSG_SHA256="$(shasum -a 256 "$fake_imsg" | awk '{print $1}')"

  # shellcheck source=../bin/imessage-proxy
  source "$CLI"

  hostname_valid 'messages.integration.dev' || fail 'valid public hostname was rejected'
  ! hostname_valid 'Messages.example.net' || fail 'mixed-case hostname was accepted'
  ! hostname_valid 'messages.local' || fail 'local hostname was accepted'
  ! hostname_valid 'messages.example.com' || fail 'documentation-only hostname was accepted'
  ! hostname_valid 'messages.example.net' || fail 'reserved example hostname was accepted'
  ! hostname_valid 'messages.integration.test' || fail 'reserved test hostname was accepted'
  ! hostname_valid 'service.home.arpa' || fail 'private home.arpa hostname was accepted'
  ! hostname_valid '203.0.113.10' || fail 'dotted IPv4 address was accepted as a hostname'
  email_valid 'operator@integration.dev' || fail 'valid ACME email was rejected'
  ! email_valid 'operator@example.com' || fail 'documentation-only ACME email was accepted'
  ipv4_address_valid '203.0.113.10' || fail 'valid IPv4 address was rejected'
  ! ipv4_address_valid '203.0.113.999' || fail 'invalid IPv4 address was accepted'
  unprivileged_port_valid 8080 || fail 'valid unprivileged port was rejected'
  ! unprivileged_port_valid 443 || fail 'privileged port was accepted'
  ! unprivileged_port_valid 08080 || fail 'non-canonical port was accepted'

  security_dir="$temporary/security"
  mkdir -p "$security_dir/private-directory" "$security_dir/logs"
  printf '%s\n' 'fixture' > "$security_dir/private-file"
  chmod 700 "$security_dir/private-directory"
  chmod 600 "$security_dir/private-file"
  ln "$security_dir/private-file" "$security_dir/private-file-hardlink"
  ln -s "$security_dir/private-file" "$security_dir/private-file-symlink"
  ln -s "$security_dir/private-directory" "$security_dir/private-directory-symlink"
  ln -s "$security_dir/private-file" "$security_dir/logs/edge-symlink.log"
  (
    stat_mode=600
    stat_owner="$(id -un)"
    stat_links=1
    stat() {
      case "${1:-} ${2:-}" in
        '-f %Lp') printf '%s\n' "$stat_mode" ;;
        '-f %Su') printf '%s\n' "$stat_owner" ;;
        '-f %l') printf '%s\n' "$stat_links" ;;
        *) fail "unexpected macOS stat fixture invocation: $*" ;;
      esac
    }

    expect_failure 'private file must be a regular non-symlink' \
      require_private_file "$security_dir/private-file-symlink"
    stat_links=2
    expect_failure 'private file must have exactly one hard link' \
      require_private_file "$security_dir/private-file-hardlink"
    stat_links=1
    stat_owner='untrusted-owner'
    expect_failure 'private file must be owned by' \
      require_private_file "$security_dir/private-file"
    stat_owner="$(id -un)"
    stat_mode=640
    expect_failure 'private file must not be group/world accessible' \
      require_private_file "$security_dir/private-file"

    expect_failure 'private directory must be a non-symlink' \
      require_private_directory "$security_dir/private-directory-symlink"
    stat_mode=750
    expect_failure 'private directory must not be group/world accessible' \
      require_private_directory "$security_dir/private-directory"
    stat_mode=700
    stat_owner='untrusted-owner'
    expect_failure 'private directory must be owned by' \
      require_private_directory "$security_dir/private-directory"

    stat_owner="$(id -un)"
    stat_mode=700
    chmod 700 "$security_dir/private-file"
    expect_failure 'fixture executable must not be writable' \
      require_private_executable "$security_dir/private-file" 'fixture executable'

    expect_failure 'log path must be a regular non-symlink' \
      prepare_private_log "$security_dir/logs/edge-symlink.log"
    stat_links=2
    expect_failure 'log file must have exactly one hard link' \
      prepare_private_log "$security_dir/private-file-hardlink"
    stat_links=1
    stat_owner='untrusted-owner'
    expect_failure 'log file must be owned by' \
      prepare_private_log "$security_dir/private-file"

    require_launch_agents_directory() { :; }
    expect_failure 'private file must be a regular non-symlink' \
      require_safe_launch_agent_target "$security_dir/private-file-symlink"
  )

  wrong_caddy="$temporary/tools/caddy-wrong-version"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # shellcheck disable=SC2016
    printf '%s\n' '[[ "${1:-}" == version ]] || exit 64'
    printf '%s\n' "printf '%s\\n' 'v2.11.3 wrong-build'"
  } > "$wrong_caddy"
  chmod 700 "$wrong_caddy"
  wrong_imsg="$temporary/tools/imsg-wrong-version"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # shellcheck disable=SC2016
    printf '%s\n' '[[ "${1:-}" == --version ]] || exit 64'
    printf '%s\n' "printf '%s\\n' '0.13.3'"
  } > "$wrong_imsg"
  chmod 700 "$wrong_imsg"
  mkdir -p "$BIN_DIR"

  IMESSAGE_PROXY_CADDY_SHA256='0000000000000000000000000000000000000000000000000000000000000000' \
    expect_failure 'configured Caddy binary SHA-256 does not match' stage_caddy_binary
  IMESSAGE_PROXY_IMSG_SHA256='0000000000000000000000000000000000000000000000000000000000000000' \
    expect_failure 'configured imsg binary SHA-256 does not match' stage_imsg_binary
  wrong_caddy_sha256="$(shasum -a 256 "$wrong_caddy" | awk '{print $1}')"
  IMESSAGE_PROXY_CADDY_BIN="$wrong_caddy" \
    IMESSAGE_PROXY_CADDY_SHA256="$wrong_caddy_sha256" \
    expect_failure 'expected Caddy 2.11.4, found v2.11.3' stage_caddy_binary
  wrong_imsg_sha256="$(shasum -a 256 "$wrong_imsg" | awk '{print $1}')"
  IMESSAGE_PROXY_IMSG_BIN="$wrong_imsg" \
    IMESSAGE_PROXY_IMSG_SHA256="$wrong_imsg_sha256" \
    expect_failure 'expected imsg 0.13.4, found 0.13.3' stage_imsg_binary
  [[ ! -e "$CADDY_BIN" && ! -e "$IMSG_BIN" ]] ||
    fail 'a rejected dependency version replaced a staged binary'

  require_macos() { :; }
  require_api_settings() { :; }
  require_command() { :; }
  require_private_directory() { :; }
  require_private_file() { :; }
  require_private_executable() {
    [[ -f "$1" && ! -L "$1" && -x "$1" ]] ||
      fail "invalid test executable: $1"
  }
  require_safe_launch_agent_target() {
    mkdir -p "$(dirname "$1")"
    [[ ! -L "$1" ]] || fail "refusing test LaunchAgent symlink: $1"
  }
  render_server_agent() {
    printf '%s\n' 'rendered native server agent' > "$SERVER_PLIST_STATE"
    chmod 600 "$SERVER_PLIST_STATE"
  }
  render_edge_agent() {
    printf '%s\n' 'rendered host Caddy edge agent' > "$EDGE_PLIST_STATE"
    chmod 600 "$EDGE_PLIST_STATE"
  }
  launchctl() {
    [[ "${1:-}" == print ]] || return 64
    printf '%s\n' 'Could not find service in domain for system' >&2
    return 113
  }

  (
    prepare_runtime_directories() { fail 'prepare mutated state while the native server was loaded'; }
    server_loaded() { return 0; }
    expect_failure 'stop the native server before replacing its staged binary' prepare
  )
  (
    prepare_runtime_directories() { fail 'prepare mutated state after a native inventory error'; }
    server_loaded() { return 2; }
    expect_failure 'could not determine native LaunchAgent state' prepare
  )
  (
    prepare_runtime_directories() { fail 'prepare mutated state while the public edge was loaded'; }
    server_loaded() { return 1; }
    edge_loaded() { return 0; }
    expect_failure 'stop the public edge before replacing its staged binary' prepare
  )
  (
    prepare_runtime_directories() { fail 'prepare mutated state after a public-edge inventory error'; }
    server_loaded() { return 1; }
    edge_loaded() { return 2; }
    expect_failure 'could not determine public-edge LaunchAgent state' prepare
  )

  prepare > "$temporary/prepare.out"
  [[ -f "$TARGETS_FILE" ]] || fail 'prepare did not create the target allowlist'
  [[ -f "$EDGE_LOG" && ! -L "$EDGE_LOG" ]] ||
    fail 'prepare did not create the bounded edge log safely'
  [[ -f "$CADDYFILE" && -x "$CADDY_BIN" && -x "$IMSG_BIN" ]] ||
    fail 'prepare did not stage the pinned native dependencies'
  [[ -f "$SERVER_PLIST_STATE" && -f "$EDGE_PLIST_STATE" ]] ||
    fail 'prepare did not render both LaunchAgents'
  [[ -f "$UI_DIR/index.html" && -f "$UI_DIR/app.js" && -f "$UI_DIR/styles.css" ]] ||
    fail 'prepare did not stage the same-origin UI'
  assert_contains 'Wildcards are not supported.' "$TARGETS_FILE"
  assert_contains 'IMESSAGE_PROXY_SOCKET_PATH' "$CADDYFILE"
  assert_contains 'IMESSAGE_PROXY_UI_DIR' "$CADDYFILE"
  assert_contains 'IMESSAGE_PROXY_EDGE_LOG_PATH' "$CADDYFILE"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$SERVER_BIN"
  chmod 700 "$SERVER_BIN"
  bootstrap_capture="$temporary/bootstrap.args"
  run_server() { printf '<%s>\n' "$@" > "$bootstrap_capture"; }
  api_key bootstrap-admin --name 'local administrator' --expires-in-days 45
  assert_contains '<bootstrap-admin>' "$bootstrap_capture"
  assert_contains '<local administrator>' "$bootstrap_capture"
  assert_contains '<45>' "$bootstrap_capture"
  : > "$DATABASE_PATH"
  chmod 600 "$DATABASE_PATH"

  (
    render_server_agent_to() { printf '%s\n' 'new server definition' > "$1"; }
    expect_failure 'staged native LaunchAgent does not match current configuration' \
      require_current_server_agent
  )
  (
    render_edge_agent_to() { printf '%s\n' 'new edge definition' > "$1"; }
    expect_failure 'staged edge LaunchAgent does not match current configuration' \
      require_current_edge_agent
  )

  expect_failure 'server-stop confirmation did not match' server_stop 'not confirmed'
  expect_failure 'server-restart confirmation did not match' server_restart 'not confirmed'
  expect_failure 'edge-install confirmation did not match' edge_install 'not confirmed'
  expect_failure 'edge-restart confirmation did not match' edge_restart 'not confirmed'
  (
    export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS='no'
    expect_failure 'set IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=yes' require_public_edge_inputs
  )

  (
    launchctl() {
      printf '%s\n' 'Could not find service in domain for system' >&2
      return 113
    }
    expect_status 1 launchctl_snapshot "$SERVER_LABEL"
  )
  (
    launchctl() { return 113; }
    expect_status 2 launchctl_snapshot "$SERVER_LABEL"
  )
  (
    launchctl() { return 5; }
    expect_status 2 launchctl_snapshot "$SERVER_LABEL"
  )
  (
    launchctl() { :; }
    expect_status 2 launchctl_snapshot "$SERVER_LABEL"
  )
  (
    launchctl() {
      printf '%s\n' 'state = running'
      printf '%s\n' 'unexpected launchctl diagnostic' >&2
    }
    expect_status 2 launchctl_snapshot "$SERVER_LABEL"
  )
  if compgen -G "$TMPDIR/imessage-proxy-launchctl.*" >/dev/null; then
    fail 'launchctl_snapshot left a diagnostic temporary file behind'
  fi

  lifecycle_call_log=/dev/null
  mock_bootstrap=ok
  mock_bootout=ok
  mock_disable=ok
  mock_launchctl() {
    printf '%s\n' "$*" >> "$lifecycle_call_log"
    case "${1:-}" in
      bootstrap) [[ "$mock_bootstrap" == ok ]] ;;
      bootout) [[ "$mock_bootout" == ok ]] ;;
      disable) [[ "$mock_disable" == ok ]] ;;
      *) return 0 ;;
    esac
  }
  setup_lifecycle_prerequisites() {
    require_macos() { :; }
    require_safe_runtime_root() { :; }
    require_command() { :; }
    require_edge_stopped() { :; }
    check_host() { :; }
    require_current_server_agent() { :; }
    require_current_edge_agent() { :; }
    require_public_edge_inputs() { :; }
    require_safe_launch_agent_target() {
      mkdir -p "$(dirname "$1")"
      [[ ! -L "$1" ]] || fail "refusing test LaunchAgent symlink: $1"
    }
    prepare_edge_log() { :; }
    socket_ready() { return 0; }
    wait_for_socket() { return 0; }
    wait_for_socket_absent() { return 0; }
    wait_for_service_absent() { return 0; }
    wait_for_edge_ready() { return 0; }
    edge_ready() { return 0; }
    service_running() { return 0; }
    lsof() { return 1; }
    launchctl() { mock_launchctl "$@"; }
  }
  reset_lifecycle_case() {
    lifecycle_call_log="$temporary/$1.calls"
    : > "$lifecycle_call_log"
    mock_bootstrap=ok
    mock_bootout=ok
    mock_disable=ok
  }

  mkdir -p "$(dirname "$SERVER_PLIST_TARGET")"
  printf '%s\n' 'installed server drift' > "$SERVER_PLIST_TARGET"
  printf '%s\n' 'installed edge drift' > "$EDGE_PLIST_TARGET"
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-installed-drift
    server_loaded() { return 1; }
    expect_failure 'installed native LaunchAgent is stale' server_start
    [[ ! -s "$lifecycle_call_log" ]] ||
      fail 'server-start called launchctl for an installed plist drift'
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-installed-drift
    edge_loaded() { return 1; }
    expect_failure 'installed edge LaunchAgent is stale' edge_start
    [[ ! -s "$lifecycle_call_log" ]] ||
      fail 'edge-start called launchctl for an installed plist drift'
  )
  install -m 600 "$SERVER_PLIST_STATE" "$SERVER_PLIST_TARGET"
  install -m 600 "$EDGE_PLIST_STATE" "$EDGE_PLIST_TARGET"

  (
    edge_loaded() { return 2; }
    expect_failure 'could not determine public-edge LaunchAgent state' require_edge_stopped
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-state-error
    server_loaded() { return 2; }
    expect_failure 'could not determine native LaunchAgent state' server_install
    [[ ! -s "$lifecycle_call_log" ]] ||
      fail 'server-install mutated launchd after an inventory error'
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-state-error
    edge_loaded() { return 2; }
    expect_failure 'could not determine public-edge LaunchAgent state' \
      edge_install 'EXPOSE IMESSAGE PROXY PUBLICLY'
    [[ ! -s "$lifecycle_call_log" ]] ||
      fail 'edge-install mutated launchd after an inventory error'
  )

  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-port-conflict
    edge_loaded() { return 1; }
    lsof() { return 0; }
    expect_failure 'TCP port 8080 already has a listener' edge_start
    [[ ! -s "$lifecycle_call_log" ]] ||
      fail 'edge-start mutated launchd after detecting a port conflict'
  )

  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-install-bootstrap
    server_loaded() { return 1; }
    mock_bootstrap=fail
    expect_failure 'native LaunchAgent bootstrap failed and was disabled again' server_install
    assert_rollback "$SERVER_LABEL" "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-start-readiness
    server_loaded() { return 1; }
    wait_for_socket() { return 1; }
    expect_failure 'native LaunchAgent did not become ready and was disabled again' server_start
    assert_rollback "$SERVER_LABEL" "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-stop-socket
    server_loaded() { return 0; }
    wait_for_socket_absent() { return 1; }
    expect_failure 'native LaunchAgent stopped but its socket remains' \
      server_stop 'STOP IMESSAGE PROXY SERVER'
    assert_contains "disable gui/$(id -u)/$SERVER_LABEL" "$lifecycle_call_log"
    assert_contains "bootout gui/$(id -u)/$SERVER_LABEL" "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-restart-unload
    server_loaded() { return 0; }
    mock_bootout=fail
    expect_failure 'native LaunchAgent could not be unloaded; its label was disabled' \
      server_restart 'RESTART IMESSAGE PROXY SERVER'
    assert_contains "disable gui/$(id -u)/$SERVER_LABEL" "$lifecycle_call_log"
    assert_not_contains 'bootstrap ' "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-restart-bootstrap
    server_loaded() { return 0; }
    mock_bootstrap=fail
    expect_failure 'native LaunchAgent restart bootstrap failed and was disabled again' \
      server_restart 'RESTART IMESSAGE PROXY SERVER'
    assert_rollback "$SERVER_LABEL" "$lifecycle_call_log"
  )

  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-install-bootstrap
    edge_loaded() { return 1; }
    mock_bootstrap=fail
    expect_failure 'public-edge LaunchAgent bootstrap failed and was disabled again' \
      edge_install 'EXPOSE IMESSAGE PROXY PUBLICLY'
    assert_rollback "$EDGE_LABEL" "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-start-readiness
    edge_loaded() { return 1; }
    wait_for_edge_ready() { return 1; }
    expect_failure 'public edge did not become ready and was disabled' edge_start
    assert_rollback "$EDGE_LABEL" "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-rollback-disable-failure
    edge_loaded() { return 1; }
    wait_for_edge_ready() { return 1; }
    mock_disable=fail
    expect_failure 'URGENT: automatic public-edge rollback could not confirm containment' \
      edge_start
    assert_rollback "$EDGE_LABEL" "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-rollback-bootout-failure
    edge_loaded() { return 1; }
    wait_for_edge_ready() { return 1; }
    wait_for_service_absent() { return 1; }
    mock_bootout=fail
    expect_failure 'URGENT: automatic public-edge rollback could not confirm containment' \
      edge_start
    assert_rollback "$EDGE_LABEL" "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-restart-unload
    edge_loaded() { return 0; }
    mock_bootout=fail
    expect_failure 'public-edge LaunchAgent could not be unloaded; its label was disabled' \
      edge_restart 'RESTART IMESSAGE PROXY EDGE'
    assert_contains "disable gui/$(id -u)/$EDGE_LABEL" "$lifecycle_call_log"
    assert_not_contains 'bootstrap ' "$lifecycle_call_log"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case edge-restart-bootstrap
    edge_loaded() { return 0; }
    mock_bootstrap=fail
    expect_failure 'public-edge restart bootstrap failed and was disabled again' \
      edge_restart 'RESTART IMESSAGE PROXY EDGE'
    assert_rollback "$EDGE_LABEL" "$lifecycle_call_log"
  )
)

printf '%s\n' 'iMessage Proxy CLI lifecycle tests passed.'
