#!/usr/bin/env bash
#
# Toolbar button inventory and the reduction the overlay achieves (AC 2.2).
#
# WHAT IS COUNTED, AND WHY IT IS COUNTED THIS WAY
# -----------------------------------------------
# There is no single file holding "the toolbar". Buttons come from the editor's
# own Toolbar.js and ViewTab.js, and from two shared views — ReviewChanges.js
# (the collaboration tab) and Plugins.js (the plugin tab) — which contribute the
# same buttons to every editor. The count is therefore per editor, over
# `new Common.UI.Button` instantiations in the views that build the ribbon.
#
# The overlay removes the collaboration tab and disables plugin loading, so the
# buttons those two views contribute are the removed set. Counting them in the
# source is the only measurement available here: the running Document Server
# serves the stock upstream image, not this overlaid tree, so a browser count
# would measure the wrong build.
#
# This counts declarations, not pixels. A declared button can still be hidden at
# runtime by a licence gate, so the absolute totals are an upper bound. The
# RATIO is what the criterion asks about, and both sides of it are measured the
# same way, so the bias cancels.
#
# Usage: scripts/count_toolbar.sh [--min 20] [--json PATH] [/path/to/onlyoffice-src]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN=20
OUT="$ROOT/baseline/toolbar_buttons.json"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --min) MIN="$2"; shift 2 ;;
    --json) OUT="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
SRC="${ARGS[0]:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
WEB="$SRC/web-apps/apps"

[ -d "$WEB" ] || { echo "no web-apps at $WEB" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

BTN='new Common\.UI\.Button'
count() { [ -f "$1" ] && grep -c "$BTN" "$1" || echo 0; }

REVIEW="$WEB/common/main/lib/view/ReviewChanges.js"
PLUGINS="$WEB/common/main/lib/view/Plugins.js"
review_n=$(count "$REVIEW")
plugins_n=$(count "$PLUGINS")

printf '%-22s %8s %8s %8s %10s\n' "editor" "total" "removed" "kept" "reduction"
printf '%.0s-' {1..60}; printf '\n'

rows=()
below=0
for ed in documenteditor spreadsheeteditor presentationeditor pdfeditor; do
  [ -d "$WEB/$ed" ] || continue
  own=$(( $(count "$WEB/$ed/main/app/view/Toolbar.js") + $(count "$WEB/$ed/main/app/view/ViewTab.js") ))
  total=$(( own + review_n + plugins_n ))
  removed=$(( review_n + plugins_n ))
  kept=$(( total - removed ))
  [ "$total" -gt 0 ] || continue
  pct=$(awk -v r="$removed" -v t="$total" 'BEGIN{printf "%.1f", r*100/t}')
  mark=""
  awk -v p="$pct" -v m="$MIN" 'BEGIN{exit !(p < m)}' && { mark=" <"; below=$((below+1)); }
  printf '%-22s %8d %8d %8d %9s%%%s\n' "$ed" "$total" "$removed" "$kept" "$pct" "$mark"
  rows+=("$(printf '{"editor":"%s","total":%d,"removed":%d,"kept":%d,"reduction_pct":%s,"meets_threshold":%s}' \
    "$ed" "$total" "$removed" "$kept" "$pct" \
    "$(awk -v p="$pct" -v m="$MIN" 'BEGIN{print (p<m)?"false":"true"}')")")
done

{
  printf '{\n  "schema": "lightoffice/toolbar@1",\n'
  printf '  "measured": "%s",\n  "threshold_pct": %s,\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MIN"
  printf '  "removed_groups": {"collaboration_tab": %d, "plugins_tab": %d},\n' "$review_n" "$plugins_n"
  printf '  "method": "new Common.UI.Button declarations in the views that build the ribbon; declarations are an upper bound on visible buttons, but both sides of the ratio are counted identically",\n'
  printf '  "editors": [\n'
  for i in "${!rows[@]}"; do
    printf '    %s' "${rows[$i]}"
    [ "$i" -lt $((${#rows[@]} - 1)) ] && printf ','
    printf '\n'
  done
  printf '  ]\n}\n'
} > "$OUT"

echo
echo "removed groups: collaboration tab ($review_n buttons) + plugins tab ($plugins_n buttons)"
echo "report: $OUT"
if [ "$below" -gt 0 ]; then
  echo
  echo "FAIL — $below editor(s) below the ${MIN}% threshold (marked <)."
  echo "Closing the remaining gap means removing functional buttons rather than"
  echo "collaboration ones, which is a product decision, not a counting one."
  exit 1
fi
echo "PASS — every editor meets the ${MIN}% threshold"
