#!/usr/bin/env bash
#
# Give b2 exactly one msvc configuration.
#
# boost.py builds with
#
#   b2.exe ... --toolset=msvc-14.2 ... install
#
# which names a toolset but pins no compiler. Boost.Build then auto-configures
# msvc by searching the machine. On a VS 2022 runner whose environment is the
# v143 toolset that search finds more than one usable configuration, and the
# build dies before it compiles anything:
#
#   error: Name clash for '...\boost_1_72_0\stage\lib\
#            libboost_chrono-vc142-mt-gd-1_72.lib'
#   error: Tried to build the target twice, with property sets having
#   error: these incompatible properties:
#   error:     -  <address-model>32
#   error:     -  <address-model>64
#
# (run 34984273239, 4m39s in). A user-config.jam naming one compiler leaves b2
# nothing to search for and nothing to disagree with.
#
# WHY THE COMPILER IS THE v143 ONE UNDER THE NAME 14.2
#
# The whole Windows build links with the default v143 toolset, because
# Microsoft's rule is that the linker must be at least as new as everything it
# links -- see .github/workflows/build.yml. boost must therefore compile with
# v143 too.
#
# But the NAME has to stay vc142: core/Common/3dParty/boost/boost.pri sets
# "vs2019:VS_VERSION=142" and builds its -llibboost_*-vc142-mt-x64-1_72 link
# flags from it, so that is the filename core searches for. b2 takes the
# filename from the toolset version it was asked for, not from the compiler.
#
# So "14.2" here is a label, and the compiler behind it is whichever cl.exe the
# environment already selected. The libraries are named vc142, which is what
# core looks for, and built by v143, which is what links them.
#
# Only the win_64 call site is patched. win_32 and win_arm64 have the same
# shape, but this project builds neither, and a patch that has never run is a
# patch that is wrong without anyone noticing.
#
# Idempotent: marker-fenced, re-running finds nothing to do.
#
# Usage: scripts/patch_boost_toolset.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-BOOST-TOOLSET"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

[ -d "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

BOOST_PY="$SRC/build_tools/scripts/core_common/modules/boost.py"
[ -f "$BOOST_PY" ] || { warn "no $BOOST_PY — nothing to patch"; exit 0; }

if grep -q "$MARK" "$BOOST_PY"; then
  ok "boost.py already honours LIGHTOFFICE_BOOST_USER_CONFIG"
  exit 0
fi

python3 - "$BOOST_PY" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1:3]
s = open(path, encoding='utf-8').read()

if "import os" not in s:
    sys.exit("boost.py does not import os — not patching blind")

old = ('      base.cmd("b2.exe", ["--prefix=./../build/win_64", "link=static", '
       '"--with-filesystem", "--with-system", "--with-date_time", "--with-regex", '
       '"--toolset=" + win_toolset, "address-model=64", "install"])\n')
new = (f'      # {mark}: --toolset names a toolset but pins no compiler, so b2\n'
       '      # searches the machine and, on a VS 2022 runner, finds more than one\n'
       '      # usable configuration -- which fails as a 32/64 name clash before\n'
       '      # anything compiles. A user-config naming one compiler settles it.\n'
       '      # See scripts/patch_boost_toolset.sh.\n'
       '      _uc = os.environ.get("LIGHTOFFICE_BOOST_USER_CONFIG", "")\n'
       '      _uc_arg = ["--user-config=" + _uc] if _uc else []\n'
       '      print("[lightoffice] boost user-config: " + (_uc or "<none>"))\n'
       '      base.cmd("b2.exe", ["--prefix=./../build/win_64", "link=static", '
       '"--with-filesystem", "--with-system", "--with-date_time", "--with-regex", '
       '"--toolset=" + win_toolset] + _uc_arg + ["address-model=64", "install"])\n')

if s.count(old) != 1:
    sys.exit(f"win_64 b2 call: found {s.count(old)} matches, expected 1")
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PY

ok "boost.py win_64 build now accepts --user-config from LIGHTOFFICE_BOOST_USER_CONFIG"
