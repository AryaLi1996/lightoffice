#!/usr/bin/env bash
#
# Let Boost 1.72's MPL compile under a modern Apple clang.
#
# THE FAILURE (run 34601443842, 38m25s into the macOS arm64 build):
#
#   boost/mpl/aux_/integral_wrapper.hpp:73:31: error: non-type template
#     argument is not a constant expression
#      73 | typedef AUX_WRAPPER_INST(
#             BOOST_MPL_AUX_STATIC_CAST(AUX_WRAPPER_VALUE_TYPE, (value - 1)) ) prior;
#   note: integer value -1 is outside the valid range of values [0, 3]
#     for the enumeration type 'int_float_mixture_enum'
#
#   .../3dParty/apple/libetonyek/src/lib/IWORKTable.cpp:829:
#     cellProps.insert("librevenge:column", numeric_cast<int>(col));
#
#   2 errors generated.
#   make: *** [.../libetonyek/src/lib/IWORKTable.o] Error 1
#
# WHAT IS ACTUALLY WRONG
#
# mpl::integral_c<T, N> defines `prior` as integral_c<T, N - 1>. When T is an
# enum with a fixed range and N is 0, that is static_cast<T>(-1) -- a value
# outside the enumeration -- in a constant expression. C++ has always said that
# is ill-formed; clang only began enforcing it. Clang 16 promoted the
# diagnostic from a warning to an error, and this runner has Apple clang 21.
#
# boost.py pins boost-1.72.0, a 2019 release, so nothing in the vendored tree
# carries the later Boost fix. Nobody instantiates `prior` here -- it is a
# member typedef that gets instantiated with the class, purely incidental to
# the numeric_cast that libetonyek actually wants.
#
# WHY THE FLAG AND NOT SOMETHING ELSE
#
# -Wno-enum-constexpr-conversion is the escape hatch LLVM added when it made
# this an error, precisely so that code vendoring old Boost could keep
# building. It is narrow: it re-permits exactly this conversion and nothing
# else.
#
# The alternatives are worse for this project:
#   - bumping vendored Boost changes upstream's pinned tree for every platform,
#     to fix a problem only the macOS toolchain has;
#   - patching Boost's own headers means maintaining a fork of a template
#     metaprogramming library;
#   - dropping libetonyek would remove Apple iWork import, which is cutting
#     functionality and is ruled out.
#
# IF THE FLAG IS GONE
#
# LLVM has said it will remove this hatch eventually, and clang 21 is recent
# enough that it might already have. The failure mode is benign: clang treats
# an unrecognised -Wno-* as a warning, not an error, so the build would simply
# fail again at the same Boost error rather than somewhere new. If that
# happens, the answer is bumping Boost, and this script's comment is the
# evidence for why.
#
# WHERE IT GOES
#
# core/Common/base.pri's core_mac block, which already carries upstream's own
# clang workaround of the same shape:
#
#   QMAKE_CFLAGS += "-Wno-implicit-function-declaration"
#
# macOS only. Linux builds this same code with GCC 13 and does not care.
#
# Idempotent: the edit is marker-fenced and re-running finds nothing to do.
#
# Usage: scripts/patch_boost_enum_constexpr.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-BOOST-ENUM-CONSTEXPR"
FLAG="-Wno-enum-constexpr-conversion"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

[ -d "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

PRI="$SRC/core/Common/base.pri"
[ -f "$PRI" ] || { warn "no $PRI — nothing to patch"; exit 0; }

if grep -q "$MARK" "$PRI"; then
  ok "base.pri already carries $FLAG"
  exit 0
fi

# Anchor on upstream's own clang workaround inside core_mac rather than on the
# block header: "core_mac {" appears more than once in this file, and matching
# the wrong one would put the flag in a block that never applies.
ANCHOR='QMAKE_CFLAGS += "-Wno-implicit-function-declaration"'
if ! grep -qF "$ANCHOR" "$PRI"; then
  warn "anchor line not found in $PRI — upstream layout changed, not patching blind"
  warn "  expected: $ANCHOR"
  exit 1
fi

python3 - "$PRI" "$MARK" "$FLAG" "$ANCHOR" <<'PY'
import sys
pri, mark, flag, anchor = sys.argv[1:5]
src = open(pri, encoding='utf-8').read()
if src.count(anchor) != 1:
    sys.exit(f"anchor appears {src.count(anchor)} times, expected exactly 1")
add = (
    f"{anchor}\n"
    f"\n"
    f"\t# {mark}: Boost 1.72's mpl::integral_c<Enum,0>::prior is\n"
    f"\t# static_cast<Enum>(-1), which clang 16+ rejects as a hard error.\n"
    f"\t# See scripts/patch_boost_enum_constexpr.sh for the full reasoning.\n"
    f"\tQMAKE_CXXFLAGS += {flag}\n"
)
open(pri, 'w', encoding='utf-8').write(src.replace(anchor, add))
PY

ok "added $FLAG to core_mac in base.pri"
