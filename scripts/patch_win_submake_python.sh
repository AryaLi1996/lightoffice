#!/usr/bin/env bash
#
# Invoke build_tools' nested make.py scripts through the Python interpreter,
# so they also run on Windows.
#
# THE FAILURE (Windows, run 34689794318, 99 minutes in):
#
#   C:\lightoffice\src\core\DesktopEditor\freetype-2.10.4\src\sfnt\sfwoff2.c(27):
#     fatal error C1083: Cannot open include file: 'brotli/decode.h':
#     No such file or directory
#   NMAKE : fatal error U1077: '"...\MSVC\14.29.30133\bin\HostX64\x64\cl.EXE"'
#
# Not a missing include path -- the compile line already carries
#
#   -IC:/lightoffice/src/core/Common/3dParty/brotli/brotli/c/include
#
# and FT_CONFIG_OPTION_USE_BROTLI is defined, so brotli.pri was wired in
# correctly. The directory simply does not exist: brotli was never fetched.
#
# WHY IT WAS NEVER FETCHED
#
# What the log shows, verbatim and in order:
#
#   [fetch & build]: harfbuzz     <- banner, then nothing at all
#   [fetch]: hyphen
#   Cloning into 'hyphen'...
#   [fetch]: googletest
#   Cloning into 'googletest'...
#   [fetch & build]: brotli       <- banner, then nothing at all
#   [fetch & build]: heif
#   Cloning into 'x265_git'...
#
# Exactly two modules produce no output and clone nothing, and they are exactly
# the two that invoke their nested fetch as a bare path:
#
#   v8.py         base.cmd_in_dir(dir, "python", ["./make.py"])    clones
#   hunspell.py   base.cmd("python", ["./make.py", ...])           clones
#   harfbuzz.py   base.cmd_in_dir(dir, "./make.py")                silent
#   oo_brotli.py  base.cmd_in_dir(dir, "./make.py")                silent
#
# "./make.py" is a POSIX shebang invocation. base.cmd turns it into
# `cmd.exe /c .\make.py` on Windows (get_path swaps the separator, shell=True),
# which depends on .PY file association and shebang handling rather than on
# anything the build controls.
#
# What is NOT pinned down: base.cmd exits the build on a non-zero return, and
# no error appeared, so whatever happened returned 0 while doing nothing. The
# precise Windows-side mechanism for that is not reproducible from here -- this
# is a Linux container with no Windows shell -- and the fix does not depend on
# knowing it: passing the interpreter explicitly removes the dependency on
# shells, file associations and shebangs altogether.
#
# The build then runs for another 90 minutes before freetype needs a header
# that was never downloaded.
#
# build_tools is inconsistent about this, and the portable form is already in
# the tree, so this is not an invention:
#
#   v8.py       base.cmd_in_dir(dir, "python", ["./make.py"])     portable
#   hunspell.py base.cmd("python", ["./make.py", ...])            portable
#   harfbuzz.py base.cmd_in_dir(dir, "./make.py")                 POSIX only
#   oo_brotli.py  same                                            POSIX only
#
# So harfbuzz has the identical bug and is the next wall after brotli. Both are
# fixed here rather than one at a time, for the same reason grunt was installed
# on Windows before Windows had reached the JS stage: each discovery costs a
# 90-minute run.
#
# sys.executable rather than the string "python": it is the interpreter already
# running the build, so it cannot resolve to a different or absent one. Both
# modules already `import sys`.
#
# WHY ONLY WINDOWS
#
# Linux restores a prebuilt tree and fetch_prebuilts.sh skips the fetch stage,
# so these modules never run there. macOS clones fresh but is POSIX, where
# "./make.py" works -- and macOS does build. Windows is the only platform that
# both runs the fetch and cannot execute a shebang.
#
# Idempotent: marker-fenced, re-running finds nothing to do.
#
# Usage: scripts/patch_win_submake_python.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-WIN-SUBMAKE-PYTHON"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

[ -d "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

MODULES="$SRC/build_tools/scripts/core_common/modules"
[ -d "$MODULES" ] || { warn "no $MODULES — nothing to patch"; exit 0; }

python3 - "$MODULES" "$MARK" <<'PY'
import sys, os
modules, mark = sys.argv[1:3]

targets = {
    "oo_brotli.py": "/../../core/Common/3dParty/brotli",
    "harfbuzz.py":  "/../../core/Common/3dParty/harfbuzz",
}

changed, already = [], []
for fname, subdir in targets.items():
    path = os.path.join(modules, fname)
    if not os.path.isfile(path):
        print(f"  no {fname}")
        continue
    s = open(path, encoding='utf-8').read()
    if mark in s:
        already.append(fname)
        continue

    old = (f'  base.cmd_in_dir(base.get_script_dir() + "{subdir}", "./make.py")\n')
    new = (
        f'  # {mark}: "./make.py" is a POSIX shebang invocation and does nothing\n'
        f'  # on Windows, so this fetch silently never ran and freetype failed 90\n'
        f'  # minutes later on a missing header. sys.executable is the interpreter\n'
        f'  # already running the build. See scripts/patch_win_submake_python.sh.\n'
        f'  base.cmd_in_dir(base.get_script_dir() + "{subdir}", sys.executable, ["./make.py"])\n'
    )
    if s.count(old) != 1:
        sys.exit(f"{fname}: found {s.count(old)} matches for the fetch call, expected 1")
    if "import sys" not in s:
        sys.exit(f"{fname} does not import sys — not patching blind")
    open(path, 'w', encoding='utf-8').write(s.replace(old, new))
    changed.append(fname)

for f in already:
    print(f"  {f} already patched")
if changed:
    print("  patched: " + ", ".join(changed))
PY

ok "brotli and harfbuzz fetches now run through the Python interpreter"
