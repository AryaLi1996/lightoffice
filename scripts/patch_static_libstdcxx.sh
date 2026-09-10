#!/usr/bin/env bash
#
# Stop the upstream link from mixing a static libstdc++ with the shared one.
#
# THE FAILURE, which has survived four builds:
#
#   ./DesktopEditors: symbol lookup error: libascdocumentscore.so:
#     undefined symbol: _ZNSt6locale10_S_classicE
#
# THE EVIDENCE (run 34449852586, "Trace the dangling libstdc++ statics"):
#
#   trap symbols: 8
#   other unresolved (not from libstdc++): 0
#
#     std::locale::_S_classic                      defined in: locale.o
#     std::locale::_S_categories                   defined in: c++locale.o
#     std::locale::_S_initialize()                 defined in: locale_init.o
#     std::locale::_Impl::_M_init_extra(...)       defined in: cow-locale_init.o
#     std::locale::_Impl::_S_facet_categories      defined in: locale_init.o
#     std::locale::facet::_S_lc_ctype_c_locale(..) defined in: c++locale.o
#     std::ios_base::Init::_S_refcount             defined in: ios.o
#     std::ios_base::Init::_S_synced_with_stdio    defined in: ios.o
#
#   ...and the archives in the build tree that carry those objects:
#
#     v8_89/v8/build/linux/debian_sid_amd64-sysroot/usr/lib/gcc/
#       x86_64-linux-gnu/7/libstdc++.a
#         contains: localename.o locale_init.o locale.o ios_init.o
#                   globals_io.o ios.o
#
# v8's Debian sid sysroot ships GCC **7**'s libstdc++.a, and upstream asks for
# a static libstdc++ in both desktop-apps/win-linux/defaults.pri and
# core/Common/base.pri. So the link mixes libstdc++ objects from one toolchain
# with the host's shared libstdc++.so.6 from GCC 13. The *_init.o objects
# reference internal statics that GCC 13 does not export from the shared
# library — nm -D --defined-only libstdc++.so.6 finds none of the eight — so
# the link succeeds (a shared object may carry undefined symbols) and the
# loader fails.
#
# THE FIX: drop -static-libstdc++. Everything then resolves against the single
# shared libstdc++.so.6 already on the system, which is the configuration the
# rest of the application is built for anyway — scripts/package.sh has always
# declared `Depends: ... libstdc++6`, so the dependency is already carried.
#
# Why not keep the static link and fix the archive selection instead: mixing a
# static and a shared libstdc++ in one process is unsound regardless of which
# archive wins. Two copies of std::locale's global state, two ios_base::Init
# refcounts. Removing the flag removes the whole class of problem rather than
# the one symbol currently on top.
#
# This supersedes scripts/fix_stdcxx_statics.sh, which supplies two of the
# eight symbols from a shim. That shim stays as a safety net and becomes a
# no-op once this works: it acts only on symbols that are actually dangling.
#
# Idempotent: the edit is marker-fenced and re-running finds nothing to do.
#
# Usage: scripts/patch_static_libstdcxx.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-NO-STATIC-LIBSTDCXX"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

[ -d "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

# Only qmake project files. The flag also appears inside v8's own vendored
# toolchain and its generated Makefiles; v8 builds against its own sysroot
# consistently and is not what breaks, so leave it alone.
# The --include filters MUST come before `--`: `--` ends option parsing, so
# `grep -rl -- PATTERN DIR --include=...` silently treats each --include as a
# FILE operand and searches everything. That is not hypothetical — it is how
# the first version of this script came to patch v8's own config.gni, and how
# the trace step in build.yml came to report clang++ and libclang.so as files
# containing a link flag.
mapfile -t FILES < <(
  grep -rl --include='*.pri' --include='*.pro' -- '-static-libstdc++' "$SRC" \
    2>/dev/null | grep -v '/3dParty/v8_89/' | sort
)

if [ "${#FILES[@]}" -eq 0 ]; then
  ok "no qmake project asks for a static libstdc++ — nothing to patch"
  exit 0
fi

patched=0 already=0
for f in "${FILES[@]}"; do
  if grep -q "$MARK" "$f"; then
    already=$((already + 1))
    continue
  fi
  # Comment the flag out rather than deleting it, so the original intent stays
  # readable in the tree and a diff against upstream shows exactly one change
  # per file.
  before="$(grep -c -- '-static-libstdc++' "$f")"
  sed -i "s|^\(.*-static-libstdc++.*\)$|# $MARK: removed — see scripts/patch_static_libstdcxx.sh\n#\1|" "$f"
  after="$(grep -c '^#.*-static-libstdc++' "$f")"
  echo "  patched ${f#"$SRC/"} ($before occurrence(s))"
  [ "$after" -ge "$before" ] || warn "${f#"$SRC/"}: expected $before commented, got $after"
  patched=$((patched + 1))
done

[ "$already" -gt 0 ] && ok "$already file(s) already patched"

# Prove it: no qmake project may still request the flag uncommented.
remaining="$(grep -rn --include='*.pri' --include='*.pro' -- '-static-libstdc++' "$SRC" \
  2>/dev/null | grep -v '/3dParty/v8_89/' | grep -v ':[0-9]*:\s*#' || true)"
if [ -n "$remaining" ]; then
  echo "still requesting a static libstdc++:" >&2
  echo "$remaining" >&2
  exit 1
fi
ok "patched $patched file(s); no qmake project requests a static libstdc++"
