#!/usr/bin/env bash
#
# Clone the ONLYOFFICE sources LightOffice builds on.
#
# DesktopEditors is an umbrella repo: the six components are submodules. The
# build driver (build_tools) is NOT a submodule and must be cloned separately —
# that trips people up, so we fetch both here.
#
# Usage: scripts/bootstrap.sh [target-dir]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-/home/user/onlyoffice-src}}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-/home/user/build_tools}"

UPSTREAM=https://github.com/ONLYOFFICE/DesktopEditors.git
TOOLS=https://github.com/ONLYOFFICE/build_tools.git

retry() {
  local n=0 max=4 delay=2
  until "$@"; do
    n=$((n + 1))
    [ $n -ge $max ] && { echo "failed after $max attempts: $*" >&2; return 1; }
    echo "  retry $n/$max in ${delay}s ..." >&2
    sleep $delay
    delay=$((delay * 2))
  done
}

if [ -d "$SRC/.git" ]; then
  echo "· upstream already present at $SRC"
else
  echo "cloning DesktopEditors -> $SRC"
  mkdir -p "$SRC"
  # Shallow, with shallow submodules: the full history of core/web-apps is
  # several GB and nothing in this project needs it.
  retry git clone --recursive --depth 1 --shallow-submodules "$UPSTREAM" "$SRC"
fi

if [ -d "$BUILD_TOOLS/.git" ]; then
  echo "· build_tools already present at $BUILD_TOOLS"
else
  echo "cloning build_tools -> $BUILD_TOOLS"
  retry git clone --depth 1 "$TOOLS" "$BUILD_TOOLS"
fi

echo
echo "submodule status:"
git -C "$SRC" submodule status | sed 's/^/  /'

# Record the pristine state so later verification can tell overlay edits apart
# from a broken checkout.
mkdir -p "$ROOT/baseline"
git -C "$SRC" submodule status > "$ROOT/baseline/submodule_status.txt"

echo
echo "qmake project files : $(find "$SRC" -name '*.pro' | wc -l)"
echo "CMakeLists.txt      : $(find "$SRC" -name 'CMakeLists.txt' | wc -l)"
echo "core C/C++ sources  : $(find "$SRC/core" \( -name '*.cpp' -o -name '*.h' \) | wc -l)"
echo
echo "bootstrap complete. Next: scripts/apply_overlay.sh"
