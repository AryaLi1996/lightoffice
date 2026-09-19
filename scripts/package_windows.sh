#!/usr/bin/env bash
#
# The second half of the Windows build: run Inno Setup over the tree
# build_windows.sh --stage-only staged, and produce the installer.
#
# WHY THIS IS A SEPARATE SCRIPT, AND A SEPARATE JOB. Measured, not guessed --
# the phase markers from two runs:
#
#   run 35238369724:  make.py 8917s (149 min), then ISCC 190+ min, killed
#   run 35320983745:  make.py 8354s (139 min), then ISCC ~195 min, killed
#
# Both died at the step timeout with ISCC still compressing. A GitHub-hosted job
# is capped at 360 minutes and the cap cannot be raised, so ~140 + ~195 does not
# fit however the timeouts are arranged.
#
# LZMANumBlockThreads=4 was tried first and bought nothing, which in hindsight
# is what SolidCompression=yes implies: the payload is one solid LZMA2 stream,
# so there are no independent blocks for the extra threads to work on. The
# cleanup line "Terminate orphan process: pid (7488) (islzma64)" is that single
# compressor.
#
# So the work is split instead of made smaller. The compile job stages the tree
# and hands it over; this runs in a job with a fresh 360 minute budget, which
# ~195 minutes of ISCC fits inside comfortably. The installer is byte-for-byte
# what the single job would have produced -- same compression, same contents,
# nothing cut.
#
# Usage: scripts/package_windows.sh [--arch x64|x86]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}"
ARCH="x64"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/lib/win_env.sh
. "$ROOT/scripts/lib/win_env.sh"

ok()   { printf '  \033[32m+\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mx\033[0m %s\n' "$*"; }

PHASE_NAME=""; PHASE_T0=$SECONDS
phase_begin() { PHASE_NAME="$1"; PHASE_T0=$SECONDS; printf '=== phase begin: %s\n' "$1"; }
phase_end()   { printf '=== phase end:   %s (%ds)\n' "${PHASE_NAME:-?}" "$((SECONDS - PHASE_T0))"; }

echo "Packaging $COMPANY/$PRODUCT $VERSION ($ARCH)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) bad "$(uname -s) is not supported — ISCC and PowerShell are Windows-only"; exit 1 ;;
esac

fatal=0
[ -d "$SRC" ] || { bad "no upstream tree at $SRC — run scripts/bootstrap.sh"; fatal=1; }
[ -f "$PKG/make_inno.ps1" ] || { bad "$PKG/make_inno.ps1 missing — run scripts/bootstrap.sh"; fatal=1; }

# The staged tree, which the compile job produced and this job restored. Without
# it ISCC would compress an empty directory for three hours and hand back an
# installer with nothing in it.
if [ -d "$STAGED/desktop" ]; then
  ok "staged tree: $STAGED ($(du -sh "$STAGED" 2>/dev/null | cut -f1))"
else
  bad "no $STAGED/desktop — the compile job's tree was not restored"
  ls -la "$STAGED" 2>/dev/null || echo "      (no $STAGED at all)"
  fatal=1
fi

INNO="$(find_inno || true)"
if [ -n "$INNO" ]; then
  ok "Inno Setup 6 at $INNO"
else
  bad "Inno Setup 6 not found — install it (choco install innosetup) or set INNOPATH"
  fatal=1
fi

[ "$fatal" -eq 0 ] || { echo; echo "packaging preflight failed" >&2; exit 1; }

phase_begin make_inno.ps1
( cd "$PKG" && INNOPATH="$(cygpath -w "$INNO")" \
  powershell -NoProfile -ExecutionPolicy Bypass -File ./make_inno.ps1 \
    -Version "$VERSION" -Arch "$ARCH" \
    -CompanyName "$COMPANY" -ProductName "$PRODUCT" )
phase_end

# make_inno.ps1 names its output <Company>-<Product>-<Version>-<Arch>.exe and
# writes it beside common.iss, in inno/ -- NOT into build/<arch>/. Run
# 35381703378 is what settled that: ISCC reported
#
#   Successful compile (296.469 sec). Resulting Setup program filename is:
#   C:\lightoffice\src\desktop-apps\package\inno\ONLYOFFICE-...-x64.exe
#
# and this script then declared failure because it was looking in build/x64.
# That expectation came from the single-job script and had never been reached
# before, so it had never been wrong in practice.
#
# Both locations are searched rather than one being swapped for the other:
# upstream is free to change where it puts the file, and a packaging run that
# finds nothing after a successful compile is the most annoying way to lose one.
name="$COMPANY-$PRODUCT-$VERSION-$ARCH.exe"
built=""
for c in "$PKG/inno/$name" "$STAGED/$name"; do
  [ -f "$c" ] && { built="$c"; break; }
done
if [ -z "$built" ]; then
  echo "make_inno.ps1 finished but $name is in neither place:" >&2
  echo "  $PKG/inno/$name" >&2
  echo "  $STAGED/$name" >&2
  echo "what ISCC did leave behind:" >&2
  find "$PKG" -maxdepth 3 -name '*.exe' -newermt '-1 hour' 2>/dev/null >&2 || true
  exit 1
fi
ok "built: $built"
mkdir -p "$ROOT/artifacts"
cp "$built" "$ROOT/artifacts/WPS-Lite-win-$ARCH.exe"
ok "installer: artifacts/WPS-Lite-win-$ARCH.exe ($(du -h "$built" | cut -f1))"

echo
echo "Windows packaging complete."
