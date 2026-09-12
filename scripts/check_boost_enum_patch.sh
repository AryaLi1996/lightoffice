#!/usr/bin/env bash
#
# Prove the boost mpl patches do what scripts/patch_boost_enum_constexpr.sh
# says they do, using whatever clang is on this machine.
#
# The macOS runner has Apple clang 21 and a 30-minute build; this box has
# clang 18 and takes about a second. clang 18 enforces the same rule that
# broke the runner (it is the release that made -Wenum-constexpr-conversion an
# error), so it reproduces the failure faithfully. What it cannot reproduce is
# clang 21 dropping the -Wno- escape hatch -- on 18 the flag still works, and
# the test records that rather than pretending otherwise.
#
# Checks, in order:
#   1. stock Boost 1.72 headers + clang  -> the three enum errors, as expected
#   2. patched headers + clang, no flags -> clean
#   3. patched headers as C++98          -> clean (the fallback branch)
#   4. mpl::next/prior still step        -> static_asserts inside the compile
#
# Usage: scripts/check_boost_enum_patch.sh [/path/to/boost/include]
#
# Exits 0 if every check holds, 1 otherwise. Skips (0) if no clang, or if the
# boost include tree is not there -- it is a check on a built tree, not a
# reason to fail a machine that has not built one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}"
BOOST_INC="${1:-}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
skip() { printf '  \033[33m-\033[0m %s\n' "$*"; }

CXX="${CXX:-}"
if [ -z "$CXX" ]; then
  for c in clang++ clang++-18 clang++-19 clang++-17 clang++-16; do
    command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }
  done
fi
[ -n "$CXX" ] || { skip "no clang on this machine — cannot test the diagnostic"; exit 0; }

if [ -z "$BOOST_INC" ]; then
  for d in "$SRC"/core/Common/3dParty/boost/build/*/include; do
    [ -f "$d/boost/mpl/aux_/integral_wrapper.hpp" ] && { BOOST_INC="$d"; break; }
  done
fi
[ -n "$BOOST_INC" ] || { skip "no built boost include tree — nothing to test against"; exit 0; }

echo "boost mpl enum-constexpr patch check: $($CXX --version | head -1)"
echo "  headers: $BOOST_INC"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/repro.cpp" <<'EOF'
// The call libetonyek makes at IWORKTable.cpp:829, which is what drags
// boost/numeric/conversion -- and its enums -- into the build.
#include <boost/numeric/conversion/cast.hpp>
#include <boost/mpl/int.hpp>
#include <boost/mpl/next_prior.hpp>
#include <boost/static_assert.hpp>

int f(unsigned col) { return boost::numeric_cast<int>(col); }

// next/prior must still step for real integral types: the patch must not buy
// enum safety by breaking the wrappers MPL actually iterates over.
BOOST_STATIC_ASSERT(( boost::mpl::next< boost::mpl::int_<4> >::type::value == 5 ));
BOOST_STATIC_ASSERT(( boost::mpl::prior< boost::mpl::int_<4> >::type::value == 3 ));
BOOST_STATIC_ASSERT(( boost::mpl::int_<0>::prior::value == -1 ));
BOOST_STATIC_ASSERT(( boost::mpl::integral_c<long,7>::next::value == 8 ));
BOOST_STATIC_ASSERT(( boost::mpl::integral_c<std::size_t,7>::prior::value == 6 ));

// And the wrapper at the bottom of an enumeration's range must instantiate.
typedef boost::mpl::integral_c<boost::numeric::udt_builtin_mixture_enum,
                               boost::numeric::builtin_to_builtin> b2b;
BOOST_STATIC_ASSERT(( b2b::value == boost::numeric::builtin_to_builtin ));
EOF

# A pristine copy to patch, so the test never touches the real tree.
cp -r "$BOOST_INC" "$WORK/patched"
python3 - "$WORK/patched/boost/mpl/aux_/integral_wrapper.hpp" \
          "$ROOT/patches/boost/mpl_integral_wrapper_step.patch" \
          "$ROOT/patches/boost/mpl_integral_wrapper.patch" <<'PY'
import sys
target, *patches = sys.argv[1:]
for p in patches:
    pc = open(p, encoding='utf-8').read()
    i1, i2, i3 = pc.find("<<<<<<<"), pc.find("======="), pc.find(">>>>>>>")
    old, new = pc[i1+7:i2].strip(), pc[i2+7:i3].strip()
    s = open(target, encoding='utf-8').read()
    if s.count(old) != 1:
        sys.exit(f"{p}: anchor matched {s.count(old)} times, expected 1")
    if old in new:
        sys.exit(f"{p}: replacement contains what it replaces — not idempotent")
    open(target, 'w', encoding='utf-8').write(s.replace(old, new))
PY

fail=0

# 1. The failure must actually reproduce, or this machine proves nothing.
if out="$("$CXX" -std=gnu++11 -fsyntax-only -I "$BOOST_INC" "$WORK/repro.cpp" 2>&1)"; then
  skip "stock headers compile here — this clang does not enforce the rule,"
  skip "  so checks 2-4 still run but do not stand in for the runner"
else
  n="$(printf '%s\n' "$out" | grep -c 'enum-constexpr-conversion' || true)"
  if [ "$n" -ge 1 ]; then
    ok "stock Boost 1.72 fails as it does on the runner ($n enum diagnostics)"
    printf '%s\n' "$out" | grep -o "for the enumeration type '[a-z_]*'" | sort -u | sed 's/^/      /'
  else
    bad "stock headers failed, but not with an enum-constexpr diagnostic:"
    printf '%s\n' "$out" | head -5 | sed 's/^/      /'
    fail=1
  fi
fi

# 2. Patched, with no flags at all.
if "$CXX" -std=gnu++11 -fsyntax-only -I "$WORK/patched" "$WORK/repro.cpp" 2>&1 | sed 's/^/      /'; then
  ok "patched headers compile clean, and next/prior still step (static_asserts)"
else
  bad "patched headers do not compile"
  fail=1
fi

# 3. The pre-C++11 fallback branch must still be the original code.
if "$CXX" -std=gnu++98 -fsyntax-only -I "$WORK/patched" "$WORK/repro.cpp" 2>&1 | sed 's/^/      /'; then
  ok "patched headers compile as C++98 (helper off, original path taken)"
else
  bad "patched headers break the pre-C++11 fallback"
  fail=1
fi

exit "$fail"
