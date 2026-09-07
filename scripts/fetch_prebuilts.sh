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

SRC="${1:-${LIGHTOFFICE_SRC:-/home/user/onlyoffice-src}}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"
DATA_REPO="https://github.com/ONLYOFFICE-data/build_tools_data"
WORK="${LIGHTOFFICE_PREBUILT_CACHE:-/tmp/lightoffice-prebuilts}"

# CEF branch for a modern gcc on linux_64. build_tools picks 5304 when
# config.is_cef_107() is true (gcc < 5.0.4) and 5414 otherwise.
CEF_BRANCH="${CEF_BRANCH:-5414}"
CEF_PLATFORM="${CEF_PLATFORM:-linux_64}"

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

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

# deps.py runs a long apt-get list; skip it when the packages are already there.
touch "$BUILD_TOOLS/tools/linux/packages_complete"

echo
echo "Prebuilts ready. Next: scripts/build_desktop.sh --check-only"
