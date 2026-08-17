#!/usr/bin/env bash
#
# Rootless Objective-C toolchain provisioner for Linux hosts.
#
# The product is macOS-only, but its two Objective-C sources are ordinary ARC
# code, and being able to compile and run them on Linux is what makes a native
# unit-test tier possible on CI runners and developer boxes that are not Macs.
# Nothing Debian ships can do that: Debian's libobjc4 exports no ARC entry
# points at all, so clang refuses -fobjc-arc outright, and Debian's GNUstep is
# built against that same runtime. The way through is to build the GNUstep v2
# runtime and Foundation from source against clang, which this script does.
#
# Everything lands under $HOME/.local. There is no sudo anywhere, no apt-get
# install, and nothing is written outside $HOME - packages are downloaded as
# .debs and unpacked into a private sysroot with dpkg -x.
#
# Each stage is skipped when its output is already on disk, so a second run
# costs seconds rather than the twenty-five minutes a cold run takes. Use
# --check to prove an existing toolchain actually works without building
# anything.

set -Eeuo pipefail
export LC_ALL=C
# dpkg -x applies each archive's own file modes, so the umask only governs the
# directories this script creates itself. A permissive value keeps the unpacked
# sysroot diffable against the real /usr it mirrors.
umask 022

readonly OPT_ROOT="${HOME}/.local/opt"
readonly BIN_DIR="${HOME}/.local/bin"
readonly TOOLCHAIN_ROOT="${OPT_ROOT}/toolchain"
readonly LIBOBJC2_ROOT="${OPT_ROOT}/libobjc2"
readonly GNUSTEP_ROOT="${OPT_ROOT}/gnustep"
readonly LLVM18_ROOT="${OPT_ROOT}/llvm18"
# Downloads and build trees are cached rather than discarded. A failed stage is
# almost always retried immediately, and re-fetching 30 MB of pinned tarballs to
# reach the same checksum is pure latency. Everything here is verified against a
# pin on every use, so a stale cache cannot silently change what gets built.
readonly CACHE_ROOT="${HOME}/.cache/imessage-proxy-linux-toolchain"

readonly GCC_VERSION='12'
readonly CLANG_VERSION='14'
readonly STAGE_COUNT=6

# Upstream pins. Each source is fixed by tag; the tag is in turn fixed by the
# commit it resolved to, recorded here because a tag is a mutable ref and a
# commit id is not. The sha256 covers the exact tarball GitHub served, and both
# were confirmed reproducible across two independent fetches - but GitHub has
# never promised its generated tarballs are byte-stable (it changed their gzip
# settings in 2023 and invalidated every such pin in the wild), so treat a
# sha256 mismatch as "check the commit id before assuming compromise".
readonly LIBOBJC2_TAG='v2.2'
readonly LIBOBJC2_COMMIT='7c2ecced4593e90f34d4408e06dcf06d2457a756'
readonly LIBOBJC2_SHA256='c4c5cede579949249f16736c9b1f85c58c44addb013f59970dcb566d9069152a'
readonly LIBOBJC2_DIR='libobjc2-2.2'
readonly TOOLS_MAKE_TAG='make-2_9_1'
readonly TOOLS_MAKE_COMMIT='f0e00360a2620522aebc1e049d38228e04eaa5ec'
readonly TOOLS_MAKE_SHA256='78ef0f68402c379979a9a46499ac308fe5c1512aa198138c87649ee611aedf41'
readonly TOOLS_MAKE_DIR='tools-make-make-2_9_1'
readonly LIBS_BASE_TAG='base-1_29_0'
readonly LIBS_BASE_COMMIT='c6af8ef4bf44c2d3ed36a136f1799fe263978af4'
readonly LIBS_BASE_SHA256='4dc7272a5c44844b823d31811af6a9f4e3bda04bb78139c0446f03ea4bdb2fd3'
readonly LIBS_BASE_DIR='libs-base-base-1_29_0'
readonly GNUSTEP_BASE_SONAME='libgnustep-base.so.1.29.0'

# .github/workflows/ci.yml gates formatting on clang-format 18.1.8, and 18
# disagrees with the locally available 14 about real things - it added
# InsertBraces and RemoveSemicolon and changed Objective-C block and attribute
# breaking - so clean-at-14 would not have implied clean-at-18. apt.llvm.org is
# the only source of an 18.1.8 arm64 build. These are snapshot packages that
# upstream prunes from the pool over time; if the download starts 404ing, the
# fix is to bump LLVM18_VERSION to a surviving 18.1.8 snapshot and re-pin the
# three checksums, not to fall back to clang-format 14.
readonly LLVM18_VERSION='18.1.8~++20240731024826+3b5b5c1ec4a3-1~exp1~20240731144843.145'
readonly LLVM18_POOL='https://apt.llvm.org/bookworm/pool/main/l/llvm-toolchain-18'
readonly CLANG_FORMAT_18_SHA256='826b6085763f9db1c9e1a2b23b650c79973eed48fc38502133d650894c2d4349'
readonly LIBLLVM18_SHA256='e805599a4b56a46413044e3e561c98c9da2acbfac06e43f4fe56179e7e6d4589'
readonly LIBCLANG_CPP18_SHA256='8b03fa76988a8a68fb0107e09ba2b330e4f3cf05054107633e4f34a18bf631ec'

