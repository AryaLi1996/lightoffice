#!/usr/bin/env bash
#
# Chinese text input check (AC 5.4).
#
# A CAVEAT THAT CHANGES WHAT THIS TEST MEANS
# ------------------------------------------
# The criterion asks for xdotool. `xdotool type 中文` does not exercise an input
# method: it remaps a spare keycode to the character's keysym and synthesises a
# key press, delivering the finished character straight to the application. The
# pinyin conversion, the candidate window and the preedit string — everything an
# IME actually does — are bypassed entirely. A test built only on that proves
# the application accepts Unicode, which is a real thing to check but is not
# "Chinese IME works".
#
# So this reports two levels separately and never lets the weaker one stand in
# for the stronger:
#
#   direct   xdotool types Chinese characters; the application must accept,
#            store and render them. Runs anywhere with X and xdotool.
#   ime      keystrokes go through a running input method (ibus/fcitx): latin
#            pinyin in, Chinese characters out. Requires an IME daemon with a
#            Chinese engine configured, so it reports BLOCKED where there is
#            none rather than passing on the direct result.
#
# Usage: scripts/ime_test.sh [--binary PATH] [--display :99] [--text 中文测试]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
DISPLAY_ARG="${DISPLAY:-}"
TEXT="中文输入测试"
OUT="$ROOT/baseline/ime.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --binary) BIN="$2"; shift 2 ;;
    --display) DISPLAY_ARG="$2"; shift 2 ;;
    --text) TEXT="$2"; shift 2 ;;
    --json) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$OUT")"

direct_status=BLOCKED; direct_note=""
ime_status=BLOCKED;    ime_note=""

report() {
  python3 - "$OUT" "$direct_status" "$direct_note" "$ime_status" "$ime_note" "$TEXT" <<'PY'
import json, sys, datetime
out, ds, dn, is_, ino, text = sys.argv[1:7]
doc = {
    "schema": "lightoffice/ime@1",
    "checked": datetime.datetime.now(datetime.timezone.utc)
                .replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    "sample_text": text,
    "direct_unicode_input": {"status": ds, "note": dn},
    "input_method_roundtrip": {"status": is_, "note": ino},
    "caveat": ("xdotool type delivers finished characters via keysym remapping and "
               "bypasses the input method entirely. A passing direct_unicode_input "
               "shows the application handles Chinese text; it does not show that "
               "an IME works."),
}
with open(out, 'w', encoding='utf-8') as fh:
    json.dump(doc, fh, indent=2, ensure_ascii=False)
    fh.write('\n')
print("report:", out)
PY
  echo
  printf '  %-24s %s\n' "direct unicode input" "$direct_status${direct_note:+ — $direct_note}"
  printf '  %-24s %s\n' "input method roundtrip" "$ime_status${ime_note:+ — $ime_note}"
}

# Only a genuine FAIL is a failure. BLOCKED means the prerequisites are absent,
# which is not the same as the application being broken, and must not be turned
# into either a pass or a failure.
exit_status() {
  if [ "$direct_status" = FAIL ] || [ "$ime_status" = FAIL ]; then return 1; fi
  return 0
}
# Report, then exit with the verdict rather than with the last command's status.
finish() { report; exit_status; exit $?; }

# ---------------------------------------------------------- prerequisites ---
if ! command -v xdotool >/dev/null; then
  direct_note="xdotool not installed (scripts/install_deps.sh)"
  ime_note="$direct_note"
  finish
fi
if [ -z "$DISPLAY_ARG" ]; then
  direct_note="no X display; run under Xvfb (Xvfb :99 & DISPLAY=:99)"
  ime_note="$direct_note"
  finish
fi
export DISPLAY="$DISPLAY_ARG"
# Probe the display itself, not its window list: a freshly started Xvfb is
# perfectly usable and has no windows, so requiring one would block on a
# working headless display.
if ! xdotool getdisplaygeometry >/dev/null 2>&1; then
  direct_note="X display $DISPLAY_ARG is not reachable (start one: Xvfb $DISPLAY_ARG -screen 0 1280x1024x24 &)"
  ime_note="$direct_note"
  finish
fi

if [ -z "$BIN" ]; then
  for c in "$(dirname "$ROOT")/out/linux_64/onlyoffice/desktopeditors/DesktopEditors" \
           "${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}/desktop-apps/win-linux/build/linux_64/DesktopEditors"; do
    [ -x "$c" ] && { BIN="$c"; break; }
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  direct_note="no built application; scripts/build_desktop.sh is blocked here (v8 sources unreachable — see scripts/build_desktop.sh --check-only)"
  ime_note="$direct_note"
  finish
