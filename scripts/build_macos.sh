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

# PLATFORM is what configure.py is told to build; OUT_DIR is where it lands.
# They must agree, and the default does not.
case "$ARCH" in
  arm64)  PLATFORM="mac_arm64"; OUT_DIR="mac_arm64"; SCHEME="ONLYOFFICE-arm" ;;
  x86_64) PLATFORM="mac_64";    OUT_DIR="mac_64";    SCHEME="ONLYOFFICE-x86_64" ;;
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

# Either direction is a cross build, and both are worth saying out loud: the
# host toolchain is happy to compile for the other architecture, so nothing
# complains until a dependency built for the host arch refuses to link.
if [ "$ARCH" != "$(uname -m)" ]; then
  warn "building $ARCH on $(uname -m) — cross build; every dependency (Qt, ICU, CEF) must be $ARCH too"
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
# CMake 4 removed support for pre-3.5 CMakeLists, and core vendors an x265
# revision that needs them. Run 34575866221 spent 22 minutes reaching that
# failure; a preflight that does not check the toolchain versions it depends on
# is why. Check it here, where it costs nothing.
if command -v cmake >/dev/null; then
  cmake_ver="$(cmake --version 2>/dev/null | head -1 | sed 's/[^0-9.]*//;s/ .*//')"
  cmake_major="${cmake_ver%%.*}"
  # A version string this does not understand (a nightly, say) must not read as
  # "fine": `[ "$x" -ge 4 ]` errors on a non-number and, with the error hidden,
  # would silently pass. Say it is unknown instead.
  case "$cmake_major" in
    ''|*[!0-9]*) warn "could not parse a cmake version from '$cmake_ver' — cannot tell whether it is a 4.x"; cmake_major=0 ;;
  esac
  if [ "$cmake_major" -ge 4 ]; then
    bad "cmake $cmake_ver — CMake 4 cannot configure core's vendored x265 (needs policies CMP0025/CMP0054 that 4.x removed)"
    echo "      install a 3.x and put it first on PATH; 3.31.7 is the last one." >&2
    fatal=1
  else
    ok "cmake $cmake_ver"
  fi
else
  bad "cmake not found"; fatal=1
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
    # Qt's OWN architecture must match the target. An x86_64 Qt on an arm64
    # build (or the reverse) is the same class of failure the ICU mismatch was:
    # the compile succeeds and the link dies with every Qt symbol undefined,
    # which reads like a missing Qt rather than the wrong one. Naming it here
    # costs a second; finding it at the link cost 18 minutes last time.
    qt_core="$(ls "$QT_PREFIX"/lib/QtCore.framework/Versions/*/QtCore \
                  "$QT_PREFIX"/lib/libQt5Core.dylib 2>/dev/null | head -1)"
    if [ -n "$qt_core" ]; then
      qt_archs="$(lipo -archs "$qt_core" 2>/dev/null || true)"
      case " $qt_archs " in
        *" $ARCH "*) ok "Qt $qt_ver [$qt_archs] at $QT_PREFIX (exposed as $QT_DIR/clang_64)" ;;
        "  ")        warn "could not read Qt's architecture from $qt_core — proceeding unverified" ;;
        *) bad "Qt at $QT_PREFIX is [$qt_archs] but this build targets $ARCH"
           echo "      install a $ARCH Qt and point LIGHTOFFICE_QT_PREFIX at it." >&2
           echo "      on an arm64 host an x86_64 Qt comes from Rosetta Homebrew:" >&2
           echo "        arch -x86_64 /usr/local/bin/brew install qt@5" >&2
           fatal=1 ;;
      esac
    else
      warn "no QtCore found under $QT_PREFIX/lib — cannot verify Qt's architecture"
    fi
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

# Boost 1.72 (what boost.py pins) vs Apple clang 21. Run 34601443842 spent
# 38 minutes reaching this and died compiling libetonyek:
#
#   integral_wrapper.hpp:73: error: non-type template argument is not a
#   constant expression -- integer value -1 is outside the valid range of
#   values [0, 3] for the enumeration type 'int_float_mixture_enum'
#
# The patch script carries the full reasoning. It is idempotent, macOS-only,
# and refuses to edit if upstream's base.pri layout has moved rather than
# patching blind.
phase_begin patch-boost
"$ROOT/scripts/patch_boost_enum_constexpr.sh" "$SRC"
phase_end

# --platform is NOT optional here, though it looks it. It defaults to "native",
# and build_tools/scripts/config.py expands that as:
#
#     bits = "32"
#     if platform.machine().endswith('64'): bits = "64"
#     ...
#     options["platform"] += (" mac_" + bits)
#
# On Apple Silicon platform.machine() is "arm64", which ends with "64", so bits
# becomes "64" and native resolves to mac_64 -- the x86_64 target -- on an arm64
# machine. "native" can never produce mac_arm64.
#
# Run 34595493731 is what that costs: every third-party library built x86_64
# into 3dParty/icu/mac_64 while the Qt side compiled arm64, and the link died
# with every ICU symbol undefined:
#
#   ld: warning: ignoring file .../icu/mac_64/build/libicuuc.a, building for
#       macOS-arm64 but attempting to link with file built for macOS-x86_64
#   ld: symbol(s) not found for architecture arm64
#
# mac_arm64 is a real platform (config.py lists it) even though configure.py's
# own --platform help text still says mac only offers mac_64.
phase_begin configure
python3 -u ./configure.py \
    --branch master --module desktop --update 0 \
    --platform "$PLATFORM" --qt-dir "$QT_DIR"
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

# Prove the core is the architecture we asked for. A build that quietly targets
# the wrong one does not fail here -- it fails much later, at the link, with
# every symbol of some third-party library undefined, which reads like a missing
# dependency rather than an architecture mismatch. That is exactly how run
# 34595493731 presented, and it cost 18 minutes to find out.
want_arch="$ARCH"
bad_arch=0
while IFS= read -r lib; do
  archs="$(lipo -archs "$lib" 2>/dev/null || true)"
  [ -n "$archs" ] || continue
  case " $archs " in
    *" $want_arch "*) ;;
    *) echo "  wrong architecture: $(basename "$lib") is [$archs], expected $want_arch" >&2
       bad_arch=$((bad_arch + 1)) ;;
  esac
done <<EOF
$(find "$CORE_OUT" -maxdepth 2 -type f \( -name '*.dylib' -o -name 'x2t' \) 2>/dev/null | head -20)
EOF
if [ "$bad_arch" -gt 0 ]; then
  echo "$bad_arch built file(s) are not $want_arch — the core was built for the wrong target" >&2
  exit 1
fi
ok "core is $want_arch"

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