# Only aarch64 has been exercised end to end. The x86_64 mapping is here so an
# unsupported host fails with a build error naming a real path rather than
# silently assembling a sysroot out of the wrong multiarch directory.
host_machine="$(uname -m)"
case "$host_machine" in
  aarch64) host_triple='aarch64-linux-gnu'; deb_arch='arm64'; loader='ld-linux-aarch64.so.1' ;;
  x86_64) host_triple='x86_64-linux-gnu'; deb_arch='amd64'; loader='ld-linux-x86-64.so.2' ;;
  *)
    printf 'ERROR: unsupported machine %s; this provisioner knows aarch64 and x86_64 only\n' \
      "$host_machine" >&2
    exit 1
    ;;
esac
readonly HOST_TRIPLE="$host_triple"
readonly DEB_ARCH="$deb_arch"
readonly LOADER="$loader"

# gnustep-base is the memory-hungry build. Capping the job count keeps a small
# CI runner from being pushed into the OOM killer part way through a ten-minute
# compile, which presents as an unexplained "make: *** [all] Error 2".
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
[ "$jobs" -gt 4 ] 2>/dev/null && jobs=4
[ "$jobs" -ge 1 ] 2>/dev/null || jobs=1
readonly JOBS="$jobs"

temporary=''
current_stage='startup'
current_log=''
current_remedy='Re-run this script; completed stages are skipped.'

usage() {
  cat <<'USAGE'
Usage: scripts/linux-toolchain.sh [--check] [--help]

Provisions a rootless Objective-C/ARC toolchain for building the native sources
on Linux. Everything is installed under $HOME/.local; no sudo, no system
packages, nothing written outside $HOME.

Options:
  --check   Verify an existing toolchain and exit. Compiles and runs a small ARC
            program exercising NSString, NSArray, NSJSONSerialization and weak
            reference zeroing. Builds nothing. Exits 0 when usable, 1 otherwise.
  --help    Show this help.

Stages, each skipped when its output is already present:
  1  Debian packages unpacked into a private sysroot (clang, binutils, libc and
     kernel headers, make, cmake, ninja, sqlite3, shellcheck, and the ffi, xml2,
     icu, gnutls, gmp and zlib development files GNUstep needs)
  2  Sysroot symlink repair
  3  clang, clang++ and clang-format wrappers, plus clang-format 18.1.8 for CI parity
  4  libobjc2 2.2, the GNUstep v2 runtime that makes -fobjc-arc possible
  5  gnustep tools-make 2.9.1 configured for the ng-gnu-gnu library combo
  6  gnustep-base 1.29.0 built against that runtime

Installed layout:
  $HOME/.local/bin/lclang, lclang++, lclang-format, lclang-format-18
  $HOME/.local/opt/toolchain    unpacked .deb sysroot
  $HOME/.local/opt/libobjc2     ARC runtime
  $HOME/.local/opt/gnustep      GNUstep make and Foundation
  $HOME/.local/opt/llvm18       clang-format 18.1.8
  $HOME/.cache/imessage-proxy-linux-toolchain  pinned downloads and build trees

A cold run takes about twenty-five minutes and about 630 MB. A warm run skips
every stage and takes seconds.
USAGE
}

cleanup() {
  [ -n "$temporary" ] || return 0
  case "$temporary" in
    "$CACHE_ROOT"/probe.*) rm -rf -- "$temporary" ;;
    *) printf 'ERROR: refusing unsafe cleanup path: %s\n' "$temporary" >&2 ;;
  esac
}

report_failure() {
  local status="$1" line="$2"
  printf 'ERROR: stage %s failed with status %s at line %s.\n' "$current_stage" "$status" "$line" >&2
  if [ -n "$current_log" ] && [ -s "$current_log" ]; then
    printf 'ERROR: last 20 lines of %s follow.\n' "$current_log" >&2
    tail -n 20 -- "$current_log" >&2
  fi
  printf 'ERROR: %s\n' "$current_remedy" >&2
}

trap 'report_failure "$?" "$LINENO"' ERR
trap cleanup EXIT

begin_stage() {
  current_stage="$1"
  current_log="$2"
  current_remedy="$3"
}

announce() {
  printf '[%d/%d] %-16s %s\n' "$1" "$STAGE_COUNT" "$2" "$3"
}

# Verifies a downloaded file against a pinned sha256 and deletes it on mismatch,
# so a truncated or tampered download is never left behind to be trusted by the
# next run's presence check.
verify_sha256() {
  local path="$1" expected="$2" actual
  actual="$(sha256sum -- "$path" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    rm -f -- "$path"
    printf 'ERROR: checksum mismatch for %s\n' "$path" >&2
    printf 'ERROR: expected %s\nERROR: obtained %s\n' "$expected" "$actual" >&2
    return 1
  fi
}

download_pinned() {
  local url="$1" path="$2" expected="$3"
  if [ -f "$path" ] && verify_sha256 "$path" "$expected" 2>/dev/null; then
    return 0
  fi
  curl -fsSL --retry 3 --retry-delay 2 -o "$path" "$url"
  verify_sha256 "$path" "$expected"
}

# Stage 1. Debian packages.

