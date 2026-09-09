#!/usr/bin/env bash
#
# Let a v8 that is already built be left alone.
#
# v8_89.py guards the Windows build on the artefact existing:
#
#     if not base.is_file("out.gn/win_64/release/obj/v8_monolith.lib"):
#       ninja_windows_make(gn_args)
#
# ...and four such guards exist for the win_* platforms. The linux_64 path has
# none: it runs `gn gen` and `ninja` unconditionally, every time. ninja is
# incremental so a warm tree costs only seconds — but it means the object files
# in out.gn/linux_64/obj can never be deleted, because ninja would rebuild all
# 2929 targets without them. Those objects are the bulk of a 24 GB prebuilt
# image, and that size is paid twice on every release run: once pulling the
# image and once copying the tree out of it.
#
# This adds the same guard upstream already uses on Windows, so the image can
# keep libv8_monolith.a and drop the intermediates.
#
# Marker-fenced and idempotent, like the other overlay patches. A drifted
# anchor exits 1 rather than silently leaving the build unguarded.
#
# Usage: scripts/patch_v8_incremental.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-OVERLAY"
V8PY="$SRC/build_tools/scripts/core_common/modules/v8_89.py"

info() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[33m·\033[0m %s (already applied)\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$V8PY" ] || fail "v8_89.py not found at $V8PY (is build_tools cloned?)"

if grep -qF "$MARK-v8-incremental" "$V8PY"; then
  skip "v8 linux_64 build guard"
  exit 0
fi

python3 - "$V8PY" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8').read()

old = ('      base.cmd2("gn", ["gen", "out.gn/linux_64", make_args(gn_args, "linux")], False)\n'
       '      base.cmd2("ninja", ["-C", "out.gn/linux_64"], False)\n')
new = ('      # ' + mark + '-v8-incremental: mirror the guard the win_* paths\n'
       '      # already use, so a prebuilt image can drop out.gn intermediates.\n'
       '      if not base.is_file("out.gn/linux_64/obj/libv8_monolith.a"):\n'
       '        base.cmd2("gn", ["gen", "out.gn/linux_64", make_args(gn_args, "linux")], False)\n'
       '        base.cmd2("ninja", ["-C", "out.gn/linux_64"], False)\n'
       '      else:\n'
       '        print("v8: libv8_monolith.a present, skipping gn/ninja")\n')

if old not in src:
    print('anchor-not-found', file=sys.stderr)
    sys.exit(1)
open(path, 'w', encoding='utf-8').write(src.replace(old, new, 1))
PY

info "v8 linux_64 build guarded on libv8_monolith.a"
