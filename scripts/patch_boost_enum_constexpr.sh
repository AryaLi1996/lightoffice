#!/usr/bin/env bash
#
# Let Boost 1.72's MPL compile under a modern clang.
#
# THE FAILURE (macOS arm64, run 34666010157, 30m11s in):
#
#   .../boost/build/mac_arm64/include/boost/mpl/aux_/integral_wrapper.hpp:73:31:
#     error: non-type template argument is not a constant expression
#      73 | typedef AUX_WRAPPER_INST(
#             BOOST_MPL_AUX_STATIC_CAST(AUX_WRAPPER_VALUE_TYPE, (value - 1)) ) prior;
#   note: integer value -1 is outside the valid range of values [0, 3]
#     for the enumeration type 'udt_builtin_mixture_enum'
#
#   .../3dParty/apple/libetonyek/src/lib/IWORKTable.cpp:829:
#     cellProps.insert("librevenge:column", numeric_cast<int>(col));
#
#   2 errors generated.
#   make: *** [.../libetonyek/src/lib/IWORKTable.o] Error 1
#
# WHAT IS ACTUALLY WRONG
#
# mpl::integral_c<T,N> defines `next` and `prior` as member typedefs:
#
#   next  = integral_c<T, static_cast<T>(N + 1)>
#   prior = integral_c<T, static_cast<T>(N - 1)>
#
# Member typedefs are instantiated with the class, so both exist whether or
# not anyone asks for them. When T is an enumeration without a fixed
# underlying type, static_cast<T> of a value outside the enumeration's range
# is undefined behaviour -- and undefined behaviour is not a constant
# expression, so the non-type template argument is ill-formed. C++ has always
# said so; clang began enforcing it in clang 16.
#
# Three of Boost's own enums in numeric/conversion trip it, and the tree only
# reaches them because libetonyek calls numeric_cast:
#
#   udt_builtin_mixture_enum   prior of 0  -> -1, range [0, 3]
#   int_float_mixture_enum     prior of 0  -> -1, range [0, 3]
#   sign_mixture_enum          next  of 3  ->  4, range [0, 3]
#
# WHY NOT JUST -Wno-enum-constexpr-conversion
#
# That was the first attempt, and it is why this script is named the way it
# is. LLVM added the flag as an escape hatch for exactly this code when it
# made the diagnostic an error. It works on clang 16 through 19 -- verified
# here against clang 18, where it takes the reproducer from three errors to a
# clean compile.
#
# It does not work on the runner. Apple clang 21 (Xcode 26) still *accepts*
# the flag -- there is no "unknown warning option" in the log, and the flag is
# present on the failing command line -- but it no longer suppresses anything.
# The cast is simply not a constant expression any more, and the diagnostic
# comes out at the template-argument site as a plain hard error, with the old
# "-1 is outside the valid range" text demoted to an explanatory note. The
# hatch is gone in substance even though it survives in spelling.
#
# So the flag has to be fixed in the header instead.
#
# THE FIX
#
# Upstream already anticipated this. build_tools/scripts/core_common/modules/
# boost.py carries an apply_patches() hook, called at the end of boost's
# make(), with the comment "Xcode 26+ Clang treats enum-constexpr-conversion
# as hard error" -- but the patch file it looks for,
# core/Common/3dParty/boost/patches/mpl_integral_wrapper.patch, does not exist
# anywhere in the v9.4.0 tree, and base.apply_patch() reads it without
# checking, so today the hook is a no-op. This script supplies the missing
# patch and widens the hook to cover the desktop macOS installs.
#
#   patches/boost/mpl_integral_wrapper_step.patch
#       adds boost::mpl::aux::wrapper_step<T>, which steps normally for
#       arithmetic T and is specialised on __is_enum(T) to report the value
#       unchanged. Stepping an enumeration is not meaningful; the typedefs
#       exist only because the class template defines them unconditionally,
#       and nothing in Boost or in this tree reads integral_c<Enum,N>::next.
#
#   patches/boost/mpl_integral_wrapper.patch
#       routes next/prior through the helper, behind
#       #elif defined(BOOST_MPL_AUX_ENUM_SAFE_STEP). The helper is only
#       defined for C++11 and later, so anything older keeps the original
#       expressions and compiles exactly the code it compiled before.
#
# apply_patches() runs after boost_qt.make() has installed the headers, so the
# mac_64 and mac_arm64 copies under build/ are what the application actually
# compiles against and they have to be patched by name. Upstream lists the
# source tree and the three iOS installs; this script appends the two desktop
# macOS ones.
#
# VERIFIED, not assumed: scripts/check_boost_enum_patch.sh compiles
# a reproducer of IWORKTable.cpp:829 against stock and patched headers with
# whatever clang is on the box. Stock clang 18 gives the three errors above;
# patched, it is clean, and mpl::next/prior still step correctly for int_,
# long, size_t and integral_c<long>.
#
# WHY NOT THE ALTERNATIVES
#
#   - Bumping vendored Boost changes the pinned tree for every platform to fix
#     a problem only one toolchain has.
#   - Giving the three enums a fixed underlying type would work, but only for
#     the enums we have already tripped over; std::float_round_style is used
#     the same way in converter.hpp and cannot be edited at all.
#   - Dropping libetonyek would remove Apple iWork import, which is cutting
#     functionality and is ruled out.
#
# Idempotent twice over: this script is marker-fenced, and each patch's
# replacement text deliberately does not contain the text it replaces, so
# boost.py re-applying them on a later make.py is a no-op.
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