fi

# ------------------------------------------------------------ direct input ---
echo "launching $BIN on $DISPLAY"
"$BIN" >/tmp/ime_app.log 2>&1 &
APP=$!
# shellcheck disable=SC2064  # expand APP now: it is the pid we want to kill
trap "kill $APP 2>/dev/null" EXIT

WIN=""
for _ in $(seq 1 30); do
  WIN="$(xdotool search --pid "$APP" --onlyvisible 2>/dev/null | head -1)"
  [ -n "$WIN" ] && break
  sleep 1
done
if [ -z "$WIN" ]; then
  direct_note="application window never appeared within 30s (see /tmp/ime_app.log)"
  ime_note="$direct_note"
  finish
fi

xdotool windowactivate --sync "$WIN" 2>/dev/null
sleep 2
xdotool type --window "$WIN" --delay 120 -- "$TEXT"
sleep 2

# Read the text back rather than trusting that the keystrokes landed. The editor
# paints to a canvas, so the check is against the accessibility tree / clipboard:
# select all, copy, and inspect the X selection.
xdotool key --window "$WIN" --clearmodifiers ctrl+a
sleep 1
xdotool key --window "$WIN" --clearmodifiers ctrl+c
sleep 1
GOT=""
if command -v xclip >/dev/null; then GOT="$(xclip -selection clipboard -o 2>/dev/null || true)"
elif command -v xsel >/dev/null; then GOT="$(xsel --clipboard --output 2>/dev/null || true)"
else
  direct_status=BLOCKED
  direct_note="neither xclip nor xsel is installed, so the typed text cannot be read back; typing it and assuming it arrived would not be a test"
  ime_note="$direct_note"
  finish
fi

if [ -n "$GOT" ] && printf '%s' "$GOT" | grep -qF -- "$TEXT"; then
  direct_status=PASS
  direct_note="the application accepted and returned $TEXT"
else
  direct_status=FAIL
  direct_note="typed '$TEXT' but the document returned '$(printf '%s' "$GOT" | head -c 60)'"
fi

# ----------------------------------------------------------- IME roundtrip ---
IME=""
pgrep -x ibus-daemon >/dev/null 2>&1 && IME=ibus
pgrep -x fcitx5 >/dev/null 2>&1 && IME=fcitx5
pgrep -x fcitx >/dev/null 2>&1 && IME="${IME:-fcitx}"

if [ -z "$IME" ]; then
  ime_note="no ibus/fcitx daemon is running, so pinyin conversion cannot be exercised; the direct check above does NOT cover it"
  finish
fi
if [ "$IME" = ibus ] && command -v ibus >/dev/null; then
  engine="$(ibus engine 2>/dev/null || true)"
  case "$engine" in
    *pinyin*|*chinese*) ;;
    *) ime_note="$IME is running but its active engine is '${engine:-unknown}', not a Chinese one"
       finish ;;
  esac
fi

xdotool windowactivate --sync "$WIN" 2>/dev/null
xdotool key --window "$WIN" --clearmodifiers ctrl+a
xdotool key --window "$WIN" --clearmodifiers Delete
sleep 1
# Latin pinyin in — the IME is what must turn it into Chinese.
xdotool type --window "$WIN" --delay 200 -- "zhongwen"
sleep 2
xdotool key --window "$WIN" --clearmodifiers space
sleep 2
xdotool key --window "$WIN" --clearmodifiers ctrl+a
xdotool key --window "$WIN" --clearmodifiers ctrl+c
sleep 1
GOT2=""
command -v xclip >/dev/null && GOT2="$(xclip -selection clipboard -o 2>/dev/null || true)"
[ -z "$GOT2" ] && command -v xsel >/dev/null && GOT2="$(xsel --clipboard --output 2>/dev/null || true)"

if printf '%s' "$GOT2" | grep -qP '[\x{4e00}-\x{9fff}]'; then
  ime_status=PASS
  ime_note="$IME converted the pinyin to '$(printf '%s' "$GOT2" | head -c 30)'"
else
  ime_status=FAIL
  ime_note="$IME is running but 'zhongwen' produced '$(printf '%s' "$GOT2" | head -c 40)' — no Chinese characters"
fi

finish
