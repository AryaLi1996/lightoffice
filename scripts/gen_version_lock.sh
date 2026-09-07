#!/usr/bin/env bash
#
# Record the exact upstream revision this build is pinned to.
#
# The tag alone is not enough to reproduce a checkout: DesktopEditors is an
# umbrella whose six submodules each carry their own SHA, and those are what
# actually determine the source. VERSION_LOCK captures both, so a rebuild can
# be verified rather than assumed.
#
# Usage: scripts/gen_version_lock.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
OUT="$ROOT/VERSION_LOCK"

[ -d "$SRC/.git" ] || { echo "no upstream checkout at $SRC" >&2; exit 1; }

tag="$(git -C "$SRC" describe --tags 2>/dev/null || echo "UNTAGGED")"
sha="$(git -C "$SRC" rev-parse HEAD)"

{
  echo "# LightOffice upstream version lock"
  echo "# Regenerate with scripts/gen_version_lock.sh"
  echo "# Verify with scripts/verify_ac.sh (AC 1.1)"
  echo
  echo "UPSTREAM_REPO=https://github.com/ONLYOFFICE/DesktopEditors.git"
  echo "UPSTREAM_TAG=$tag"
  echo "UPSTREAM_SHA=$sha"
  echo
  echo "# submodule SHAs recorded by that tag"
  git -C "$SRC" submodule status | awk '{gsub(/^[ +-]/,"",$1); print "SUBMODULE_" toupper($2) "=" $1}' \
    | tr '-' '_' | sed 's/SUBMODULE_\(.*\)=/SUBMODULE_\1=/'
} > "$OUT"

echo "wrote $OUT"
cat "$OUT" | grep -vE '^#|^$'
