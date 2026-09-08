# Portable size helpers.
#
# GNU coreutils `du -sb` reports apparent size in bytes. BSD du, which is what
# macOS ships, has no -b at all and exits 64 — that is what broke the macOS
# release job, several steps after the flag that caused it.
#
# `du -sk` exists on both and is used instead. Two caveats that matter for how
# the results are read:
#
#   * the unit is KiB, so byte-exact comparisons are not available. Every caller
#     uses these for before/after reduction ratios over directories of tens of
#     megabytes, where KiB granularity is far below the noise.
#   * GNU reports apparent size while BSD reports allocated blocks, so a figure
#     measured on Linux is not comparable with one measured on macOS. Each run
#     measures both sides on one machine, so a ratio stays valid; an absolute
#     size recorded on one platform must not be compared against another.
#
# shellcheck shell=bash

# Size of a directory in bytes. Prints 0 for a missing directory rather than
# failing, so callers can measure a tree that does not exist yet.
dir_bytes() {
  [ -d "$1" ] || { echo 0; return; }
  local kb
  kb=$(du -sk "$1" 2>/dev/null | awk '{print $1; exit}')
  echo $(( ${kb:-0} * 1024 ))
}

# Combined size in bytes of every directory passed.
dirs_bytes() {
  local total=0 d
  for d in "$@"; do
    [ -d "$d" ] || continue
    total=$(( total + $(dir_bytes "$d") ))
  done
  echo "$total"
}

# Combined size of directories read one per line from stdin. Takes them on
# stdin rather than as arguments so callers can pipe `find` straight in without
# word splitting, and without mapfile, which macOS's bash 3.2 lacks.
dirs_bytes_stdin() {
  local total=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    total=$(( total + $(dir_bytes "$d") ))
  done
  echo "$total"
}

# Size of a single file in bytes. GNU stat and BSD stat spell this differently.
file_bytes() {
  [ -f "$1" ] || { echo 0; return; }
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}
