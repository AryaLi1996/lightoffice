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
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
BUILD_TOOLS="${LIGHTOFFICE_BUILD_TOOLS:-$SRC/build_tools}"

UPSTREAM=https://github.com/ONLYOFFICE/DesktopEditors.git
TOOLS=https://github.com/ONLYOFFICE/build_tools.git
# build_tools is not a submodule, so nothing pins it — cloning master means the
# build driver drifts independently of everything else, which is the same trap
# unpinned depot_tools was. Track the branch matching the locked upstream tag.
TOOLS_REF="${LIGHTOFFICE_BUILD_TOOLS_REF:-release/v9.4.0}"

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
  echo "cloning build_tools ($TOOLS_REF) -> $BUILD_TOOLS"
  retry git clone --depth 1 --branch "$TOOLS_REF" "$TOOLS" "$BUILD_TOOLS"
fi

# ---------------------------------------------------------------------------
# sdkjs override
# ---------------------------------------------------------------------------
# DesktopEditors v9.4.0 records sdkjs at b2f0aa1d (2026-03-23). build_tools —
# on master AND on release/v9.4.0 — builds sdkjs by running
# `python build.py` in sdkjs/build (scripts/build_js.py, _run_build_py). That
# file does not exist at b2f0aa1d; it was added to sdkjs's release/v9.4.0
# branch later and reached sdkjs master only via a merge from it. So the tag's
# own submodule pointer is older than the build driver for that same release
# requires, and a build from the tag as-recorded dies with:
#
#   python: can't open file '<src>/sdkjs/build/build.py': No such file
#
# This advances sdkjs to the head of its own release/v9.4.0 branch — still
# inside the v9.4.0 line, and the combination build_tools v9.4.0 expects.
# It is a DELIBERATE, documented deviation from the tag's recorded SHA, which
# is why it is a named variable and recorded in VERSION_LOCK rather than
# quietly patched in. Set LIGHTOFFICE_SDKJS_REF= (empty) to disable it and get
# exactly what the tag records.
SDKJS_REF="${LIGHTOFFICE_SDKJS_REF:-d8e412430b8cb856edd46e15b18ad44814e307fb}"
# -e, not -d: in a recursive clone a submodule's .git is a FILE pointing into
# the superproject's .git/modules, so -d would miss it entirely.
if [ -e "$SRC/sdkjs/.git" ]; then
  current="$(git -C "$SRC/sdkjs" rev-parse HEAD 2>/dev/null || echo '')"
  if [ -n "$SDKJS_REF" ] && [ "$current" != "$SDKJS_REF" ]; then
    echo "advancing sdkjs to $SDKJS_REF (see comment in $0)"
    if retry git -C "$SRC/sdkjs" fetch --depth 1 origin "$SDKJS_REF" \
       && git -C "$SRC/sdkjs" checkout --quiet --detach "$SDKJS_REF"; then
      echo "· sdkjs at $(git -C "$SRC/sdkjs" rev-parse --short HEAD)"
    else
      echo "  WARNING: could not advance sdkjs; the build will fail in sdkjs" >&2
    fi
  fi
  if [ ! -f "$SRC/sdkjs/build/build.py" ]; then
    echo "  WARNING: sdkjs/build/build.py is absent — build_tools needs it" >&2
  fi
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
