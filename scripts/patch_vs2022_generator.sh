#!/usr/bin/env bash
#
# Teach build_tools' CMake modules that the runner has VS 2022, not VS 2019.
#
# THE FAILURE (Windows, run 34672136278, 94 minutes in):
#
#   [fetch & build]: heif
#   Cloning into 'x265_git'...
#   CMake Error at CMakeLists.txt:19 (project):
#     Generator
#       Visual Studio 16 2019
#     could not find any instance of Visual Studio.
#
# This is the third instance of one theme, and worth naming: every Windows
# path in this 2019-era tree hardcodes VS 2019 and has no branch for anything
# newer.
#
#   boost.py          msvc-14.0 / msvc-14.2, no vc143
#   v8_89             vs_toolchain.py accepts only 2017 and 2019
#   heif.py           CMake generator "Visual Studio 16 2019"
#   ixwebsocket.py    the same string, built by hand
#
# The first two are already handled -- boost by selecting the v142 toolset in
# vcvarsall, V8 by pointing its own vs2019_install hatch at the 2022 install.
# Neither helps here: CMake's VS generator resolves a real Visual Studio
# instance by version, and vs2019_install is a gyp/Chromium convention CMake
# knows nothing about. There is no VS 2019 on this runner to find.
#
# WHAT THIS DOES
#
# Makes the generator configurable instead of hardcoded, and has the workflow
# ask for "Visual Studio 17 2022" with "-T v142".
#
# The toolset matters and is not a detail. VS 2022 ships both v143 and v142
# (14.44.35207 and 14.29.30133 on this runner), and everything else in the
# build is already on v142: vcvarsall selected it, Qt is msvc2019_64, and
# boost.py builds vc142 libraries. Letting CMake default to v143 here would
# mix toolsets inside one binary. "-T v142" keeps x265 on the same one.
#
# Two env vars rather than an edit per call site, so the same override reaches
# every module and the workflow stays the single place that names a version:
#
#   LIGHTOFFICE_VS_GENERATOR   the version string, e.g. "17 2022"
#   LIGHTOFFICE_VS_TOOLSET     the toolset, e.g. "v142" (optional)
#
# Unset, both modules behave exactly as they do today.
#
# ixwebsocket.py also gets a second fix it needs independently: for win_64 it
# builds the generator as "Visual Studio <ver> Win64". That trailing Win64 was
# how CMake spelled 64-bit up to "Visual Studio 14 2015 Win64"; from the VS16
# generator on, CMake rejects it and the architecture is "-A x64" instead. So
# the string is already wrong for the 2019 value it has today, and would still
# be wrong for 2022. Switch it to -A x64, matching what heif.py already does.
#
# Idempotent: marker-fenced, re-running finds nothing to do.
#
# Usage: scripts/patch_vs2022_generator.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-VS2022-GENERATOR"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

