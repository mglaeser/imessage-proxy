#!/usr/bin/env bash
#
# Builds and runs the native unit tier on whichever platform it is invoked on.
# On macOS that is Apple's clang against the real frameworks. On Linux it is the
# rootless GNUstep toolchain scripts/linux-toolchain.sh provisions plus the
# vendored SDK in tests/native/linux, which together make the same ARC sources
# compile and run on a host that has no Foundation of its own. The product is
# macOS-only; a tier only a Mac can run is a tier CI skips.
#
# The Foundation parity probe runs first and its failure stops the run, because
# a unit test that passes against a Foundation answering differently from
# Apple's is worse than no test: it reports a property the product does not have.

set -Eeuo pipefail

REPOSITORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPOSITORY
readonly TEST_DIR="$REPOSITORY/tests/native"
readonly SDK_DIR="$TEST_DIR/linux"
readonly BUILD_DIR="$REPOSITORY/build/native"
readonly RUNNER="$TEST_DIR/runner.m"
readonly PARITY_SOURCE="$SDK_DIR/foundation-parity.m"
readonly SHIM_SOURCE="$SDK_DIR/darwin-shim.c"
readonly SHIM_OBJECT="$BUILD_DIR/darwin-shim.o"

readonly OPT_ROOT="$HOME/.local/opt"
readonly TOOLCHAIN_ROOT="$OPT_ROOT/toolchain"
readonly LIBOBJC2_ROOT="$OPT_ROOT/libobjc2"
readonly GNUSTEP_ROOT="$OPT_ROOT/gnustep"
readonly CLANG="$HOME/.local/bin/lclang"
readonly TOOLCHAIN_REMEDY='bash scripts/linux-toolchain.sh'

filter="${1:-}"
readonly filter
platform="$(uname -s)"
readonly platform

report_failure() {
  printf 'ERROR: tests/native/run.sh failed at line %s with status %s.\n' "$2" "$1" >&2
}
trap 'report_failure "$?" "$LINENO"' ERR

require_toolchain() {
  local path="$1" label="$2"
  if [[ -e "$path" ]]; then
    return 0
  fi
  printf 'ERROR: %s is missing: %s\n' "$label" "$path" >&2
  printf 'ERROR: provision the Linux Objective-C toolchain with: %s\n' "$TOOLCHAIN_REMEDY" >&2
  exit 127
}

case "$platform" in
  Darwin)
    if ! command -v xcrun > /dev/null 2>&1; then
      printf 'ERROR: xcrun is required; install the command line tools with: xcode-select --install\n' >&2
      exit 127
    fi
    # The release build's warning set from the Makefile, unchanged, so a test
    # source is held to the same standard as the code it tests.
    readonly WARNINGS='-Wall -Wextra -Wpedantic -Werror -Wno-gnu-conditional-omitted-operand
      -Wno-gnu-statement-expression-from-macro-expansion'
    readonly OBJC_FLAGS='-fobjc-arc'
    ;;
  Linux)
    require_toolchain "$CLANG" 'the clang driver'
    require_toolchain "$LIBOBJC2_ROOT/lib/libobjc.so" 'the libobjc2 ARC runtime'
    require_toolchain "$GNUSTEP_ROOT/Local/Library/Headers/Foundation/Foundation.h" 'the GNUstep Foundation headers'
    require_toolchain "$GNUSTEP_ROOT/GNUstep.conf" 'the GNUstep configuration'
    # The host triple names the one sysroot library directory that holds
    # sqlite3, and getting it wrong assembles a link line out of the wrong
    # multiarch tree.
    case "$(uname -m)" in
      aarch64 | arm64) readonly HOST_TRIPLE='aarch64-linux-gnu' ;;
      x86_64) readonly HOST_TRIPLE='x86_64-linux-gnu' ;;
      *)
        printf 'ERROR: the native unit tier has no library path for architecture %s.\n' "$(uname -m)" >&2
        exit 1
        ;;
    esac
    require_toolchain "$TOOLCHAIN_ROOT/usr/lib/$HOST_TRIPLE" 'the unpacked sysroot'
    # The same warning set with two substitutions. Clang 14 spells the
    # statement-expression exemption without the -from-macro-expansion suffix
    # Clang 16 added, and refuses the whole build on an unknown warning option
    # under -Werror. -Wno-nullability-completeness is the one diagnostic here
    # that cannot be acted on: GNUstep's headers are not nullability audited, so
    # every unannotated pointer draws a warning that says nothing about this
    # repository.
    readonly WARNINGS='-Wall -Wextra -Wpedantic -Werror -Wno-gnu-conditional-omitted-operand
      -Wno-gnu-statement-expression -Wno-nullability-completeness'
    readonly OBJC_FLAGS='-fobjc-arc -fobjc-runtime=gnustep-2.0 -fblocks -fexceptions'
    # GNUstep resolves its own resource paths through this file, and without it
    # every Foundation call that reaches a bundle or the time zone database
    # fails with a diagnostic that blames the test rather than the environment.
    export GNUSTEP_CONFIG_FILE="$GNUSTEP_ROOT/GNUstep.conf"
    ;;
  *)
    printf 'ERROR: the native unit tier runs on macOS and Linux, not on %s.\n' "$platform" >&2
    exit 1
    ;;
