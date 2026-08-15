#!/usr/bin/env bash
#
# iMessage Proxy one-command installer.
#
# The installer verifies the Mac, obtains a pinned iMessage Proxy release,
# builds and installs the lifecycle CLI, pins imsg by SHA-256, writes one private
# configuration file, and runs the product's own guarded bootstrap. Progress goes
# to standard error. On success standard output is exactly the first
# administrator API key.
#
# Sending is proved before reading is discussed. Sending is guarded by Apple
# Events, which macOS prompts for, so a test send raises that prompt while the
# operator is watching and leaves them with a message they can point at. Reading
# is guarded by Full Disk Access, which macOS never prompts for, so it is a
# question with a manual checkpoint behind it - and one an installation may
# answer with no and still be complete.
#
# The service listens on 127.0.0.1 only. Publishing it is the operator's job,
# with their own TLS proxy in front.

set -Eeuo pipefail
# Captured before the hardened PATH below replaces it. Deciding whether the
# install prefix is already reachable has to ask what the operator's shell has,
# not what this script set for its own subprocesses; against the hardened value
# the answer is always "no" for the default prefix, which would append an export
# to a startup file that already had one.
readonly OPERATOR_PATH="${PATH:-}"
export PATH='/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin'
export LC_ALL=C
umask 077

readonly PROJECT_REPOSITORY='mglaeser/imessage-proxy'
readonly PROJECT_URL="https://github.com/${PROJECT_REPOSITORY}"
readonly RELEASE_BASE_URL="${PROJECT_URL}/releases/download"
readonly REPOSITORY_API="https://api.github.com/repos/${PROJECT_REPOSITORY}"
readonly SOURCE_ARCHIVE_BASE_URL="https://codeload.github.com/${PROJECT_REPOSITORY}/tar.gz"
# The 1.0 architecture lives on main. No 1.0 release is published yet, so the
# default install resolves main's current commit and proves the downloaded
# archive is exactly that commit. Published releases predate this architecture
# and are opt-in through --tag.
readonly SOURCE_BRANCH='main'
readonly SERVER_LABEL='io.github.mglaeser.imessage-proxy'
readonly EXPECTED_IMSG_VERSION='0.13.4'
readonly IMSG_BASE_URL='https://github.com/openclaw/imsg/releases/download'
readonly IMSG_ARCHIVE='imsg-macos.zip'
# Reviewed digest of the published imsg 0.13.4 macOS archive.
readonly IMSG_ARCHIVE_SHA256='e2fcac341363b5d53d16d28e61df981c4585bcc6b7fa8fdc77ec41f14e87c468'

action='install'
admin_name='local-bootstrap'
archive_path=''
archive_sha256=''
expires_days='30'
imsg_path=''
install_prefix="${HOME:-}/.local"
key_file=''
release_tag=''
run_tests='auto'
service_port='8765'
bold=''
dim=''
cyan=''
green=''
yellow=''
red=''
magenta=''
reset=''
verbose='no'
# Both questions have a flag equivalent, and both resolve to what a bare Enter
# gives: no test send, no reading. An unattended run therefore installs a service
# that sends and does not read, and says so at the end.
messages_read='ask'
send_test='ask'
send_test_target=''
path_result=''
path_profile=''
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
  printf '%sERROR:%s %s\n' "${bold}${red}" "$reset" "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

step() {
  printf '\n%s==>%s %s%s%s\n' "${bold}${cyan}" "$reset" "$bold" "$*" "$reset" >&2
}

# Compiler command lines and install manifests are the loudest thing an operator
# sees and the least useful: they scroll the two facts that matter, the Full Disk
# Access checkpoint and the administrator key, off the screen. Keep them, show a
# single line instead, and print the whole log if the command fails or --verbose
# asked for it. The log is inside the temporary root, so it is removed with it.
run_quietly() {
  local description="$1" log status=0
  shift
  if [[ "$verbose" == yes ]]; then
    note "  $description"
    "$@" >&2 || return 1
    return 0
  fi
  log="$(mktemp "${temporary_root:-${TMPDIR:-/tmp}}/install-step.XXXXXX")"
  printf '  %s ... ' "$description" >&2
  "$@" > "$log" 2>&1 || status=$?
  if ((status != 0)); then
    printf '%sfailed%s\n' "${bold}${red}" "$reset" >&2
    note ''
    note "${red}${bold}$description failed. Full output:${reset}"
    cat "$log" >&2 || true
    rm -f -- "$log"
    return "$status"
  fi
  printf '%sdone%s\n' "$green" "$reset" >&2
  rm -f -- "$log"
}