[ -d "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

MODULES="$SRC/build_tools/scripts/core_common/modules"
[ -d "$MODULES" ] || { warn "no $MODULES — nothing to patch"; exit 0; }

python3 - "$MODULES" "$MARK" <<'PY'
import sys, os
modules, mark = sys.argv[1:3]

heif = os.path.join(modules, "heif.py")
ixws = os.path.join(modules, "ixwebsocket.py")

changed = []

# ---- heif.py (x265, libde265, libheif) --------------------------------------
if os.path.isfile(heif):
    s = open(heif, encoding='utf-8').read()
    if mark in s:
        print("  heif.py already patched")
    else:
        old_fn = (
            'def get_vs_version():\n'
            '  vs_version = "14 2015"\n'
            '  if config.option("vs-version") == "2019":\n'
            '    vs_version = "16 2019"\n'
            '  return vs_version\n'
        )
        new_fn = (
            'def get_vs_version():\n'
            '  vs_version = "14 2015"\n'
            '  if config.option("vs-version") == "2019":\n'
            '    vs_version = "16 2019"\n'
            f'  # {mark}: CMake resolves a real VS instance by generator\n'
            '  # version, and this runner has only 2022. See\n'
            '  # scripts/patch_vs2022_generator.sh.\n'
            '  return os.environ.get("LIGHTOFFICE_VS_GENERATOR", vs_version)\n'
        )
        old_args = (
            '    cmake_args_ext = [\n'
            '      "-G", f"Visual Studio {get_vs_version()}"\n'
            '    ]\n'
        )
        new_args = (
            '    cmake_args_ext = [\n'
            '      "-G", f"Visual Studio {get_vs_version()}"\n'
            '    ]\n'
            f'    # {mark}: keep x265 on the same toolset as vcvarsall, Qt and\n'
            '    # boost. VS 2022 ships v143 and v142; defaulting would pick v143\n'
            '    # and mix toolsets inside one binary.\n'
            '    _toolset = os.environ.get("LIGHTOFFICE_VS_TOOLSET")\n'
            '    if _toolset:\n'
            '      cmake_args_ext += ["-T", _toolset]\n'
        )
        for name, old in (("get_vs_version", old_fn), ("cmake_args_ext", old_args)):
            if s.count(old) != 1:
                sys.exit(f"heif.py {name}: found {s.count(old)} matches, expected 1")
        if "import os" not in s:
            sys.exit("heif.py does not import os — not patching blind")
        s = s.replace(old_fn, new_fn).replace(old_args, new_args)
        open(heif, 'w', encoding='utf-8').write(s)
        changed.append("heif.py")
else:
    print("  no heif.py")

# ---- ixwebsocket.py ---------------------------------------------------------
if os.path.isfile(ixws):
    s = open(ixws, encoding='utf-8').read()
    if mark in s:
        print("  ixwebsocket.py already patched")
    else:
        old = (
            '    vsVersion = "14 2015"\n'
            '    if (config.option("vs-version") == "2019"):\n'
            '      vsVersion = "16 2019"\n'
        )
        new = (
            '    vsVersion = "14 2015"\n'
            '    if (config.option("vs-version") == "2019"):\n'
            '      vsVersion = "16 2019"\n'
            f'    # {mark}: see scripts/patch_vs2022_generator.sh\n'
            '    vsVersion = os.environ.get("LIGHTOFFICE_VS_GENERATOR", vsVersion)\n'
            '    vsToolset = os.environ.get("LIGHTOFFICE_VS_TOOLSET")\n'
            '    vsExtra = ["-T", vsToolset] if vsToolset else []\n'
        )
        # The trailing " Win64" is how CMake spelled 64-bit up to the VS14
        # generator; VS16 and later reject it and want -A x64.
        old64 = (
            '      build_arch("windows", "win_64", ["-G","Visual Studio " + vsVersion + " Win64"])\n'
            '      build_arch("windows_debug", "win_64", ["-G","Visual Studio " + vsVersion + " Win64"], True)\n'
        )
        new64 = (
            '      build_arch("windows", "win_64", ["-G","Visual Studio " + vsVersion, "-A", "x64"] + vsExtra)\n'
            '      build_arch("windows_debug", "win_64", ["-G","Visual Studio " + vsVersion, "-A", "x64"] + vsExtra, True)\n'
        )
        for name, o in (("vsVersion", old), ("win_64 generator", old64)):
            if s.count(o) != 1:
                sys.exit(f"ixwebsocket.py {name}: found {s.count(o)} matches, expected 1")
        if "import os" not in s:
            sys.exit("ixwebsocket.py does not import os — not patching blind")
        s = s.replace(old, new).replace(old64, new64)
        open(ixws, 'w', encoding='utf-8').write(s)
        changed.append("ixwebsocket.py")
else:
    print("  no ixwebsocket.py")

print("PATCHED:" + ",".join(changed) if changed else "PATCHED:")
PY

ok "CMake VS generator is overridable via LIGHTOFFICE_VS_GENERATOR / _TOOLSET"
