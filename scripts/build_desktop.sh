#!/usr/bin/env bash
#
# Drive the official ONLYOFFICE desktop build.
#
# This is a thin wrapper over build_tools/tools/linux/automate.py — we do not
# reimplement the build, we run upstream's. Before invoking it the script checks
# the three prerequisites that actually fail in locked-down networks, because
# automate.py's own failure mode is an opaque wget error several minutes in.
#
# Usage: scripts/build_desktop.sh [--check-only] [--sysroot 0|1]
#
# --sysroot selects how v8 and the C++ modules are compiled. Upstream's
# configure.py normalises "0" to the empty string, and
# scripts/core_common/modules/v8_89.py branches on that:
#
#   sysroot != ""  ->  use_sysroot=true,  is_clang=false, sysroot=<ubuntu16>
#   sysroot == ""  ->  is_clang=true,     use_sysroot=false, use_custom_libcxx=false
#
# Both settings were tried in CI. sysroot=0 is the default because it is the
# one whose failure is ours to fix:
#
#   sysroot=0  fetch works (it did on 2026-09-07), boost builds via b2, and v8
#              FAILS TO COMPILE on Ubuntu 24.04: src/base/macros.h uses
#              intptr_t/uintptr_t without including <cstdint>, which older glibc
#              headers supplied transitively. 15 errors. patch_v8_for_cstdint
#              below addresses exactly this.
#   sysroot=1  boost, CEF, ICU and OpenSSL build against the ubuntu16 sysroot,
#              but the ubuntu16 gcc is a poor match for the rest of the
#              toolchain and this path was never carried through.
#
# NOT the reason for either: the v8 FETCH failures seen from 2026-09-08 onward.
# Those were first blamed on the sysroot poisoning PATH/LD_LIBRARY_PATH, and
# that was wrong — the identical failure occurs with sysroot=0. v8_89.py clones
# depot_tools from HEAD, unpinned, and current HEAD cannot bootstrap:
#
#     python3_bin_reldir.txt not found. need to initialize depot_tools ...
#     ./depot_tools/cipd_client_version.digests: No such file   (seen once)
#     Error: client not configured; see 'gclient config'
#
# so no v8 is fetched and v8_89.py reaches os.chdir("v8") with nothing there.
# That is upstream drift in a third-party dependency, not a setting here.
#
# It IS fixable by pre-staging a pinned depot_tools, with one detail that an
# earlier attempt missed. v8_89.py calls common_check_version("v8", "1", clean),
# and clean() deletes depot_tools — but only when ./v8.data does not already
# hold the exact string "v8_version_1". fetch_prebuilts.sh writes that marker
# alongside the staged checkout, so the clone is skipped and the pin survives.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"
CHECK_ONLY=0
SYSROOT="${LIGHTOFFICE_SYSROOT:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --sysroot) SYSROOT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo "Preflight checks"

fatal=0

# 0. Platform. This wrapper drives build_tools/tools/linux/*, and the prebuilts
#    it checks for are Linux binaries. Every check below is a file-existence
#    test on a linux-named path, and fetch_prebuilts.sh creates those paths on
#    any host — so without this guard the preflight passes on macOS and the
#    build then tries to exec a Linux ELF ("cannot execute binary file",
#    exit 126). Fail here instead, with the reason, so the caller can route to
#    its skipped-build path.
if [ "$(uname -s)" != "Linux" ]; then
  bad "$(uname -s) is not supported by this script — it drives the Linux build (tools/linux/automate.py) with Linux prebuilts"
  echo
  echo "Preflight FAILED — nothing was built." >&2
  echo "Building .dmg/.exe needs the native recipes: desktop-apps/macos (Xcode)" >&2
  echo "and desktop-apps/win-linux/package/windows (MSVC + Inno Setup)." >&2
  exit 2
fi

# 1. build_tools present, laid out as a sibling of core/ etc.
if [ -d "$BUILD_TOOLS/tools/linux" ]; then
  ok "build_tools present ($BUILD_TOOLS)"
else
  bad "build_tools missing — run scripts/bootstrap.sh"; fatal=1
fi

# 2. Bootstrap python and CEF. These live in the build_tools_data repo, whose raw
#    HTTPS URLs are commonly blocked, but they are ordinary git blobs (only the Qt
#    tarballs and sysroots are LFS-tracked there), so a sparse git checkout gets
#    them. scripts/fetch_prebuilts.sh does exactly that.
if [ -x "$BUILD_TOOLS/tools/linux/python3/bin/python3" ]; then
  ok "bootstrap python3 present"
else
  bad "bootstrap python3 missing — run scripts/fetch_prebuilts.sh"; fatal=1
fi
if [ -d "$SRC/core/Common/3dParty/cef/linux_64/build" ]; then
  ok "CEF binaries staged"
