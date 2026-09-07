#!/usr/bin/env bash
#
# Record the exact upstream revision this build is pinned to.
#
# The tag alone is not enough to reproduce a checkout: DesktopEditors is an
# umbrella whose six submodules each carry their own SHA, and those are what
# actually determine the source. VERSION_LOCK captures both, so a rebuild can
# be verified rather than assumed.
#
# --check compares the checkout against the recorded lock instead of rewriting
# it. Drift matters: once the tree is not the tree the measurements were taken
# against, every "reduced by N%" and every baseline comparison is meaningless.
# Regenerating silently would hide exactly that, so the check is separate from
# the write.
#
# Usage: scripts/gen_version_lock.sh [--check] [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
SRC="${ARGS[0]:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
OUT="$ROOT/VERSION_LOCK"
[ "$CHECK" -eq 1 ] && OUT="$(mktemp)"

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

if [ "$CHECK" -eq 1 ]; then
  LOCK="$ROOT/VERSION_LOCK"
  if [ ! -f "$LOCK" ]; then
    echo "no VERSION_LOCK to check against; run scripts/gen_version_lock.sh" >&2
    rm -f "$OUT"; exit 1
  fi
  # Compare only the assignments: the comment header is prose and may be
  # reworded without the pin having moved.
  if diff -u <(grep -vE '^#|^$' "$LOCK") <(grep -vE '^#|^$' "$OUT"); then
    echo "VERSION_LOCK matches the checkout at $SRC"
    rm -f "$OUT"; exit 0
  fi
  echo "VERSION_LOCK does not match the checkout at $SRC (diff above: - recorded, + actual)" >&2
  rm -f "$OUT"; exit 1
fi

echo "wrote $OUT"
grep -vE '^#|^$' "$OUT"
