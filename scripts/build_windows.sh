#!/usr/bin/env bash
#
# Drive the official ONLYOFFICE Windows build and package an .exe installer.
#
# WHAT UPSTREAM ACTUALLY PROVIDES, because the previous belief was wrong
# ---------------------------------------------------------------------
# scripts/package.sh invoked
#   desktop-apps/win-linux/package/windows/make_installer.bat
# That path does not exist at the pinned desktop-apps revision (bc46371) --
# there is no .bat file anywhere in the repository. It is the same mistake as
# the package_mac.py call that was removed from the macOS path for the same
# reason: a plausible-looking filename that was never checked against the tree.
#
# The real Windows packaging is PowerShell, in desktop-apps/package:
#
#   make.ps1        stages build_tools/out/win_64/<Company>/<Product> into
#                   build\<arch>\desktop, and splits the help assets out into
#                   build\<arch>\help
#   make_inno.ps1   builds the Inno Setup installer from package/inno/*.iss,
#                   emitting <Company>-<Product>-<Version>-<Arch>.exe
#   make_advinst.ps1 / make_zip.ps1   MSI and portable zip, not used here
#
# SIGNING
# -------
# Both scripts take -Sign as an OPT-IN switch, defaulting off, so an unsigned
# build needs no certificate and no change to upstream's scripts. That matches
# the fleet-only posture already settled for macOS: no Authenticode cert, and
# Windows SmartScreen will warn on first run exactly as macOS Gatekeeper does.
# Passing -Sign would require Ascensio's "Ascensio System SIA" certificate,
# which we do not have and would not be entitled to use.
#
# THE TOOLCHAIN GAP TO EXPECT
# ---------------------------
# build_tools/scripts/core_common/modules/boost.py knows exactly two Visual
# Studio toolsets:
#
#     win_toolset = "msvc-14.0";  win_vs_version = "vc140"      # VS 2015
#     if (config.option("vs-version") == "2019"):
#       win_toolset = "msvc-14.2";  win_vs_version = "vc142"    # VS 2019
#
# There is no branch for VS 2022 (msvc-14.3 / vc143), and GitHub's
# windows-2019 image is retired. So --vs-version 2019 is the newest this pin
# understands, and it only works if the v142 toolset is actually installed
# alongside VS 2022. The preflight below reports which MSVC toolsets exist
# rather than assuming, because on macOS the equivalent assumption cost 18
# minutes and surfaced as an unrelated-looking link error.
#
# Usage: scripts/build_windows.sh [--check-only] [--arch x64|x86]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"
CHECK_ONLY=0
ARCH="x64"
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --arch) ARCH="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$ARCH" in
  x64) PLATFORM="win_64"; OUT_DIR="win_64" ;;
  x86) PLATFORM="win_32"; OUT_DIR="win_32" ;;
  *) echo "unknown --arch $ARCH (expected x64 or x86)" >&2; exit 2 ;;
esac

# make.ps1 resolves its source as out/<prefix>/<CompanyName>/<ProductName>, so
# these two must match what the build actually deploys, not what we call the
# product elsewhere.
COMPANY="${LIGHTOFFICE_WIN_COMPANY:-ONLYOFFICE}"
PRODUCT="${LIGHTOFFICE_WIN_PRODUCT:-DesktopEditors}"
VERSION="${LIGHTOFFICE_VERSION:-1.0.0.0}"

