#!/usr/bin/env bash
#
# Losslessly recompress the help animations in the deployed tree.
#
# WHY: after deduplication the installer is 632 MB against a 500 MB limit, and
# .gif is the largest single file type in the payload — 317.7 MiB across 79
# files, now mostly unique content. A single help animation is 14.5 MiB, which
# is very large for an 800x600 screencast and suggests these were written out
# without frame optimisation.
#
# gifsicle -O3 is lossless: it re-encodes frames as minimal diffs against the
# previous frame and re-orders the colour table. It does NOT touch pixels. That
# was verified rather than taken on faith — a 60-frame animation through -O3,
# decoded frame by frame:
#
#     frames: 60 vs 60
#     every frame pixel-identical: True
#
# (--lossy is gifsicle's lossy mode. It is not used here and must not be.)
#
# WHAT WAS TRIED AND REJECTED: raising .deb compression to xz -9 --extreme.
# Measured on real JS/JSON, -9e beats -6 by 1.4% (2,648,100 -> 2,610,956
# bytes). Across the payload's compressible portion that is well under 1 MB,
# for roughly triple the packaging time. Not worth it, so packaging stays at
# xz -6.
#
# ORDER: this must run BEFORE dedupe_deploy_tree.sh. It rewrites files, and
# after deduplication identical files share an inode, so writing one would
# write through every link at once. It also pairs well with running first:
# identical GIFs stay identical after the same transformation, so dedupe still
# collapses them afterwards.
#
# A file is only replaced when the result is genuinely smaller, so a tree of
# already-optimised GIFs is left exactly as it was and re-running saves zero.
#
# Usage: scripts/optimize_gifs.sh <deploy-tree>

set -euo pipefail

TREE="${1:-}"
[ -n "$TREE" ] && [ -d "$TREE" ] || { echo "usage: $0 <deploy-tree>" >&2; exit 2; }

if ! command -v gifsicle >/dev/null; then
  printf '  \033[33m!\033[0m gifsicle not installed — skipping GIF optimisation\n' >&2
  exit 0
fi

mapfile -t GIFS < <(find "$TREE" -type f -iname '*.gif' -size +64k 2>/dev/null | sort)
if [ "${#GIFS[@]}" -eq 0 ]; then
  printf '  \033[32m✓\033[0m no GIFs above the size floor — nothing to optimise\n'
  exit 0
fi

echo "optimising ${#GIFS[@]} GIF(s) ..."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

before=0 after=0 rewritten=0 skipped=0
for f in "${GIFS[@]}"; do
  b=$(stat -c%s "$f"); before=$((before + b))
  out="$work/o.gif"
  if ! gifsicle -O3 "$f" -o "$out" 2>/dev/null; then
    after=$((after + b)); skipped=$((skipped + 1)); continue
  fi
  a=$(stat -c%s "$out" 2>/dev/null || echo 0)
  # Only take the result when it actually helps. gifsicle can emit a slightly
  # larger file for an already-optimal input, and a bigger installer is the
  # opposite of the point.
  if [ "$a" -gt 0 ] && [ "$a" -lt "$b" ]; then
    # cat rather than mv: preserves the destination inode, mode and owner, and
    # keeps any hardlink the tree already had rather than silently breaking it.
    cat "$out" > "$f"
    after=$((after + a)); rewritten=$((rewritten + 1))
  else
    after=$((after + b)); skipped=$((skipped + 1))
  fi
done

awk -v b="$before" -v a="$after" -v r="$rewritten" -v s="$skipped" \
  'BEGIN { printf "  \033[32m✓\033[0m rewrote %d GIF(s), left %d alone: %.1f MiB → %.1f MiB (saved %.1f MiB, %.1f%%)\n",
           r, s, b/1048576, a/1048576, (b-a)/1048576, (b>0 ? (b-a)*100/b : 0) }'

# Never fails the build: an unoptimised GIF is larger, not broken.
exit 0
