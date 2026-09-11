#!/usr/bin/env bash
#
# Drive the official ONLYOFFICE macOS build, ad-hoc signed.
#
# WHY THIS IS A SEPARATE SCRIPT FROM build_desktop.sh
# ---------------------------------------------------
# build_desktop.sh drives build_tools/tools/linux/automate.py and checks for
# Linux prebuilts; it refuses to run off Linux, on purpose (see the platform
# guard at the top of it). macOS is a genuinely different pipeline:
#
#   - build_tools/tools/mac holds only 7za and toolchain.prf. There is no
#     bundled python3 and no staged Qt, so this uses the system python3 and a
#     Qt installed from Homebrew.
#   - The application is NOT built by qmake here. build_tools produces the core
#     into build_tools/out/mac_arm64/onlyoffice/desktopeditors, and
#     desktop-apps/macos/ONLYOFFICE.xcodeproj links against exactly that path
#     (FRAMEWORK_SEARCH_PATHS / LIBRARY_SEARCH_PATHS, verified in the pbxproj
#     at the pinned desktop-apps revision bc46371).
#
# SIGNING
# -------
# Distribution is fleet-only and there is no Apple Developer account, so
# everything is ad-hoc signed (codesign -s -). Run 34560326333 proved the whole
# path on a real runner: codesign accepts it, `codesign --verify --strict`
# passes, the app launches (even with com.apple.quarantine set), and appdmg
# builds a .dmg with no account once the hardcoded Developer ID is removed.
#
# The Xcode project hardcodes Ascensio's identity:
#
#   CODE_SIGN_IDENTITY = "Developer ID Application: Ascensio System SIA (2WH24U26GJ)"
#   CODE_SIGN_STYLE    = Manual
#   DEVELOPMENT_TEAM   = 2WH24U26GJ
#   ENABLE_HARDENED_RUNTIME = YES
#
# Those are overridden on the xcodebuild command line rather than patched into
# the pbxproj: the overlay stays a patch over a pinned checkout, and a build
# setting passed as an argument cannot drift out of sync with upstream the way
# an edited 4000-line project file does. Hardened runtime is turned OFF because
# it is meaningful only alongside notarization, which we deliberately do not do.
#
# The fastlane lane is NOT used. Its common_release hardwires
# gym(export_method: 'developer-id') + notarize(), both of which require the
# account we do not have, and it ends by committing a version bump and pushing
# to git. What is worth keeping from it -- the appdmg call -- is reproduced
# here directly.
#
# Usage: scripts/build_macos.sh [--check-only] [--arch arm64|x86_64]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"
CHECK_ONLY=0
ARCH="arm64"
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --arch) ARCH="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$ARCH" in
  arm64)  OUT_DIR="mac_arm64"; SCHEME="ONLYOFFICE-arm" ;;
  x86_64) OUT_DIR="mac_64";    SCHEME="ONLYOFFICE-x86_64" ;;
  *) echo "unknown --arch $ARCH (expected arm64 or x86_64)" >&2; exit 2 ;;
esac

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

PHASE_NAME=""; PHASE_T0=$SECONDS
phase_begin() { PHASE_NAME="$1"; PHASE_T0=$SECONDS; printf '=== phase begin: %s\n' "$1"; }
phase_end()   { printf '=== phase end:   %s (%ds)\n' "${PHASE_NAME:-?}" "$((SECONDS - PHASE_T0))"; }

echo "Preflight checks (target: $OUT_DIR, scheme $SCHEME)"
fatal=0

# 0. Platform. Every path below is a macOS path and xcodebuild exists nowhere
#    else. Fail here with the reason rather than several minutes in.
if [ "$(uname -s)" != "Darwin" ]; then
  bad "$(uname -s) is not supported by this script — it drives the macOS build (Xcode + build_tools mac)"
  echo
  echo "Preflight FAILED — nothing was built." >&2
  echo "The Linux build is scripts/build_desktop.sh." >&2
  exit 2
fi

if [ "$ARCH" = arm64 ] && [ "$(uname -m)" != "arm64" ]; then
  warn "building arm64 on $(uname -m); this is a cross build and has not been exercised"
fi

# 1. The upstream tree.
if [ -d "$BUILD_TOOLS" ]; then
  ok "build_tools present ($BUILD_TOOLS)"
else
  bad "build_tools missing — run scripts/bootstrap.sh"; fatal=1
fi
if [ -d "$SRC/desktop-apps/macos" ]; then
  ok "desktop-apps/macos present"
else
  bad "desktop-apps/macos missing — run scripts/bootstrap.sh"; fatal=1
fi

# 2. Toolchain. There is no bundled python3 under tools/mac, unlike tools/linux.
if command -v python3 >/dev/null; then
  ok "python3 ($(python3 --version 2>&1))"
else
  bad "python3 not found"; fatal=1
fi
if command -v xcodebuild >/dev/null; then
  ok "xcodebuild ($(xcodebuild -version 2>/dev/null | head -1))"
else
  bad "xcodebuild not found — install Xcode (the Command Line Tools alone are not enough)"; fatal=1
fi
command -v codesign >/dev/null && ok "codesign" || { bad "codesign not found"; fatal=1; }
command -v hdiutil  >/dev/null && ok "hdiutil"  || { bad "hdiutil not found";  fatal=1; }
command -v npx      >/dev/null && ok "npx (for appdmg)" || warn "npx not found — the .dmg step will be skipped"

