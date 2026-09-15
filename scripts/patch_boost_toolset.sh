#!/usr/bin/env bash
#
# Pin boost's b2 build to the same MSVC toolset that links it.
#
# THE FAILURE (Windows, run 34697916039, 95m41s in):
#
#   libboost_regex-vc142-mt-x64-1_72.lib(instances.obj) : error LNK2019:
#     unresolved external symbol __std_mismatch_1
#   libboost_regex-vc142-mt-x64-1_72.lib(winstances.obj) : error LNK2019:
#     unresolved external symbol __std_mismatch_2
#   ..\build\lib\win_64\HtmlFile2.dll : fatal error LNK1120: 2 unresolved externals
#
# __std_mismatch_1/2 are vectorised-algorithm helpers in the separately
# compiled part of the MSVC STL, present only from the VS 2022 era toolset.
# Everything in this build links v142 deliberately -- vcvarsall runs with
# -vcvars_ver=14.2, Qt is msvc2019_64, and boost.py names its output vc142 --
# yet the boost .lib REFERENCES symbols only the newer STL provides. So boost
# was compiled by a newer toolset than the one linking it, which is exactly
# what Microsoft's binary-compatibility rule forbids: the linking toolset must
# be at least as new as anything it links.
#
# WHY b2 PICKED A DIFFERENT COMPILER
#
# boost.py builds with
#
#   b2.exe ... --toolset=msvc-14.2 ... install
#
# which names a toolset but never pins a compiler PATH. Boost.Build resolves
# "14.2" by looking for a Visual Studio 2019 installation. This runner has no
# VS 2019 -- only VS 2022, carrying both v143 (14.44.35207) and v142
# (14.29.30133) -- so the search fails and b2 falls back to its default, while
# still naming the output vc142 because that is what it was asked for. The
# libraries are labelled v142 and built with v143.
#
# THE FIX
#
# Declare the toolset explicitly, with the path to the v142 cl.exe:
#
#   using msvc : 14.2 : "C:/.../MSVC/14.29.30133/bin/HostX64/x64/cl.exe" ;
#
# in a user-config.jam that boost.py passes to b2 via --user-config. Then
# "14.2" resolves to that exact compiler rather than to whatever b2 finds, the
# libraries are compiled by the toolset they are named for, and the link has
# nothing newer to resolve.
#
# The path is not hardcoded: build_windows.sh derives it from the cl.exe
# already on PATH, which vcvarsall put there. Nothing here assumes a
# particular MSVC point release.
#
# Only the win_64 call site is patched. win_32 and win_arm64 have the same
# shape and the same latent problem, but this project builds neither, and a
# patch that has never run is a patch that is wrong without anyone noticing.
#
# WHY THE CHECK LIVES HERE AND NOT AFTER THE BUILD
#
# The first two attempts at this fix both failed, and neither said so until
# the link step ~70 minutes later:
#
#   34744587536  112m08s  the jam path was an MSYS path b2 could not open
#   34758394050   93m17s  same LNK2019; the post-build check never ran at all,
#                         because the failure it was meant to diagnose aborted
#                         the build before reaching it
#
# So the check runs immediately after b2 installs, where boost is actually
# built (~20 minutes in), and --debug-configuration records which compiler b2
# resolved the toolset to. A check that only executes when the build succeeds
# cannot report the failure it exists for.
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
new = (f'      # {mark}: --toolset names a toolset but pins no compiler path, so\n'
       '      # b2 searches for a VS 2019 install, does not find one on a VS 2022\n'
       '      # runner, and builds with its default while still naming the output\n'
       '      # vc142 -- libraries labelled v142 and compiled by v143. A\n'
       '      # user-config.jam declaring "using msvc : 14.2 : <cl.exe> ;" makes\n'
       '      # 14.2 resolve to the intended compiler. See\n'
       '      # scripts/patch_boost_toolset.sh.\n'
       '      _uc = os.environ.get("LIGHTOFFICE_BOOST_USER_CONFIG", "")\n'
       '      _uc_arg = ["--user-config=" + _uc] if _uc else []\n'
       '      print("[lightoffice] boost user-config: " + (_uc or "<none>"))\n'
       '      if _uc and os.path.isfile(_uc):\n'
       '        print("[lightoffice] " + open(_uc).read().strip())\n'
       '      elif _uc:\n'
       '        print("[lightoffice] WARNING: b2 cannot open that path -- it will be ignored")\n'
       '      # --debug-configuration makes b2 name the compiler each toolset\n'
       '      # actually resolved to. Without it the only evidence that it picked\n'
       '      # the wrong one arrives 70 minutes later as an unresolved symbol.\n'
       '      base.cmd("b2.exe", ["--prefix=./../build/win_64", "link=static", '
       '"--with-filesystem", "--with-system", "--with-date_time", "--with-regex", '
       '"--toolset=" + win_toolset] + _uc_arg + '
       '["--debug-configuration", "address-model=64", "install"])\n'
       '      # Check the toolset HERE, where boost is built, not after the whole\n'
       '      # build. The mismatch surfaces as an LNK2019 about 70 minutes later,\n'
       '      # and because that failure aborts the build the old post-build check\n'
       '      # never ran at all -- it only ever executed when there was nothing\n'
       '      # wrong to report.\n'
       '      _lo_lib = "./../build/win_64/lib/libboost_regex-" + win_vs_version + '
       '"-mt-x64-1_72.lib"\n'
       '      if not base.is_file(_lo_lib):\n'
       '        print("[lightoffice] WARNING: no " + _lo_lib + " to check")\n'
       '      else:\n'
       '        _blob = open(_lo_lib, "rb").read()\n'
       '        _hits = _blob.count(b"__std_mismatch")\n'
       '        _ctl = _blob.count(b"boost")\n'
       '        print("[lightoffice] %s: %d bytes, __std_mismatch=%d, control=%d"\n'
       '              % (_lo_lib, len(_blob), _hits, _ctl))\n'
       '        if 0 == _ctl:\n'
       '          print("[lightoffice] WARNING: the control string is absent, so this")\n'
       '          print("[lightoffice]   check cannot see inside the archive and a")\n'
       '          print("[lightoffice]   zero __std_mismatch count proves nothing")\n'
       '        elif 0 != _hits:\n'
       '          sys.exit("[lightoffice] boost was compiled by a newer toolset than "\n'
       '                   "the one linking it: " + _lo_lib + " references "\n'
       '                   "__std_mismatch_*, which only the VS 2022 era STL "\n'
       '                   "provides, while this build links v142. The "\n'
       '                   "--user-config pin did not take -- see the "\n'
       '                   "--debug-configuration output above for the compiler b2 "\n'
       '                   "actually chose.")\n'
       '        else:\n'
       '          print("[lightoffice] boost matches the linking toolset")\n')

if s.count(old) != 1:
    sys.exit(f"win_64 b2 call: found {s.count(old)} matches, expected 1")
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PY

ok "boost.py win_64 build now accepts --user-config from LIGHTOFFICE_BOOST_USER_CONFIG"