else
  bad "CEF missing — run scripts/fetch_prebuilts.sh"; fatal=1
fi

# 3. Qt. The prebuilt Qt 5.9.9 in build_tools_data IS LFS-tracked and therefore
#    unavailable on an anonymous git lane — but upstream ships use_system_qt.py
#    for exactly this case, and the distro Qt5 works.
qt_versioned=""
for cand in "$BUILD_TOOLS"/tools/linux/qt_build/Qt-[0-9]*; do
  [ -d "$cand/gcc_64" ] && { qt_versioned="$cand"; break; }
done
if [ -n "$qt_versioned" ]; then
  ok "Qt available ($(basename "$qt_versioned"))"
elif [ -d "$BUILD_TOOLS/tools/linux/system_qt/gcc_64" ]; then
  # Usable only without the sysroot: with it, boost.py builds boost through
  # qmake, which needs the version to be readable from the directory name.
  if [ "$SYSROOT" = "1" ]; then
    bad "only an unversioned system Qt is present; a sysroot build reads the version from the directory name — rerun scripts/fetch_prebuilts.sh to create the qt_build/Qt-<version> alias"
    fatal=1
  else
    ok "Qt available (system Qt, unversioned — fine without the sysroot)"
  fi
else
  bad "no Qt — run: (cd $BUILD_TOOLS/tools/linux && python3 use_system_qt.py)"; fatal=1
fi

# 4. v8. This is the one dependency with no supported substitute on Linux:
#    core/DesktopEditor/doctrenderer needs a JS engine, and use_javascript_core
#    (the only alternative) links Apple frameworks and Objective-C sources, so it
#    is macOS/iOS only. Building v8 means depot_tools + gclient sync, which pull
#    from chromium.googlesource.com and the CIPD service.
for host in chromium.googlesource.com chrome-infra-packages.appspot.com; do
  code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://$host/" 2>/dev/null || true); code="${code:-000}"
  if [ "$code" != "000" ] && [ "$code" != "403" ] && [ "$code" != "407" ]; then
    ok "$host reachable (HTTP $code)"
  else
    bad "$host unreachable (HTTP $code) — v8 cannot be fetched or built"
    fatal=1
  fi
done

# 5. The ubuntu16 sysroot, when it is the one being used. It is fetched from
#    build_tools_data over plain HTTPS at configure time; if that is blocked the
#    build dies well into the run rather than here.
if [ "$SYSROOT" = "1" ]; then
  sysroot_dir="$BUILD_TOOLS/tools/linux/sysroot/ubuntu16-amd64-sysroot"
  if [ -d "$sysroot_dir" ]; then
    ok "ubuntu16 sysroot already unpacked"
  else
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' \
      "https://github.com/ONLYOFFICE-data/build_tools_data/raw/refs/heads/master/sysroot/ubuntu16-amd64-sysroot.tar.gz" \
      2>/dev/null || true); code="${code:-000}"
    case "$code" in
      000|403|404|407)
        bad "sysroot download unreachable (HTTP $code) — rerun with --sysroot 0, but note v8 will then compile against host glibc headers"
        fatal=1 ;;
      *) ok "sysroot download reachable (HTTP $code)" ;;
    esac
  fi
else
  ok "sysroot disabled (--sysroot 0): v8 compiles against host glibc headers; macros.h is patched for <cstdint> if that fails"
fi

# 6. Disk. A full build materialises boost, ICU, OpenSSL, CEF, v8 and all objects.
#    df -BG/--output are GNU extensions; -k is in POSIX and works on macOS too.
avail_gb=$(df -k . | awk 'NR==2 {print int($4/1048576)}')
if [ "${avail_gb:-0}" -ge 40 ]; then
  ok "disk: ${avail_gb}G available"
else
  bad "disk: ${avail_gb}G available; a full desktop build needs roughly 40G"
  fatal=1
fi

echo
if [ "$fatal" -ne 0 ]; then
  echo "Preflight FAILED — the build would abort. Nothing was built." >&2
  echo "See docs/DEVELOPER_GUIDE.md §3 for what the pipeline needs." >&2
  exit 2
fi
ok "preflight passed"

[ "$CHECK_ONLY" -eq 1 ] && { echo "--check-only: stopping before build."; exit 0; }

echo
echo
echo "Running upstream build (this takes hours) ..."
cd "$BUILD_TOOLS"
# Prefer a versioned Qt directory. Upstream reads the Qt version out of this
# path (base.py qt_version takes QT_DEPLOY.split("/")[-3] and keeps only digits
# and dots), so a name like "system_qt" strips to "" and int("") raises. Any
# qt_build/Qt-<version> works, including the alias fetch_prebuilts.sh makes for
# the system Qt.
QT_DIR="$BUILD_TOOLS/tools/linux/system_qt"
for cand in "$BUILD_TOOLS"/tools/linux/qt_build/Qt-[0-9]*; do
  [ -d "$cand/gcc_64" ] && { QT_DIR="$cand"; break; }