esac

mkdir -p "$BUILD_DIR"

# One build function rather than two scripts, because both platforms have to
# build the same sources from the same list or the tier stops being a parity
# check and becomes two suites that happen to share a directory. GNUstep's own
# headers are reached through -isystem: they use named variadic macros and
# expand to `defined`, both of which -Wpedantic refuses, and lowering the
# warning level to accommodate somebody else's headers would lower it for the
# sources under test too.
build_suite() {
  local output="$1"
  shift
  case "$platform" in
    Darwin)
      # shellcheck disable=SC2086
      xcrun clang -O1 $OBJC_FLAGS $WARNINGS \
        -I"$TEST_DIR" \
        "$@" -o "$output" \
        -framework Foundation -framework Security -lsqlite3
      ;;
    Linux)
      # shellcheck disable=SC2086
      "$CLANG" -O1 $OBJC_FLAGS $WARNINGS \
        -I"$TEST_DIR" \
        -I"$SDK_DIR" \
        -isystem "$LIBOBJC2_ROOT/include" \
        -isystem "$GNUSTEP_ROOT/Local/Library/Headers" \
        -isystem "$TOOLCHAIN_ROOT/usr/include" \
        -include "$SDK_DIR/compat/darwin-compat.h" \
        "$@" "$SHIM_OBJECT" -o "$output" \
        -L"$LIBOBJC2_ROOT/lib" \
        -L"$GNUSTEP_ROOT/Local/Library/Libraries" \
        -L"$TOOLCHAIN_ROOT/usr/lib/$HOST_TRIPLE" \
        -lobjc -lgnustep-base -lsqlite3 -lpthread -lm \
        -Wl,-rpath,"$LIBOBJC2_ROOT/lib" \
        -Wl,-rpath,"$GNUSTEP_ROOT/Local/Library/Libraries"
      ;;
  esac
}

# Output is captured rather than streamed so that a failure can be reported once
# in full on stderr and a success can still show the divergence lines the parity
# probe prints. Every suite here finishes in well under a second, so there is
# nothing to watch while it runs. The third argument decides whether the filter
# reaches the binary, because the parity probe is a gate rather than a suite: a
# gate that ran a third of its checks would report a host as sound on evidence
# it never gathered. Run build/native/foundation-parity <substring> by hand to
# iterate on one of its checks.
run_suite() {
  local binary="$1" log="$2" filtered="$3" status=0
  if [[ "$filtered" = 'filtered' && -n "$filter" ]]; then
    "$binary" "$filter" > "$log" 2>&1 || status=$?
  else
    "$binary" > "$log" 2>&1 || status=$?
  fi
  return "$status"
}

if [[ "$platform" = 'Linux' ]]; then
  # The shim supplies CommonCrypto, Security, os_log, dispatch and the two
  # CoreFoundation type-id calls, none of which Linux has. It is plain C, it
  # depends on no suite, and it is rebuilt only when its source moves.
  if [[ ! -f "$SHIM_OBJECT" || "$SHIM_SOURCE" -nt "$SHIM_OBJECT" ]]; then
    # shellcheck disable=SC2086
    "$CLANG" -c -std=c11 -O1 -fblocks $WARNINGS \
      -I"$SDK_DIR" -isystem "$LIBOBJC2_ROOT/include" \
      "$SHIM_SOURCE" -o "$SHIM_OBJECT"
  fi
fi

