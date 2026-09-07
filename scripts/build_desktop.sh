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
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-/home/user/build_tools}"
CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

DATA_BASE="https://github.com/ONLYOFFICE-data/build_tools_data/raw/refs/heads/master"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo "Preflight checks"

fatal=0

# 1. build_tools present
if [ -d "$BUILD_TOOLS/tools/linux" ]; then
  ok "build_tools present ($BUILD_TOOLS)"
else
  bad "build_tools missing — run scripts/bootstrap.sh"; fatal=1
fi

# 2. The bootstrap Python tarball. automate.py's first action is ./python.sh,
#    which wgets this. A 403 here means the whole pipeline cannot start.
code=$(curl -s -o /dev/null -w '%{http_code}' -L "$DATA_BASE/python/python3.tar.gz" || echo 000)
if [ "$code" = "200" ]; then
  ok "bootstrap python3 reachable"
else
  bad "bootstrap python3 unreachable (HTTP $code) — $DATA_BASE/python/python3.tar.gz"
  fatal=1
fi

# 3. Prebuilt Qt. Fetched by qt_binary_fetch.py; also LFS-backed in the data repo,
#    so an anonymous git lane returns a 133-byte pointer rather than the archive.
code=$(curl -s -o /dev/null -w '%{http_code}' -L "$DATA_BASE/qt/qt_binary_5.9.9_gcc_64.7z" || echo 000)
if [ "$code" = "200" ]; then
  ok "prebuilt Qt 5.9.9 reachable"
else
  bad "prebuilt Qt unreachable (HTTP $code) — $DATA_BASE/qt/qt_binary_5.9.9_gcc_64.7z"
  bad "  (system Qt is a fallback: build_tools/tools/linux/use_system_qt.py)"
  fatal=1
fi

# 4. Disk. A full build materialises Qt, a sysroot, CEF and all object files.
avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "${avail_gb:-0}" -ge 60 ]; then
  ok "disk: ${avail_gb}G available"
else
  bad "disk: ${avail_gb}G available; a full desktop build needs roughly 60G"
  fatal=1
fi

echo
if [ "$fatal" -ne 0 ]; then
  echo "Preflight FAILED — automate.py would abort. Nothing was built." >&2
  echo "See docs/DEVELOPER_GUIDE.md §3 for what the pipeline needs." >&2
  exit 2
fi
ok "preflight passed"

[ "$CHECK_ONLY" -eq 1 ] && { echo "--check-only: stopping before build."; exit 0; }

echo
echo "Running upstream build (this takes hours) ..."
cd "$BUILD_TOOLS/tools/linux"
./automate.py desktop
rc=$?

BIN="$SRC/../out/linux_64/onlyoffice/desktopeditors/DesktopEditors"
echo
echo "automate.py exit code: $rc"
if [ -x "$BIN" ]; then
  ok "binary: $BIN"
  file "$BIN"
else
  bad "expected binary not found at $BIN"
fi
exit $rc
