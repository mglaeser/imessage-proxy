#!/usr/bin/env bash
#
# iMessage Proxy one-command installer.
#
# The installer verifies the Mac, obtains a pinned iMessage Proxy release,
# builds and installs the lifecycle CLI, pins the native dependencies by
# SHA-256, writes one private configuration file, and runs the product's own
# guarded bootstrap. Progress goes to standard error. On success standard
# output is exactly the first administrator API key.
#
# It never enables public HTTPS. Public exposure stays behind the reviewed
# operations gate described in docs/operations.md.

set -Eeuo pipefail
export PATH='/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin'
export LC_ALL=C
umask 077

readonly PROJECT_REPOSITORY='mglaeser/imessage-proxy'
readonly PROJECT_URL="https://github.com/${PROJECT_REPOSITORY}"
readonly RELEASE_BASE_URL="${PROJECT_URL}/releases/download"
readonly LATEST_RELEASE_API="https://api.github.com/repos/${PROJECT_REPOSITORY}/releases/latest"
readonly SERVER_LABEL='io.github.mglaeser.imessage-proxy'
readonly EXPECTED_IMSG_VERSION='0.13.4'
readonly IMSG_PROJECT_URL='https://github.com/openclaw/imsg'
readonly EXPECTED_CADDY_VERSION='2.11.4'
readonly CADDY_BASE_URL='https://github.com/caddyserver/caddy/releases/download'
# Reviewed Caddy 2.11.4 release-archive digests; identical to the pins the CI
# workflow uses when it installs Caddy on macOS runners.
readonly CADDY_ARM64_ARCHIVE='caddy_2.11.4_mac_arm64.tar.gz'
readonly CADDY_ARM64_SHA512='3190ae0df98b59ab4b6021556fa35adc3c526a4f3e138776b0eaec8a037cc26121cbbb1ad53453f565551b47d37d5ba4755e2c2c3652256737fe2ce9e53c8ec0'
readonly CADDY_AMD64_ARCHIVE='caddy_2.11.4_mac_amd64.tar.gz'
readonly CADDY_AMD64_SHA512='e04eb10f9ce7e2e079bc9bff1bd5d3a3164888d1edbb1a49e5d15be4eab691b57e89ed36bb29c65ba43f1ba8d9279e0967b1003991c13fe4cb78384c3caf25de'

action='install'
admin_name='local-bootstrap'
archive_path=''
archive_sha256=''
caddy_path=''
expires_days='30'
imsg_path=''
install_prefix="${HOME:-}/.local"
public_bind='0.0.0.0'
http_port='8080'
https_port='8443'
release_tag=''
run_tests='auto'
service_email=''
service_host=''
source_directory=''
temporary_root=''
verify_attestation='no'

# The installer runs both as a file and as `curl ... | bash`, where BASH_SOURCE
# is unset. Only a real file location can imply a local source tree.
script_directory=''
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fi
readonly SCRIPT_DIR="$script_directory"

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
Usage: install.sh [options]

Installs iMessage Proxy on this Mac and creates the first administrator key.

Options:
  --host HOSTNAME        Public DNS name the service will eventually use
  --email ADDRESS        Operator email used for future ACME certificates
  --imsg PATH            Absolute path to a reviewed imsg 0.13.4 executable
  --caddy PATH           Absolute path to a reviewed Caddy 2.11.4 executable
                         (default: download and verify the pinned release)
  --admin-name NAME      First administrator label (default: local-bootstrap)
  --expires-in-days N    First administrator lifetime, 1-365 (default: 30)
  --tag vMAJOR.MINOR.PATCH
                         Release to install (default: the pinned release)
  --source DIR           Install from an existing reviewed source tree
  --archive FILE         Install from an already downloaded release archive
  --sha256 HEX           Required release-archive digest for reviewed installs
  --attest               Additionally verify GitHub build provenance with gh
  --prefix DIR           Installation prefix (default: $HOME/.local)
  --tests, --no-tests    Force running or skipping the product test suite
  --self-test            Validate this installer's own logic and exit
  -h, --help             Show this help and exit

