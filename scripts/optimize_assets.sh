#!/usr/bin/env bash
#
# Compress web-apps static assets.
#
# Default mode is LOSSLESS (pngcrush + optipng + svgo), which is what Ticket 4's
# task list asks for ("静态资源无损压缩"). Measured on this ONLYOFFICE revision the
# lossless ceiling is roughly 4-8%: upstream already ships crushed PNGs, so the
# >15% figure in AC 4.2 is not reachable without changing pixels.
#
# --lossy additionally runs pngquant (palette quantisation, quality 65-90). On a
# 200-file sample that reduces PNG bytes by ~56%, comfortably past AC 4.2, at the
# cost of no longer being bit-exact. Icons survive this well; it is opt-in so the
# choice stays with whoever owns the release.
#
# Usage: scripts/optimize_assets.sh [--lossy] [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOSSY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --lossy) LOSSY=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
SRC="${ARGS[0]:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
WEB="$SRC/web-apps"
OUTDIR="$ROOT/baseline"
JOBS="$(nproc)"

[ -d "$WEB" ] || { echo "no web-apps at $WEB" >&2; exit 1; }
mkdir -p "$OUTDIR"

total() { find "$WEB" -name "$1" -printf '%s\n' | awk '{s+=$1} END{print s+0}'; }

PNG_BEFORE_FILE="$OUTDIR/png.baseline"
SVG_BEFORE_FILE="$OUTDIR/svg.baseline"
[ -f "$PNG_BEFORE_FILE" ] || total '*.png' > "$PNG_BEFORE_FILE"
[ -f "$SVG_BEFORE_FILE" ] || total '*.svg' > "$SVG_BEFORE_FILE"
PNG_BEFORE=$(cat "$PNG_BEFORE_FILE")
SVG_BEFORE=$(cat "$SVG_BEFORE_FILE")

echo "PNG baseline: $PNG_BEFORE bytes   SVG baseline: $SVG_BEFORE bytes   jobs: $JOBS"

# ---------------------------------------------------------------- PNG --------
# Each file is optimised in place, and only kept if it actually got smaller —
# pngcrush/optipng can round-trip a already-minimal file to something larger.
cat > /tmp/lo_png_one.sh <<'ONE'
#!/usr/bin/env bash
set -euo pipefail
f="$1"; lossy="$2"
before=$(stat -c%s "$f")
tmp="$(mktemp /tmp/lo_png.XXXXXX.png)"
work="$(mktemp /tmp/lo_png.XXXXXX.png)"
cp "$f" "$work"
pngcrush -q -rem alla -reduce "$work" "$tmp" >/dev/null 2>&1 && mv "$tmp" "$work" || rm -f "$tmp"
optipng -quiet -o2 -strip all "$work" >/dev/null 2>&1 || true
if [ "$lossy" = "1" ]; then
  q="$(mktemp /tmp/lo_png.XXXXXX.png)"
  if pngquant --quality=65-90 --speed 3 --force --output "$q" "$work" >/dev/null 2>&1; then
    [ -s "$q" ] && mv "$q" "$work" || rm -f "$q"
  else
    rm -f "$q"
  fi
fi
after=$(stat -c%s "$work")
if [ "$after" -lt "$before" ]; then mv "$work" "$f"; else rm -f "$work"; fi
ONE
chmod +x /tmp/lo_png_one.sh

echo "optimising PNGs (lossy=$LOSSY) ..."
find "$WEB" -name '*.png' -print0 | xargs -0 -r -P "$JOBS" -I{} /tmp/lo_png_one.sh {} "$LOSSY"

# ---------------------------------------------------------------- SVG --------
echo "optimising SVGs ..."
svgo --quiet --multipass -r -f "$WEB" >/dev/null 2>&1 || \
  find "$WEB" -name '*.svg' -print0 | xargs -0 -r -P "$JOBS" -I{} svgo --quiet --multipass {} >/dev/null 2>&1 || true

PNG_AFTER=$(total '*.png')
SVG_AFTER=$(total '*.svg')

report() {
  awk -v b="$2" -v a="$3" -v n="$1" 'BEGIN{
    if (b==0) { printf "%-4s no files\n", n; exit }
    printf "%-4s %12d -> %12d bytes   reduction %6.2f%%\n", n, b, a, (b-a)*100.0/b
  }'
}
echo
report PNG "$PNG_BEFORE" "$PNG_AFTER"
report SVG "$SVG_BEFORE" "$SVG_AFTER"

TOT_B=$((PNG_BEFORE + SVG_BEFORE)); TOT_A=$((PNG_AFTER + SVG_AFTER))
report ALL "$TOT_B" "$TOT_A"

{
  echo "png_before=$PNG_BEFORE"; echo "png_after=$PNG_AFTER"
  echo "svg_before=$SVG_BEFORE"; echo "svg_after=$SVG_AFTER"
  echo "lossy=$LOSSY"
} > "$OUTDIR/asset_optimization.result"
echo
echo "result written to baseline/asset_optimization.result"