done
echo "sysroot: $SYSROOT"

# Hold the depot_tools pin that fetch_prebuilts.sh staged — but ONLY if that
# staging actually completed. depot_tools provisions its Python during the same
# self-update this disables, so setting it blindly is how a previous attempt
# turned a fetch failure into "python3_bin_reldir.txt not found". The presence
# of that file is the evidence that the bootstrap already ran.
STAGED_DEPOT_TOOLS="$SRC/core/Common/3dParty/v8_89/depot_tools"
if [ -f "$STAGED_DEPOT_TOOLS/python3_bin_reldir.txt" ]; then
  export DEPOT_TOOLS_UPDATE=0
  echo "depot_tools: staged and bootstrapped, holding the pin ($(git -C "$STAGED_DEPOT_TOOLS" rev-parse --short HEAD 2>/dev/null || echo '?'))"
else
  echo "depot_tools: not staged here; leaving its self-update enabled so it can bootstrap itself"
fi

./tools/linux/python3/bin/python3 ./configure.py \
    --branch master --module desktop --sysroot "$SYSROOT" --update 0 --qt-dir "$QT_DIR"

# v8 is fetched by make.py itself (v8_89.py, guarded by `if not is_dir("v8")`),
# so there is no hook between the fetch and the compile. This is the hook: run
# make.py, and if it fails with v8 present but unpatched, apply the one-line
# include it needs and run once more. The second pass skips everything already
# built, so it goes almost straight back to v8.
V8_BASE_DIR="$SRC/core/Common/3dParty/v8_89/v8/src/base"

# This v8 predates libstdc++ tightening its transitive includes: several headers
# under src/base use fixed-width types while including nothing that declares
# them. Modern glibc/libc++ no longer supply them by accident.
#
# The first version of this patched only macros.h, on the reasoning that
# macros.h includes logging.h at line 12 so one include covers both. That holds
# only for translation units that reach logging.h THROUGH macros.h — and
# src/base/logging.cc includes logging.h directly at line 5, so it still failed:
#
#     In file included from ../../src/base/logging.cc:5:
#     ../../src/base/logging.h:176:34: error: use of undeclared identifier 'uint8_t'
#
# Fixing one named file per 20-minute CI cycle is not a strategy, so this is
# mechanical instead: every header under src/base that USES one of these types
# and does NOT already include a header declaring them gets the include. Both
# conditions must hold, so it touches nothing that is already correct, and
# <cstdint> is idempotent and self-guarding. It is deliberately scoped to
# src/base, where every failure so far has been; widen it only if a failure
# appears elsewhere.
patch_v8_for_cstdint() {
  local patched=0 f
  [ -d "$V8_BASE_DIR" ] || return 1
  while IFS= read -r f; do
    grep -qE '#include +<(cstdint|stdint\.h)>' "$f" && continue
    grep -qE '\b(u?int(8|16|32|64)_t|u?intptr_t)\b' "$f" || continue
    sed -i '1i #include <cstdint>  // LIGHTOFFICE: fixed-width types used below but never declared' "$f"
    echo "  patched $(basename "$f")"
    patched=$((patched + 1))
  done < <(find "$V8_BASE_DIR" -name '*.h' | sort)
  # Success only when something actually changed, so an unrelated failure is
  # never silently retried and the retry cannot loop.
  [ "$patched" -gt 0 ]
}

# `set -e` is on, so a bare `make.py` followed by `rc=$?` never reaches the
# retry: the failing command aborts the script first, and everything below it
# — including the patch above — is dead code. That is exactly what happened on
# 2026-09-08: v8 was fetched, the compile failed with the intptr_t errors the
# patch exists to fix, and the patch never ran. Disable the trap around the two
# invocations whose failure this script is designed to handle.
run_make() {
  local status
  set +e
  ./tools/linux/python3/bin/python3 ./make.py
  status=$?
  set -e
  return "$status"
}

rc=0
run_make || rc=$?

if [ "$rc" -ne 0 ]; then
  if patch_v8_for_cstdint; then
    echo
    echo "make.py failed; patched v8 headers under src/base for <cstdint> — retrying."
    rc=0
    run_make || rc=$?
  fi
fi

BIN="$(find "$SRC/desktop-apps" "$SRC/../out" -type f -name DesktopEditors -perm -u+x 2>/dev/null | head -1)"
echo
echo "build exit code: $rc"
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
  ok "binary: $BIN"
  file "$BIN"
else
  bad "no DesktopEditors binary produced"
fi
exit $rc
