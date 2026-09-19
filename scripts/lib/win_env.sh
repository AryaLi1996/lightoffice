# shellcheck shell=bash
#
# The values build_windows.sh and package_windows.sh must agree on.
#
# They are in one file because they have to match exactly. make.ps1 resolves its
# source as out/<prefix>/<CompanyName>/<ProductName> and make_inno.ps1 names its
# output <Company>-<Product>-<Version>-<Arch>.exe, so a compile job and a
# packaging job that disagree by one character produce a tree the packager
# cannot find or an installer nobody looks for. Sourced, not duplicated.
#
# shellcheck disable=SC2034  # this file's entire job is to set variables for
# whoever sources it, so every one of them is "unused" when it is checked alone.
#
# Expects ARCH to be set by the caller. Sets PLATFORM, OUT_DIR, COMPANY,
# PRODUCT, VERSION, PKG, and defines find_inno.

case "${ARCH:?ARCH must be set before sourcing win_env.sh}" in
  x64) PLATFORM="win_64"; OUT_DIR="win_64" ;;
  x86) PLATFORM="win_32"; OUT_DIR="win_32" ;;
  *) echo "unknown --arch $ARCH (expected x64 or x86)" >&2; exit 2 ;;
esac

COMPANY="${LIGHTOFFICE_WIN_COMPANY:-ONLYOFFICE}"
PRODUCT="${LIGHTOFFICE_WIN_PRODUCT:-DesktopEditors}"
VERSION="${LIGHTOFFICE_VERSION:-1.0.0.0}"
PKG="$SRC/desktop-apps/package"

# The directory make.ps1 fills and make_inno.ps1 reads. This is what the compile
# job hands to the packaging job.
STAGED="$PKG/build/$ARCH"

# make_inno.ps1 reads $env:INNOPATH first and only then a registry key, so the
# caller sets INNOPATH rather than hoping the key is where upstream expects.
find_inno() {
  local c
  if [ -n "${INNOPATH:-}" ] && [ -x "$INNOPATH/ISCC.exe" ]; then
    printf '%s\n' "$INNOPATH"; return 0
  fi
  for c in "/c/Program Files (x86)/Inno Setup 6" "/c/Program Files/Inno Setup 6"; do
    [ -x "$c/ISCC.exe" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