ok()   { printf '  \033[32m+\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mx\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

PHASE_NAME=""; PHASE_T0=$SECONDS
phase_begin() { PHASE_NAME="$1"; PHASE_T0=$SECONDS; printf '=== phase begin: %s\n' "$1"; }
phase_end()   { printf '=== phase end:   %s (%ds)\n' "${PHASE_NAME:-?}" "$((SECONDS - PHASE_T0))"; }

echo "Preflight checks (target: $PLATFORM, $COMPANY/$PRODUCT $VERSION)"
fatal=0

# 0. Platform. Everything below is a Windows path and PowerShell exists
#    nowhere else. Fail here with the reason rather than minutes in.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    bad "$(uname -s) is not supported by this script — it drives the Windows build (MSVC + Inno Setup)"
    echo
    echo "Preflight FAILED — nothing was built." >&2
    echo "Linux is scripts/build_desktop.sh; macOS is scripts/build_macos.sh." >&2
    exit 2 ;;
esac

# 1. The upstream tree.
[ -d "$BUILD_TOOLS" ] && ok "build_tools present ($BUILD_TOOLS)" \
  || { bad "build_tools missing — run scripts/bootstrap.sh"; fatal=1; }
PKG="$SRC/desktop-apps/package"
if [ -f "$PKG/make.ps1" ] && [ -f "$PKG/make_inno.ps1" ]; then
  ok "desktop-apps/package present (make.ps1, make_inno.ps1)"
else
  bad "desktop-apps/package/make.ps1 or make_inno.ps1 missing — run scripts/bootstrap.sh"; fatal=1
fi

# 2. Toolchain.
command -v python3 >/dev/null && ok "python3 ($(python3 --version 2>&1))" \
  || { bad "python3 not found"; fatal=1; }
command -v powershell >/dev/null || command -v pwsh >/dev/null \
  && ok "powershell" || { bad "powershell not found"; fatal=1; }

# Which MSVC toolsets actually exist. boost.py can ask for msvc-14.0 (VS 2015)
# or msvc-14.2 (VS 2019) and nothing else, so knowing what is installed decides
# whether this build can work at all -- and saying so here is the whole point.
VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
if [ -x "$VSWHERE" ]; then
  vs_root="$("$VSWHERE" -latest -property installationPath 2>/dev/null | tr -d '\r')"
  ok "Visual Studio at ${vs_root:-unknown}"
  if [ -n "$vs_root" ] && [ -d "$vs_root/VC/Tools/MSVC" ]; then
    # `|| true` is not redundant despite the -d guard above: ls exits non-zero
    # on an unreadable directory too, and with pipefail + set -e that aborts
    # the preflight silently. The identical pattern in build_macos.sh cost run
    # 34663626582 its whole arm64 leg in under a second, with no message.
    toolsets="$(ls "$vs_root/VC/Tools/MSVC" 2>/dev/null | tr '\n' ' ' || true)"
    ok "MSVC toolsets installed: ${toolsets:-none}"
    # 14.2x is the v142 (VS 2019) toolset boost.py's "2019" branch selects.
    case " $toolsets " in
      *" 14.2"*) ok "v142 toolset present — --vs-version 2019 can work" ;;
      *) warn "no v142 (14.2x) toolset: boost.py has no branch for anything newer,"
         warn "  so b2 will be told msvc-14.2 and may not find it."
         warn "  Install the VS 2019 C++ build tools, or add a vc143 branch to boost.py." ;;
    esac
  else
    warn "could not enumerate MSVC toolsets under $vs_root"
  fi
else
  bad "vswhere not found — no Visual Studio installation to query"; fatal=1
fi

# Installed is not the same as usable, and only the second one matters. Run
# 34666010157 passed this preflight and then died 4m46s later on
#
#   'cl' is not recognized as an internal or external command
#
# because MSVC reaches PATH only after vcvarsall.bat, which a Developer Command
# Prompt runs and a plain shell does not. Checking for the compiler itself is
# the check that would have caught it in a second.
if command -v cl >/dev/null 2>&1 || command -v cl.exe >/dev/null 2>&1; then
  ok "cl is on PATH ($(cl 2>&1 | head -1 | tr -d '\r' || true))"
else
  bad "cl (the MSVC compiler) is not on PATH — the MSVC environment is not set up"
  echo "      run vcvarsall.bat x64 first, or use a Developer Command Prompt." >&2
  echo "      in CI this is the 'Set up the MSVC environment' step." >&2
  fatal=1
