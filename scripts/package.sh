#!/usr/bin/env bash
#
# Produce LightOffice installers and a checksum manifest.
#
# Cross-platform packaging is host-bound and there is no way around it:
#   .deb  needs Linux + dpkg-deb
#   .exe  needs Windows + the Inno Setup / MSVC toolchain (make_installer.bat)
#   .dmg  needs macOS + Xcode and codesign (package_mac.py)
# Running this on Linux therefore produces the .deb and reports the other two as
# not-buildable-here rather than emitting a stub that would fail AC 5.1's size
# check anyway. Drive the three from a CI matrix, one runner per OS, and collect
# the artifacts into artifacts/ before running scripts/verify_ac.sh.
#
# Usage: scripts/package.sh [--version X.Y.Z] [--compress-type gzip|xz|zstd] [--compress-level N]
#
# The default package pipeline used xz compression, which is slower but smaller.
# For CI the fast path is gzip with a low compression level, trading a little
# size for much shorter builder time. Keep the defaults conservative on local
# builds but allow the workflow to opt into faster compression explicitly.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}"
ART="$ROOT/artifacts"
VERSION="1.0.0"
COMPRESS_TYPE="${LIGHTOFFICE_DEB_COMPRESS_TYPE:-gzip}"
COMPRESS_LEVEL="${LIGHTOFFICE_DEB_COMPRESS_LEVEL:-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --compress-type)
      COMPRESS_TYPE="$2"
      shift 2
      ;;
    --compress-level)
      COMPRESS_LEVEL="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$ART"
OS="$(uname -s)"
echo "packaging LightOffice $VERSION on $OS"

# Upstream deploys to build_tools/scripts/../out, i.e. $SRC/build_tools/out —
# NOT $SRC/../out, which is what this used to assume. The log line is
#   .../src/build_tools/scripts/../out/linux_64/onlyoffice/desktopeditors/...
# That mistake was invisible for as long as no build reached packaging: the
# script simply reported "skip .deb — no build output" and exited 0, so a
# successful build would still have produced no installer. Candidates are
# ordered most- to least-likely, with a search as the last resort.
find_bin_dir() {
  local c
  for c in \
    "$SRC/build_tools/out/linux_64/onlyoffice/desktopeditors" \
    "$SRC/out/linux_64/onlyoffice/desktopeditors" \
    "$SRC/../out/linux_64/onlyoffice/desktopeditors"; do
    [ -x "$c/DesktopEditors" ] && { echo "$c"; return; }
  done
  local hit
  hit="$(find "$SRC" -maxdepth 6 -type f -name DesktopEditors -perm -u+x 2>/dev/null | head -1)"
  [ -n "$hit" ] && dirname "$hit"
}
BIN_DIR="$(find_bin_dir)"
[ -n "$BIN_DIR" ] || BIN_DIR="$SRC/build_tools/out/linux_64/onlyoffice/desktopeditors"
BIN="$BIN_DIR/DesktopEditors"

built=0

# ------------------------------------------------------------------ linux ---
if [ "$OS" = "Linux" ]; then
  if [ ! -x "$BIN" ]; then
    echo "  skip .deb — no build output at $BIN (run scripts/build_desktop.sh first)"
  elif ! command -v dpkg-deb >/dev/null; then
    echo "  skip .deb — dpkg-deb not installed"
  else
    STAGE="$(mktemp -d)"
    install -d "$STAGE/DEBIAN" "$STAGE/opt/lightoffice" "$STAGE/usr/bin" \
               "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/256x256/apps"
    cp -a "$BIN_DIR/." "$STAGE/opt/lightoffice/"
    ln -sf /opt/lightoffice/DesktopEditors "$STAGE/usr/bin/WPS-Lite"
    install -m 0644 "$ROOT/overlay/branding/lightoffice_256.png" \
        "$STAGE/usr/share/icons/hicolor/256x256/apps/lightoffice.png"

    cat > "$STAGE/usr/share/applications/lightoffice.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LightOffice
Comment=轻量版办公套件
Exec=/usr/bin/WPS-Lite %F
Icon=lightoffice
Categories=Office;
MimeType=application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;application/vnd.openxmlformats-officedocument.presentationml.presentation;
EOF

    SIZE_KB="$(du -sk "$STAGE" | cut -f1)"
    cat > "$STAGE/DEBIAN/control" <<EOF
Package: wps-lite
Version: $VERSION
Section: office
Priority: optional
Architecture: amd64
Installed-Size: $SIZE_KB
Maintainer: LightOffice Technologies Co., Ltd. <it@lightoffice.internal>
Depends: libc6, libstdc++6, libx11-6, libxcb1, libgtk-3-0
Description: LightOffice Desktop Editors
 Lightweight on-premises office suite based on ONLYOFFICE Desktop Editors,
 configured for intranet collaboration.
EOF
    case "$COMPRESS_TYPE" in
      gzip|xz|zstd) ;;
      *) echo "unsupported compression type: $COMPRESS_TYPE (expected gzip, xz, or zstd)" >&2; exit 2 ;;
    esac
    case "$COMPRESS_LEVEL" in
      ''|*[!0-9]*) echo "invalid compression level: $COMPRESS_LEVEL" >&2; exit 2 ;;
    esac
    dpkg-deb --build --root-owner-group -Z"$COMPRESS_TYPE" -z"$COMPRESS_LEVEL" "$STAGE" "$ART/WPS-Lite-linux-amd64.deb"
    rm -rf "$STAGE"
    echo "  built $ART/WPS-Lite-linux-amd64.deb"
    built=$((built + 1))
  fi
else
  echo "  skip .deb — needs Linux (host is $OS)"
fi

# ---------------------------------------------------------------- windows ---
case "$OS" in
  MINGW*|MSYS*|CYGWIN*)
    ( cd "$SRC/desktop-apps/win-linux/package/windows" && cmd //c make_installer.bat )
    built=$((built + 1))
    ;;
  *)
    echo "  skip .exe — needs a Windows host (make_installer.bat, MSVC + Inno Setup)"
    ;;
esac

# ------------------------------------------------------------------ macos ---
if [ "$OS" = "Darwin" ]; then
  python3 "$SRC/desktop-apps/macos/package_mac.py" --version "$VERSION"
  built=$((built + 1))
else
  echo "  skip .dmg — needs a macOS host (package_mac.py, Xcode + codesign)"
fi

# -------------------------------------------------------------- checksums ---
cd "$ART"
shopt -s nullglob
pkgs=(WPS-Lite-*.deb WPS-Lite-*.exe WPS-Lite-*.msi WPS-Lite-*.dmg)
if [ ${#pkgs[@]} -gt 0 ]; then
  sha256sum "${pkgs[@]}" > checksums.txt
  echo
  echo "artifacts:"
  ls -lh "${pkgs[@]}" | awk '{printf "  %-42s %s\n", $9, $5}'
  echo "checksums -> artifacts/checksums.txt"
else
  echo
  echo "no installers produced on this host."
fi

echo
echo "packages built here: $built of 3 (win / mac / linux)"
