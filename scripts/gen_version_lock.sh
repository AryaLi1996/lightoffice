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
  # Read these from the commit (git ls-tree), NOT from `git submodule status`.
  #
  # submodule status reports the WORKING TREE's SHA, and bootstrap.sh
  # deliberately advances sdkjs off the tag to SUBMODULE_SDKJS_OVERRIDE (see
  # the long comment in VERSION_LOCK for why). So status reported d8e4124 for
  # sdkjs while the lock recorded the tag's b2f0aa1d, and `--check` diffed a
  # regenerated file against the lock and found that difference every single
  # time. AC V.6 could not pass no matter how clean the checkout was — the
  # failure was in the comparison, not the tree.
  #
  # ls-tree gives the SHA the tag records, which is what the header line above
  # claims this block contains. The deliberate deviation stays recorded once,
  # in SUBMODULE_SDKJS_OVERRIDE, and is verified separately below.
  git -C "$SRC" ls-tree HEAD \
    | awk '$2 == "commit" { n = $4; gsub(/-/, "_", n); print "SUBMODULE_" toupper(n) "=" $3 }' \
    | sort

  # These two are POLICY rather than state read from the checkout, but they
  # decide what actually gets built, so they belong in the lock.
  #
  # They are read from bootstrap.sh, NOT carried forward from VERSION_LOCK. An
  # earlier version did carry them forward, which made them self-fulfilling:
  # --check compared the file against itself and could never fail. Reading the
  # defaults out of bootstrap.sh means editing one without the other is caught,
  # which is the whole point of a lock file.
  policy() {
    local var="$1" out
    out="$(sed -n "s/^${var}=\"\${[A-Z_]*:-\(.*\)}\"$/\1/p" "$ROOT/scripts/bootstrap.sh" | head -1)"
    [ -n "$out" ] || out="UNREADABLE-FROM-bootstrap.sh"
    echo "$out"
  }
  echo
  echo "SUBMODULE_SDKJS_OVERRIDE=$(policy SDKJS_REF)"
  echo "BUILD_TOOLS_REF=$(policy TOOLS_REF)"
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
    # The block above now compares the SHAs the TAG records, so on its own it
    # would no longer notice whether the deliberate sdkjs deviation was
    # actually applied to the tree. Check that separately, so dropping the
    # override — or silently ending up on some third revision — is still caught.
    want="$(sed -n 's/^SUBMODULE_SDKJS_OVERRIDE=//p' "$LOCK" | head -1)"
    if [ -n "$want" ] && [ "$want" != "UNREADABLE-FROM-bootstrap.sh" ]; then
      have="$(git -C "$SRC/sdkjs" rev-parse HEAD 2>/dev/null || echo MISSING)"
      if [ "$have" != "$want" ]; then
        echo "sdkjs is checked out at $have but the lock requires the override $want" >&2
        echo "run scripts/bootstrap.sh, or clear LIGHTOFFICE_SDKJS_REF deliberately" >&2
        rm -f "$OUT"; exit 1
      fi
    fi
    echo "VERSION_LOCK matches the checkout at $SRC"
    rm -f "$OUT"; exit 0
  fi
  echo "VERSION_LOCK does not match the checkout at $SRC (diff above: - recorded, + actual)" >&2
  rm -f "$OUT"; exit 1
fi

echo "wrote $OUT"
grep -vE '^#|^$' "$OUT"
