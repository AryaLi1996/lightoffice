#!/usr/bin/env bash
#
# Chinese localisation coverage check.
#
# web-apps has no single locale file: each editor and each form factor
# (main / mobile / embed / forms) carries its own, 14 directories in all. A
# check that looked at only one would miss a gap in the others, so this
# compares zh against en in every directory and reports the worst.
#
# Coverage is measured over leaf keys, not top-level ones: a translation file
# can have every section present and still be missing most of the strings
# inside them.
#
# Usage: scripts/check_i18n.sh [--min 95] [/path/to/onlyoffice-src]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN=95
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --min) MIN="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
SRC="${ARGS[0]:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
WEB="$SRC/web-apps/apps"

[ -d "$WEB" ] || { echo "no web-apps at $WEB" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required (scripts/install_deps.sh)" >&2; exit 1; }

OUT="$ROOT/baseline/i18n_coverage.json"
mkdir -p "$(dirname "$OUT")"

printf '%-48s %9s %9s %8s\n' "locale directory" "zh" "en" "coverage"
printf '%.0s-' {1..78}; printf '\n'

worst=100
rows=()
fail=0

while IFS= read -r d; do
  [ -f "$d/en.json" ] && [ -f "$d/zh.json" ] || continue

  # Leaf keys only. `paths(scalars)` walks to the actual strings, so a section
  # that exists but is empty does not count as translated.
  en_keys=$(jq -r '[paths(scalars)|join(".")]|sort|.[]' "$d/en.json" 2>/dev/null)
  zh_keys=$(jq -r '[paths(scalars)|join(".")]|sort|.[]' "$d/zh.json" 2>/dev/null)
  en_n=$(printf '%s\n' "$en_keys" | grep -c . || true)
  [ "${en_n:-0}" -eq 0 ] && continue

  # Present in en but absent from zh.
  missing=$(comm -23 <(printf '%s\n' "$en_keys") <(printf '%s\n' "$zh_keys") | grep -c . || true)
  have=$(( en_n - missing ))
  pct=$(awk -v a="$have" -v b="$en_n" 'BEGIN{printf "%.1f", a*100/b}')

  rel="${d#"$SRC"/}"
  printf '%-48s %9d %9d %7s%%\n' "$rel" "$have" "$en_n" "$pct"
  rows+=("$(printf '{"dir":"%s","translated":%d,"total":%d,"coverage":%s}' "$rel" "$have" "$en_n" "$pct")")

  awk -v p="$pct" -v m="$MIN" 'BEGIN{exit !(p < m)}' && fail=$((fail+1))
  awk -v p="$pct" -v w="$worst" 'BEGIN{exit !(p < w)}' && worst="$pct"
done < <(find "$WEB" -type d -name locale | sort)

{
  printf '{\n  "minimum_required": %s,\n  "worst_coverage": %s,\n  "directories": [\n' "$MIN" "$worst"
  for i in "${!rows[@]}"; do
    printf '    %s' "${rows[$i]}"
    [ "$i" -lt $((${#rows[@]} - 1)) ] && printf ','
    printf '\n'
  done
  printf '  ]\n}\n'
} > "$OUT"

echo
echo "worst coverage: ${worst}%  (threshold ${MIN}%)"
echo "report: $OUT"

if [ "$fail" -gt 0 ]; then
  echo "FAIL — $fail directory/directories below ${MIN}%"
  exit 1
fi
echo "PASS — every locale directory meets the threshold"