# The sentinel-to-package table. bash 3.2 has no associative arrays, so this is
# a pipe-separated table read line by line. The sentinel is what makes the stage
# skippable: a package is only fetched when the one file we actually consume
# from it is missing, which also means a half-unpacked sysroot repairs itself.
package_manifest() {
  cat <<MANIFEST
usr/lib/llvm-${CLANG_VERSION}/bin/clang-${CLANG_VERSION}|clang-${CLANG_VERSION}
usr/lib/llvm-${CLANG_VERSION}/bin/clang-format|clang-format-${CLANG_VERSION}
usr/bin/ld|binutils
usr/bin/make|make
usr/bin/cmake|cmake
usr/bin/ninja|ninja-build
usr/bin/pkg-config|pkg-config
usr/bin/shellcheck|shellcheck
usr/bin/sqlite3|sqlite3
usr/include/sqlite3.h|libsqlite3-dev
usr/include/Block.h|libblocksruntime-dev
usr/include/zlib.h|zlib1g-dev
usr/include/linux/limits.h|linux-libc-dev
usr/include/${HOST_TRIPLE}/sys/stat.h|libc6-dev
usr/include/c++/${GCC_VERSION}/vector|libstdc++-${GCC_VERSION}-dev
usr/lib/gcc/${HOST_TRIPLE}/${GCC_VERSION}/libgcc.a|libgcc-${GCC_VERSION}-dev
usr/include/${HOST_TRIPLE}/ffi.h|libffi-dev
usr/include/${HOST_TRIPLE}/gmp.h|libgmp-dev
usr/include/libxml2/libxml/tree.h|libxml2-dev
usr/include/unicode/utypes.h|libicu-dev
usr/include/gnutls/gnutls.h|libgnutls28-dev
MANIFEST
}

missing_packages() {
  local sentinel package
  while IFS='|' read -r sentinel package; do
    [ -n "$sentinel" ] || continue
    [ -e "${TOOLCHAIN_ROOT}/${sentinel}" ] || printf '%s\n' "$package"
  done <<EOF
$(package_manifest)
EOF
}

missing_sentinels() {
  local sentinel package
  while IFS='|' read -r sentinel package; do
    [ -n "$sentinel" ] || continue
    [ -e "${TOOLCHAIN_ROOT}/${sentinel}" ] || printf '%s (%s)\n' "$sentinel" "$package"
  done <<EOF
$(package_manifest)
EOF
}

fetch_and_unpack_packages() {
  local wanted="$1" log="$2" uris line url filename digest count=0
  uris="${CACHE_ROOT}/uris.txt"

  # apt-get install --print-uris resolves the whole dependency closure without
  # root and without touching the system. ForceHash makes apt report the sha256
  # it read from the Release file it already verified against the archive
  # signing key, which is the only checksum for a Debian package that is
  # obtainable without hand-maintaining ninety hashes in this file.
  # shellcheck disable=SC2086
  apt-get install --print-uris -y --no-install-recommends \
    -o Acquire::ForceHash=SHA256 $wanted 2>>"$log" |
    grep "^'" > "$uris"

  while read -r line; do
    url="${line#\'}"
    url="${url%%\'*}"
    filename="$(printf '%s' "${line#*\' }" | cut -d' ' -f1)"
    digest="$(printf '%s' "${line#*\' }" | cut -d' ' -f3)"
    case "$digest" in
      SHA256:*) digest="${digest#SHA256:}" ;;
      *)
        printf 'ERROR: %s came back without a SHA256; refusing to unpack it\n' "$filename" >&2
        return 1
        ;;
    esac
    download_pinned "$url" "${CACHE_ROOT}/${filename}" "$digest"
    dpkg -x "${CACHE_ROOT}/${filename}" "$TOOLCHAIN_ROOT" >>"$log" 2>&1
    count=$((count + 1))
  done < "$uris"

  printf '%s\n' "$count"
}

stage_packages() {
  local log="${CACHE_ROOT}/packages.log" wanted unpacked still_missing
  begin_stage 'packages' "$log" \
    "Check network access to deb.debian.org, then re-run. Packages already unpacked into ${TOOLCHAIN_ROOT} are kept."

  wanted="$(missing_packages | sort -u | tr '\n' ' ')"
  wanted="${wanted% }"
  if [ -z "$wanted" ]; then
    announce 1 'packages' 'present, skipped'
    return 0
  fi

  announce 1 'packages' \
    "downloading $(printf '%s' "$wanted" | wc -w | tr -d ' ') package(s) and their dependencies"
  mkdir -p "$TOOLCHAIN_ROOT"
  : > "$log"
  unpacked="$(fetch_and_unpack_packages "$wanted" "$log")"
  printf '       unpacked %s .deb archive(s) into %s\n' "$unpacked" "$TOOLCHAIN_ROOT"

  still_missing="$(missing_sentinels)"
  if [ -n "$still_missing" ]; then
    # apt omits a package from --print-uris when the host already has it
    # installed, because from apt's point of view there is nothing to fetch.
    # The private sysroot is not the host, so that omission leaves a real hole.
    printf 'ERROR: these files are still missing after unpacking:\n%s\n' "$still_missing" >&2
    printf 'ERROR: this usually means the host already has the package installed, so apt saw nothing to download.\n' >&2
    printf 'ERROR: fetch each one by hand with: (cd %s && apt-get download <package>) and dpkg -x it into %s\n' \
      "$CACHE_ROOT" "$TOOLCHAIN_ROOT" >&2
    return 1
  fi
}

