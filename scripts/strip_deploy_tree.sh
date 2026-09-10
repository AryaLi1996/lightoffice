#!/usr/bin/env bash
#
# Strip debug info from the deployed tree before it is packaged.
#
# WHY: the first installer came out at 1052 MiB under gzip and 797.9 MB under
# xz, against a 500MB limit. AC 4.3 checks that the DesktopEditors binary is
# stripped and it passes — but that binary is 2,550,512 bytes of a 3.5 GB tree.
# Nothing has ever checked the shared libraries, which are the tree.
#
# Debug symbols have no runtime value in a shipped installer: nothing loads
# .debug_* sections, and .symtab is not used for dynamic linking — .dynsym is,
# and strip keeps it. So this is a size cut with no behavioural cost, which is
# why it goes first, before anything that removes features or languages.
#
# --strip-unneeded on shared objects, plain strip on executables. Never
# --strip-all on a .so: that would take .dynsym with it and nothing would link.
#
# ORDER MATTERS: this must run BEFORE scripts/fix_stdcxx_statics.sh. strip
# rewrites section headers and is known to corrupt binaries whose program
# headers patchelf has already rewritten; doing it the other way round would
# undo the launch fix in a way that only shows up at runtime.
#
# Idempotent: an already-stripped file is skipped, so re-running is a no-op and
# reports zero saved.
#
# Usage: scripts/strip_deploy_tree.sh <deploy-tree>

set -euo pipefail

TREE="${1:-}"
[ -n "$TREE" ] && [ -d "$TREE" ] || { echo "usage: $0 <deploy-tree>" >&2; exit 2; }

command -v strip >/dev/null || { echo "strip is required (binutils)" >&2; exit 1; }

before=$(du -sb "$TREE" | cut -f1)

# Collect first, then strip: `find -exec` over a tree this size while modifying
# it in place is asking for surprises, and the file list is wanted for the count.
mapfile -t TARGETS < <(
  find "$TREE" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0 \
  | xargs -0 -r -P "$(nproc)" -n 32 sh -c '
      for f; do
        head -c 4 "$f" 2>/dev/null | grep -q ELF || continue
        file "$f" 2>/dev/null | grep -q "not stripped" && echo "$f"
      done' _
)

if [ "${#TARGETS[@]}" -eq 0 ]; then
  printf '  \033[32m✓\033[0m nothing left to strip (tree is %s)\n' \
    "$(du -sh "$TREE" | cut -f1)"
  exit 0
fi

echo "stripping ${#TARGETS[@]} file(s) ..."
failed=0
for f in "${TARGETS[@]}"; do
  case "$f" in
    *.so|*.so.*) strip --strip-unneeded "$f" 2>/dev/null || failed=$((failed + 1)) ;;
    *)           strip "$f"                 2>/dev/null || failed=$((failed + 1)) ;;
  esac
done

after=$(du -sb "$TREE" | cut -f1)
awk -v b="$before" -v a="$after" -v n="${#TARGETS[@]}" -v e="$failed" \
  'BEGIN { printf "  \033[32m✓\033[0m stripped %d file(s): %.1f MiB → %.1f MiB (saved %.1f MiB, %.1f%%)\n",
           n, b/1048576, a/1048576, (b-a)/1048576, (b-a)*100/b
           if (e > 0) printf "  \033[33m!\033[0m %d file(s) could not be stripped and were left alone\n", e }'

# A file strip refuses is left as it was, so this never fails the build: an
# unstripped library is large, not broken.
exit 0