fi

# grunt drives the JS stage (sdkjs, web-apps) via build_tools/scripts/build_js.py,
# which shells out to a bare `grunt`. Upstream installs grunt-cli in
# tools/linux/deps.py -- Linux only -- so nothing provides it here. macOS hit
# exactly this in run 34669576598: 35 minutes of native compile, then
# "/bin/sh: grunt: command not found" (Error (grunt): 127). Windows has not got
# that far yet, so check for it now rather than learn the same thing later.
# Checked by presence: `grunt --version` exits non-zero with no local Gruntfile.
if command -v grunt >/dev/null 2>&1; then
  ok "grunt ($(command -v grunt))"
else
  bad "grunt not found — the JS stage needs it: npm install -g grunt-cli"; fatal=1
fi

# V8 8.9 ships a 2021-era Chromium vs_toolchain.py that accepts only VS 2017 and
# 2019 and raises "No supported Visual Studio can be found" on anything newer.
# Its own escape hatch is vs2019_install, which the workflow points at the 2022
# installation. Without it the build reaches V8 about 30 minutes in and stops.
if [ -n "${vs2019_install:-}" ] && [ -d "${vs2019_install:-}" ]; then
  ok "vs2019_install is set for V8 ($vs2019_install)"
elif [ -n "${vs2019_install:-}" ]; then
  bad "vs2019_install is set but does not exist: $vs2019_install"; fatal=1
else
  warn "vs2019_install is unset — V8's vs_toolchain.py rejects VS 2022 and the"
  warn "  build will stop in V8. In CI the MSVC environment step sets it."
fi

# 3. Qt. Same rule as macOS: upstream derives the Qt VERSION from the deploy
#    path (base.py takes QT_DEPLOY.split("/")[-3] and keeps digits and dots),
#    so the directory must look like <...>/Qt-<version>/<compiler>/<...>.
QT_PREFIX="${LIGHTOFFICE_QT_PREFIX:-}"
QT_DIR=""
if [ -n "$QT_PREFIX" ] && [ -x "$QT_PREFIX/bin/qmake.exe" ]; then
  qt_ver="$("$QT_PREFIX/bin/qmake.exe" -query QT_VERSION 2>/dev/null | tr -d '\r')"
  if [ -n "$qt_ver" ]; then
    QT_DIR="$BUILD_TOOLS/tools/win/qt_build/Qt-$qt_ver"
    if [ "$CHECK_ONLY" -eq 0 ]; then
      mkdir -p "$QT_DIR"
      rm -rf "$QT_DIR/msvc2019_64"
      # A copy, not a symlink: Windows symlinks need privileges that CI does
      # not reliably have, and qmake resolves paths through them badly.
      cp -r "$QT_PREFIX" "$QT_DIR/msvc2019_64"
    fi
    ok "Qt $qt_ver at $QT_PREFIX (exposed as $QT_DIR/msvc2019_64)"
  else
    bad "qmake at $QT_PREFIX did not report a version"; fatal=1
  fi
else
  bad "Qt not found — set LIGHTOFFICE_QT_PREFIX to a Qt 5 MSVC install"
  echo "      in CI this comes from aqtinstall; see the workflow." >&2
  fatal=1
fi

# 4. Inno Setup. make_inno.ps1 reads $env:INNOPATH first and only then falls
#    back to the uninstall registry key, so setting it is both supported and
#    more reliable than hoping the key is where it expects.
INNO="${INNOPATH:-}"
if [ -z "$INNO" ]; then
  for c in "/c/Program Files (x86)/Inno Setup 6" "/c/Program Files/Inno Setup 6"; do
    [ -x "$c/ISCC.exe" ] && { INNO="$c"; break; }
  done
fi
if [ -n "$INNO" ] && [ -x "$INNO/ISCC.exe" ]; then
  ok "Inno Setup 6 at $INNO"
