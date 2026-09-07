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
# Usage: scripts/package.sh [--version X.Y.Z]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-/home/user/onlyoffice-src}"
ART="$ROOT/artifacts"
VERSION="$(sed -n 's/.*--version \(.*\)/\1/p' <<<"${*:-}")"
[ -n "$VERSION" ] || VERSION="1.0.0"

mkdir -p "$ART"
OS="$(uname -s)"
echo "packaging LightOffice $VERSION on $OS"

BIN_DIR="$SRC/../out/linux_64/onlyoffice/desktopeditors"
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
    dpkg-deb --build --root-owner-group "$STAGE" "$ART/WPS-Lite-linux-amd64.deb"
    rm -rf "$STAGE"
    echo "  built $ART/WPS-Lite-linux-amd64.deb"
    built=$((built + 1))
  fi
else
  echo "  skip .deb — needs Linux (host is $OS)"
fi

# ---------------------------------------------------------------- windows ---
if [ "$OS" = "MINGW"* ] || [ "$OS" = "MSYS"* ] || [ "$OS" = "CYGWIN"* ]; then
  ( cd "$SRC/desktop-apps/win-linux/package/windows" && cmd //c make_installer.bat )
  built=$((built + 1))
else
  echo "  skip .exe — needs a Windows host (make_installer.bat, MSVC + Inno Setup)"
fi

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