# Stage 2. Sysroot repair.

dangling_symlinks() {
  local dir="$1" link
  [ -d "$dir" ] || return 0
  for link in "$dir"/*.so "$dir"/*.so.*; do
    [ -L "$link" ] || continue
    [ -e "$link" ] && continue
    printf '%s\n' "$link"
  done
}

# Repoints one dangling development symlink at the real shared object on the
# host. Returns non-zero when no candidate exists, which is the caller's signal
# that the loop has converged rather than that something is wrong.
repair_one_symlink() {
  local link="$1" dir target candidate
  dir="$(dirname -- "$link")"
  target="$(basename -- "$(readlink -- "$link")")"
  for candidate in "/lib/${HOST_TRIPLE}/${target}" "/usr/lib/${HOST_TRIPLE}/${target}" \
    "/lib/${target}" "/usr/lib/${target}"; do
    if [ -e "$candidate" ]; then
      ln -sfn "$candidate" "${dir}/${target}"
      return 0
    fi
  done
  return 1
}

stage_sysroot() {
  local dev_dir="${TOOLCHAIN_ROOT}/usr/lib/${HOST_TRIPLE}"
  local runtime_dir="${TOOLCHAIN_ROOT}/lib/${HOST_TRIPLE}"
  local file base link pass repaired dangling
  begin_stage 'sysroot' '' \
    "Confirm the host still has /lib/${HOST_TRIPLE} and /lib/${LOADER}, then re-run."

  dangling="$(dangling_symlinks "$dev_dir" | wc -l | tr -d ' ')"
  if [ -e "${TOOLCHAIN_ROOT}/lib/${LOADER}" ] && [ -e "${runtime_dir}/libc.so.6" ] &&
    [ "$dangling" -eq 0 ]; then
    announce 2 'sysroot' 'repaired, skipped'
    return 0
  fi

  announce 2 'sysroot' "linking runtime libraries and repairing ${dangling} dangling symlink(s)"

  # First trap. libc.so.6 and the dynamic loader live in no -dev package at all;
  # they are shipped by libc6 itself, which apt will not offer because the host
  # already has it. Without these two symlinks every link ends in "cannot find
  # -lc" or, worse, a binary that will not start.
  mkdir -p "$runtime_dir"
  for file in "/lib/${HOST_TRIPLE}"/*.so*; do
    [ -e "$file" ] || continue
    base="$(basename -- "$file")"
    [ -e "${runtime_dir}/${base}" ] || ln -s "$file" "${runtime_dir}/${base}"
  done
  ln -sfn "/lib/${LOADER}" "${TOOLCHAIN_ROOT}/lib/${LOADER}"

  # Second trap, and the one that costs an afternoon. Every -dev package ships
  # its libfoo.so as a relative symlink to a versioned object that lives in the
  # runtime package, and the runtime package is not in this sysroot. Inside an
  # unpacked tree those symlinks therefore dangle - and ld does not say so. It
  # silently falls back to the static libfoo.a sitting next to them, which
  # Debian builds without -fPIC, and reports "relocation
  # R_AARCH64_ADR_PREL_PG_HI21 against symbol ... recompile with -fPIC". The
  # error names a compiler flag and the cause is a broken symlink. Repointing
  # each dangling link at the host's real object is the whole fix; nothing needs
  # recompiling. Repair runs to a fixpoint because the symlinks form chains
  # (libicuuc.so to libicuuc.so.72 to libicuuc.so.72.1) and repairing one link
  # can expose the next.
  pass=0
  while [ "$pass" -lt 4 ]; do
    repaired=0
    while read -r link; do
      [ -n "$link" ] || continue
      if repair_one_symlink "$link"; then
        repaired=$((repaired + 1))
      fi
    done < <(dangling_symlinks "$dev_dir")
    [ "$repaired" -eq 0 ] && break
    pass=$((pass + 1))
  done

  dangling="$(dangling_symlinks "$dev_dir" | wc -l | tr -d ' ')"
  if [ "$dangling" -ne 0 ]; then
    printf 'WARNING: %s development symlink(s) in %s still dangle and have no host counterpart.\n' \
      "$dangling" "$dev_dir" >&2
    printf 'WARNING: linking against those libraries will fail with a misleading -fPIC diagnostic.\n' >&2
  fi
}

# Stage 3. Compiler wrappers and CI-parity clang-format.

# Debian's /usr/bin/clang is itself a wrapper script that assumes a system
# install, so it cannot be used from an unpacked tree. These wrappers call the
# real binary and supply what a sysroot install cannot infer: where the sysroot
# is, where gcc's runtime bits are, and which dynamic loader the output should
# name. The wrappers are written before libobjc2 is built because cmake, and
# every stage after it, needs a working compiler driver on PATH.
wrapper_prologue() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '#' \
    '# Generated by scripts/linux-toolchain.sh. Edit that, not this.' \
    '' \
    'set -Eeuo pipefail' \
    "toolchain='${TOOLCHAIN_ROOT}'" \
    "triple='${HOST_TRIPLE}'" \
    "loader='${LOADER}'" \
    "llvm='llvm-${CLANG_VERSION}'" \
    "gcc_version='${GCC_VERSION}'" \
    "compiler='$1'"
}

write_clang_wrapper() {
  local path="$1" compiler="$2" draft="${temporary}/wrapper"
  {
    wrapper_prologue "$compiler"
    cat <<'BODY'

export LD_LIBRARY_PATH="${toolchain}/usr/lib/${triple}:${toolchain}/usr/${llvm}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

exec "${toolchain}/usr/lib/${llvm}/bin/${compiler}" \
  --sysroot="${toolchain}" \
  --gcc-toolchain="${toolchain}/usr" \
  -B "${toolchain}/usr/lib/gcc/${triple}/${gcc_version}" \
  -B "${toolchain}/usr/bin" \
  -L "/lib/${triple}" \
  -L "/usr/lib/${triple}" \
  -Wl,-rpath,"${toolchain}/usr/lib/${triple}" \
  -Wl,-rpath,"${toolchain}/usr/lib" \
  -Wl,-dynamic-linker,"/lib/${loader}" \
  -Qunused-arguments \
  "$@"
BODY
  } > "$draft"
  install_if_changed "$draft" "$path"
}

write_format_wrapper() {
  local path="$1" root="$2" llvm="$3" draft="${temporary}/wrapper"
  {
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      '#' \
      '# Generated by scripts/linux-toolchain.sh. Edit that, not this.' \
      '' \
      'set -Eeuo pipefail' \
      "root='${root}'" \
      "triple='${HOST_TRIPLE}'" \
      "llvm='${llvm}'"
    cat <<'BODY'

export LD_LIBRARY_PATH="${root}/usr/lib/${llvm}/lib:${root}/usr/lib/${triple}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

exec "${root}/usr/lib/${llvm}/bin/clang-format" "$@"
BODY
  } > "$draft"
  install_if_changed "$draft" "$path"
}

# Rewrites the destination only when the generated content differs, so a warm
# run neither churns mtimes nor reports work it did not do.
install_if_changed() {
  local draft="$1" path="$2"
  if [ -x "$path" ] && cmp -s "$draft" "$path"; then
    rm -f -- "$draft"
    return 1
  fi
  install -m 0755 "$draft" "$path"
  rm -f -- "$draft"
  return 0
}

stage_wrappers() {
  local log="${CACHE_ROOT}/llvm18.log" written=0 package url
  begin_stage 'wrappers' "$log" \
    "Check network access to apt.llvm.org. If the 18.1.8 snapshot has been pruned from the pool, bump LLVM18_VERSION and re-pin its three checksums."

  mkdir -p "$BIN_DIR"

  if [ -x "${LLVM18_ROOT}/usr/lib/llvm-18/bin/clang-format" ] &&
    [ -x "${BIN_DIR}/lclang" ] && [ -x "${BIN_DIR}/lclang++" ] &&
    [ -x "${BIN_DIR}/lclang-format" ] && [ -x "${BIN_DIR}/lclang-format-18" ]; then
    # The wrappers are cheap to regenerate and are the one artefact that changes
    # when this script changes, so they are always diffed rather than assumed.
    write_clang_wrapper "${BIN_DIR}/lclang" "clang-${CLANG_VERSION}" && written=$((written + 1))
    write_clang_wrapper "${BIN_DIR}/lclang++" 'clang++' && written=$((written + 1))
    write_format_wrapper "${BIN_DIR}/lclang-format" "$TOOLCHAIN_ROOT" "llvm-${CLANG_VERSION}" &&
      written=$((written + 1))
    write_format_wrapper "${BIN_DIR}/lclang-format-18" "$LLVM18_ROOT" 'llvm-18' &&
      written=$((written + 1))
    if [ "$written" -eq 0 ]; then
      announce 3 'wrappers' 'present, skipped'
    else
      announce 3 'wrappers' "refreshed ${written} wrapper(s)"
    fi
    return 0
  fi

  announce 3 'wrappers' 'installing driver wrappers and clang-format 18.1.8'
  : > "$log"
  mkdir -p "$LLVM18_ROOT"
  for package in clang-format-18 libllvm18 libclang-cpp18; do
    url="${LLVM18_POOL}/${package}_${LLVM18_VERSION}_${DEB_ARCH}.deb"
    case "$package" in
      clang-format-18) download_pinned "$url" "${CACHE_ROOT}/${package}.deb" "$CLANG_FORMAT_18_SHA256" ;;
      libllvm18) download_pinned "$url" "${CACHE_ROOT}/${package}.deb" "$LIBLLVM18_SHA256" ;;
      libclang-cpp18) download_pinned "$url" "${CACHE_ROOT}/${package}.deb" "$LIBCLANG_CPP18_SHA256" ;;
    esac
    dpkg -x "${CACHE_ROOT}/${package}.deb" "$LLVM18_ROOT" >>"$log" 2>&1
  done

  write_clang_wrapper "${BIN_DIR}/lclang" "clang-${CLANG_VERSION}" || true
  write_clang_wrapper "${BIN_DIR}/lclang++" 'clang++' || true
  write_format_wrapper "${BIN_DIR}/lclang-format" "$TOOLCHAIN_ROOT" "llvm-${CLANG_VERSION}" || true
  write_format_wrapper "${BIN_DIR}/lclang-format-18" "$LLVM18_ROOT" 'llvm-18' || true
}

# Stage 4. libobjc2.

unpack_pinned_source() {
  local project="$1" tag="$2" digest="$3" directory="$4" commit="$5"
  local archive="${CACHE_ROOT}/${project}-${tag}.tar.gz"
  download_pinned "https://codeload.github.com/gnustep/${project}/tar.gz/refs/tags/${tag}" \
    "$archive" "$digest"
  # The commit id is recorded rather than checked, because a tarball carries no
  # git metadata to check it against. It is what an auditor uses to reconstruct
  # this exact tree from the repository if the tarball checksum ever moves.
  printf '%s\n' "$commit" > "${CACHE_ROOT}/${project}-${tag}.commit"
  rm -rf -- "${CACHE_ROOT:?}/${directory}"
  tar xzf "$archive" -C "$CACHE_ROOT"
}

stage_libobjc2() {
  local log="${CACHE_ROOT}/libobjc2.log" build="${CACHE_ROOT}/libobjc2-build"
  begin_stage 'libobjc2' "$log" \
    "Confirm ${BIN_DIR}/lclang compiles a C hello world, then re-run. Nothing in Debian provides libobjc2; it must build from source or ARC is unavailable."

  if [ -e "${LIBOBJC2_ROOT}/lib/libobjc.so" ] && [ -e "${LIBOBJC2_ROOT}/include/objc/runtime.h" ]; then
    announce 4 'libobjc2' "${LIBOBJC2_TAG} present, skipped"
    return 0
  fi

  announce 4 'libobjc2' "building ${LIBOBJC2_TAG} (about 2 minutes)"
  : > "$log"
  unpack_pinned_source 'libobjc2' "$LIBOBJC2_TAG" "$LIBOBJC2_SHA256" "$LIBOBJC2_DIR" "$LIBOBJC2_COMMIT"

  export PATH="${TOOLCHAIN_ROOT}/usr/bin:${BIN_DIR}:${PATH}"
  export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib/${HOST_TRIPLE}:${TOOLCHAIN_ROOT}/usr/lib/llvm-${CLANG_VERSION}/lib"

  rm -rf -- "$build"
  mkdir -p "$build"
  (
    cd "$build"
    cmake "${CACHE_ROOT}/${LIBOBJC2_DIR}" -G Ninja \
      -DCMAKE_C_COMPILER="${BIN_DIR}/lclang" \
      -DCMAKE_CXX_COMPILER="${BIN_DIR}/lclang++" \
      -DCMAKE_OBJC_COMPILER="${BIN_DIR}/lclang" \
      -DCMAKE_OBJCXX_COMPILER="${BIN_DIR}/lclang++" \
      -DCMAKE_ASM_COMPILER="${BIN_DIR}/lclang" \
      -DCMAKE_INSTALL_PREFIX="$LIBOBJC2_ROOT" \
      -DCMAKE_BUILD_TYPE=Release \
      -DTESTS=OFF
    ninja "-j${JOBS}"
    ninja install
  ) >>"$log" 2>&1
}

# Stage 5. gnustep tools-make.

stage_tools_make() {
  local log="${CACHE_ROOT}/tools-make.log" config="${GNUSTEP_ROOT}/System/Library/Makefiles/config.make"
  begin_stage 'gnustep-make' "$log" \
    "Confirm stage 4 installed ${LIBOBJC2_ROOT}/lib/libobjc.so, then re-run. Without --with-library-combo=ng-gnu-gnu the install defaults to the legacy gcc ABI and stage 6 will build a Foundation that cannot do ARC."

  if [ -e "$config" ] && grep -q 'DEFAULT_OBJC_RUNTIME_ABI = gnustep-2.0' "$config"; then
    announce 5 'gnustep-make' "${TOOLS_MAKE_TAG} present, skipped"
    return 0
  fi

  announce 5 'gnustep-make' "building ${TOOLS_MAKE_TAG} (about 1 minute)"
  : > "$log"
  unpack_pinned_source 'tools-make' "$TOOLS_MAKE_TAG" "$TOOLS_MAKE_SHA256" "$TOOLS_MAKE_DIR" \
    "$TOOLS_MAKE_COMMIT"

  # The build environment is confined to a subshell on purpose: each stage has
  # to be independently runnable, so no stage may inherit flags another one
  # exported. Shellcheck reads that confinement as an accident.
  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${TOOLCHAIN_ROOT}/usr/bin:${BIN_DIR}:${PATH}"
    export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib/${HOST_TRIPLE}:${TOOLCHAIN_ROOT}/usr/lib/llvm-${CLANG_VERSION}/lib"
    export CC="${BIN_DIR}/lclang" CXX="${BIN_DIR}/lclang++"
    export CPPFLAGS="-I${LIBOBJC2_ROOT}/include -I${TOOLCHAIN_ROOT}/usr/include -I${TOOLCHAIN_ROOT}/usr/include/${HOST_TRIPLE}"
    export LDFLAGS="-L${LIBOBJC2_ROOT}/lib -Wl,-rpath,${LIBOBJC2_ROOT}/lib"
    cd "${CACHE_ROOT}/${TOOLS_MAKE_DIR}"
    ./configure --prefix="$GNUSTEP_ROOT" --with-layout=gnustep \
      --with-library-combo=ng-gnu-gnu --with-config-file="${GNUSTEP_ROOT}/GNUstep.conf"
    make "-j${JOBS}" install
  ) >>"$log" 2>&1

  if ! grep -q 'DEFAULT_OBJC_RUNTIME_ABI = gnustep-2.0' "$config"; then
    printf 'ERROR: %s did not record the gnustep-2.0 ABI.\n' "$config" >&2
    printf 'ERROR: the ng-gnu-gnu combo was not accepted; check %s for the configure summary.\n' "$log" >&2
    return 1
  fi
}

# Stage 6. gnustep-base.

stage_gnustep_base() {
  local log="${CACHE_ROOT}/gnustep-base.log"
  local library="${GNUSTEP_ROOT}/Local/Library/Libraries/${GNUSTEP_BASE_SONAME}"
  begin_stage 'gnustep-base' "$log" \
    "Read the configure summary in the log. A missing libxml2, gnutls, icu or ffi almost always means a dangling development symlink in the sysroot; re-run so stage 2 repairs it."

  if [ -e "$library" ] && [ -e "${GNUSTEP_ROOT}/Local/Library/Headers/Foundation/Foundation.h" ]; then
    announce 6 'gnustep-base' "${LIBS_BASE_TAG} present, skipped"
    return 0
  fi

  announce 6 'gnustep-base' "building ${LIBS_BASE_TAG} (about 10 minutes)"
  : > "$log"
  unpack_pinned_source 'libs-base' "$LIBS_BASE_TAG" "$LIBS_BASE_SHA256" "$LIBS_BASE_DIR" \
    "$LIBS_BASE_COMMIT"

  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${TOOLCHAIN_ROOT}/usr/bin:${BIN_DIR}:${PATH}"
    export LD_LIBRARY_PATH="${TOOLCHAIN_ROOT}/usr/lib/${HOST_TRIPLE}:${TOOLCHAIN_ROOT}/usr/lib/llvm-${CLANG_VERSION}/lib"
    export CC="${BIN_DIR}/lclang" CXX="${BIN_DIR}/lclang++"
    export PKG_CONFIG_PATH="${TOOLCHAIN_ROOT}/usr/lib/${HOST_TRIPLE}/pkgconfig:${TOOLCHAIN_ROOT}/usr/share/pkgconfig:${LIBOBJC2_ROOT}/lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$TOOLCHAIN_ROOT"

    # GNUstep.sh is upstream shell that predates set -u by two decades and is
    # sourced, not run, so an unbound reference inside it would abort this
    # script rather than itself. Relaxing -u for the duration keeps an upstream
    # change from surfacing here as an unexplained failure.
    set +u
    # shellcheck source=/dev/null
    . "${GNUSTEP_ROOT}/System/Library/Makefiles/GNUstep.sh"
    set -u

    export CFLAGS="-I${LIBOBJC2_ROOT}/include -I${TOOLCHAIN_ROOT}/usr/include/${HOST_TRIPLE}"
    export CPPFLAGS="-I${LIBOBJC2_ROOT}/include -I${TOOLCHAIN_ROOT}/usr/include -I${TOOLCHAIN_ROOT}/usr/include/${HOST_TRIPLE} -I${TOOLCHAIN_ROOT}/usr/include/libxml2"
    export LDFLAGS="-L${LIBOBJC2_ROOT}/lib -Wl,-rpath,${LIBOBJC2_ROOT}/lib"
    export LIBS='-lobjc'

    cd "${CACHE_ROOT}/${LIBS_BASE_DIR}"
    ./configure --prefix="${GNUSTEP_ROOT}/System" --with-installation-domain=SYSTEM
    make "-j${JOBS}"
    make install
  ) >>"$log" 2>&1
}

# Verification.

# The probe deliberately asserts weak zeroing rather than merely compiling with
# -fobjc-arc. A runtime with the ARC symbols stubbed out still compiles and
# still links; the first thing that actually breaks is __weak, and it breaks
# silently by never clearing. Everything else here is what the product's own
# sources lean on hardest: string formatting, a generic array, and a JSON
# round trip.
write_probe_source() {
  cat > "$1" <<'PROBE'
#import <Foundation/Foundation.h>

@interface IMPToolchainProbe : NSObject
@property (nonatomic, copy) NSString *name;
@end

@implementation IMPToolchainProbe
@end

int main(void) {
    int failures = 0;
    __weak IMPToolchainProbe *observer = nil;

    if (!__has_feature(objc_arc)) {
        fprintf(stderr, "ERROR: the probe was not compiled with ARC\n");
        failures++;
    }

    @autoreleasepool {
        IMPToolchainProbe *probe = [IMPToolchainProbe new];
        probe.name = [NSString stringWithFormat:@"probe-%d", 7];
        observer = probe;

        if (![probe.name isEqualToString:@"probe-7"]) {
            fprintf(stderr, "ERROR: NSString formatting produced an unexpected value\n");
            failures++;
        }

        NSArray<NSString *> *tags = @[ @"alpha", @"beta", @"gamma" ];
        if (tags.count != 3 || ![tags[1] isEqualToString:@"beta"]) {
            fprintf(stderr, "ERROR: NSArray literals or subscripting are unavailable\n");
            failures++;
        }

        NSError *error = nil;
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:@{ @"name" : probe.name, @"tags" : tags }
                                                          options:0
                                                            error:&error];
        if (encoded == nil) {
            fprintf(stderr, "ERROR: NSJSONSerialization failed to encode: %s\n",
                    error.localizedDescription.UTF8String);
            failures++;
        } else {
            NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:encoded options:0 error:&error];
            if (decoded == nil || ![decoded[@"name"] isEqualToString:@"probe-7"] ||
                [decoded[@"tags"] count] != 3) {
                fprintf(stderr, "ERROR: the JSON round trip did not preserve the payload\n");
                failures++;
            }
        }

        if (observer == nil) {
            fprintf(stderr, "ERROR: a weak reference was cleared while a strong one was still held\n");
            failures++;
        }
    }

    if (observer != nil) {
        fprintf(stderr, "ERROR: a weak reference was not zeroed after its object was released\n");
        failures++;
    }

    if (failures != 0) {
        return 1;
    }
    printf("probe ok\n");
    return 0;
}
PROBE
}

require_path() {
  local path="$1" label="$2"
  if [ ! -e "$path" ]; then
    printf 'ERROR: %s is missing: %s\n' "$label" "$path" >&2
    return 1
  fi
  printf '  %-16s %s\n' "$label" "$path"
}

run_check() {
  local source="${temporary}/probe.m" binary="${temporary}/probe" output status=0

  require_path "${BIN_DIR}/lclang" 'clang driver' || status=1
  require_path "${BIN_DIR}/lclang-format-18" 'clang-format 18' || status=1
  require_path "${LIBOBJC2_ROOT}/lib/libobjc.so" 'libobjc2' || status=1
  require_path "${GNUSTEP_ROOT}/Local/Library/Libraries/${GNUSTEP_BASE_SONAME}" 'gnustep-base' || status=1
  require_path "${GNUSTEP_ROOT}/GNUstep.conf" 'gnustep config' || status=1
  require_path "${TOOLCHAIN_ROOT}/usr/bin/shellcheck" 'shellcheck' || status=1
  require_path "${TOOLCHAIN_ROOT}/usr/bin/sqlite3" 'sqlite3' || status=1

  if [ "$status" -ne 0 ]; then
    printf 'ERROR: the toolchain is incomplete; run scripts/linux-toolchain.sh with no arguments to build it.\n' >&2
    return 1
  fi

  write_probe_source "$source"
  if ! "${BIN_DIR}/lclang" -fobjc-arc -fobjc-runtime=gnustep-2.0 -fblocks -fexceptions \
    -I"${LIBOBJC2_ROOT}/include" -I"${GNUSTEP_ROOT}/Local/Library/Headers" \
    "$source" -o "$binary" \
    -L"${LIBOBJC2_ROOT}/lib" -L"${GNUSTEP_ROOT}/Local/Library/Libraries" \
    -lobjc -lgnustep-base \
    -Wl,-rpath,"${LIBOBJC2_ROOT}/lib" -Wl,-rpath,"${GNUSTEP_ROOT}/Local/Library/Libraries" \
    > "${temporary}/compile.err" 2>&1; then
    printf 'ERROR: the ARC probe did not compile.\n' >&2
    tail -n 20 -- "${temporary}/compile.err" >&2
    return 1
  fi

  if ! output="$(GNUSTEP_CONFIG_FILE="${GNUSTEP_ROOT}/GNUstep.conf" "$binary" 2>&1)"; then
    printf 'ERROR: the ARC probe compiled but did not run cleanly.\n' >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  if [ "$output" != 'probe ok' ]; then
    printf 'ERROR: the ARC probe reported: %s\n' "$output" >&2
    return 1
  fi

  printf '  %-16s %s\n' 'arc probe' 'NSString, NSArray, NSJSONSerialization and weak zeroing all behave'
  printf '%s\n' 'Linux Objective-C toolchain check passed.'
}


main() {
  local mode='provision' tool

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) mode='check' ;;
      --help | -h)
        usage
        return 0
        ;;
      *)
        printf 'ERROR: unknown option: %s\n' "$1" >&2
        usage >&2
        return 2
        ;;
    esac
    shift
  done

  for tool in apt-get curl dpkg tar sha256sum install; do
    command -v "$tool" > /dev/null 2>&1 || {
      printf 'ERROR: %s is required and was not found on PATH\n' "$tool" >&2
      return 127
    }
  done

  mkdir -p "$CACHE_ROOT" "$OPT_ROOT" "$BIN_DIR"
  temporary="$(mktemp -d "${CACHE_ROOT}/probe.XXXXXX")"
  chmod 0700 "$temporary"

  if [ "$mode" = 'check' ]; then
    current_stage='check'
    current_remedy='Run scripts/linux-toolchain.sh with no arguments to build the missing pieces.'
    run_check
    return 0
  fi

  stage_packages
  stage_sysroot
  stage_wrappers
  stage_libobjc2
  stage_tools_make
  stage_gnustep_base

  current_stage='verification'
  current_remedy='The stages completed but the toolchain does not work end to end. Read the probe diagnostic above; it names the first capability that failed.'
  run_check
  printf '%s\n' 'Linux Objective-C toolchain ready.'
}

main "$@"
