#!/usr/bin/env bash
#
# Syntax-check desktop-apps against the system Qt, without building anything.
#
# Why this exists
# ---------------
# A full desktop build takes about an hour, and roughly 55 minutes of that is
# rebuilding pinned dependencies that never change (boost, cef, icu, openssl,
# then v8's 2929 targets, then core/). Only the last ~3 minutes compiles the
# code we actually iterate on. So every trivial mistake in desktop-apps — a
# missing include, a macro collision — costs a full hour to discover, and you
# only learn about the FIRST one, because make stops there.
#
# This script compiles the same sources with `g++ -fsyntax-only` in well under
# a minute, and reports ALL of them at once. On the run that prompted it, CI
# spent 61 minutes to report two errors; this reported all three in 40 seconds.
#
# What it does NOT do: link, run moc, or build anything. It catches the
# "source does not compile against this Qt" class, which is every desktop-apps
# failure this project has hit.
#
# Usage: scripts/check_qt_compat.sh [/path/to/onlyoffice-src]
# Exit:  0 clean, 1 errors found, 2 cannot run (missing tree or Qt)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
WL="$SRC/desktop-apps/win-linux"

skipping() { printf '\033[33mSKIP\033[0m: %s\n' "$*"; exit 2; }

[ -d "$WL/src" ]              || skipping "no desktop-apps checkout at $SRC (run scripts/bootstrap.sh first)"
[ -d "$SRC/core/Common" ]     || skipping "no core/ checkout at $SRC"
[ -d "$SRC/desktop-sdk" ]     || skipping "no desktop-sdk checkout at $SRC"
command -v g++ >/dev/null     || skipping "g++ not installed"
command -v pkg-config >/dev/null || skipping "pkg-config not installed"

QT_INC="$(pkg-config --variable=includedir Qt5Core 2>/dev/null || true)"
if [ -z "$QT_INC" ] || [ ! -d "$QT_INC" ]; then skipping "Qt5 development headers not found (install qtbase5-dev)"; fi

INC="-I$WL -I$WL/src -I$WL/src/prop -I$WL/extras/update-daemon/src/classes"
INC="$INC -I$SRC/desktop-sdk/ChromiumBasedEditors/lib/include"
INC="$INC -I$SRC/desktop-sdk/ChromiumBasedEditors/lib/qt_wrapper/include"
INC="$INC -I$SRC/core/DesktopEditor -I$SRC/core/Common"
for m in "" QtCore QtGui QtWidgets QtNetwork QtDBus QtSvg QtPrintSupport \
         QtMultimedia QtMultimediaWidgets QtX11Extras; do
  INC="$INC -I$QT_INC/$m"
done
INC="$INC $(pkg-config --cflags gtk+-3.0 2>/dev/null)"

# These MUST match what the real build passes. An earlier version of this check
# omitted -D__DONT_WRITE_IN_APP_TITLE and reported four confident errors in a
# block the real build never compiles. A check that invents failures is worse
# than no check, so the define list is copied from the qmake command line in
# the build log rather than guessed.
DEF='-DINTVER=9.4.0.0 -DCOPYRIGHT_YEAR=2026 -DLINUX -D_LINUX'
DEF="$DEF -DVER_PRODUCT_VERSION=9.4.0.0 -DDOCUMENTSCORE_OPENSSL_SUPPORT"
DEF="$DEF -D__DONT_WRITE_IN_APP_TITLE -DQT_NO_DEBUG"
for lib in PRINTSUPPORT SVG MULTIMEDIAWIDGETS WIDGETS MULTIMEDIA X11EXTRAS \
           GUI NETWORK DBUS CORE; do
  DEF="$DEF -DQT_${lib}_LIB"
done

# This harness deliberately does not run moc or generate resources, and does
# not reproduce every -I the .pro computes, so "No such file or directory" is
# a limitation of the check rather than a defect in the code. Semantic errors
# are real — all three failures this script was written for were semantic.
errors=0
checked=0
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Syntax-checking desktop-apps against Qt at $QT_INC"
while IFS= read -r f; do
  checked=$((checked + 1))
  # shellcheck disable=SC2086  # INC/DEF are intentionally word-split flag lists
  g++ -fsyntax-only -std=gnu++11 -fPIC -w $DEF $INC "$f" 2>&1 \
    | grep -E '\berror:' \
    | grep -vF 'No such file or directory' > "$tmp"
  if [ -s "$tmp" ]; then
    while IFS= read -r line; do
      printf '  \033[31m✗\033[0m %s\n' "${line#"$SRC/"}"
      errors=$((errors + 1))
    done < "$tmp"
  fi
done < <(find "$WL/src" -name '*.cpp' | grep -viE 'platform_win|_win\.cpp|/win/' | sort)

echo
if [ "$errors" -gt 0 ]; then
  printf '\033[31m%d compile error(s) across %d source files.\033[0m\n' "$errors" "$checked"
  printf 'Fix these before spending an hour in CI. scripts/patch_qt_compat.sh carries the known ones.\n'
  exit 1
fi
printf '\033[32m%d source files compile against this Qt.\033[0m\n' "$checked"
