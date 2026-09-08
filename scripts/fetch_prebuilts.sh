#!/usr/bin/env bash
#
# Fetch the prebuilt blobs the ONLYOFFICE build needs from build_tools_data.
#
# Why this exists: build_tools downloads its bootstrap Python, prebuilt Qt and
# CEF from raw.githubusercontent-style URLs under
# github.com/ONLYOFFICE-data/build_tools_data. Those raw URLs are frequently
# blocked by corporate egress policy (HTTP 403), which kills automate.py on its
# very first step with an opaque wget error.
#
# The repository itself is still clonable over plain git, and — importantly —
# only a handful of its files are LFS-tracked. Per its .gitattributes those are
# the Qt source tarballs, the Qt Linux/arm binaries, the sysroots and
# android/v8.7z. Everything else, CEF and the bootstrap Python included, is an
# ordinary git blob. So a sparse checkout gets them even where the raw URLs and
# the LFS endpoint do not work.
#
# What this does NOT solve: prebuilt Qt (LFS — use use_system_qt.py instead) and
# v8, which is not in this repo at all and needs depot_tools from
# chromium.googlesource.com. See scripts/build_desktop.sh --check-only.
#
# Usage: scripts/fetch_prebuilts.sh [/path/to/onlyoffice-src]

set -euo pipefail

# ROOT was referenced in the SRC default without ever being set. Under `set -u`
# that aborts the script — but only when neither an argument nor
# LIGHTOFFICE_SRC is given, which is why CI never hit it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"
DATA_REPO="https://github.com/ONLYOFFICE-data/build_tools_data"
WORK="${LIGHTOFFICE_PREBUILT_CACHE:-/tmp/lightoffice-prebuilts}"

# CEF branch for a modern gcc on linux_64. build_tools picks 5304 when
# config.is_cef_107() is true (gcc < 5.0.4) and 5414 otherwise.
CEF_BRANCH="${CEF_BRANCH:-5414}"
CEF_PLATFORM="${CEF_PLATFORM:-linux_64}"

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

[ -d "$BUILD_TOOLS/tools/linux" ] || { echo "build_tools not found at $BUILD_TOOLS" >&2; exit 1; }

# --- sparse checkout of just the two blobs we need ---------------------------
if [ ! -d "$WORK/.git" ]; then
  echo "cloning build_tools_data (blobless, sparse) ..."
  GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --filter=blob:none --sparse "$DATA_REPO" "$WORK"
fi
git -C "$WORK" sparse-checkout set --skip-checks \
  "python/python3.tar.gz" "python/extract.sh" \
  "cef/$CEF_BRANCH/$CEF_PLATFORM/cef_binary.7z"
git -C "$WORK" checkout HEAD -- python cef

# A 133-byte file here means we got an LFS pointer rather than the real archive.
for f in "$WORK/python/python3.tar.gz" "$WORK/cef/$CEF_BRANCH/$CEF_PLATFORM/cef_binary.7z"; do
  [ -f "$f" ] || { echo "missing after checkout: $f" >&2; exit 1; }
  if head -c 40 "$f" | grep -q "git-lfs.github.com"; then
    echo "$f is an LFS pointer, not the archive — the anonymous git lane does not serve LFS objects." >&2
    exit 1
  fi
done
ok "blobs fetched ($(du -sh "$WORK" | cut -f1))"

# --- bootstrap python --------------------------------------------------------
if [ -x "$BUILD_TOOLS/tools/linux/python3/bin/python3" ]; then
  ok "bootstrap python3 already installed"
else
  install -m 0644 "$WORK/python/python3.tar.gz" "$BUILD_TOOLS/tools/linux/"
  install -m 0755 "$WORK/python/extract.sh"     "$BUILD_TOOLS/tools/linux/"
  ( cd "$BUILD_TOOLS/tools/linux" && ./extract.sh >/dev/null && cd python3/bin && ln -sf python3 python )
  ok "bootstrap python3 installed ($("$BUILD_TOOLS/tools/linux/python3/bin/python3" --version))"
