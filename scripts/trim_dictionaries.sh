#!/usr/bin/env bash
#
# Keep only the locales LightOffice ships, and record the size delta.
#
# ONLYOFFICE bundles 48 hunspell dictionaries (~239 MB) — the single largest
# chunk of the install footprint. An intranet Chinese/English deployment needs a
# fraction of that.
#
# Note: upstream ships NO zh_CN dictionary. Chinese has no hunspell affix/dic in
# the ONLYOFFICE dictionaries repo (CJK spellchecking is not hunspell-based), so
# the keep-list below asks for it and simply finds nothing to keep. It is listed
# anyway so that if upstream ever adds one, it survives the trim automatically.
#
# Usage: scripts/trim_dictionaries.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-/home/user/onlyoffice-src}}"
DICT="$SRC/dictionaries"
BASELINE="$ROOT/baseline/dictionaries.baseline"

KEEP=(en_US zh_CN)

[ -d "$DICT" ] || { echo "no dictionaries dir at $DICT" >&2; exit 1; }

# Record the pristine size once, so repeated runs still compare against the
# real starting point rather than an already-trimmed tree.
if [ ! -f "$BASELINE" ]; then
  mkdir -p "$(dirname "$BASELINE")"
  du -sb "$DICT" | cut -f1 > "$BASELINE"
  echo "recorded baseline: $(cat "$BASELINE") bytes"
fi
BEFORE=$(cat "$BASELINE")

keep_re=""
for k in "${KEEP[@]}"; do keep_re="${keep_re}|${k}"; done
keep_re="^(${keep_re#|})$"

removed=0
missing=()
for k in "${KEEP[@]}"; do
  [ -d "$DICT/$k" ] || missing+=("$k")
done

while IFS= read -r d; do
  name="$(basename "$d")"
  if [[ ! "$name" =~ $keep_re ]]; then
    rm -rf "$d"
    removed=$((removed + 1))
  fi
done < <(find "$DICT" -mindepth 1 -maxdepth 1 -type d)

AFTER=$(du -sb "$DICT" | cut -f1)
PCT=$(awk -v a="$AFTER" -v b="$BEFORE" 'BEGIN{ if(b==0){print "n/a"} else {printf "%.1f", a*100.0/b} }')

echo "kept        : ${KEEP[*]}"
[ ${#missing[@]} -gt 0 ] && echo "not upstream: ${missing[*]} (nothing to keep)"
echo "removed     : $removed locale directories"
echo "before      : $BEFORE bytes ($(numfmt --to=iec "$BEFORE" 2>/dev/null || echo "$BEFORE"))"
echo "after       : $AFTER bytes ($(numfmt --to=iec "$AFTER" 2>/dev/null || echo "$AFTER"))"
echo "remaining   : ${PCT}% of baseline (AC 4.1 requires < 50%)"