Public HTTPS stays disabled. Enable it deliberately afterwards by following
docs/operations.md.
USAGE
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

file_sha512() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$1" | awk '{print $1}'
  else
    sha512sum "$1" | awk '{print $1}'
  fi
}

hostname_valid() {
  local label name="$1"
  local -a labels
  [[ -n "$name" && "${#name}" -le 253 && "$name" != *[A-Z]* &&
    "$name" == *.* && "$name" != .* && "$name" != *. && "$name" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$name"
  for label in "${labels[@]}"; do
    [[ "${#label}" -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  [[ ! "$name" =~ ^[0-9.]+$ ]] || return 1
  case "$name" in
    example.com | *.example.com | example.net | *.example.net | example.org | *.example.org | \
      *.example | *.invalid | localhost | *.localhost | *.local | *.internal | \
      *.test | home.arpa | *.home.arpa | onion | *.onion | arpa | *.arpa) return 1 ;;
  esac
}

email_valid() {
  local address="$1" domain
  [[ "$address" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ &&
    "${#address}" -le 254 ]] || return 1
  domain="${address##*@}"
  hostname_valid "$domain"
}

admin_name_valid() {
  local name="$1"
  [[ -n "$name" && "${#name}" -le 80 &&
    "$name" != ' '* && "$name" != *' ' && "$name" != *[![:print:]]* ]]
}

expires_days_valid() {
  local days="$1"
  [[ "$days" =~ ^[1-9][0-9]{0,2}$ ]] && ((10#$days <= 365))
}

sha256_valid() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

release_tag_valid() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

config_value_valid() {
  local value="$1"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'#'* ]]
}

node_version_supported() {
  local version="$1"
  [[ "$version" =~ ^v22\.([0-9]+)\.([0-9]+)$ ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 12))
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        [[ $# -ge 2 ]] || die '--host requires a hostname'
        service_host="$2"
        shift 2
        ;;
      --email)
        [[ $# -ge 2 ]] || die '--email requires an address'
        service_email="$2"
        shift 2
        ;;
      --imsg)
        [[ $# -ge 2 ]] || die '--imsg requires a path'
        imsg_path="$2"
        shift 2
        ;;
      --caddy)
        [[ $# -ge 2 ]] || die '--caddy requires a path'
        caddy_path="$2"
        shift 2
        ;;
      --admin-name)
        [[ $# -ge 2 ]] || die '--admin-name requires a value'
        admin_name="$2"
        shift 2
        ;;
      --expires-in-days)
        [[ $# -ge 2 ]] || die '--expires-in-days requires a value'
        expires_days="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || die '--tag requires a release tag'
        release_tag="$2"
        shift 2
        ;;
      --source)
        [[ $# -ge 2 ]] || die '--source requires a directory'
        source_directory="$2"
        shift 2
        ;;
      --archive)
        [[ $# -ge 2 ]] || die '--archive requires a file'
        archive_path="$2"
        shift 2
        ;;
      --sha256)
        [[ $# -ge 2 ]] || die '--sha256 requires a digest'
        archive_sha256="$2"
        shift 2
        ;;
      --attest)
        verify_attestation='yes'
        shift
        ;;
      --prefix)
        [[ $# -ge 2 ]] || die '--prefix requires a directory'
        install_prefix="$2"
        shift 2
        ;;
      --tests)
        run_tests='yes'
        shift
        ;;
      --no-tests)
        run_tests='no'
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
  admin_name_valid "$admin_name" ||
    die '--admin-name must contain 1-80 printable ASCII bytes without surrounding spaces'
  expires_days_valid "$expires_days" ||
    die '--expires-in-days must be in the range 1-365'
  [[ -z "$release_tag" ]] || release_tag_valid "$release_tag" ||
    die '--tag must have the form vMAJOR.MINOR.PATCH'
  [[ -z "$archive_sha256" ]] || sha256_valid "$archive_sha256" ||
    die '--sha256 must be a 64-character lowercase SHA-256 digest'
  [[ -z "$service_host" ]] || hostname_valid "$service_host" ||
    die '--host must be an explicit lowercase public DNS hostname'
  [[ -z "$service_email" ]] || email_valid "$service_email" ||
    die '--email must be a valid operator address on a public domain'
  [[ -z "$imsg_path" || "$imsg_path" == /* ]] ||
    die '--imsg must be an absolute path'
  [[ -z "$caddy_path" || "$caddy_path" == /* ]] ||
    die '--caddy must be an absolute path'
  [[ "$install_prefix" == /* ]] || die '--prefix must be an absolute path'
  [[ -z "$source_directory" || -z "$archive_path" ]] ||
    die 'use either --source or --archive, not both'
}

require_supported_host() {
  [[ "$(uname -s)" == Darwin ]] || die 'iMessage Proxy runs only on macOS'
  [[ "$EUID" -ne 0 ]] || die 'run the installer as the Messages.app user, not root'
  [[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" && ! -L "$HOME" ]] ||
    die 'HOME must be a real absolute user directory'
  require_command awk
  require_command curl
  require_command install
  require_command launchctl
  require_command make
  require_command mktemp
  require_command shasum
  require_command tar
  require_command uname
  command -v xcrun >/dev/null 2>&1 ||
    die 'install the Xcode Command Line Tools first: xcode-select --install'
  xcrun --find clang >/dev/null 2>&1 ||
    die 'the Xcode Command Line Tools are incomplete; run xcode-select --install'
}

require_terminal() {
  [[ -r /dev/tty && -w /dev/tty ]] ||
    die 'run the installer in an interactive terminal; macOS Full Disk Access must be granted interactively'
}

prompt_for_value() {
  local answer='' label="$1"
  printf '%s' "$label" >&2
  IFS= read -r answer < /dev/tty || die 'could not read the answer from the terminal'
  printf '%s\n' "$answer"
}

service_is_installed() {
  launchctl print "gui/$(id -u)/$SERVER_LABEL" >/dev/null 2>&1
}

make_temporary_root() {
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/imessage-proxy-install.XXXXXX")"
  readonly temporary_root
  trap 'rm -rf -- "${temporary_root:-}"' EXIT
}

download_verified_file() {
  local destination="$2" status url="$1"
  status=0
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --silent --show-error \
    --output "$destination" "$url" || status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 22 ]]; then
      note "The server did not publish this file: $url"
    fi
    return "$status"
  fi
  [[ -f "$destination" && ! -L "$destination" ]] ||
    die "downloaded file is not a regular file: $destination"
}

require_download() {
  download_verified_file "$1" "$2" || die "could not download $1"
}

verify_archive_members() {
  local archive="$1" canonical expected_prefix="$2" listing member
  listing="$temporary_root/archive-members.txt"
  tar -tzf "$archive" > "$listing" || die 'could not list the release archive'
  [[ -s "$listing" ]] || die 'the release archive is empty'
  tar -tvzf "$archive" |
    awk '{type = substr($1, 1, 1); if (type != "-" && type != "d") exit 1}' ||
    die 'the release archive contains a link, device, or other unsupported entry'
  while IFS= read -r member; do
    [[ "$member" == "$expected_prefix"* ]] ||
      die "release archive member escapes $expected_prefix: $member"
    canonical="${member%/}"
    [[ -n "$canonical" && "$canonical" != /* ]] ||
      die "release archive contains an unsafe member: $member"
    case "/$canonical/" in
      *'//'* | *'/./'* | *'/../'*) die "release archive contains an unsafe member: $member" ;;
    esac
  done < "$listing"
}

verify_release_archive() {
  local actual archive="$1" published
  actual="$(file_sha256 "$archive")"
  if [[ -n "$archive_sha256" ]]; then
    [[ "$actual" == "$archive_sha256" ]] ||
      die 'the release archive does not match the reviewed --sha256 digest'
    note 'Verified the release archive against the reviewed digest.'
  elif [[ -f "$temporary_root/SHA256SUMS" ]]; then
    published="$(awk -v name="${archive##*/}" '$2 == name || $2 == "*" name {print $1}' \
      "$temporary_root/SHA256SUMS")"
    sha256_valid "$published" ||
      die 'the published SHA256SUMS file does not list this release archive'
    [[ "$actual" == "$published" ]] ||
      die 'the release archive does not match the published SHA256SUMS entry'
    note 'Verified the release archive against the published SHA256SUMS.'
  else
    die 'no release digest is available; pass --sha256 with a reviewed value'
  fi
  if [[ "$verify_attestation" == yes ]]; then
    require_command gh
    gh attestation verify "$archive" --repo "$PROJECT_REPOSITORY" >&2 ||
      die 'GitHub build provenance verification failed'
    note 'Verified GitHub build provenance for the release archive.'
  fi
}

parse_latest_release_tag() {
  awk '{
    if (match($0, /"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
      field = substr($0, RSTART, RLENGTH)
      sub(/^.*:[[:space:]]*"/, "", field)
      sub(/"$/, "", field)
      print field
      exit
    }
  }'
}

resolve_latest_release_tag() {
  local metadata tag
  metadata="$temporary_root/latest-release.json"
  require_download "$LATEST_RELEASE_API" "$metadata"
  tag="$(parse_latest_release_tag < "$metadata")"
  release_tag_valid "$tag" ||
    die 'could not determine the latest published release; pass --tag vMAJOR.MINOR.PATCH'
  note "Latest published release: $tag"
  printf '%s\n' "$tag"
}

resolve_source_tree() {
  local archive candidate tag version

  if [[ -n "$source_directory" ]]; then
    candidate="$(cd "$source_directory" 2>/dev/null && pwd -P)" ||
      die "cannot use --source directory: $source_directory"
    [[ -f "$candidate/VERSION" && -f "$candidate/Makefile" &&
      -f "$candidate/src/imessage-proxy-server.m" ]] ||
      die "--source must name a complete iMessage Proxy source tree: $candidate"
    printf '%s\n' "$candidate"
    return
  fi

  if [[ -z "$release_tag" && -z "$archive_path" && -n "$SCRIPT_DIR" &&
    -f "$SCRIPT_DIR/../VERSION" && -f "$SCRIPT_DIR/../src/imessage-proxy-server.m" ]]; then
    candidate="$(cd "$SCRIPT_DIR/.." && pwd -P)"
    note "Using the local iMessage Proxy source tree at $candidate"
    printf '%s\n' "$candidate"
    return
  fi

  tag="$release_tag"
  if [[ -z "$tag" ]]; then
    tag="$(resolve_latest_release_tag)"
  fi
  release_tag_valid "$tag" || die 'the release tag must have the form vMAJOR.MINOR.PATCH'
  version="${tag#v}"
  archive="$temporary_root/imessage-proxy-${version}.tar.gz"

  if [[ -n "$archive_path" ]]; then
    [[ -f "$archive_path" && ! -L "$archive_path" ]] ||
      die "--archive must name a regular non-symlink file: $archive_path"
    install -m 600 "$archive_path" "$archive" ||
      die "could not stage the supplied archive: $archive_path"
  else
    note "Downloading iMessage Proxy $tag from $PROJECT_URL"
    if ! download_verified_file \
      "$RELEASE_BASE_URL/$tag/imessage-proxy-${version}.tar.gz" "$archive"; then
      note ''
      note "iMessage Proxy $tag is not published yet."
      note "Check the available releases at $PROJECT_URL/releases and either"
      note '  install a published release:  --tag vMAJOR.MINOR.PATCH'
      note '  or install a reviewed checkout: --source /path/to/imessage-proxy'
      die "release $tag is unavailable"
    fi
    if [[ -z "$archive_sha256" ]]; then
      require_download "$RELEASE_BASE_URL/$tag/SHA256SUMS" \
        "$temporary_root/SHA256SUMS"
    fi
  fi

  verify_release_archive "$archive"
  verify_archive_members "$archive" "imessage-proxy-${version}/"
  mkdir -m 700 "$temporary_root/source"
  tar -xzf "$archive" -C "$temporary_root/source" ||
    die 'could not extract the release archive'
  candidate="$temporary_root/source/imessage-proxy-${version}"
  [[ -d "$candidate" && ! -L "$candidate" ]] ||
    die 'the release archive did not contain the expected source directory'
  [[ "$(< "$candidate/VERSION")" == "$version" ]] ||
    die 'the release archive VERSION does not match its tag'
  printf '%s\n' "$candidate"
}

tests_are_possible() {
  local version
  command -v node >/dev/null 2>&1 || return 1
  version="$(node --version 2>/dev/null)" || return 1
  node_version_supported "$version"
}

build_and_install_product() {
  local cli source_tree="$1" source_is_temporary="$2" version
  version="$(< "$source_tree/VERSION")"
  step "Building iMessage Proxy $version"
  make -C "$source_tree" build >&2 || die 'the native build failed'

  case "$run_tests" in
    yes)
      tests_are_possible ||
        die 'the product test suite needs Node.js >=22.12.0 <23 on PATH'
      step 'Running the product test suite'
      make -C "$source_tree" test >&2 || die 'the product test suite failed'
      ;;
    auto)
      if tests_are_possible; then
        step 'Running the product test suite'
        make -C "$source_tree" test >&2 || die 'the product test suite failed'
      else
        note 'Skipping the product test suite: Node.js >=22.12.0 <23 was not found.'
        note 'Run "make test" from a source checkout to execute it later.'
      fi
      ;;
    no) note 'Skipping the product test suite at your request.' ;;
  esac

  step "Installing the lifecycle CLI into $install_prefix"
  make -C "$source_tree" install PREFIX="$install_prefix" >&2 ||
    die 'the product installation failed'
  cli="$install_prefix/bin/imessage-proxy"
  [[ -x "$cli" && ! -L "$cli" ]] || die "the installed CLI is invalid: $cli"
  [[ "$("$cli" version)" == "$version" ]] ||
    die 'the installed CLI reports an unexpected version'
  # Only tidy build output the installer created itself; a user's own checkout
  # keeps whatever it had.
  if [[ "$source_is_temporary" == yes ]]; then
    make -C "$source_tree" clean >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$cli"
}

verify_dependency_binary() {
  local candidate="$1" label="$2"
  [[ "$candidate" == /* ]] || die "$label path must be absolute: $candidate"
  [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]] ||
    die "$label must be an executable regular non-symlink file: $candidate"
}

resolve_caddy() {
  local archive archive_name expected_sha512 managed managed_directory
  managed_directory="$install_prefix/libexec/imessage-proxy"
  managed="$managed_directory/caddy"

  if [[ -n "$caddy_path" ]]; then
    verify_dependency_binary "$caddy_path" 'Caddy'
    printf '%s\n' "$caddy_path"
    return
  fi
  if [[ -x "$managed" && ! -L "$managed" ]] &&
    [[ "$("$managed" version 2>/dev/null | awk '{print $1}')" == "v$EXPECTED_CADDY_VERSION" ]]; then
    note "Reusing the pinned Caddy $EXPECTED_CADDY_VERSION at $managed"
    printf '%s\n' "$managed"
    return
  fi

  case "$(uname -m)" in
    arm64)
      archive_name="$CADDY_ARM64_ARCHIVE"
      expected_sha512="$CADDY_ARM64_SHA512"
      ;;
    x86_64)
      archive_name="$CADDY_AMD64_ARCHIVE"
      expected_sha512="$CADDY_AMD64_SHA512"
      ;;
    *) die "unsupported macOS architecture: $(uname -m)" ;;
  esac

  step "Fetching the pinned Caddy $EXPECTED_CADDY_VERSION edge"
  archive="$temporary_root/$archive_name"
  require_download "$CADDY_BASE_URL/v$EXPECTED_CADDY_VERSION/$archive_name" "$archive"
  [[ "$(file_sha512 "$archive")" == "$expected_sha512" ]] ||
    die 'the downloaded Caddy archive does not match the reviewed SHA-512 digest'
  mkdir -m 700 "$temporary_root/caddy"
  tar -xzf "$archive" -C "$temporary_root/caddy" caddy ||
    die 'could not extract the Caddy executable'
  install -d -m 700 "$managed_directory"
  install -m 500 "$temporary_root/caddy/caddy" "$managed" ||
    die "could not install the pinned Caddy executable at $managed"
  [[ "$("$managed" version 2>/dev/null | awk '{print $1}')" == "v$EXPECTED_CADDY_VERSION" ]] ||
    die "the installed Caddy executable is not $EXPECTED_CADDY_VERSION"
  note "Installed the pinned Caddy $EXPECTED_CADDY_VERSION at $managed"
  printf '%s\n' "$managed"
}

resolve_imsg() {
  local candidate="$imsg_path" reported
  while true; do
    if [[ -z "$candidate" ]]; then
      note ''
      note "iMessage Proxy drives Messages.app through imsg $EXPECTED_IMSG_VERSION."
      note "Download and review it first: $IMSG_PROJECT_URL"
      candidate="$(prompt_for_value "Absolute path to imsg $EXPECTED_IMSG_VERSION: ")"
    fi
    if [[ "$candidate" == /* && -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]]; then
      reported="$("$candidate" --version 2>/dev/null || true)"
      if [[ "$reported" == "$EXPECTED_IMSG_VERSION" ]]; then
        printf '%s\n' "$candidate"
        return
      fi
      note "That executable reports '${reported:-unknown}'; exactly $EXPECTED_IMSG_VERSION is required."
    else
      note 'That path is not an absolute, executable, regular, non-symlink file.'
    fi
    [[ -z "$imsg_path" ]] || die "the --imsg executable is not a usable imsg $EXPECTED_IMSG_VERSION"
    candidate=''
  done
}

collect_service_identity() {
  while [[ -z "$service_host" ]] || ! hostname_valid "$service_host"; do
    if [[ -n "$service_host" ]]; then
      note 'That is not an explicit lowercase public DNS hostname.'
    else
      note ''
      note 'Name the service. Use the DNS name you would eventually publish, even'
      note 'though this installation stays private and binds no network port.'
    fi
    service_host="$(prompt_for_value 'Service hostname (for example messages.yourdomain.com): ')"
  done
  while [[ -z "$service_email" ]] || ! email_valid "$service_email"; do
    if [[ -n "$service_email" ]]; then
      note 'That is not a valid operator address on a public domain.'
    else
      note ''
      note 'Certificates are requested only if you later enable public HTTPS.'
    fi
    service_email="$(prompt_for_value 'Operator email: ')"
  done
}

write_service_config() {
  local caddy_binary="$1" caddy_digest config_directory config_path
  local imsg_binary="$2" imsg_digest temporary
  config_directory="$HOME/.config/imessage-proxy"
  config_path="$config_directory/service.env"

  if [[ -e "$config_path" || -L "$config_path" ]]; then
    [[ -f "$config_path" && ! -L "$config_path" ]] ||
      die "existing configuration must be a regular non-symlink file: $config_path"
    chmod 600 "$config_path"
    ! grep -q 'REPLACE_WITH' "$config_path" ||
      die "finish editing the existing configuration first: $config_path"
    note "Reusing the existing private configuration at $config_path"
    printf '%s\n' "$config_path"
    return
  fi

  caddy_digest="$(file_sha256 "$caddy_binary")"
  imsg_digest="$(file_sha256 "$imsg_binary")"
  sha256_valid "$caddy_digest" || die 'could not compute the Caddy SHA-256 digest'
  sha256_valid "$imsg_digest" || die 'could not compute the imsg SHA-256 digest'
  config_value_valid "$caddy_binary" || die 'the Caddy path cannot be stored as configuration'
  config_value_valid "$imsg_binary" || die 'the imsg path cannot be stored as configuration'

  install -d -m 700 "$config_directory"
  temporary="$(mktemp "$config_directory/service.env.XXXXXX")"
  {
    printf '%s\n' "IMESSAGE_PROXY_API_HOST=$service_host"
    printf '%s\n' "IMESSAGE_PROXY_ACME_EMAIL=$service_email"
    printf '%s\n' "IMESSAGE_PROXY_PUBLIC_BIND=$public_bind"
    printf '%s\n' "IMESSAGE_PROXY_HTTP_PORT=$http_port"
    printf '%s\n' "IMESSAGE_PROXY_HTTPS_PORT=$https_port"
    printf '%s\n' 'IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no'
    printf '%s\n' "IMESSAGE_PROXY_IMSG_BIN=$imsg_binary"
    printf '%s\n' "IMESSAGE_PROXY_IMSG_SHA256=$imsg_digest"
    printf '%s\n' "IMESSAGE_PROXY_CADDY_BIN=$caddy_binary"
    printf '%s\n' "IMESSAGE_PROXY_CADDY_SHA256=$caddy_digest"
  } > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$config_path"
  note "Wrote the private configuration to $config_path"
  printf '%s\n' "$config_path"
}

print_next_steps() {
  local config_path="$1"
  note ''
  note 'iMessage Proxy is running on its private Unix socket.'
  note "  Configuration: $config_path"
  note "  Allowlist:     $HOME/Library/Application Support/iMessage Proxy/private/allowed-targets.txt"
  note "  CLI:           $install_prefix/bin/imessage-proxy"
  note ''
  note 'Next: add one exact recipient to the allowlist, then send a test message.'
  note 'The administrator key above is shown once. Store it in a password manager.'
  note "Public HTTPS stays disabled. To publish the service, follow $PROJECT_URL/blob/main/docs/operations.md"
}

report_existing_installation() {
  note ''
  note "$SERVER_LABEL is already loaded, so the installer left it running."
  note 'The CLI and product assets were refreshed in place.'
  note ''
  note 'Check it, or create more keys from the management console:'
  note "  $install_prefix/bin/imessage-proxy server-status"
  note ''
  note 'To adopt a rebuilt server binary, stop the edge and server, then run'
  note 'prepare, build-host, and server-install as described in the operations guide.'
}

self_test() {
  local candidate long_name
  hostname_valid messages.acme-corp.com || die 'self-test rejected a valid hostname'
  hostname_valid a.b.c.example-host.io || die 'self-test rejected a valid nested hostname'
  for candidate in '' localhost messages.local messages.example.com MESSAGES.acme.com \
    'messages..acme.com' '.acme.com' 'acme.com.' 192.168.1.10 'messages.acme .com' \
    messages.home.arpa messages.invalid messages.test; do
    ! hostname_valid "$candidate" ||
      die "self-test accepted an invalid hostname: ${candidate:-<empty>}"
  done
  email_valid operator@acme-corp.com || die 'self-test rejected a valid email address'
  for candidate in '' operator operator@localhost operator@acme.invalid \
    'operator @acme.com' operator@example.com; do
    ! email_valid "$candidate" ||
      die "self-test accepted an invalid email address: ${candidate:-<empty>}"
  done
  admin_name_valid local-bootstrap || die 'self-test rejected a valid administrator name'
  long_name="$(printf 'a%.0s' {1..80})"
  admin_name_valid "$long_name" || die 'self-test rejected an 80-byte administrator name'
  for candidate in '' ' leading' 'trailing ' "$(printf 'control\001name')" "${long_name}a"; do
    ! admin_name_valid "$candidate" ||
      die "self-test accepted an invalid administrator name: ${candidate:-<empty>}"
  done
  expires_days_valid 1 || die 'self-test rejected a one-day credential'
  expires_days_valid 365 || die 'self-test rejected a 365-day credential'
  for candidate in '' 0 366 -1 30d 007; do
    ! expires_days_valid "$candidate" ||
      die "self-test accepted an invalid expiry: ${candidate:-<empty>}"
  done
  ! sha256_valid "$CADDY_ARM64_SHA512" ||
    die 'self-test accepted a SHA-512 digest as SHA-256'
  sha256_valid "$(printf '0%.0s' {1..64})" || die 'self-test rejected a valid SHA-256 digest'
  for candidate in '' abc "$(printf 'A%.0s' {1..64})" "$(printf '0%.0s' {1..63})"; do
    ! sha256_valid "$candidate" ||
      die "self-test accepted an invalid SHA-256 digest: ${candidate:-<empty>}"
  done
  release_tag_valid v1.0.0 || die 'self-test rejected a valid release tag'
  for candidate in '' 1.0.0 latest main v1.0 v1.0.0-rc.1; do
    ! release_tag_valid "$candidate" ||
      die "self-test accepted an invalid release tag: ${candidate:-<empty>}"
  done
  [[ "$LATEST_RELEASE_API" == "https://api.github.com/repos/$PROJECT_REPOSITORY/releases/latest" ]] ||
    die 'the latest-release endpoint does not target the project repository'
  node_version_supported v22.12.0 || die 'self-test rejected the minimum Node.js version'
  node_version_supported v22.23.2 || die 'self-test rejected a supported Node.js version'
  for candidate in v22.11.9 v23.0.0 22.12.0 v21.9.9; do
    ! node_version_supported "$candidate" ||
      die "self-test accepted an unsupported Node.js version: $candidate"
  done
  config_value_valid /opt/homebrew/bin/caddy || die 'self-test rejected a valid config value'
  for candidate in '' "$(printf 'value\nsecond=1')" "$(printf 'value\r')" 'value # comment'; do
    ! config_value_valid "$candidate" ||
      die 'self-test accepted an unsafe configuration value'
  done
  parse_latest_release_tag <<< '{"name":"x","tag_name":"v1.2.3","draft":false}' |
    grep -Fqx v1.2.3 || die 'self-test could not parse a release tag'
  parse_latest_release_tag <<< '{"tag_name": "v10.20.30" , "x":1}' |
    grep -Fqx v10.20.30 || die 'self-test could not parse a spaced release tag'
  [[ -z "$(parse_latest_release_tag <<< '{"name":"no tag here"}')" ]] ||
    die 'self-test invented a release tag'
  printf 'installer self-test passed\n' >&2
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
  require_terminal
  make_temporary_root

  local caddy_binary cli config_path imsg_binary source_is_temporary source_tree
  note 'iMessage Proxy installer'
  note 'Everything stays on this Mac. Public HTTPS is not enabled.'

  step 'Obtaining the reviewed source'
  source_tree="$(resolve_source_tree)"
  source_is_temporary=no
  if [[ -n "$temporary_root" && "$source_tree" == "$temporary_root"/* ]]; then
    source_is_temporary=yes
  fi
  cli="$(build_and_install_product "$source_tree" "$source_is_temporary")"

  if service_is_installed; then
    report_existing_installation
    return 0
  fi

  step 'Collecting service identity and native dependencies'
  collect_service_identity
  imsg_binary="$(resolve_imsg)"
  caddy_binary="$(resolve_caddy)"
  config_path="$(write_service_config "$caddy_binary" "$imsg_binary")"

  step 'Running the guarded product bootstrap'
  note 'The bootstrap pauses once so macOS can grant Full Disk Access.'
  "$cli" bootstrap \
    --config "$config_path" \
    --admin-name "$admin_name" \
    --expires-in-days "$expires_days"
  print_next_steps "$config_path"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
