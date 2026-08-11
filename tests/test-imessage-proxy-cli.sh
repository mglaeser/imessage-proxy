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
  'bootstrap --config FILE' \
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
# shellcheck disable=SC2030,SC2031,SC2329
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

  ((SERVER_START_TIMEOUT_SECONDS >= SERVER_READ_TIMEOUT_SECONDS + 10)) ||
    fail 'native startup readiness budget does not cover its Messages read preflight'

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

    require_macos() { :; }
    service_config="$security_dir/service.env"
    {
      printf '%s\n' \
        'IMESSAGE_PROXY_API_HOST=messages.integration.dev' \
        'IMESSAGE_PROXY_ACME_EMAIL=operator@integration.dev' \
        'IMESSAGE_PROXY_PUBLIC_BIND=0.0.0.0' \
        'IMESSAGE_PROXY_HTTP_PORT=8080' \
        'IMESSAGE_PROXY_HTTPS_PORT=8443' \
        'IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no' \
        "IMESSAGE_PROXY_IMSG_BIN=$fake_imsg" \
        "IMESSAGE_PROXY_IMSG_SHA256=$IMESSAGE_PROXY_IMSG_SHA256" \
        "IMESSAGE_PROXY_CADDY_BIN=$fake_caddy" \
        "IMESSAGE_PROXY_CADDY_SHA256=$IMESSAGE_PROXY_CADDY_SHA256"
    } > "$service_config"
    chmod 600 "$service_config"
    load_service_config "$service_config"
    [[ "$IMESSAGE_PROXY_API_HOST" == messages.integration.dev &&
      "$IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS" == no &&
      "$IMESSAGE_PROXY_IMSG_BIN" == "$fake_imsg" ]] ||
      fail 'closed service config did not load exact values'

    duplicate_config="$security_dir/service-duplicate.env"
    cp "$service_config" "$duplicate_config"
    printf '%s\n' 'IMESSAGE_PROXY_API_HOST=duplicate.integration.dev' >> "$duplicate_config"
    expect_failure 'defines IMESSAGE_PROXY_API_HOST more than once' \
      load_service_config "$duplicate_config"
    unknown_config="$security_dir/service-unknown.env"
    cp "$service_config" "$unknown_config"
    printf '%s\n' 'IMESSAGE_PROXY_API_KEY=must-not-load' >> "$unknown_config"
    expect_failure 'uses an unknown key' load_service_config "$unknown_config"
    missing_config="$security_dir/service-missing.env"
    sed '/^IMESSAGE_PROXY_CADDY_SHA256=/d' "$service_config" > "$missing_config"
    expect_failure 'is missing IMESSAGE_PROXY_CADDY_SHA256' \
      load_service_config "$missing_config"
    ln -s "$service_config" "$security_dir/service-link.env"
    expect_failure 'private file must be a regular non-symlink' \
      load_service_config "$security_dir/service-link.env"

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
  # A start failure used to be undiagnosable because both LaunchAgent streams
  # went to /dev/null. The server log must exist, be private, and be rendered
  # into the plist instead.
  [[ -f "$SERVER_LOG" && ! -L "$SERVER_LOG" ]] ||
    fail 'prepare did not create the bounded native server log safely'
  [[ "$(stat -f '%Lp' "$SERVER_LOG")" == 600 ]] ||
    fail 'the native server log is not private'
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

  server_environment_capture="$temporary/server-environment.capture"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "%s\n" "$IMESSAGE_PROXY_MESSAGES_DATABASE_PATH" "$IMESSAGE_PROXY_MAX_CONCURRENCY" "$IMESSAGE_PROXY_READ_TIMEOUT_SECONDS" "$IMESSAGE_PROXY_SEND_TIMEOUT_SECONDS" "$IMESSAGE_PROXY_SOCKET_TIMEOUT_SECONDS" > "$IMESSAGE_PROXY_TEST_CAPTURE"'
  } > "$SERVER_BIN"
  chmod 700 "$SERVER_BIN"
  IMESSAGE_PROXY_TEST_CAPTURE="$server_environment_capture" \
    IMESSAGE_PROXY_MESSAGES_DATABASE_PATH=/tmp/poisoned-chat.db \
    IMESSAGE_PROXY_MAX_CONCURRENCY=64 \
    IMESSAGE_PROXY_READ_TIMEOUT_SECONDS=300 \
    IMESSAGE_PROXY_SEND_TIMEOUT_SECONDS=1 \
    IMESSAGE_PROXY_SOCKET_TIMEOUT_SECONDS=60 \
    run_server check-config
  [[ "$(< "$server_environment_capture")" == \
    "${HOME}/Library/Messages/chat.db"$'\n8\n30\n180\n10' ]] ||
    fail 'run_server accepted ambient native configuration drift'

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

  # The checkpoint exists so a human reads the sentence, not to test typing. A
  # single mistyped character used to discard a completed build and install, so
  # case and surrounding whitespace are forgiven while the words remain
  # mandatory. Anything short of the full sentence must still be refused.
  for accepted in \
    'FULL DISK ACCESS GRANTED' \
    'full disk access granted' \
    'Full Disk Access Granted' \
    '   FULL DISK ACCESS GRANTED   '; do
    full_disk_access_acknowledgement_matches "$accepted" ||
      fail "a valid Full Disk Access acknowledgement was refused: $accepted"
  done
  for refused in \
    'FULL DISK ACCESS GRANTE' \
    'FULL DISK ACCESS' \
    'GRANTED' \
    'FULL  DISK ACCESS GRANTED' \
    'FULL DISK ACCESS GRANTED PLEASE' \
    'yes' \
    ''; do
    if full_disk_access_acknowledgement_matches "$refused"; then
      fail "an invalid Full Disk Access acknowledgement was accepted: $refused"
    fi
  done

  bootstrap_token="imp_$(printf 'a%.0s' {1..43})"
  (
    bootstrap_log="$temporary/bootstrap-sequence.log"
    bootstrap_stderr="$temporary/bootstrap-sequence.stderr"
    : > "$bootstrap_log"
    load_service_config() {
      printf '%s\n' config >> "$bootstrap_log"
      export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no
    }
    require_bootstrap_tty() { :; }
    doctor() { printf '%s\n' doctor >> "$bootstrap_log"; }
    prepare() { printf '%s\n' prepare >> "$bootstrap_log"; }
    build_host() { printf '%s\n' build-host >> "$bootstrap_log"; }
    acknowledge_full_disk_access() { printf '%s\n' full-disk-access >> "$bootstrap_log"; }
    initialize_database() { printf '%s\n' initialize-database >> "$bootstrap_log"; }
    check_messages_read_path() { printf '%s\n' messages-read >> "$bootstrap_log"; }
    check_bootstrap_eligibility() { printf '%s\n' bootstrap-preflight >> "$bootstrap_log"; }
    check_host() { printf '%s\n' check-host >> "$bootstrap_log"; }
    server_install() { printf '%s\n' server-install >> "$bootstrap_log"; }
    edge_install() { printf '%s\n' edge-install >> "$bootstrap_log"; }
    api_key_bootstrap() {
      printf 'key %s\n' "$*" >> "$bootstrap_log"
      printf '%s\n' "$bootstrap_token"
    }
    output="$(bootstrap --config /private/service.env --admin-name first-admin \
      --expires-in-days 14 2> "$bootstrap_stderr")"
    [[ "$output" == "$bootstrap_token" ]] || fail 'bootstrap stdout was not exactly the first key'
    [[ "$(< "$bootstrap_log")" == \
      $'config\ndoctor\nprepare\nbuild-host\nfull-disk-access\ninitialize-database\nbootstrap-preflight\ncheck-host\nmessages-read\nserver-install\nkey bootstrap-admin --name first-admin --expires-in-days 14' ]] ||
      fail 'bootstrap lifecycle order or final key operation changed'
    assert_not_contains 'edge-install' "$bootstrap_log"
    assert_not_contains "$bootstrap_token" "$bootstrap_stderr"
    assert_contains 'Progress is sent to stderr; the key is stdout only.' "$bootstrap_stderr"
  )
  (
    bootstrap_log="$temporary/bootstrap-public-sequence.log"
    : > "$bootstrap_log"
    load_service_config() { export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=yes; }
    require_bootstrap_tty() { :; }
    doctor() { printf '%s\n' doctor >> "$bootstrap_log"; }
    prepare() { printf '%s\n' prepare >> "$bootstrap_log"; }
    build_host() { printf '%s\n' build-host >> "$bootstrap_log"; }
    acknowledge_full_disk_access() { printf '%s\n' full-disk-access >> "$bootstrap_log"; }
    initialize_database() { printf '%s\n' initialize-database >> "$bootstrap_log"; }
    check_messages_read_path() { printf '%s\n' messages-read >> "$bootstrap_log"; }
    check_bootstrap_eligibility() { printf '%s\n' bootstrap-preflight >> "$bootstrap_log"; }
    check_host() { printf '%s\n' check-host >> "$bootstrap_log"; }
    server_install() { printf '%s\n' server-install >> "$bootstrap_log"; }
    edge_install() {
      [[ "$1" == 'EXPOSE IMESSAGE PROXY PUBLICLY' ]] || fail 'public bootstrap changed confirmation'
      printf '%s\n' edge-install >> "$bootstrap_log"
    }
    api_key_bootstrap() {
      printf '%s\n' key >> "$bootstrap_log"
      printf '%s\n' "$bootstrap_token"
    }
    output="$(bootstrap --config /private/service.env --admin-name first-admin --public \
      --confirm 'EXPOSE IMESSAGE PROXY PUBLICLY' 2> "$temporary/bootstrap-public.stderr")"
    [[ "$output" == "$bootstrap_token" ]] || fail 'public bootstrap did not return exactly the key'
    [[ "$(< "$bootstrap_log")" == \
      $'doctor\nprepare\nbuild-host\nfull-disk-access\ninitialize-database\nbootstrap-preflight\ncheck-host\nmessages-read\nserver-install\nedge-install\nkey' ]] ||
      fail 'public bootstrap lifecycle order or final key operation changed'
  )
  (
    bootstrap_log="$temporary/bootstrap-failure-sequence.log"
    : > "$bootstrap_log"
    load_service_config() { export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no; }
    require_bootstrap_tty() { :; }
    doctor() { :; }
    prepare() { :; }
    build_host() { false; fail 'errexit ignored an internal build failure'; }
    acknowledge_full_disk_access() { fail 'bootstrap continued after build failure'; }
    api_key_bootstrap() { fail 'bootstrap created a key after build failure'; }
    set +e
    (
      set -e
      bootstrap --config /private/service.env --admin-name first-admin
    ) > "$temporary/bootstrap-failure.stdout" 2> "$temporary/bootstrap-failure.stderr"
    bootstrap_status=$?
    set -e
    [[ "$bootstrap_status" -ne 0 ]] || fail 'bootstrap accepted a pre-key lifecycle failure'
    [[ ! -s "$temporary/bootstrap-failure.stdout" ]] ||
      fail 'failed bootstrap wrote secret-like stdout'
  )
  (
    bootstrap_log="$temporary/bootstrap-read-preflight-failure.log"
    : > "$bootstrap_log"
    load_service_config() { export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no; }
    require_bootstrap_tty() { :; }
    doctor() { :; }
    prepare() { :; }
    build_host() { :; }
    acknowledge_full_disk_access() { :; }
    initialize_database() { printf '%s\n' initialize-database >> "$bootstrap_log"; }
    check_bootstrap_eligibility() { printf '%s\n' bootstrap-preflight >> "$bootstrap_log"; }
    check_host() { printf '%s\n' check-host >> "$bootstrap_log"; }
    check_messages_read_path() {
      printf '%s\n' messages-read >> "$bootstrap_log"
      return 29
    }
    server_install() { fail 'bootstrap installed the server after a failed Messages read preflight'; }
    api_key_bootstrap() { fail 'bootstrap created a key after a failed Messages read preflight'; }
    set +e
    (
      set -e
      bootstrap --config /private/service.env --admin-name first-admin
    ) > "$temporary/bootstrap-read-preflight-failure.stdout" \
      2> "$temporary/bootstrap-read-preflight-failure.stderr"
    bootstrap_status=$?
    set -e
    [[ "$bootstrap_status" -eq 29 ]] ||
      fail 'bootstrap did not preserve the Messages read-preflight failure status'
    [[ ! -s "$temporary/bootstrap-read-preflight-failure.stdout" ]] ||
      fail 'failed Messages read preflight wrote secret-like stdout'
    [[ "$(< "$bootstrap_log")" == \
      $'initialize-database\nbootstrap-preflight\ncheck-host\nmessages-read' ]] ||
      fail 'bootstrap continued after the Messages read preflight failed'
  )
  (
    mutation_log="$temporary/bootstrap-invalid-mutation.log"
    : > "$mutation_log"
    load_service_config() { printf '%s\n' mutated >> "$mutation_log"; }
    for invalid_request in \
      '--admin-name|   |--expires-in-days|30' \
      '--admin-name|administrator|--expires-in-days|0' \
      '--admin-name|administrator|--expires-in-days|366'; do
      IFS='|' read -r name_flag name expiry_flag expiry <<< "$invalid_request"
      expect_failure '--' bootstrap --config /private/service.env \
        "$name_flag" "$name" "$expiry_flag" "$expiry"
    done
    long_admin_name="$(printf 'a%.0s' {1..81})"
    expect_failure '--admin-name must contain' bootstrap --config /private/service.env \
      --admin-name "$long_admin_name"
    for invalid_admin_name in \
      "administrator$(printf '\302\240')" \
      "administrator$(printf '\302\205')" \
      "administrator$(printf '\377')"; do
      expect_failure 'printable ASCII' bootstrap --config /private/service.env \
        --admin-name "$invalid_admin_name"
    done
    [[ ! -s "$mutation_log" ]] || fail 'invalid bootstrap arguments reached config or lifecycle work'
  )
  (
    mutation_log="$temporary/bootstrap-no-tty-mutation.log"
    : > "$mutation_log"
    load_service_config() { export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no; }
    require_bootstrap_tty() {
      die 'bootstrap needs an interactive controlling terminal before it can change runtime state'
    }
    doctor() { printf '%s\n' mutated >> "$mutation_log"; }
    expect_failure 'interactive controlling terminal' bootstrap \
      --config /private/service.env --admin-name first-admin
    [[ ! -s "$mutation_log" ]] || fail 'noninteractive bootstrap reached lifecycle work'
  )
  (
    rollback_log="$temporary/bootstrap-key-failure-rollback.log"
    : > "$rollback_log"
    load_service_config() { export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=yes; }
    require_bootstrap_tty() { :; }
    doctor() { :; }
    prepare() { :; }
    build_host() { :; }
    acknowledge_full_disk_access() { :; }
    initialize_database() { :; }
    check_messages_read_path() { :; }
    check_bootstrap_eligibility() { :; }
    check_host() { :; }
    server_install() { :; }
    edge_install() { :; }
    api_key_bootstrap() { return 9; }
    bootstrap_invoke_self() { printf '%s\n' "$*" >> "$rollback_log"; }
    set +e
    (
      set -e
      bootstrap --config /private/service.env --admin-name first-admin --public \
        --confirm 'EXPOSE IMESSAGE PROXY PUBLICLY'
    ) > "$temporary/bootstrap-key-failure.stdout" 2> "$temporary/bootstrap-key-failure.stderr"
    bootstrap_status=$?
    set -e
    [[ "$bootstrap_status" -eq 9 ]] || fail 'bootstrap did not preserve final key failure status'
    [[ ! -s "$temporary/bootstrap-key-failure.stdout" ]] ||
      fail 'failed final key creation wrote stdout'
    [[ "$(< "$rollback_log")" == $'edge-stop\nserver-stop --confirm STOP IMESSAGE PROXY SERVER' ]] ||
      fail 'bootstrap did not contain edge then server after final key failure'
  )
  (
    rollback_log="$temporary/bootstrap-server-install-failure-rollback.log"
    : > "$rollback_log"
    load_service_config() { export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no; }
    require_bootstrap_tty() { :; }
    doctor() { :; }
    prepare() { :; }
    build_host() { :; }
    acknowledge_full_disk_access() { :; }
    initialize_database() { :; }
    check_messages_read_path() { :; }
    check_bootstrap_eligibility() { :; }
    check_host() { :; }
    server_install() { return 23; }
    api_key_bootstrap() { fail 'bootstrap created a key after server-install failure'; }
    bootstrap_invoke_self() { printf '%s\n' "$*" >> "$rollback_log"; }
    set +e
    (
      set -e
      bootstrap --config /private/service.env --admin-name first-admin
    ) > "$temporary/bootstrap-server-install-failure.stdout" \
      2> "$temporary/bootstrap-server-install-failure.stderr"
    bootstrap_status=$?
    set -e
    [[ "$bootstrap_status" -eq 23 ]] ||
      fail 'bootstrap did not preserve server-install failure status'
    [[ "$(< "$rollback_log")" == 'server-stop --confirm STOP IMESSAGE PROXY SERVER' ]] ||
      fail 'bootstrap did not contain a possibly loaded server after install failure'
  )
  expect_failure "public bootstrap requires --confirm 'EXPOSE IMESSAGE PROXY PUBLICLY'" \
    bootstrap --config /private/service.env --admin-name first-admin --public

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

  (
    lsof() {
      printf '%s\n' p123 f7u "n$SOCKET_PATH"
    }
    server_socket_owned_by_pid 123 || fail 'the exact server Unix socket was not attributed to its PID'
    lsof() {
      printf '%s\n' p123 f7u "n${SOCKET_PATH}.stale"
    }
    ! server_socket_owned_by_pid 123 || fail 'a different Unix socket was attributed to the server PID'
  )
  (
    service_pid() { printf '%s\n' 123; }
    service_running() { :; }
    server_socket_owned_by_pid() { [[ "$1" == 123 ]]; }
    socket_ready() { :; }
    server_ready || fail 'a stable LaunchAgent PID owning the ready socket was rejected'
  )
  (
    service_pid() { return 1; }
    socket_ready() { :; }
    ! server_ready || fail 'a ready stale socket without a LaunchAgent PID was accepted'
  )
  (
    pid_state="$temporary/server-ready-pid-state"
    : > "$pid_state"
    service_pid() {
      if [[ -s "$pid_state" ]]; then
        printf '%s\n' 124
      else
        printf '%s\n' changed > "$pid_state"
        printf '%s\n' 123
      fi
    }
    service_running() { :; }
    server_socket_owned_by_pid() { :; }
    socket_ready() { :; }
    ! server_ready || fail 'a changing LaunchAgent PID was accepted as ready'
  )

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
    server_ready() { return 0; }
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
    reset_lifecycle_case server-stop-absent
    server_loaded() { return 1; }
    server_stop 'STOP IMESSAGE PROXY SERVER' > "$temporary/server-stop-absent.out"
    assert_contains "disable gui/$(id -u)/$SERVER_LABEL" "$lifecycle_call_log"
    assert_not_contains 'bootout ' "$lifecycle_call_log"
    assert_contains 'already stopped' "$temporary/server-stop-absent.out"
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
  # A readiness failure must carry its own explanation. This exact failure was
  # unresolvable in the field because both LaunchAgent streams went to /dev/null
  # and the operator was told only that the socket never appeared.
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-start-readiness-log
    server_loaded() { return 1; }
    wait_for_socket() { return 1; }
    printf '%s\n' 'WARNING: distinctive native startup detail' > "$SERVER_LOG"
    capture="$temporary/server-start-readiness-log.out"
    if (server_start) > "$capture" 2>&1; then
      fail 'server-start succeeded despite an unready socket'
    fi
    assert_contains 'distinctive native startup detail' "$capture"
    assert_contains 'server-logs' "$capture"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-start-readiness-empty-log
    server_loaded() { return 1; }
    wait_for_socket() { return 1; }
    : > "$SERVER_LOG"
    capture="$temporary/server-start-readiness-empty.out"
    if (server_start) > "$capture" 2>&1; then
      fail 'server-start succeeded despite an unready socket'
    fi
    assert_contains 'the log is empty' "$capture"
  )
  # A service that answers requests but cannot read Messages is running, not
  # healthy. Only lines appended by this start may raise the notice, so a stale
  # warning cannot become a false alarm.
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-start-degraded
    server_loaded() { return 1; }
    printf '%s\n' 'WARNING: serving in a degraded state.' > "$SERVER_LOG"
    wait_for_socket() {
      printf '%s\n' 'WARNING: serving in a degraded state.' >> "$SERVER_LOG"
      return 0
    }
    capture="$temporary/server-start-degraded.out"
    server_start > "$capture" 2>&1
    assert_contains 'cannot read Messages' "$capture"
    assert_contains 'Full Disk Access' "$capture"
  )
  (
    setup_lifecycle_prerequisites
    reset_lifecycle_case server-start-stale-degraded
    server_loaded() { return 1; }
    printf '%s\n' 'WARNING: serving in a degraded state.' > "$SERVER_LOG"
    capture="$temporary/server-start-stale-degraded.out"
    server_start > "$capture" 2>&1
    assert_not_contains 'cannot read Messages' "$capture"
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