# 3. Qt. Upstream reads the Qt VERSION out of the deploy path itself: base.py
#    computes qt_version as QT_DEPLOY.split("/")[-3] and keeps only digits and
#    dots, so a directory named "qt5" strips to "" and int("") raises. The path
#    must therefore look like <...>/Qt-<version>/clang_64/<...>. Homebrew's
#    layout does not, so build a small symlink tree that does.
QT_PREFIX="${LIGHTOFFICE_QT_PREFIX:-}"
if [ -z "$QT_PREFIX" ]; then
  for cand in "$(brew --prefix qt@5 2>/dev/null || true)" \
              "$(brew --prefix qt5 2>/dev/null || true)" \
              /usr/local/opt/qt@5 /opt/homebrew/opt/qt@5; do
    [ -n "$cand" ] && [ -x "$cand/bin/qmake" ] && { QT_PREFIX="$cand"; break; }
  done
fi
QT_DIR=""
if [ -n "$QT_PREFIX" ] && [ -x "$QT_PREFIX/bin/qmake" ]; then
  qt_ver="$("$QT_PREFIX/bin/qmake" -query QT_VERSION 2>/dev/null || echo '')"
  if [ -n "$qt_ver" ]; then
    QT_DIR="$BUILD_TOOLS/tools/mac/qt_build/Qt-$qt_ver"
    if [ "$CHECK_ONLY" -eq 0 ]; then
      mkdir -p "$QT_DIR"
      rm -f "$QT_DIR/clang_64"
      ln -s "$QT_PREFIX" "$QT_DIR/clang_64"
    fi
    ok "Qt $qt_ver at $QT_PREFIX (exposed as $QT_DIR/clang_64)"
  else
    bad "qmake at $QT_PREFIX/bin/qmake did not report a version"; fatal=1
  fi
else
  bad "Qt not found — install it: brew install qt@5 (or set LIGHTOFFICE_QT_PREFIX)"; fatal=1
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

phase_begin configure
python3 -u ./configure.py \
    --branch master --module desktop --update 0 --qt-dir "$QT_DIR"
phase_end

phase_begin make.py
python3 -u ./make.py
phase_end

CORE_OUT="$BUILD_TOOLS/out/$OUT_DIR/onlyoffice/desktopeditors"
if [ ! -d "$CORE_OUT" ]; then
  echo "make.py finished but produced no $CORE_OUT" >&2
  echo "what it did produce:" >&2
  ls -la "$BUILD_TOOLS/out" 2>/dev/null >&2 || echo "  (no out/ at all)" >&2
  exit 1
fi
ok "core built: $CORE_OUT ($(du -sh "$CORE_OUT" | cut -f1))"

# ------------------------------------------------------------------- app ----
# Ad-hoc from here down. See the header for why each override is set.
phase_begin xcodebuild
APP_BUILD="$SRC/desktop-apps/macos/build"
rm -rf "$APP_BUILD"
mkdir -p "$APP_BUILD"
xcodebuild \
  -project "$SRC/desktop-apps/macos/ONLYOFFICE.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$APP_BUILD/DerivedData" \
  CONFIGURATION_BUILD_DIR="$APP_BUILD" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=NO \
  build
phase_end

APP="$APP_BUILD/ONLYOFFICE.app"
[ -d "$APP" ] || { echo "xcodebuild reported success but $APP does not exist" >&2; exit 1; }

# Sign again, deep and explicitly. xcodebuild signs the app it produces, but the
# core drops its own dylibs and the converter into the bundle afterwards, and an
# unsigned nested Mach-O makes the whole bundle fail --verify --deep on the
# target machine rather than at build time.
phase_begin codesign
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | sed -n '1,8p'
phase_end
ok "ad-hoc signed and verified"

# ------------------------------------------------------------------- dmg ----
# appdmg itself needs no Apple account; the lane's appdmg.json does, because it
# carries a "code-sign" block naming Ascensio's Developer ID. Strip that block
# and it produces a plain .dmg -- proved on a real runner in run 34560326333.
if command -v npx >/dev/null; then
  phase_begin appdmg
  cfg="$SRC/desktop-apps/macos/fastlane/resources/appdmg.json"
  if [ -f "$cfg" ]; then
    tmpcfg="$(mktemp -d)/appdmg.json"
    python3 - "$cfg" "$tmpcfg" "$APP" <<'PY'
import json, sys
src, dst, app = sys.argv[1:4]
doc = json.load(open(src))
doc.pop("code-sign", None)          # the Developer ID we do not have
for c in doc.get("contents", []):
    if c.get("type") != "link" and c.get("path", "").endswith(".app"):
        c["path"] = app
json.dump(doc, open(dst, "w"), indent=2)
print("appdmg config rewritten without the code-sign block")
PY
    mkdir -p "$ROOT/artifacts"
    ( cd "$(dirname "$tmpcfg")" \
      && npx --yes appdmg "$tmpcfg" "$ROOT/artifacts/WPS-Lite-macos-$ARCH.dmg" )
    ok "dmg: $ROOT/artifacts/WPS-Lite-macos-$ARCH.dmg"
  else
    warn "no appdmg.json at $cfg — skipping the .dmg"
  fi
  phase_end
fi

echo
echo "macOS build complete."