usage() {
  cat >&2 <<'USAGE'
Usage: install.sh [options]

Installs iMessage Proxy on this Mac and creates the first administrator key.

Options:
  --imsg PATH            Use this imsg 0.13.4 executable instead of installing
                         the pinned one (a symlink such as a Homebrew shim is
                         resolved to its real target)
  --admin-name NAME      First administrator label (default: local-bootstrap)
  --expires-in-days N    First administrator lifetime, 1-1461 (default: 30)
  --tag vMAJOR.MINOR.PATCH
                         Release to install (default: the pinned release)
  --source DIR           Install from an existing reviewed source tree
  --archive FILE         Install from an already downloaded release archive
  --sha256 HEX           Required release-archive digest for reviewed installs
  --attest               Additionally verify GitHub build provenance with gh
  --port N               Loopback port for the service (default: 8765)
  --prefix DIR           Installation prefix (default: $HOME/.local)
  --tests, --no-tests    Force running or skipping the product test suite
  --send-test ADDRESS    Send the test message to this number or email without
                         asking; it is added to the send allowlist first
  --no-send-test         Skip the test send without asking
  --messages-read        Read the Messages database, and print the Full Disk
                         Access instructions, without asking
  --no-messages-read     Install a send-only service without asking
  --key-file PATH        Write the administrator key to this absolute path,
                         created private to you, instead of printing it
  --verbose              Show the full output of each build and install step
  --self-test            Validate this installer's own logic and exit
  -h, --help             Show this help and exit

Without --send-test/--no-send-test and --messages-read/--no-messages-read the
installer asks for both, so an unattended run needs them on the command line.
Adding --key-file leaves an unattended run with nothing on stdout at all, which
is the whole shape of one:

  curl -fsSL .../install.sh | bash -s -- --no-send-test --messages-read \
    --key-file "$HOME/imessage-proxy-admin.key"

Full Disk Access still has to be granted by hand afterwards. macOS has no way to
grant it from a script, and --messages-read prints the steps rather than pausing
on them when the questions were answered here.

The service listens on 127.0.0.1 only. Put your own TLS proxy in front of it if
you want to publish it.
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

admin_name_valid() {
  local name="$1"
  [[ -n "$name" && "${#name}" -le 80 &&
    "$name" != ' '* && "$name" != *' ' && "$name" != *[![:print:]]* ]]
}

expires_days_valid() {
  local days="$1"
  [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] && ((10#$days <= 1461))
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

# The rule target_is_valid in bin/imessage-proxy and IsDirectMessageRecipient in
# src/imessage-proxy-server.m both apply, minus chat_id: a test send goes to a
# person. Checked here as well as there so a mistyped address is refused while
# the operator is still looking at the prompt, rather than two commands later.
send_target_valid() {
  local digits value="$1"
  case "$value" in
    '' | -* | *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  [[ "${#value}" -le 256 ]] || return 1
  if [[ "$value" == +* ]]; then
    digits="${value#+}"
    [[ "$digits" =~ ^[1-9][0-9]{6,14}$ ]] && return 0
  fi
  # Exactly one @, neither first nor last.
  [[ "$value" == *@* && "$value" != @* && "$value" != *@ && "$value" != *@*@* ]]
}

# A path that will be written into a shell startup file and evaluated by every
# later shell. Refuse anything that could terminate the quoting or start an
# expansion, rather than trying to escape it.
prefix_is_safe() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  case "$value" in
    *\'* | *\"* | *\\* | *'$'* | *'`'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'('* | *')'* | *[[:cntrl:]]*)
      return 1
      ;;
  esac
}

# An absolute path that names a file rather than a directory. Nothing here is
# re-evaluated by a later shell, so unlike the prefix it needs no quoting rules -
# only that it is somewhere this installer can put a credential and find it
# again.
key_file_valid() {
  local value="$1"
  [[ "$value" == /* ]] || return 1
  [[ "$value" != */ ]] || return 1
  [[ "$value" != *$'\n'* ]] || return 1
  [[ "${value##*/}" != '.' && "${value##*/}" != '..' ]]
}

node_version_supported() {
  local version="$1"
  [[ "$version" =~ ^v22\.([0-9]+)\.([0-9]+)$ ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 12))
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --imsg)
        [[ $# -ge 2 ]] || die '--imsg requires a path'
        imsg_path="$2"
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
      --port)
        [[ $# -ge 2 ]] || die '--port requires a number'
        service_port="$2"
        shift 2
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
      --send-test)
        [[ $# -ge 2 ]] || die '--send-test requires a number or email'
        send_test='yes'
        send_test_target="$2"
        shift 2
        ;;
      --no-send-test)
        send_test='no'
        shift
        ;;
      --messages-read)
        messages_read='enabled'
        shift
        ;;
      --no-messages-read)
        messages_read='disabled'
        shift
        ;;
      --key-file)
        [[ $# -ge 2 ]] || die '--key-file requires a path'
        key_file="$2"
        shift 2
        ;;
      --verbose)
        verbose='yes'
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
    die '--expires-in-days must be in the range 1-1461'
  [[ -z "$release_tag" ]] || release_tag_valid "$release_tag" ||
    die '--tag must have the form vMAJOR.MINOR.PATCH'
  [[ -z "$archive_sha256" ]] || sha256_valid "$archive_sha256" ||
    die '--sha256 must be a 64-character lowercase SHA-256 digest'
  if ! [[ "$service_port" =~ ^[0-9]+$ ]] || ((service_port < 1024 || service_port > 65535)); then
    die "--port must be in the range 1024-65535, not: $service_port"
  fi
  [[ -z "$imsg_path" || "$imsg_path" == /* ]] ||
    die '--imsg must be an absolute path'
  [[ "$install_prefix" == /* ]] || die '--prefix must be an absolute path'
  # The prefix is written into the operator's shell startup file, where it
  # outlives this process and is re-evaluated by every future shell. A quote or a
  # dollar sign there stops being a path and becomes code, so the characters that
  # could end the quoting or introduce an expansion are refused outright rather
  # than escaped. Spaces are allowed; the emitted line quotes the path.
  prefix_is_safe "$install_prefix" ||
    die '--prefix must not contain quotes, backslashes, dollar signs, backticks, semicolons, or control characters'
  [[ -z "$source_directory" || -z "$archive_path" ]] ||
    die 'use either --source or --archive, not both'
  [[ "$send_test" != yes ]] || send_target_valid "$send_test_target" ||
    die '--send-test must be +digits (7-15, no leading zero) or one address containing a single @'
  # Absolute, because the published shape of this installer is `curl ... | bash`
  # and a relative path would land wherever that shell happened to be. The
  # directory is checked here, before anything is built, so a run that cannot
  # deliver the key fails in the first second rather than after the install and
  # with the one credential it produces already gone.
  if [[ -n "$key_file" ]]; then
    key_file_valid "$key_file" || die "--key-file must be an absolute path to a file, not: $key_file"
    # -e is false for a symlink whose target does not exist, so a dangling one
    # would pass the overwrite check and then be followed by the redirection,
    # putting the credential wherever it points. Both are refused by name.
    [[ ! -e "$key_file" && ! -L "$key_file" ]] ||
      die "--key-file already exists, and will not be overwritten: $key_file"
    [[ -d "${key_file%/*}" ]] || die "--key-file directory does not exist: ${key_file%/*}"
    [[ -w "${key_file%/*}" ]] || die "--key-file directory is not writable: ${key_file%/*}"
  fi
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

# A terminal exists is not the same as somebody is watching. A CI runner keeps a
# controlling terminal while its output goes to a log, so /dev/tty opens happily
# and a read on it blocks until the job is killed - which is exactly what
# happened: the macOS job hit its 25 minute timeout on a question nobody could
# see. Progress goes to stderr, so a stderr that is a terminal is the signal that
# somebody is there to answer.
terminal_available() {
  [[ -t 2 ]] && [[ -r /dev/tty && -w /dev/tty ]]
}

# Only a run that still has something to ask needs a terminal. Both questions
# have flag equivalents, and answering them on the command line is what makes an
# unattended install possible at all.
require_terminal() {
  [[ "$send_test" == ask || "$messages_read" == ask ]] || return 0
  terminal_available ||
    die 'there is no terminal to ask on; answer with --send-test ADDRESS or --no-send-test, and --messages-read or --no-messages-read'
}

# Always /dev/tty, never stdin: the published shape of this installer is
# `curl ... | bash`, where stdin is the remainder of the script and a read would
# swallow it. A terminal that cannot be read answers nothing, which every caller
# treats as the skip.
ask_line() {
  local answer=''
  # Checked again here rather than trusted from the caller: a question that
  # cannot be seen must return the skip, never wait for it.
  terminal_available || {
    printf '\n'
    return 0
  }
  # The prompt is the only line on screen waiting for a person, so it is the only
  # one printed in the question colour.
  printf '  %s%s%s' "${bold}${yellow}" "$1" "$reset" >&2
  IFS= read -r answer < /dev/tty || answer=''
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

parse_json_string_field() {
  local field="$1"
  awk -v field="$field" '{
    pattern = "\"" field "\"[[:space:]]*:[[:space:]]*\"[^\"]+\""
    if (match($0, pattern)) {
      value = substr($0, RSTART, RLENGTH)
      sub(/^.*:[[:space:]]*"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  }'
}

commit_sha_valid() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

resolve_branch_commit() {
  local commit metadata
  metadata="$temporary_root/branch.json"
  require_download "$REPOSITORY_API/commits/$SOURCE_BRANCH" "$metadata"
  commit="$(parse_json_string_field sha < "$metadata")"
  commit_sha_valid "$commit" ||
    die "could not resolve the current $SOURCE_BRANCH commit; pass --tag vMAJOR.MINOR.PATCH"
  printf '%s\n' "$commit"
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

  if [[ -n "$archive_path" || -n "$release_tag" ]]; then
    resolve_released_source_tree
    return
  fi
  resolve_branch_source_tree
}

# Default path: install the current main commit. The 1.0 architecture, its
# bootstrap action, and this installer all live on main; published releases
# still carry the previous architecture and a CLI without bootstrap.
resolve_branch_source_tree() {
  local archive candidate commit prefix
  commit="$(resolve_branch_commit)"
  prefix="imessage-proxy-${commit}"
  archive="$temporary_root/${prefix}.tar.gz"
  note "Downloading iMessage Proxy $SOURCE_BRANCH at ${commit:0:7} from $PROJECT_URL"
  require_download "$SOURCE_ARCHIVE_BASE_URL/$commit" "$archive"
  verify_archive_members "$archive" "$prefix/"
  mkdir -m 700 "$temporary_root/source"
  tar -xzf "$archive" -C "$temporary_root/source" ||
    die 'could not extract the downloaded source archive'
  candidate="$temporary_root/source/$prefix"
  [[ -d "$candidate" && ! -L "$candidate" ]] ||
    die 'the source archive did not contain the expected directory'
  # GitHub exports REVISION through export-subst, so the archive proves which
  # commit it carries without trusting the download path.
  [[ -f "$candidate/REVISION" && "$(< "$candidate/REVISION")" == "$commit" ]] ||
    die 'the downloaded source archive does not carry the resolved commit'
  [[ -f "$candidate/VERSION" && -f "$candidate/src/imessage-proxy-server.m" ]] ||
    die 'the downloaded source archive is not a complete iMessage Proxy tree'
  note "Verified the source archive against commit $commit"
  printf '%s\n' "$candidate"
}

resolve_released_source_tree() {
  local archive candidate tag version
  tag="$release_tag"
  [[ -n "$tag" ]] || die '--archive requires --tag vMAJOR.MINOR.PATCH'
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
      note "iMessage Proxy $tag has no published source archive."
      note "Check $PROJECT_URL/releases, or omit --tag to install $SOURCE_BRANCH."
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
  require_bootstrap_capable_cli "$candidate" "$tag"
  printf '%s\n' "$candidate"
}

# Releases before 1.0 ship a CLI without the bootstrap action this installer
# drives. Refuse them up front instead of failing with a bare usage dump.
require_bootstrap_capable_cli() {
  local candidate="$1" label="$2"
  grep -Eq '^[[:space:]]*bootstrap\)' "$candidate/bin/imessage-proxy" || {
    note ''
    note "iMessage Proxy $label predates the one-command bootstrap architecture,"
    note 'so this installer cannot drive it.'
    note "Omit --tag to install $SOURCE_BRANCH, which supports it."
    die "$label does not support one-command installation"
  }
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
  run_quietly 'Compiling the native server' make -C "$source_tree" build ||
    die 'the native build failed'

  case "$run_tests" in
    yes)
      tests_are_possible ||
        die 'the product test suite needs Node.js >=22.12.0 <23 on PATH'
      step 'Running the product test suite'
      run_quietly 'Running the reviewed test suite' make -C "$source_tree" test ||
        die 'the product test suite failed'
      ;;
    auto)
      if tests_are_possible; then
        step 'Running the product test suite'
        run_quietly 'Running the reviewed test suite' make -C "$source_tree" test ||
        die 'the product test suite failed'
      else
        note 'Skipping the product test suite: Node.js >=22.12.0 <23 was not found.'
        note 'Run "make test" from a source checkout to execute it later.'
      fi
      ;;
    no) note 'Skipping the product test suite at your request.' ;;
  esac

  step "Installing the lifecycle CLI into $install_prefix"
  run_quietly 'Installing the CLI and reviewed assets' \
    make -C "$source_tree" install PREFIX="$install_prefix" ||
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

imsg_reports_expected_version() {
  [[ "$("$1" --version 2>/dev/null || true)" == "$EXPECTED_IMSG_VERSION" ]]
}

# imsg ships as a directory payload: the executable loads a sidecar dylib and
# resource bundles through @loader_path, so the whole payload must stay together
# and the executable must be launched from inside it.
install_pinned_imsg() {
  local archive candidate managed_directory payload
  managed_directory="$install_prefix/libexec/imessage-proxy/imsg-$EXPECTED_IMSG_VERSION"
  candidate="$managed_directory/imsg"

  if [[ -x "$candidate" && ! -L "$candidate" ]] && imsg_reports_expected_version "$candidate"; then
    note "Reusing the pinned imsg $EXPECTED_IMSG_VERSION at $candidate"
    printf '%s\n' "$candidate"
    return
  fi

  require_command unzip
  step "Fetching the pinned imsg $EXPECTED_IMSG_VERSION"
  archive="$temporary_root/$IMSG_ARCHIVE"
  require_download "$IMSG_BASE_URL/v$EXPECTED_IMSG_VERSION/$IMSG_ARCHIVE" "$archive"
  [[ "$(file_sha256 "$archive")" == "$IMSG_ARCHIVE_SHA256" ]] ||
    die 'the downloaded imsg archive does not match the reviewed SHA-256 digest'

  payload="$temporary_root/imsg-payload"
  mkdir -m 700 "$payload"
  unzip -q -o "$archive" -d "$payload" || die 'could not extract the imsg archive'
  [[ -f "$payload/imsg" && ! -L "$payload/imsg" ]] ||
    die 'the imsg archive did not contain the expected executable'
  # The executable alone is not the dependency. It dlopens the bridge dylib and
  # reads the resource bundles from its own directory, and only when sending, so
  # an archive missing one of these still reports its version and reads chats
  # while being unable to send a single message. Name them, so a future imsg that
  # renames or adds one fails here rather than at an operator's first send.
  for member in imsg-bridge-helper.dylib PhoneNumberKit_PhoneNumberKit.bundle SQLite.swift_SQLite.bundle; do
    [[ -e "$payload/$member" && ! -L "$payload/$member" ]] ||
      die "the imsg archive is missing the payload member $member"
  done
  chmod 700 "$payload/imsg"
  imsg_reports_expected_version "$payload/imsg" ||
    die "the downloaded imsg executable is not $EXPECTED_IMSG_VERSION"

  install -d -m 700 "$install_prefix/libexec/imessage-proxy"
  # Guard the recursive replace: only ever the installer's own versioned payload.
  [[ "$managed_directory" == "$install_prefix/libexec/imessage-proxy/imsg-$EXPECTED_IMSG_VERSION" ]] ||
    die "refusing to replace an unexpected imsg directory: $managed_directory"
  if [[ -e "$managed_directory" || -L "$managed_directory" ]]; then
    [[ -d "$managed_directory" && ! -L "$managed_directory" ]] ||
      die "existing imsg payload path is not a directory: $managed_directory"
    rm -rf -- "$managed_directory"
  fi
  mkdir -m 700 "$managed_directory"
  # Copy the complete payload; the executable cannot run without its siblings.
  (cd "$payload" && tar -cf - .) | (cd "$managed_directory" && tar -xf -) ||
    die "could not install the imsg payload at $managed_directory"
  chmod 500 "$candidate"
  [[ -x "$candidate" && ! -L "$candidate" ]] ||
    die "the installed imsg executable is invalid: $candidate"
  imsg_reports_expected_version "$candidate" ||
    die "the installed imsg executable is not $EXPECTED_IMSG_VERSION"
  note "Installed the pinned imsg $EXPECTED_IMSG_VERSION at $candidate"
  printf '%s\n' "$candidate"
}

# Expose imsg on PATH next to the product CLI. The executable finds its sidecar
# dylib and resource bundles through @loader_path, which dyld resolves from the
# real payload directory, so a symlink here is safe.
link_imsg() {
  local link payload="$1"
  link="$install_prefix/bin/imsg"
  install -d -m 755 "$install_prefix/bin"
  if [[ -e "$link" && ! -L "$link" ]]; then
    note "Left the existing $link in place; it is not managed by this installer."
    return
  fi
  ln -sfn "$payload" "$link" || die "could not link imsg at $link"
  [[ -x "$link" ]] || die "the imsg link is not executable: $link"
  note "Linked imsg to $link"
}

resolve_imsg() {
  local reported
  if [[ -z "$imsg_path" ]]; then
    install_pinned_imsg
    return
  fi

  # An explicit --imsg is honored, including a symlink such as a Homebrew shim:
  # resolve it to its real target rather than rejecting it.
  [[ "$imsg_path" == /* ]] || die '--imsg must be an absolute path'
  local resolved
  resolved="$(resolve_real_path "$imsg_path")" ||
    die "--imsg does not name an existing executable: $imsg_path"
  [[ -f "$resolved" && -x "$resolved" ]] ||
    die "--imsg must resolve to an executable regular file: $imsg_path"
  reported="$("$resolved" --version 2>/dev/null || true)"
  [[ "$reported" == "$EXPECTED_IMSG_VERSION" ]] ||
    die "--imsg reports '${reported:-unknown}'; exactly $EXPECTED_IMSG_VERSION is required"
  if [[ "$resolved" != "$imsg_path" ]]; then
    note "Resolved --imsg $imsg_path to $resolved"
  fi
  printf '%s\n' "$resolved"
}

resolve_real_path() {
  local target="$1"
  [[ -e "$target" ]] || return 1
  if [[ -L "$target" ]]; then
    # The product CLI requires a real, non-symlink path.
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target" 2>/dev/null ||
      readlink -f "$target" 2>/dev/null ||
      return 1
  else
    printf '%s\n' "$target"
  fi
}

write_service_config() {
  local config_directory config_path
  local imsg_binary="$1" imsg_digest temporary
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

  imsg_digest="$(file_sha256 "$imsg_binary")"
  sha256_valid "$imsg_digest" || die 'could not compute the imsg SHA-256 digest'
  config_value_valid "$imsg_binary" || die 'the imsg path cannot be stored as configuration'

  install -d -m 700 "$config_directory"
  temporary="$(mktemp "$config_directory/service.env.XXXXXX")"
  # Three keys: the one an operator might change, and the two that pin imsg.
  {
    printf '%s\n' "IMESSAGE_PROXY_PORT=$service_port"
    printf '%s\n' "IMESSAGE_PROXY_IMSG_BIN=$imsg_binary"
    printf '%s\n' "IMESSAGE_PROXY_IMSG_SHA256=$imsg_digest"
  } > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$config_path"
  note "Wrote the private configuration to $config_path"
  printf '%s\n' "$config_path"
}

# Colour only where it is wanted: NO_COLOR and a dumb TERM are honoured, and so
# is a redirect, because a log file full of escape sequences helps nobody.
# Colour is decoration everywhere except on the two things an operator has to act
# on - the question about reading their Messages, and the Full Disk Access steps
# behind it - which is why those get the strongest colour in the palette. An
# unattended run has no terminal on stderr, so every one of these is the empty
# string and the output is byte-identical to what it was before.
setup_colour() {
  bold='' dim='' cyan='' green='' yellow='' red='' magenta='' reset=''
  [[ -t 2 ]] || return 0
  [[ -z "${NO_COLOR:-}" ]] || return 0
  [[ "${TERM:-dumb}" != dumb ]] || return 0
  bold=$'\033[1m'
  dim=$'\033[2m'
  cyan=$'\033[36m'
  green=$'\033[32m'
  yellow=$'\033[33m'
  red=$'\033[31m'
  magenta=$'\033[35m'
  reset=$'\033[0m'
}

banner() {
  local version="$1"
  note ''
  note "  ${green}    ___ ${reset}"
  note "  ${green}   |   |    ${bold}iMessage Proxy${reset}"
  note "  ${green}   |   |__  ${dim}version ${version} - running on this Mac${reset}"
  note "  ${green}   |______| ${reset}"
  note ''
}

heading() {
  note "  ${bold}$*${reset}"
}

print_send_test_hint() {
  note 'Prove it whenever you like:'
  note "     ${dim}imessage-proxy targets add YOUR-NUMBER-OR-EMAIL${reset}"
  note "     ${dim}imessage-proxy send-test YOUR-NUMBER-OR-EMAIL${reset}"
}

# `targets add` refuses an address that is already listed, which is the ordinary
# state on a second run, so the list is consulted first rather than reading that
# refusal as a failure.
allow_send_target() {
  local address="$2" cli="$1" listed
  listed="$("$cli" targets list 2>/dev/null || true)"
  case $'\n'"$listed"$'\n' in
    *$'\n'"$address"$'\n'*) return 0 ;;
  esac
  run_quietly "Allowing $address to be messaged" "$cli" targets add "$address" ||
    die "could not add $address to the send allowlist"
}

# Sending is guarded by Apple Events, the one macOS permission here that does
# prompt. The test send raises that prompt now, with the operator warned and
# watching, instead of on some later request nobody is looking at - and it leaves
# them a delivered message as the proof. The address goes on the send allowlist
# first, because the service refuses every target that is not on it.
offer_test_send() {
  local address='' cli="$1"
  note 'macOS will ask you to allow control of Messages. Approve it: nothing'
  note 'can be sent until you do. If no window appears, look behind this one.'
  note ''
  if [[ "$send_test" == no ]]; then
    note 'Skipping the test send at your request.'
    print_send_test_hint
    return 0
  fi
  address="$send_test_target"
  if [[ "$send_test" == ask ]]; then
    while true; do
      address="$(ask_line 'Your own number or email for a test message, or Enter to skip: ')"
      [[ -n "$address" ]] || break
      send_target_valid "$address" && break
      note 'Use +15551234567 or name@example.com.'
    done
  fi
  if [[ -z "$address" ]]; then
    note 'Skipped, so nothing was sent.'
    print_send_test_hint
    return 0
  fi
  allow_send_target "$cli" "$address"
  note ''
  # A refused prompt is a fact about this Mac, not a broken install: the service
  # is running and everything else is done, so the run reports it and carries on.
  if "$cli" send-test "$address" >&2; then
    note "Sent, and $address is now an allowed recipient."
  else
    note ''
    note "$address is an allowed recipient, but the test message did not go out."
    note 'Approve the Messages prompt, then run:'
    note "     ${dim}imessage-proxy send-test $address${reset}"
  fi
}

# The one binary the grant has to name, derived exactly as bin/imessage-proxy
# derives SERVER_BIN. A grant given to any other path silently does nothing.
server_binary_path() {
  printf '%s\n' \
    "${IMESSAGE_PROXY_HOME:-$HOME/Library/Application Support/iMessage Proxy}/state/bin/imessage-proxy-server"
}

# Modelled on the message the pinned dependency prints when a read fails, with
# the one substitution that matters: the grant belongs to the LaunchAgent binary
# named below, not to a terminal or its parent launcher. TCC attributes the read
# to the process launchd started, so a terminal's own Full Disk Access proves
# nothing about the service.
print_full_disk_access_instructions() {
  local checkpoint="${1:-no}"
  note ''
  note "  ${bold}${yellow}FULL DISK ACCESS - THE ONE STEP YOU HAVE TO DO BY HAND${reset}"
  note ''
  note "  The Messages database at ${cyan}~/Library/Messages/chat.db${reset} requires"
  note "  ${bold}${yellow}Full Disk Access${reset} permission."
  note ''
  note "  ${bold}To grant it:${reset}"
  note "  ${bold}${yellow}1.${reset} Open ${bold}System Settings > Privacy & Security > Full Disk Access${reset}"
  note "  ${bold}${yellow}2.${reset} Add this exact binary, which is the one that reads the database:"
  note "       ${bold}${cyan}$(server_binary_path)${reset}"
  note "  ${bold}${yellow}3.${reset} Turn its switch ${green}on${reset}"
  note "  ${bold}${yellow}4.${reset} Toggle a stale entry off and on after the binary is rebuilt, since"
  note '     the grant follows its code signature'
  note "  ${bold}${yellow}5.${reset} Restart the service, then try again:"
  note "       ${dim}imessage-proxy server-restart --confirm 'RESTART IMESSAGE PROXY SERVER'${reset}"
  note ''
  note "  ${yellow}macOS never prompts for Full Disk Access, so nothing will ask you for${reset}"
  note "  ${yellow}this later.${reset}"
  # A checkpoint rather than a prompt: there is nothing to answer, and no probe
  # this script could run would prove the grant, since a read from here would
  # only ever prove the terminal's own permissions. It pauses solely to keep the
  # instructions on screen while they are followed, so a run that answered on the
  # command line - which is nobody watching - goes straight past it.
  if [[ "$checkpoint" == yes ]] && terminal_available; then
    ask_line 'Press Enter when you have added it: ' > /dev/null
  fi
}

# Reading needs Full Disk Access, which macOS never prompts for, so an
# installation that declines it is a supported configuration rather than a
# half-finished one. Asked after the send test on purpose: by now the operator
# has watched sending work and can weigh the broad grant against what it buys.
offer_messages_read() {
  local answer asked='no'
  note ''
  note "  ${bold}${magenta}READING YOUR MESSAGES${reset}"
  note ''
  note "  Reading the Messages database lists your ${cyan}chats${reset}, returns"
  note "  ${cyan}message history${reset}, answers the ${cyan}statistics${reset} routes and finds"
  note "  ${cyan}scheduled messages${reset}."
  note "  ${green}Sending never needs it${reset}, on either transport."
  note "  It needs ${bold}${yellow}Full Disk Access${reset}, which ${yellow}macOS never asks for${reset} -"
  note "  ${yellow}you grant it by hand, or reading stays off.${reset}"
  note ''
  if [[ "$messages_read" == ask ]]; then
    asked='yes'
    answer="$(ask_line 'Read your Messages as well? Type y, or Enter to skip: ')"
    case "$answer" in
      [yY] | [yY][eE][sS]) messages_read='enabled' ;;
      *) messages_read='disabled' ;;
    esac
  fi
  if [[ "$messages_read" == enabled ]]; then
    print_full_disk_access_instructions "$asked"
    return 0
  fi
  note ''
  note "  ${green}Reading stays off.${reset} Sending is unaffected on both transports."
}

# The service reads the switch once, when it starts, from the environment its
# LaunchAgent carries, and server-restart reinstalls the staged plist unchanged.
# The choice therefore only takes effect once that plist has been rendered again
# and reinstalled - and prepare refuses to render while the service is loaded,
# which is why this stops it in the middle rather than restarting it at the end.
apply_send_only() {
  local cli="$1"
  run_quietly 'Recording the send-only configuration' \
    "$cli" disable-messages-read --confirm 'DISABLE MESSAGES READ' ||
    die 'could not record the send-only configuration'
  run_quietly 'Stopping the service' \
    "$cli" server-stop --confirm 'STOP IMESSAGE PROXY SERVER' ||
    die 'could not stop the service to apply the send-only configuration'
  run_quietly 'Rendering the LaunchAgent' "$cli" prepare ||
    die 'could not render the send-only LaunchAgent'
  run_quietly 'Starting the service' "$cli" server-install ||
    die 'the send-only service could not be started again'
}

# Five facts and nothing else: where the console is, how to call the API, how to
# remove it all, what reading does today, and the key. Everything an operator
# needed the old six sections for is either unnecessary now or one command away.
print_next_steps() {
  local port="$1" version="$2"

  banner "$version"

  heading 'OPEN THE CONSOLE'
  note "     ${cyan}http://127.0.0.1:${port}${reset}"
  note ''

  heading 'OR CALL THE API'
  note "     ${dim}curl -H \"Authorization: Bearer KEY\" \\${reset}"
  note "     ${dim}  http://127.0.0.1:${port}/api/status${reset}"
  note ''

  heading 'UNINSTALL'
  note "     ${dim}curl -fsSL ${PROJECT_URL}/raw/main/scripts/uninstall.sh | bash${reset}"
  note ""
  note "  ${bold}UNINSTALL AND DESTROY KEYS, ALLOWLIST AND LOGS${reset}"
  note "     ${dim}curl -fsSL ${PROJECT_URL}/raw/main/scripts/uninstall.sh | bash -s -- \\${reset}"
  note "     ${dim}  --purge --confirm 'DESTROY IMESSAGE PROXY STATE'${reset}"
  note ''

  heading 'READING YOUR MESSAGES'
  if [[ "$messages_read" == enabled ]]; then
    note "     ${dim}On, as soon as Full Disk Access covers the server binary.${reset}"
    note "     ${dim}Until then /api/status reports messages-unavailable.${reset}"
  else
    note "     ${dim}Off. Listing chats, message history, the statistics routes${reset}"
    note "     ${dim}and scheduled messages answer 409 messages-read-disabled,${reset}"
    note "     ${dim}and so does a send addressed to a chat_id. Sending to a${reset}"
    note "     ${dim}recipient is unaffected. Turn reading on with:${reset}"
    note "     ${dim}  imessage-proxy enable-messages-read${reset}"
  fi
  note ''

  print_path_result
  note ''
  heading 'YOUR ADMINISTRATOR KEY'
  if [[ -n "$key_file" ]]; then
    note "  ${dim}Written to ${key_file}, readable only by you.${reset}"
    note "  ${dim}It is not printed here. Its sender identifier is adm, so every${reset}"
    note "  ${dim}message it sends ends with 🔖adm, or ^adm over SMS.${reset}"
  else
    note "  ${dim}Shown once, on the line below. Store it in a password manager.${reset}"
    note "  ${dim}Its sender identifier is adm, so every message it sends ends${reset}"
    note "  ${dim}with 🔖adm, or ^adm over SMS.${reset}"
  fi
  note ''
}

# The install prefix is frequently absent from an interactive shell's PATH, which
# otherwise leaves the operator with `command not found` right after a success.
# Adding the line is the whole remedy, so the installer does it rather than
# printing homework, and says exactly what it changed.
ensure_path_entry() {
  local line profile
  path_result=''
  # Checked again here, not only in validate_arguments: this is the one place
  # that writes a value into a file the operator's shell will evaluate forever,
  # so it refuses rather than trusting an earlier caller to have validated.
  if ! prefix_is_safe "$install_prefix"; then
    path_result='unsafe-prefix'
    return 0
  fi
  case ":$OPERATOR_PATH:" in
    *":$install_prefix/bin:"*)
      path_result='already'
      return 0
      ;;
  esac
  case "${SHELL##*/}" in
    zsh) profile="$HOME/.zshrc" ;;
    bash) profile="$HOME/.bash_profile" ;;
    *)
      path_result='unknown-shell'
      return 0
      ;;
  esac
  # Single-quoted, so the path cannot introduce an expansion or end its own
  # quoting even if prefix_is_safe is ever loosened. Only $PATH is left to expand
  # at shell start, which is the whole point of the line.
  line="export PATH='$install_prefix/bin':\"\$PATH\""
  if [[ -e "$profile" || -L "$profile" ]]; then
    [[ -f "$profile" && ! -L "$profile" ]] || {
      path_result='unsafe-profile'
      path_profile="$profile"
      return 0
    }
    if grep -Fqx -- "$line" "$profile" 2>/dev/null; then
      path_result='pending'
      path_profile="$profile"
      return 0
    fi
  fi
  {
    printf '\n%s\n' '# Added by the iMessage Proxy installer.'
    printf '%s\n' "$line"
  } >> "$profile" || {
    path_result='failed'
    path_profile="$profile"
    return 0
  }
  path_result='added'
  path_profile="$profile"
}

print_path_result() {
  heading 'YOUR PATH'
  case "$path_result" in
    already)
      note "  $install_prefix/bin is already on your PATH. Run: imessage-proxy server-status"
      ;;
    added)
      note "  Added $install_prefix/bin to $path_profile."
      note '  For this shell, run:'
      note "       export PATH=\"$install_prefix/bin:\$PATH\""
      ;;
    pending)
      note "  $path_profile already adds $install_prefix/bin, but this shell predates it."
      note '  For this shell, run:'
      note "       export PATH=\"$install_prefix/bin:\$PATH\""
      ;;
    unsafe-prefix)
      note "  $install_prefix/bin was not added to your shell startup file: the"
      note '  path contains characters that a shell would re-interpret. Use a'
      note '  prefix without quotes, backslashes, or expansion characters.'
      ;;
    *)
      note "  $install_prefix/bin is not on your PATH, and the installer could not"
      note '  add it safely. Add this line to your shell startup file:'
      note "       export PATH=\"$install_prefix/bin:\$PATH\""
      ;;
  esac
  note "  Until then use the full path: $install_prefix/bin/imessage-proxy"
}

# This branch refreshes the CLI and the product assets, and deliberately does
# not rebuild the staged server binary - only build-host does that, and only
# bootstrap and the explicit subcommand call it. So the operator is left with a
# new CLI driving the binary the previous release built, and this release parts
# them: the CLI now passes IMESSAGE_PROXY_MESSAGES_READ on every invocation and
# renders it into the LaunchAgent, while the previous binary refuses the setting
# by name and exits. check_host ends in `run_server check-config`, so
# server-install, server-start and server-restart all die there; server-status
# and server-restart also fail earlier, on the staged plist no longer matching
# what this CLI renders.
#
# The service that is already running is untouched by any of that and keeps
# working - until the first stop or reboot, after which nothing starts it again
# until the binary is rebuilt. Hence build-host in the sequence below: without
# it the operator stops a working service and cannot start it again, which is a
# worse outcome than the one they came here with.
#
# The CLI is asked, rather than the difference guessed at, because it is the
# thing that renders the plist and the thing that refuses.
report_existing_installation() {
  local cli="$1"
  note ''
  note "$SERVER_LABEL is already loaded, so the installer left it running."
  note 'The CLI and product assets were refreshed in place.'
  note ''
  if "$cli" server-status > /dev/null 2>&1; then
    note 'Check it, or create more keys from the management console:'
    note "  $install_prefix/bin/imessage-proxy server-status"
    ensure_path_entry
    print_path_result
    note ''
    note 'To adopt a rebuilt server binary, stop the edge and server, then run'
    note 'prepare, build-host, and server-install as described in the operations guide.'
    return 0
  fi
  note 'The service is still running, but this release changes both its'
  note 'LaunchAgent and what the CLI passes the server, so the lifecycle commands'
  note 'refuse until the staged plist and the server binary are both rebuilt.'
  note 'Nothing is lost, and the running service is unaffected until you stop it.'
  note 'Adopt the new build with all four, in this order:'
  note "  imessage-proxy server-stop --confirm 'STOP IMESSAGE PROXY SERVER'"
  note '  imessage-proxy prepare'
  note '  imessage-proxy build-host'
  note '  imessage-proxy server-install'
  ensure_path_entry
  print_path_result
}

self_test() {
  local candidate long_name
  admin_name_valid local-bootstrap || die 'self-test rejected a valid administrator name'
  long_name="$(printf 'a%.0s' {1..80})"
  admin_name_valid "$long_name" || die 'self-test rejected an 80-byte administrator name'
  for candidate in '' ' leading' 'trailing ' "$(printf 'control\001name')" "${long_name}a"; do
    ! admin_name_valid "$candidate" ||
      die "self-test accepted an invalid administrator name: ${candidate:-<empty>}"
  done
  expires_days_valid 1 || die 'self-test rejected a one-day credential'
  expires_days_valid 1461 || die 'self-test rejected a four-year credential'
  for candidate in '' 0 1462 -1 30d 007 10000; do
    ! expires_days_valid "$candidate" ||
      die "self-test accepted an invalid expiry: ${candidate:-<empty>}"
  done
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
  [[ "$REPOSITORY_API" == "https://api.github.com/repos/$PROJECT_REPOSITORY" ]] ||
    die 'the repository endpoint does not target the project repository'
  [[ "$SOURCE_ARCHIVE_BASE_URL" == "https://codeload.github.com/$PROJECT_REPOSITORY/tar.gz" ]] ||
    die 'the source-archive endpoint does not target the project repository'
  commit_sha_valid "$(printf 'a%.0s' {1..40})" ||
    die 'self-test rejected a valid commit SHA'
  for candidate in '' abc main "$(printf 'A%.0s' {1..40})" "$(printf 'a%.0s' {1..39})"; do
    ! commit_sha_valid "$candidate" ||
      die "self-test accepted an invalid commit SHA: ${candidate:-<empty>}"
  done
  sha256_valid "$IMSG_ARCHIVE_SHA256" ||
    die 'the pinned imsg archive digest is not a valid SHA-256'
  node_version_supported v22.12.0 || die 'self-test rejected the minimum Node.js version'
  node_version_supported v22.23.2 || die 'self-test rejected a supported Node.js version'
  for candidate in v22.11.9 v23.0.0 22.12.0 v21.9.9; do
    ! node_version_supported "$candidate" ||
      die "self-test accepted an unsupported Node.js version: $candidate"
  done
  for candidate in +15551234567 +447700900123 name@example.com a@b; do
    send_target_valid "$candidate" || die "self-test rejected a valid send target: $candidate"
  done
  for candidate in '' ' ' -15551234567 '+0155512345' '+15551' 'no-at-sign' 'a@b@c' '@leading' 'trailing@' \
    'has space@example.com' 'chat_id:42' "$(printf 'a%.0s' {1..250})@example.com"; do
    ! send_target_valid "$candidate" ||
      die "self-test accepted an invalid send target: ${candidate:-<empty>}"
  done
  for candidate in /tmp/admin.key "$HOME/keys/admin key.txt" /a; do
    key_file_valid "$candidate" || die "self-test rejected a valid key file: $candidate"
  done
  for candidate in '' relative/path ./admin.key /trailing/slash/ /dots/.. /dots/. "$(printf '/new\nline')"; do
    ! key_file_valid "$candidate" ||
      die "self-test accepted an invalid key file: ${candidate:-<empty>}"
  done
  config_value_valid /opt/homebrew/bin/caddy || die 'self-test rejected a valid config value'
  for candidate in '' "$(printf 'value\nsecond=1')" "$(printf 'value\r')" 'value # comment'; do
    ! config_value_valid "$candidate" ||
      die 'self-test accepted an unsafe configuration value'
  done
  parse_json_string_field sha <<< '{"sha":"0123456789abcdef0123456789abcdef01234567","x":1}' |
    grep -Fqx 0123456789abcdef0123456789abcdef01234567 ||
    die 'self-test could not parse a commit SHA'
  parse_json_string_field sha <<< '{"sha": "abc" , "y":2}' |
    grep -Fqx abc || die 'self-test could not parse a spaced JSON field'
  [[ -z "$(parse_json_string_field sha <<< '{"name":"no sha here"}')" ]] ||
    die 'self-test invented a JSON field value'
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

  local cli config_path imsg_binary source_is_temporary source_tree
  local -a bootstrap_terminal
  setup_colour
  note 'iMessage Proxy installer'
  note 'Everything stays on this Mac.'

  step 'Obtaining the reviewed source'
  source_tree="$(resolve_source_tree)"
  source_is_temporary=no
  if [[ -n "$temporary_root" && "$source_tree" == "$temporary_root"/* ]]; then
    source_is_temporary=yes
  fi
  cli="$(build_and_install_product "$source_tree" "$source_is_temporary")"

  if service_is_installed; then
    report_existing_installation "$cli"
    return 0
  fi

  step 'Installing the native dependency'
  imsg_binary="$(resolve_imsg)"
  link_imsg "$imsg_binary"
  config_path="$(write_service_config "$imsg_binary")"
  # Every action but bootstrap reads the reviewed configuration from
  # IMESSAGE_PROXY_CONFIG, and disable-messages-read writes to it. Pinning it to
  # the file this run just wrote stops an operator who already had the variable
  # set from having the service configured out of one file and switched in
  # another.
  export IMESSAGE_PROXY_CONFIG="$config_path"

  step 'Starting the service'
  # Waived only when this run has nothing left to ask. A run that still has a
  # question keeps the gate, so `bootstrap` refuses in a context that could not
  # have answered one either.
  bootstrap_terminal=()
  if [[ "$send_test" != ask && "$messages_read" != ask ]]; then
    bootstrap_terminal=(--unattended)
  fi
  "$cli" bootstrap \
    --config "$config_path" \
    --admin-name "$admin_name" \
    --expires-in-days "$expires_days" \
    --without-admin-key \
    "${bootstrap_terminal[@]+"${bootstrap_terminal[@]}"}"
  ensure_path_entry

  step 'Proving that sending works'
  offer_test_send "$cli"

  step 'Reading your Messages'
  offer_messages_read
  [[ "$messages_read" == enabled ]] || apply_send_only "$cli"

  print_next_steps "$service_port" "$("$cli" version)"
  # Deliberately the last command, and never captured. The key is the only thing
  # this script writes to stdout, so a pipeline can take it and nothing here can
  # leak it into a log or a trace - and because it runs last it lands directly
  # under the heading printed above.
  #
  # --key-file redirects that same stdout into a file instead. Redirected, not
  # captured: the key never becomes a shell variable, so it cannot reach an
  # error trace or the environment of anything this script runs. The file is
  # created empty and private first, so it never exists world-readable, not even
  # for the moment between creation and the write.
  if [[ -n "$key_file" ]]; then
    # noclobber makes the creation O_EXCL, so it fails rather than following a
    # symlink or truncating a file that appeared since validation - the window
    # between that check and here is the whole install. umask 077 applies to the
    # creation, which is this one; the redirection below only writes to the file
    # that already exists, so the mode stands.
    (
      umask 077
      set -o noclobber
      : > "$key_file"
    ) || die "could not create the key file, or something already exists at: $key_file"
    if ! "$cli" api-key bootstrap-admin --name "$admin_name" --expires-in-days "$expires_days" > "$key_file"; then
      # An empty file at the path the summary just named would read as a key
      # that failed to arrive, and would block the retry by existing.
      rm -f -- "$key_file"
      die 'the administrator key could not be issued'
    fi
    return 0
  fi
  "$cli" api-key bootstrap-admin --name "$admin_name" --expires-in-days "$expires_days"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