fi

# --- CEF ---------------------------------------------------------------------
CEFDIR="$SRC/core/Common/3dParty/cef"
if [ -d "$CEFDIR/$CEF_PLATFORM/build" ]; then
  ok "CEF already staged"
else
  command -v 7z >/dev/null || { echo "7z is required (apt install p7zip-full)" >&2; exit 1; }
  mkdir -p "$CEFDIR/$CEF_PLATFORM"
  # build_tools wipes this tree unless module.version matches what cef.py expects.
  printf '2' > "$CEFDIR/module.version"
  (
    cd "$CEFDIR/$CEF_PLATFORM"
    cp "$WORK/cef/$CEF_BRANCH/$CEF_PLATFORM/cef_binary.7z" .
    7z x -y cef_binary.7z >/dev/null
    mkdir -p build
    cp -a cef_binary/Release/* build/
    cp -a cef_binary/Resources/* build/
    chmod a+xr build/locales 2>/dev/null || true
    rm -rf cef_binary cef_binary.7z
    # cef.py compares this against the Last-Modified header of the download URL.
    # That request fails closed (empty string) when the URL is blocked, so an
    # empty marker file is what makes cef.py skip the download and keep build/.
    : > cef_binary.7z.data
  )
  ok "CEF staged ($(du -sh "$CEFDIR/$CEF_PLATFORM/build" | cut -f1))"
fi

# --- system Qt ---------------------------------------------------------------
if [ -d "$BUILD_TOOLS/tools/linux/system_qt/gcc_64" ]; then
  ok "system Qt already linked"
else
  ( cd "$BUILD_TOOLS/tools/linux" && python3 use_system_qt.py )
  ok "system Qt linked ($(qmake -query QT_VERSION 2>/dev/null || echo '?'))"
fi

# --- versioned alias for the system Qt ---------------------------------------
# use_system_qt.py produces tools/linux/system_qt/gcc_64, and that directory name
# is the problem: upstream reads the Qt version out of the PATH rather than from
# qmake. base.py does
#
#     qt_version()  ->  QT_DEPLOY.split("/")[-3], keeping only digits and dots
#
# so with --qt-dir .../system_qt the third-from-last component is "system_qt",
# which strips to the empty string and int("") raises. The failure only appears
# on the sysroot build path, because boost.py builds boost with plain b2 when
# sysroot is empty and via qmake when it is not — and we need sysroot for v8.
#
# So give the system Qt a directory whose NAME carries the version, in the
# layout upstream already expects for a prebuilt Qt. It is a symlink, not a
# copy: one name, no duplicated toolchain.
QT_VER="$(qmake -query QT_VERSION 2>/dev/null || qmake-qt5 -query QT_VERSION 2>/dev/null || true)"
if [ -z "$QT_VER" ]; then
  warn "qmake did not report a Qt version; skipping the versioned alias. A sysroot build will fail in base.py qt_version()."
else
  QT_ALIAS="$BUILD_TOOLS/tools/linux/qt_build/Qt-$QT_VER"
  if [ -d "$QT_ALIAS/gcc_64" ]; then
    ok "versioned Qt alias present (Qt-$QT_VER)"
  else
    mkdir -p "$QT_ALIAS"
    ln -sfn "$BUILD_TOOLS/tools/linux/system_qt/gcc_64" "$QT_ALIAS/gcc_64"
    ok "versioned Qt alias created: qt_build/Qt-$QT_VER/gcc_64 -> system_qt/gcc_64"
  fi
fi

# --- depot_tools, pinned, and the marker that stops upstream deleting it ------
# v8_89.py clones depot_tools from HEAD, unpinned. That dependency moved: the
# same code path fetched v8 successfully on 2026-09-07 and has failed on every
# run since, because current HEAD cannot bootstrap its CIPD client. Pinning it
# is the whole point of a reproducible build — an unpinned HEAD dependency is a
# build that works until someone else's Tuesday.
#
# Staging it here only works if the marker below is written too. v8_89.py calls
#
#     base.common_check_version("v8", "1", clean)
#
# and base.py does an EXACT string compare of ./v8.data against "v8_version_1",
# calling clean() — which deletes depot_tools, v8, .gclient and
# .gclient_entries — on any mismatch, including a missing file. An earlier
# attempt staged depot_tools without the marker and watched upstream delete it;
# the log line was "delete warning [folder not exist]: depot_tools". readFile
# and writeFile are byte-exact, so the marker must carry NO trailing newline.
V8_BASE="$SRC/core/Common/3dParty/v8_89"
DEPOT_TOOLS="$V8_BASE/depot_tools"
V8_MARKER="$V8_BASE/v8.data"
DEPOT_TOOLS_URL="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
# Anchored on evidence rather than a guessed SHA: pin to the last revision from
# before the day the fetch was last known to work. Override to move the pin.
PIN_BEFORE="${LIGHTOFFICE_DEPOT_TOOLS_BEFORE:-2026-09-07}"

write_v8_marker() {
  # Byte-exact, no newline — see above.
  printf '%s' 'v8_version_1' > "$V8_MARKER"
}

if [ -d "$DEPOT_TOOLS/.git" ]; then
  ok "depot_tools already staged ($(git -C "$DEPOT_TOOLS" rev-parse --short HEAD 2>/dev/null || echo '?'))"
  write_v8_marker
  ok "v8.data marker written — upstream will keep the staged checkout"
elif ! git ls-remote --exit-code "$DEPOT_TOOLS_URL" HEAD >/dev/null 2>&1; then
  warn "depot_tools is unreachable from here; upstream will clone HEAD during the build, which currently cannot bootstrap"
else
  mkdir -p "$V8_BASE"
  if git clone --quiet "$DEPOT_TOOLS_URL" "$DEPOT_TOOLS"; then
    pin="$(git -C "$DEPOT_TOOLS" rev-list -1 --before="$PIN_BEFORE" HEAD 2>/dev/null || true)"
    if [ -n "$pin" ]; then
      git -C "$DEPOT_TOOLS" checkout --quiet --detach "$pin"
      ok "depot_tools pinned to ${pin:0:12} (last revision before $PIN_BEFORE)"
    else
      warn "no depot_tools revision found before $PIN_BEFORE; staying on HEAD"
    fi

    # Provision depot_tools' Python now, while the network and a normal
    # environment are available. Doing it here is what lets the build disable
    # depot_tools' self-update without losing the bootstrap: a previous attempt
    # set DEPOT_TOOLS_UPDATE=0 alone and the build died on
    # "python3_bin_reldir.txt not found".
    if [ -x "$DEPOT_TOOLS/ensure_bootstrap" ]; then
      if ( cd "$DEPOT_TOOLS" && DEPOT_TOOLS_UPDATE=0 ./ensure_bootstrap >/dev/null 2>&1 ); then
        ok "depot_tools bootstrapped ($( [ -f "$DEPOT_TOOLS/python3_bin_reldir.txt" ] && echo 'python3 provisioned' || echo 'no python3_bin_reldir.txt' ))"
      else
        warn "ensure_bootstrap failed; the v8 fetch may not run"
      fi
    fi

    write_v8_marker
    ok "v8.data marker written — upstream will keep the staged checkout"
  else
    warn "depot_tools clone failed; upstream will try its own during the build"
  fi
fi

# deps.py runs a long apt-get list; skip it when the packages are already there.
touch "$BUILD_TOOLS/tools/linux/packages_complete"

echo
echo "Prebuilts ready. Next: scripts/build_desktop.sh --check-only"