else
  bad "Inno Setup 6 not found — install it (choco install innosetup) or set INNOPATH"
  fatal=1
fi

echo
if [ "$fatal" -ne 0 ]; then
  echo "Preflight FAILED — nothing was built." >&2
  exit 2
fi
echo "Preflight OK"
[ "$CHECK_ONLY" -eq 1 ] && { echo "(--check-only: stopping before the build)"; exit 0; }

# ------------------------------------------------------------------ core ----
echo
echo "Running upstream build (this takes hours) ..."
cd "$BUILD_TOOLS"

# The CMake modules hardcode the "Visual Studio 16 2019" generator, which
# resolves a real VS instance and finds none -- run 34672136278 spent 94
# minutes reaching x265 to discover that. Make the generator overridable and
# ask for 2022 with the v142 toolset, matching what vcvarsall selected and
# what Qt and boost are built against. See scripts/patch_vs2022_generator.sh.
phase_begin patch-vs-generator
"$ROOT/scripts/patch_vs2022_generator.sh" "$SRC"
export LIGHTOFFICE_VS_GENERATOR="${LIGHTOFFICE_VS_GENERATOR:-17 2022}"
export LIGHTOFFICE_VS_TOOLSET="${LIGHTOFFICE_VS_TOOLSET:-v142}"
echo "cmake generator: Visual Studio $LIGHTOFFICE_VS_GENERATOR -T $LIGHTOFFICE_VS_TOOLSET"
phase_end

phase_begin configure
python3 -u ./configure.py \
    --branch master --module desktop --update 0 \
    --platform "$PLATFORM" --vs-version 2019 --qt-dir "$QT_DIR"
phase_end

phase_begin make.py
python3 -u ./make.py
phase_end

CORE_OUT="$BUILD_TOOLS/out/$OUT_DIR/$COMPANY/$PRODUCT"
if [ ! -d "$CORE_OUT" ]; then
  echo "make.py finished but produced no $CORE_OUT" >&2
  echo "what it did produce:" >&2
  ls -la "$BUILD_TOOLS/out" 2>/dev/null >&2 || echo "  (no out/ at all)" >&2
  exit 1
fi
ok "core built: $CORE_OUT ($(du -sh "$CORE_OUT" | cut -f1))"

# --------------------------------------------------------------- package ----
phase_begin make.ps1
( cd "$PKG" && powershell -NoProfile -ExecutionPolicy Bypass -File ./make.ps1 \
    -Version "$VERSION" -Arch "$ARCH" \
    -CompanyName "$COMPANY" -ProductName "$PRODUCT" \
    -SourceDir "$(cygpath -w "$CORE_OUT")" )
phase_end

phase_begin make_inno.ps1
( cd "$PKG" && INNOPATH="$(cygpath -w "$INNO")" \
  powershell -NoProfile -ExecutionPolicy Bypass -File ./make_inno.ps1 \
    -Version "$VERSION" -Arch "$ARCH" \
    -CompanyName "$COMPANY" -ProductName "$PRODUCT" )
phase_end

# make_inno.ps1 names its output <Company>-<Product>-<Version>-<Arch>.exe.
# Rename to the name release.yml and AC 5.1 expect, rather than teaching them a
# second name -- one of them would inevitably drift.
built="$PKG/build/$ARCH/$COMPANY-$PRODUCT-$VERSION-$ARCH.exe"
if [ ! -f "$built" ]; then
  echo "make_inno.ps1 finished but $built does not exist" >&2
  ls -la "$PKG/build/$ARCH" 2>/dev/null >&2 || true
  exit 1
fi
mkdir -p "$ROOT/artifacts"
cp "$built" "$ROOT/artifacts/WPS-Lite-win-$ARCH.exe"
ok "installer: artifacts/WPS-Lite-win-$ARCH.exe ($(du -h "$built" | cut -f1))"

echo
echo "Windows build complete."
