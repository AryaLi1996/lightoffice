#!/usr/bin/env bash
#
# Replace byte-identical files in the deployed tree with hardlinks.
#
# WHY: the installer is 783 MB against a 500 MB limit, and the payload profile
# (run 34455954530) shows where the weight is:
#
#     317.7 MiB    79  .gif
#     155.6 MiB 10569  .png
#     125.2 MiB    75  .pdf
#
#   14.5 MiB  .../help/tr/images/conditionalformatting/cellvalueformula.gif
#   14.5 MiB  .../help/ru/images/conditionalformatting/cellvalueformula.gif
#   14.5 MiB  .../help/pt/…  fr/…  en/…  de/…
#
# One animated GIF, seven copies, one per help language. The same shape repeats
# across the help PNGs and PDFs, and libicudata ships six times (29.4 MiB x4 and
# 28.1 MiB x2). None of it compresses: GIF, PNG and PDF are already compressed,
# so every duplicate megabyte is a megabyte in the .deb.
#
# Deleting the extra languages would fix the size and REMOVE FUNCTIONALITY —
# help would stop working in those languages. Hardlinking fixes the size and
# removes nothing: every path still exists, every language still has its help
# image, the bytes are just stored once.
#
# This works end to end because every tool in the path stores a hardlink as a
# link rather than repeating the content. Measured, not assumed — six copies of
# one 20 MB blob:
#
#     tree on disk                115M  ->  20M
#     tar + xz -6           120,012,388  ->  20,002,356 bytes
#     cp -a staged copy           115M  ->  20M   (link count 6)
#     dpkg-deb -Zxz -z6                     20,002,860 bytes
#
# ORDER: this must run LAST, after strip_deploy_tree.sh and after
# fix_stdcxx_statics.sh. Both mutate files, and a tool that writes in place
# would write through every link at once. Nothing may modify the tree after
# this point; packaging only reads it.
#
# Files are grouped by (size, mode) and then by content hash, so a hardlink is
# only ever made between files that are byte-identical AND already share
# permissions — sharing an inode means sharing both.
#
# Idempotent: files already sharing an inode are skipped, so re-running saves 0.
#
# Usage: scripts/dedupe_deploy_tree.sh <deploy-tree>

set -euo pipefail

TREE="${1:-}"
[ -n "$TREE" ] && [ -d "$TREE" ] || { echo "usage: $0 <deploy-tree>" >&2; exit 2; }

# Below this, the saving is smaller than the directory entry it costs to keep.
MIN_BYTES="${LIGHTOFFICE_DEDUPE_MIN_BYTES:-4096}"

before=$(du -sb "$TREE" | cut -f1)

# Only files whose (size, mode) is shared with another file can possibly be
# duplicates, so hash those and nothing else — hashing 1.8 GB outright would
# dominate the runtime for no benefit.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

find "$TREE" -type f -size +"$((MIN_BYTES - 1))"c -printf '%s\t%m\t%i\t%p\n' \
  2>/dev/null > "$work/all.tsv"

cut -f1,2 "$work/all.tsv" | sort | uniq -d > "$work/dupe-keys.tsv"

if [ ! -s "$work/dupe-keys.tsv" ]; then
  printf '  \033[32m✓\033[0m no candidates — nothing to deduplicate\n'
  exit 0
fi

# Hash the candidates in parallel; keep size+mode in the key so a hash
# collision across different sizes can never link two unrelated files.
awk -F'\t' 'NR==FNR { k[$1"\t"$2]; next } ($1"\t"$2) in k' \
  "$work/dupe-keys.tsv" "$work/all.tsv" > "$work/cand.tsv"

cut -f4 "$work/cand.tsv" | tr '\n' '\0' \
  | xargs -0 -r -P "$(nproc)" -n 64 sha256sum 2>/dev/null > "$work/hashes.txt"

# join hash back onto size/mode/inode
awk -F'\t' 'NR==FNR { h=$0; sub(/  .*/,"",h); p=$0; sub(/^[0-9a-f]+  /,"",p);
                      H[p]=h; next }
            { print H[$4]"\t"$1"\t"$2"\t"$3"\t"$4 }' \
  "$work/hashes.txt" "$work/cand.tsv" | sort > "$work/keyed.tsv"

linked=0 saved=0 groups=0
prev_key="" keep="" keep_inode=""
while IFS=$'\t' read -r hash size mode inode path; do
  key="$hash	$size	$mode"
  if [ "$key" != "$prev_key" ]; then
    prev_key="$key"; keep="$path"; keep_inode="$inode"; groups=$((groups + 1))
    continue
  fi
  # Already the same inode: previously linked, or an upstream hardlink.
  [ "$inode" = "$keep_inode" ] && continue
  # ln -f replaces atomically via rename, so a failure leaves the original.
  if ln -f "$keep" "$path" 2>/dev/null; then
    linked=$((linked + 1)); saved=$((saved + size))
  fi
done < "$work/keyed.tsv"

after=$(du -sb "$TREE" | cut -f1)
awk -v b="$before" -v a="$after" -v n="$linked" -v g="$groups" \
  'BEGIN { printf "  \033[32m✓\033[0m hardlinked %d duplicate(s) across %d distinct file(s): %.1f MiB → %.1f MiB (saved %.1f MiB, %.1f%%)\n",
           n, g, b/1048576, a/1048576, (b-a)/1048576, (b>0 ? (b-a)*100/b : 0) }'

# Nothing here may fail the build: a tree that could not be deduplicated is
# larger, not broken.
exit 0
