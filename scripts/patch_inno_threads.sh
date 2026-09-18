#!/usr/bin/env bash
#
# Let Inno Setup use more than one core to compress the installer.
#
# THE PROBLEM, measured rather than guessed. Run 35238369724 printed the phase
# timings this build had been collecting all along:
#
#   === phase end:   make.py (8917s)      <- 149 minutes, the entire compile
#   === phase end:   make.ps1 (22s)
#   === phase begin: make_inno.ps1        <- no matching end
#
# and the runner's cleanup named what was still alive when the 340 minute step
# timeout fired:
#
#   Terminate orphan process: pid (1680) (ISCC)
#
# So compilation is not the problem and has not been for a while. ISCC is: it
# had been running for over 190 minutes and had not finished. A GitHub-hosted
# job is capped at 360 minutes and that cap cannot be raised, so 149 + 190 does
# not fit however the step timeout is arranged.
#
# common.iss asks for lzma2/ultra64 with SolidCompression=yes over a payload of
# about a gigabyte. Inno's LZMA2 can compress in parallel, but only when told:
# LZMANumBlockThreads defaults to 1, so all four of the runner's cores but one
# sit idle for those three hours.
#
# Setting it to 4 keeps the compression level exactly as upstream chose it.
# Block-parallel LZMA2 costs a little ratio -- the stream is split so blocks can
# be worked on independently -- so the installer grows slightly. It does not
# change what is in the installer, which is the part that matters here: this
# ships the same product at the same compression setting, just built on four
# cores instead of one.
#
# Applied to every .iss that sets an lzma2 compression, so common.iss (the one
# make_inno.ps1 builds) and help.iss stay consistent rather than drifting.
#
# Usage: scripts/patch_inno_threads.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
THREADS="${LIGHTOFFICE_ISCC_THREADS:-4}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

case "$THREADS" in
  ''|*[!0-9]*) bad "LIGHTOFFICE_ISCC_THREADS must be a number, got '$THREADS'"; exit 1 ;;
esac

INNO_DIR="$SRC/desktop-apps/package/inno"
[ -d "$INNO_DIR" ] || { warn "no $INNO_DIR — nothing to patch"; exit 0; }

patched=0
for f in "$INNO_DIR"/*.iss; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*Compression=lzma2' "$f" || continue

  if grep -qE '^[[:space:]]*LZMANumBlockThreads=' "$f"; then
    # Already there: make it say what we want rather than leaving whatever
    # value a previous run or an upstream change left behind.
    current="$(grep -oE '^[[:space:]]*LZMANumBlockThreads=[0-9]+' "$f" | grep -oE '[0-9]+$' | head -1)"
    if [ "$current" = "$THREADS" ]; then
      ok "$(basename "$f"): LZMANumBlockThreads=$THREADS already"
      patched=$((patched + 1))
      continue
    fi
    sed -i -E "s/^([[:space:]]*)LZMANumBlockThreads=[0-9]+/\\1LZMANumBlockThreads=$THREADS/" "$f"
    ok "$(basename "$f"): LZMANumBlockThreads $current -> $THREADS"
  else
    sed -i -E "s/^([[:space:]]*)(Compression=lzma2.*)$/\\1\\2\n\\1LZMANumBlockThreads=$THREADS/" "$f"
    ok "$(basename "$f"): LZMANumBlockThreads=$THREADS added"
  fi
  patched=$((patched + 1))
done

if [ "$patched" -eq 0 ]; then
  warn "no .iss in $INNO_DIR sets Compression=lzma2 — nothing patched"
  exit 0
fi

# Prove it, per file. A silently unpatched common.iss is a three hour ISCC run
# and a timeout, which is the most expensive way to find out.
rc=0
for f in "$INNO_DIR"/*.iss; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*Compression=lzma2' "$f" || continue
  if ! grep -qE "^[[:space:]]*LZMANumBlockThreads=${THREADS}[[:space:]]*$" "$f"; then
    bad "$(basename "$f") still has no LZMANumBlockThreads=$THREADS"
    rc=1
  fi
done
[ "$rc" -eq 0 ] || exit 1
ok "$patched .iss file(s) will compress on $THREADS threads"
exit 0
