#!/usr/bin/env bash
#
# Build boost in a v142 environment of its own, while the rest of the build
# links v143.
#
# WHAT THE RUNS ACTUALLY SHOWED
#
#   ambient env   user-config            boost
#   -----------   --------------------   -------------------------
#   v142          v142 named as 14.2     built (6 runs, 15445 targets)
#   v143          none                   32/64 name clash
#   v143          v143 named as 14.2     32/64 name clash
#   v143          v142 named as 14.2     32/64 name clash
#
#   error: Name clash for '...\boost_1_72_0\stage\lib\
#            libboost_chrono-vc142-mt-gd-1_72.lib'
#   error: Tried to build the target twice, with property sets having
#   error: these incompatible properties:
#   error:     -  <address-model>32
#   error:     -  <address-model>64
#
# Three different user-configs, one failure. The variable that decides it is
# the ambient environment, not how the compiler is named: b2's project load
# breaks under v143 whatever the user-config says. Three runs were spent
# testing the wrong variable (34984273239, 34986042357, 34987757885).
#
# THE FIX
#
# Give boost the v142 environment it is known to build in, without giving it
# to anything else. boost.py already does exactly this for win_arm64: it
# builds a batch file with its own vcvarsall call and runs that. The win_64
# branch gets the same treatment, calling vcvarsall with -vcvars_ver=14.2 so
# b2 sees one toolset and nothing to disagree about.
#
# The rest of the build keeps the default v143 environment, so the link that
# consumes these libraries is v143 -- older objects under a newer linker,
# which is the direction Microsoft's rule allows and the reason the
# __std_mismatch failures are gone.
#
# vcvarsall's path comes from LIGHTOFFICE_BOOST_VCVARS, set by
# scripts/build_windows.sh. It is NOT taken from config.option("vs-path"):
# build_tools/scripts/config.py only ever fills that in with hardcoded
# "Microsoft Visual Studio/2019/..." paths, which do not exist on a VS 2022
# runner. With the variable unset this patch leaves boost.py alone, so a host
# that does not need the isolation is unaffected.
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
  ok "boost.py already builds win_64 in its own vcvarsall environment"
  exit 0
fi

python3 - "$BOOST_PY" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1:3]
s = open(path, encoding='utf-8').read()

if "import os" not in s:
    sys.exit("boost.py does not import os — not patching blind")

old = ('      base.cmd("bootstrap.bat", [win_boot_arg])\n'
       '      base.cmd("b2.exe", ["headers"])\n'
       '      base.cmd("b2.exe", ["--clean"])\n'
       '      base.cmd("b2.exe", ["--prefix=./../build/win_64", "link=static", '
       '"--with-filesystem", "--with-system", "--with-date_time", "--with-regex", '
       '"--toolset=" + win_toolset, "address-model=64", "install"])\n')

new = (f'      # {mark}: b2 cannot load this project under a v143 environment --\n'
       '      # it ends up with both address models and dies on a 32/64 name\n'
       '      # clash before compiling anything. Give boost the v142 environment\n'
       '      # it builds in, the same way the win_arm64 branch below gives\n'
       '      # itself an arm64 one, and leave the rest of the build on v143 so\n'
       '      # the link that consumes these libraries is the newer toolset.\n'
       '      # See scripts/patch_boost_toolset.sh.\n'
       '      _vcv = os.environ.get("LIGHTOFFICE_BOOST_VCVARS", "")\n'
       '      _b2 = ("b2.exe --prefix=./../build/win_64 link=static '
       '--with-filesystem --with-system --with-date_time --with-regex '
       '--toolset=" + win_toolset + " address-model=64 install")\n'
       '      if _vcv:\n'
       '        print("[lightoffice] boost vcvarsall: " + _vcv)\n'
       '        _bat = []\n'
       '        # chr(34) rather than an escaped quote: this line is emitted by a\n'
       '        # shell heredoc into Python, and counting backslashes through two\n'
       '        # layers of quoting is how the first attempt produced a syntax\n'
       '        # error. No escaping, nothing to miscount.\n'
       '        _q = chr(34)\n'
       '        _bat.append("call " + _q + _vcv + _q + " x64 -vcvars_ver=14.2")\n'
       '        _bat.append("call bootstrap.bat " + win_boot_arg)\n'
       '        _bat.append("call b2.exe headers")\n'
       '        _bat.append("call b2.exe --clean")\n'
       '        _bat.append("call " + _b2)\n'
       '        base.run_as_bat(_bat)\n'
       '      else:\n'
       '        print("[lightoffice] no LIGHTOFFICE_BOOST_VCVARS — building boost "\n'
       '              "in the ambient environment")\n'
       '        base.cmd("bootstrap.bat", [win_boot_arg])\n'
       '        base.cmd("b2.exe", ["headers"])\n'
       '        base.cmd("b2.exe", ["--clean"])\n'
       '        base.cmd("b2.exe", ["--prefix=./../build/win_64", "link=static", '
       '"--with-filesystem", "--with-system", "--with-date_time", "--with-regex", '
       '"--toolset=" + win_toolset, "address-model=64", "install"])\n')

if s.count(old) != 1:
    sys.exit(f"win_64 boost block: found {s.count(old)} matches, expected 1")
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PY

ok "boost.py win_64 now builds under LIGHTOFFICE_BOOST_VCVARS with -vcvars_ver=14.2"