printf '%s\n' 'Building and running the Foundation parity probe.'
build_suite "$BUILD_DIR/foundation-parity" "$RUNNER" "$PARITY_SOURCE"
if ! run_suite "$BUILD_DIR/foundation-parity" "$BUILD_DIR/foundation-parity.log" whole; then
  cat -- "$BUILD_DIR/foundation-parity.log" >&2
  # Every parity message opens with the name of the API it measures, so the
  # first failure is the shortest true statement of what is wrong with the host.
  first_failure="$(grep -m 1 '^FAIL: ' "$BUILD_DIR/foundation-parity.log" ||
    printf 'FAIL: the probe exited without naming an API')"
  printf 'ERROR: this host does not answer the way the Foundation the product ships against does.\n' >&2
  printf 'ERROR: %s\n' "${first_failure#FAIL: }" >&2
  printf 'ERROR: the native unit tier is refused here until that API agrees.\n' >&2
  exit 1
fi
cat -- "$BUILD_DIR/foundation-parity.log"

# Suites are discovered rather than listed, so adding a file is the whole of
# adding its tests. They fall into two kinds and the difference is structural: a
# suite that registers its cases with IMP_TEST is linked with runner.m, which
# supplies main and the filter, while a suite that #includes a production source
# whole cannot be, because src/imessage-proxy-server.m:3746 has a main of its
# own and two of them do not link. The self-contained kind is therefore built
# and run alone, and then compiled a second time into the registered binary in
# the exposure-only mode the next block describes.
registered_count=0
registered_sources=()
standalone_count=0
standalone_sources=()
for candidate in "$TEST_DIR"/test-*.m; do
  [[ -f "$candidate" ]] || continue
  if grep -q 'IMP_TEST(' "$candidate"; then
    registered_sources[registered_count]="$candidate"
    registered_count=$((registered_count + 1))
  else
    standalone_sources[standalone_count]="$candidate"
    standalone_count=$((standalone_count + 1))
  fi
done

if [[ "$registered_count" -eq 0 && "$standalone_count" -eq 0 ]]; then
  printf '%s\n' 'No tests/native/test-*.m sources yet, so the parity probe is the whole run.'
  exit 0
fi

if [[ "$registered_count" -gt 0 ]]; then
  printf '%s\n' 'Building and running the native unit tests.'
  # Every self-contained suite is compiled a second time into this binary under
  # -DIMP_TEST_EXPOSE_ONLY, which is the contract that makes a cross-file test
  # possible at all: a rule written once at the HTTP layer and once at the
  # database can only be compared by a translation unit that can reach both, and
  # neither production source can be compiled twice into one binary. Under that
  # macro a self-contained suite must reduce to its imp_test_expose_* shims and
  # nothing else - no entry point, no registry, no cases - or this link fails
  # with a duplicate symbol naming whichever of the three it kept.
  build_suite "$BUILD_DIR/unit-tests" -DIMP_TEST_EXPOSE_ONLY "$RUNNER" "${registered_sources[@]}" \
    ${standalone_sources[@]+"${standalone_sources[@]}"}
  if ! run_suite "$BUILD_DIR/unit-tests" "$BUILD_DIR/unit-tests.log" filtered; then
    cat -- "$BUILD_DIR/unit-tests.log" >&2
    exit 1
  fi
  cat -- "$BUILD_DIR/unit-tests.log"
fi

standalone_ran=0
for suite in ${standalone_sources[@]+"${standalone_sources[@]}"}; do
  name="$(basename "$suite" .m)"
  # A self-contained suite has no filter contract of its own, so the argument
  # selects whole suites by name instead of being handed down.
  if [[ -n "$filter" && "$name" != *"$filter"* ]]; then
    continue
  fi
  standalone_ran=$((standalone_ran + 1))
  printf 'Building and running %s.\n' "$name"
  build_suite "$BUILD_DIR/$name" "$suite"
  status=0
  "$BUILD_DIR/$name" > "$BUILD_DIR/$name.log" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]]; then
    cat -- "$BUILD_DIR/$name.log" >&2
    exit 1
  fi
  cat -- "$BUILD_DIR/$name.log"
done

# The runner refuses a filter that selects none of its tests, so the only way a
# filter can quietly run nothing is when every suite is self-contained. A typo
# in the argument would otherwise look exactly like a clean run.
if [[ -n "$filter" && "$registered_count" -eq 0 && "$standalone_ran" -eq 0 ]]; then
  printf 'ERROR: no native unit suite name contains: %s\n' "$filter" >&2
  exit 1
fi
