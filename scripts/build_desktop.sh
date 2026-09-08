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
# --sysroot selects how v8 and the C++ modules are compiled, and it is not the
# cosmetic flag it looks like. Upstream's configure.py normalises "0" to the
# empty string, and scripts/core_common/modules/v8_89.py branches on that:
#
#   sysroot != ""  ->  use_sysroot=true,  is_clang=false, sysroot=<ubuntu16>
#   sysroot == ""  ->  is_clang=true,     use_sysroot=false, use_custom_libcxx=false
#
# The second path compiles v8 against the HOST's glibc headers. On Ubuntu 24.04
# that fails: v8's src/base/macros.h uses intptr_t/uintptr_t without including
# <cstdint>, which older headers supplied transitively and current ones do not
# ("unknown type name 'intptr_t'", 15 errors, ~23 minutes in). Upstream expects
# the sysroot path on modern Ubuntu — v8_89.py carries an is_ubuntu_24_or_higher()
# accommodation inside that branch and none in the other.
#
# So the default here is 1. Override with --sysroot 0 or LIGHTOFFICE_SYSROOT=0
# on a host old enough not to need it, or if the sysroot download is blocked.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"
CHECK_ONLY=0
SYSROOT="${LIGHTOFFICE_SYSROOT:-1}"
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
  ok "sysroot disabled (--sysroot 0): v8 will compile against host glibc headers"
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
./tools/linux/python3/bin/python3 ./configure.py \
    --branch master --module desktop --sysroot "$SYSROOT" --update 0 --qt-dir "$QT_DIR"
./tools/linux/python3/bin/python3 ./make.py
rc=$?

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
