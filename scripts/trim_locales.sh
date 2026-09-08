#!/usr/bin/env bash
#
# Keep only the interface languages LightOffice ships.
#
# web-apps carries 45 languages across 14 locale directories. An intranet
# deployment for a Chinese/English organisation needs two of them, and the rest
# are dead weight in every installer.
#
# zh-tw is kept by default alongside zh: Traditional Chinese is a different
# translation, not a variant spelling, and dropping it silently would remove
# working Chinese support for Taiwan/Hong Kong users. Pass --strict to keep
# exactly en and zh, which is what the acceptance criterion asks for literally.
#
# Usage: scripts/trim_locales.sh [--strict] [--dry-run] [/path/to/onlyoffice-src]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0
DRY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    --dry-run) DRY=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
SRC="${ARGS[0]:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
WEB="$SRC/web-apps/apps"
# shellcheck source=scripts/lib/portable.sh
. "$ROOT/scripts/lib/portable.sh"


[ -d "$WEB" ] || { echo "no web-apps at $WEB" >&2; exit 1; }

if [ "$STRICT" -eq 1 ]; then
  KEEP=(en zh)
else
  KEEP=(en zh zh-tw)
fi

keep_re="^($(IFS='|'; echo "${KEEP[*]}"))\.json$"

before=$(find "$WEB" -type d -name locale | dirs_bytes_stdin)
removed=0
kept=0

while IFS= read -r d; do
  while IFS= read -r f; do
    base="$(basename "$f")"
    if [[ "$base" =~ $keep_re ]]; then
      kept=$((kept + 1))
    else
      [ "$DRY" -eq 0 ] && rm -f "$f"
      removed=$((removed + 1))
    fi
  done < <(find "$d" -maxdepth 1 -name '*.json')
done < <(find "$WEB" -type d -name locale | sort)

after=$(find "$WEB" -type d -name locale | dirs_bytes_stdin)

echo "kept languages : ${KEEP[*]}"
echo "files kept     : $kept"
echo "files removed  : $removed$([ "$DRY" -eq 1 ] && echo ' (dry run — nothing deleted)')"
echo "locale bytes   : $before -> $after"
awk -v b="$before" -v a="$after" 'BEGIN{
  if (b > 0) printf "reduction      : %.1f%%\n", (b-a)*100/b
}'

if [ "$DRY" -eq 0 ]; then
  remaining=$(find "$WEB" -type d -name locale -exec sh -c \
                'for f in "$1"/*.json; do [ -e "$f" ] && basename "$f" .json; done' _ {} \; \
              | sort -u | tr '\n' ' ')
  echo "remaining      : $remaining"
fi
