#!/usr/bin/env bash
#
# Drive the official ONLYOFFICE desktop build.
#
# This is a thin wrapper over build_tools/tools/linux/automate.py — we do not
# reimplement the build, we run upstream's. Before invoking it the script checks
# the three prerequisites that actually fail in locked-down networks, because
# automate.py's own failure mode is an opaque wget error several minutes in.
#
# Usage: scripts/build_desktop.sh [--check-only]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-/home/user/onlyoffice-src}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"
CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

DATA_BASE="https://github.com/ONLYOFFICE-data/build_tools_data/raw/refs/heads/master"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo "Preflight checks"

fatal=0

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
if [ -d "$BUILD_TOOLS/tools/linux/system_qt/gcc_64" ] || [ -d "$BUILD_TOOLS/tools/linux/qt_build" ]; then
  ok "Qt available ($( [ -d "$BUILD_TOOLS/tools/linux/system_qt/gcc_64" ] && echo system Qt || echo prebuilt Qt ))"
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

# 5. Disk. A full build materialises boost, ICU, OpenSSL, CEF, v8 and all objects.
avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
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
QT_DIR="$BUILD_TOOLS/tools/linux/system_qt"
[ -d "$BUILD_TOOLS/tools/linux/qt_build/Qt-5.9.9" ] && QT_DIR="$BUILD_TOOLS/tools/linux/qt_build/Qt-5.9.9"
# --sysroot 0: the ubuntu16 sysroot is LFS-tracked and only affects glibc
# compatibility of the shipped binary, not whether it builds.
./tools/linux/python3/bin/python3 ./configure.py \
    --branch master --module desktop --sysroot 0 --update 0 --qt-dir "$QT_DIR"
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
