#!/usr/bin/env bash
#
# Make the Windows openssl build usable: give it a real vcvarsall, and stop it
# failing silently.
#
# THE FAILURE (run 34991067915, 94m23s in -- past boost, past the HtmlFile2.dll
# link that stopped every earlier attempt):
#
#   hash.cpp(7): fatal error C1083: Cannot open include file: 'openssl/sha.h'
#     -IC:/lightoffice/src/core/Common/3dParty/openssl/build/win_64/lib/../include
#
# openssl.py's win_64 branch builds a batch file
#
#   call "<config.option('vs-path')>/vcvarsall.bat" x64
#   perl Configure VC-WIN64A --prefix=...\build\win_64 ... no-shared no-asm
#   call nmake clean
#   call nmake build_libs install
#
# and runs it with base.run_as_bat(qmake_bat, True) -- where True is
# is_no_errors. So whatever went wrong went wrong about eighty minutes before
# anything needed the headers, and said nothing.
#
# Two changes, both narrow:
#
# 1. vcvarsall comes from LIGHTOFFICE_VCVARS when set. config.option("vs-path")
#    is not usable here: build_tools/scripts/config.py fills it in with
#    hardcoded "Microsoft Visual Studio/2019/..." paths, and this runner has
#    2022. That is the same root cause as the boost vcvarsall problem.
#
# 2. is_no_errors goes away for win_64, so a failing openssl stops the build
#    where it breaks instead of eighty minutes later in an unrelated file.
#
# Whether (1) is the actual cause is NOT established. The ambient environment
# is already correct by the time make.py runs -- build.yml's MSVC setup step
# exports PATH/INCLUDE/LIB/LIBPATH -- so a `call` to a path that does not exist
# may well be harmless, and openssl may be failing for some other reason
# entirely. (2) is what settles it, and it is the reason to run this at all:
# the next failure names itself.
#
# Only the win_64 branch is touched. win_32, win_arm64 and win_64_xp have the
# same shape and the same latent problem, but this project builds none of them.
#
# Idempotent: marker-fenced, re-running finds nothing to do.
#
# Usage: scripts/patch_openssl_vcvars.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-OPENSSL-VCVARS"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

[ -d "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

SSL_PY="$SRC/build_tools/scripts/core_common/modules/openssl.py"
[ -f "$SSL_PY" ] || { warn "no $SSL_PY — nothing to patch"; exit 0; }

if grep -q "$MARK" "$SSL_PY"; then
  ok "openssl.py already honours LIGHTOFFICE_VCVARS"
  exit 0
fi

python3 - "$SSL_PY" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1:3]
s = open(path, encoding='utf-8').read()

if "import os" not in s:
    s = s.replace("import config", "import os\nimport config", 1)
    if "import os" not in s:
        sys.exit("openssl.py has no import config to anchor an os import to")

# The x64 vcvarsall line is byte-identical in the win_64 and win_64_xp
# branches (lines 44 and 73), so the following perl Configure line is part
# of the anchor: only win_64's names \\build\\win_64 without a suffix.
old_call = ('      qmake_bat.append("call \\"" + config.option("vs-path") + '
            '"/vcvarsall.bat\\" x64")      \n'
            '      qmake_bat.append("perl Configure VC-WIN64A --prefix=" + '
            'old_cur_dir + "\\\\build\\\\win_64 --openssldir=" + old_cur_dir + '
            '"\\\\build\\\\win_64 no-shared no-asm enable-md2")\n')
new_call = (f'      # {mark}: config.option("vs-path") is filled in by\n'
            '      # build_tools/scripts/config.py with hardcoded "Microsoft Visual\n'
            '      # Studio/2019/..." paths, which do not exist on a VS 2022 runner.\n'
            '      # See scripts/patch_openssl_vcvars.sh.\n'
            '      _vcv = os.environ.get("LIGHTOFFICE_VCVARS", "")\n'
            '      if not _vcv:\n'
            '        _vcv = config.option("vs-path") + "/vcvarsall.bat"\n'
            '      print("[lightoffice] openssl vcvarsall: " + _vcv)\n'
            '      qmake_bat.append("call " + chr(34) + _vcv + chr(34) + " x64")\n'
            '      qmake_bat.append("perl Configure VC-WIN64A --prefix=" + '
            'old_cur_dir + "\\\\build\\\\win_64 --openssldir=" + old_cur_dir + '
            '"\\\\build\\\\win_64 no-shared no-asm enable-md2")\n')

if s.count(old_call) != 1:
    sys.exit(f"openssl win_64 vcvarsall call: found {s.count(old_call)} matches, expected 1")
s = s.replace(old_call, new_call)

# Only the win_64 run_as_bat: it is the first one in the windows block.
old_run = ('      qmake_bat.append("call nmake build_libs install")\n'
           '      base.run_as_bat(qmake_bat, True)\n'
           '    if (-1 != config.option("platform").find("win_32"))')
new_run = ('      qmake_bat.append("call nmake build_libs install")\n'
           '      # is_no_errors dropped: openssl failing quietly here surfaced\n'
           '      # eighty minutes later as a missing openssl/sha.h in doctrenderer.\n'
           '      base.run_as_bat(qmake_bat)\n'
           '    if (-1 != config.option("platform").find("win_32"))')

if s.count(old_run) != 1:
    sys.exit(f"openssl win_64 run_as_bat: found {s.count(old_run)} matches, expected 1")
open(path, 'w', encoding='utf-8').write(s.replace(old_run, new_run))
PY

ok "openssl.py win_64 uses LIGHTOFFICE_VCVARS and no longer ignores its own errors"