# ---------------------------------------------------------------- the patches

PATCH_SRC="$ROOT/patches/boost"
PATCH_DST="$SRC/core/Common/3dParty/boost/patches"

for p in mpl_integral_wrapper.patch mpl_integral_wrapper_step.patch; do
  [ -f "$PATCH_SRC/$p" ] || { echo "missing patch: $PATCH_SRC/$p" >&2; exit 1; }
done

mkdir -p "$PATCH_DST"
cp "$PATCH_SRC"/mpl_integral_wrapper.patch \
   "$PATCH_SRC"/mpl_integral_wrapper_step.patch "$PATCH_DST/"
ok "installed 2 boost mpl patches into core/Common/3dParty/boost/patches"

# ------------------------------------------------- widen upstream's hook

BOOST_PY="$SRC/build_tools/scripts/core_common/modules/boost.py"
if [ ! -f "$BOOST_PY" ]; then
  warn "no $BOOST_PY — nothing to widen"
else
  if grep -q "$MARK" "$BOOST_PY"; then
    ok "boost.py already covers the desktop macOS installs"
  else
    python3 - "$BOOST_PY" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1:3]
s = open(path, encoding='utf-8').read()

# apply_patches() must exist; if upstream ever drops the hook we want to know
# rather than silently build the old headers.
if 'def apply_patches(' not in s or 'apply_patches(base_dir)' not in s:
    sys.exit("boost.py no longer has the apply_patches hook — not patching blind")

targets_old = (
    '    base_dir + "/build/ios_xcframework/ios_simulator/include/boost/mpl/aux_/integral_wrapper.hpp",\n'
    '  ]\n'
)
targets_new = (
    '    base_dir + "/build/ios_xcframework/ios_simulator/include/boost/mpl/aux_/integral_wrapper.hpp",\n'
    f'    # {mark}: the desktop macOS installs land here. apply_patches() runs\n'
    '    # after boost_qt.make() has copied the headers into them, so the source\n'
    '    # tree entry above does not reach what the application compiles against.\n'
    '    base_dir + "/build/mac_64/include/boost/mpl/aux_/integral_wrapper.hpp",\n'
    '    base_dir + "/build/mac_arm64/include/boost/mpl/aux_/integral_wrapper.hpp",\n'
    '  ]\n'
)

loop_old = (
    '  for target in mpl_targets:\n'
    '    if base.is_file(target):\n'
    '      base.apply_patch(target, mpl_patch)\n'
)
loop_new = (
    f'  # {mark}: the step helper defines what the typedefs call, so it goes in\n'
    '  # first. Both halves are idempotent; re-running make.py is a no-op.\n'
    '  mpl_step_patch = patches_dir + "/mpl_integral_wrapper_step.patch"\n'
    '  for target in mpl_targets:\n'
    '    if base.is_file(target):\n'
    '      if base.is_file(mpl_step_patch):\n'
    '        base.apply_patch(target, mpl_step_patch)\n'
    '      base.apply_patch(target, mpl_patch)\n'
)

for name, old in (("mpl_targets list", targets_old), ("apply loop", loop_old)):
    n = s.count(old)
    if n != 1:
        sys.exit(f"{name}: found {n} matches in boost.py, expected exactly 1")

s = s.replace(targets_old, targets_new).replace(loop_old, loop_new)
open(path, 'w', encoding='utf-8').write(s)
PY
    ok "boost.py now patches build/mac_64 and build/mac_arm64 too"
  fi
fi

# ----------------------------------------------------------------- the flag

# Kept even though it no longer suppresses anything on Apple clang 21: it costs
# nothing, it is still the right flag on clang 16-19, and dropping it would
# leave the tree with no signal at all about this class of diagnostic. The
# header patch above is what actually fixes the build.
PRI="$SRC/core/Common/base.pri"
if [ ! -f "$PRI" ]; then
  warn "no $PRI — skipping the compiler flag"
elif grep -q "$MARK" "$PRI"; then
  ok "base.pri already carries $FLAG"
else
  # Anchor on upstream's own clang workaround inside core_mac rather than on
  # the block header: "core_mac {" appears more than once in this file, and
  # matching the wrong one would put the flag in a block that never applies.
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
    f"\t# {mark}: quiets clang 16-19 on Boost 1.72's\n"
    f"\t# mpl::integral_c<Enum,0>::prior. Apple clang 21 accepts the flag but\n"
    f"\t# ignores it -- the header patch is the actual fix. See\n"
    f"\t# scripts/patch_boost_enum_constexpr.sh.\n"
    f"\tQMAKE_CXXFLAGS += {flag}\n"
)
open(pri, 'w', encoding='utf-8').write(src.replace(anchor, add))
PY

  ok "added $FLAG to core_mac in base.pri"
fi
