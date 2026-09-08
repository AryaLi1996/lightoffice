#!/usr/bin/env bash
#
# Record the pre-optimisation baseline that later "reduced by N%" criteria
# compare against.
#
# Two rules govern this script:
#
#   1. It records the PRISTINE tree. Once baseline_metrics.json exists it is not
#      silently overwritten, because a baseline captured after trimming would
#      make every reduction target trivially satisfiable. Use --force when you
#      genuinely want to re-baseline.
#   2. It never invents a number. Binary size, cold-start time and peak memory
#      require a built application; where that is unavailable the key is null
#      and a sibling *_unavailable field says why. A fabricated baseline is
#      worse than a missing one — it silently rebases every later comparison.
#
# Usage: scripts/record_baseline.sh [--force] [/path/to/onlyoffice-src]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
SRC="${ARGS[0]:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
OUT="$ROOT/baseline_metrics.json"
# shellcheck source=scripts/lib/portable.sh
. "$ROOT/scripts/lib/portable.sh"


[ -d "$SRC" ] || { echo "no upstream checkout at $SRC" >&2; exit 1; }

if [ -f "$OUT" ] && [ "$FORCE" -eq 0 ]; then
  echo "$OUT already exists; refusing to overwrite a recorded baseline."
  echo "Re-baselining invalidates every 'reduced by N%' comparison — pass --force if that is what you want."
  exit 0
fi

dirsize() { dir_bytes "$1"; }

echo "measuring pristine sizes under $SRC ..."
dict=$(dirsize "$SRC/dictionaries")
web=$(dirsize "$SRC/web-apps")
desk=$(dirsize "$SRC/desktop-apps")
png=$(find "$SRC/web-apps" -name '*.png' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
svg=$(find "$SRC/web-apps" -name '*.svg' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
locales=$(find "$SRC/web-apps/apps" -type d -name locale 2>/dev/null | wc -l)

# --- the built application, if one exists -----------------------------------
find_binary() {
  local c
  for c in "$(dirname "$SRC")/out/linux_64/onlyoffice/desktopeditors/DesktopEditors" \
           "$SRC/desktop-apps/win-linux/build/linux_64/DesktopEditors"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  find "$SRC/desktop-apps" -type f -name DesktopEditors -perm -u+x 2>/dev/null | head -1
}
BIN="$(find_binary)"

bin_size=null; bin_hash=null; bin_note=''
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
  bin_size=$(stat -c%s "$BIN")
  bin_hash="\"$(sha256sum "$BIN" | cut -d' ' -f1)\""
  echo "binary: $BIN ($bin_size bytes)"
else
  bin_note='no built application found; run scripts/build_desktop.sh (blocked here: v8 sources are unreachable, see scripts/build_desktop.sh --check-only)'
  echo "binary: none — recording null rather than a placeholder"
fi

# --- runtime measurements ----------------------------------------------------
cold=null; rss=null; run_note=''
if [ -n "$BIN" ] && [ -x "$BIN" ] && [ -x /usr/bin/time ]; then
  echo "measuring cold start and peak RSS ..."
  rssfile=$(mktemp)
  start=$(date +%s%3N)
  /usr/bin/time -v -o "$rssfile" "$BIN" --version >/dev/null 2>&1
  cold=$(( $(date +%s%3N) - start ))
  rss_kb=$(grep -oP 'Maximum resident set size \(kbytes\): \K[0-9]+' "$rssfile" 2>/dev/null || echo '')
  [ -n "$rss_kb" ] && rss=$(( rss_kb / 1024 ))
  rm -f "$rssfile"
else
  run_note='requires a built application; cold start and RSS cannot be measured without one'
fi

# The spec targets a 2-core/2GB reference machine. Record what we actually ran
# on so a number measured elsewhere is never mistaken for one measured there.
host_cores=$(nproc 2>/dev/null || echo 0)
host_mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

python3 - "$OUT" "$dict" "$web" "$desk" "$png" "$svg" "$locales" \
         "$bin_size" "$bin_hash" "$bin_note" "$cold" "$rss" "$run_note" \
         "$host_cores" "$host_mem_mb" "$SRC" <<'PY'
import json, subprocess, sys, datetime

(out, dict_, web, desk, png, svg, locales,
 bin_size, bin_hash, bin_note, cold, rss, run_note,
 cores, mem, src) = sys.argv[1:17]

def num(v):
    return None if v in ('null', '', None) else int(v)

def rev(path):
    try:
        return subprocess.run(['git', '-C', path, 'describe', '--tags'],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return None

doc = {
    "schema": "lightoffice/baseline@1",
    "recorded": datetime.datetime.now(datetime.timezone.utc)
                 .replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    "upstream_tag": rev(src),
    "measured_on": {
        "cores": num(cores),
        "memory_mb": num(mem),
        "note": "The performance targets are specified for a 2-core/2GB machine. "
                "Compare only against numbers measured on equivalent hardware."
    },
    "sizes": {
        "dictionaries_bytes": num(dict_),
        "web_apps_bytes": num(web),
        "desktop_apps_bytes": num(desk),
        "web_apps_png_bytes": num(png),
        "web_apps_svg_bytes": num(svg),
        "locale_dir_count": num(locales),
    },
    "binary_size_bytes": num(bin_size),
    "binary_hash": json.loads(bin_hash) if bin_hash not in ('null', '') else None,
    "cold_start_time_ms": num(cold),
    "peak_memory_mb": num(rss),
}
if bin_note:
    doc["binary_unavailable"] = bin_note
if run_note:
    doc["runtime_metrics_unavailable"] = run_note

with open(out, 'w', encoding='utf-8') as fh:
    json.dump(doc, fh, indent=2)
    fh.write('\n')
print("wrote", out)
PY

jq '{upstream_tag, sizes, binary_size_bytes, cold_start_time_ms, peak_memory_mb}' "$OUT"
