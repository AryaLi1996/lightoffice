#!/usr/bin/env bash
#
# Make upstream's desktop-apps sources compile against a modern system Qt.
#
# Upstream builds against a PREBUILT Qt 5.9.9 that it fetches itself. We build
# against the distro Qt (5.15 on Ubuntu 24.04) via use_system_qt.py, because the
# prebuilt Qt is LFS-tracked and unavailable on an anonymous git lane. Three
# upstream sources do not compile in that combination. None of these are our
# code and none are behaviour changes — they are the same class of problem as
# the v8 <cstdint> patches in build_desktop.sh: source written for an older
# toolchain, built with a newer one.
#
# Every edit is fenced with a LIGHTOFFICE marker and anchored on an exact
# upstream line, so this is idempotent and a drifted anchor is reported rather
# than silently skipped.
#
# Usage: scripts/patch_qt_compat.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
MARK="LIGHTOFFICE-OVERLAY"
WL="$SRC/desktop-apps/win-linux"

info()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip()  { printf '  \033[33m·\033[0m %s (already applied)\n' "$*"; }
drift() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; DRIFTED=$((DRIFTED + 1)); }

DRIFTED=0
[ -d "$WL/src" ] || { printf 'not an ONLYOFFICE checkout: %s\n' "$SRC" >&2; exit 1; }

echo "Applying Qt compatibility patches -> $WL"

# Insert TEXT immediately after the line matching ANCHOR in FILE, once.
insert_after() {
  local file="$1" anchor="$2" text="$3" label="$4"
  if ! [ -f "$file" ]; then drift "$label: file missing ($file)"; return; fi
  if grep -qF "$MARK" "$file" && grep -qF "${text%%$'\n'*}" "$file"; then
    skip "$label"; return
  fi
  if ! grep -qxF "$anchor" "$file"; then
    drift "$label: anchor-not-found -> $anchor"; return
  fi
  python3 - "$file" "$anchor" "$text" <<'PY'
import sys
path, anchor, text = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8', errors='surrogateescape').read().split('\n')
out = []
for line in lines:
    out.append(line)
    if line == anchor:
        out.extend(text.split('\n'))
        anchor = None          # first occurrence only
open(path, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))
PY
  info "$label"
}

# 1. QPainterPath ------------------------------------------------------------
# paintEvent() declares a QPainterPath but includes only <QPainter>. Through Qt
# 5.14 qpainter.h pulled qpainterpath.h in transitively; 5.15 stopped, so the
# type is incomplete:
#   cwindowplatform.cpp:188: error: aggregate 'QPainterPath path' has
#   incomplete type and cannot be defined
insert_after \
  "$WL/src/windows/platform_linux/cwindowplatform.cpp" \
  '#include <QPainter>' \
  "#include <QPainterPath>  // $MARK: Qt 5.15 no longer pulls this in via <QPainter>" \
  "cwindowplatform.cpp: explicit <QPainterPath>"

# 2. QDesktopWidget ----------------------------------------------------------
# The Linux branch of the same file calls QApplication::desktop() with no
# version guard, but upstream includes <QDesktopWidget> only under
#   #if QT_VERSION < QT_VERSION_CHECK(5, 11, 0)
# so on any Qt >= 5.11 the type is incomplete. QDesktopWidget is deprecated
# from 5.11 but present through the whole Qt 5 series, so including it
# unconditionally is the minimal fix and changes no behaviour. (Qt 6 removes
# it; a Qt 6 port would have to move this code to QScreen.)
#
# Placed next to the other Qt includes rather than at the top of the file on
# purpose: this translation unit later includes gtk headers, and pulling Qt in
# ahead of them triggers the `signals` collision that patch 3 is about.
insert_after \
  "$WL/src/utils.cpp" \
  '#include <QScreen>' \
  "#include <QDesktopWidget>  // $MARK: used unguarded below; upstream includes it only for Qt < 5.11" \
  "utils.cpp: unconditional <QDesktopWidget>"

# 3. glib's `signals` vs Qt's `signals` --------------------------------------
# Qt defines `signals` as a macro expanding to `public`. glib's
# gio/gdbusintrospection.h declares a struct member literally named `signals`:
#     GDBusSignalInfo **signals;
# cthemes.cpp includes cthemes.h (which pulls Qt) BEFORE the gtk/gio headers,
# so by the time glib is parsed the macro is live and the member declaration
# becomes `GDBusSignalInfo **public ...`:
#     qobjectdefs.h:93: error: expected unqualified-id before 'public'
# Undefining the macro across the glib includes and restoring it afterwards is
# the standard remedy; Q_SIGNALS is Qt's own non-colliding spelling, so the
# restore is exact and `signals:` sections later in the file still work.
CTHEMES="$WL/src/cthemes.cpp"
if [ ! -f "$CTHEMES" ]; then
  drift "cthemes.cpp: file missing"
elif grep -qF "$MARK: glib declares a struct member named \`signals\`" "$CTHEMES"; then
  skip "cthemes.cpp: shield glib from Qt's signals macro"
elif ! grep -qxF '# include <gtk/gtk.h>' "$CTHEMES"; then
  drift "cthemes.cpp: anchor-not-found -> # include <gtk/gtk.h>"
else
  python3 - "$CTHEMES" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8', errors='surrogateescape').read()
old = '# include <gtk/gtk.h>\n# include <gio/gio.h>\n# include <glib.h>\n'
new = ('# undef signals  // %s: glib declares a struct member named `signals`\n'
       '# include <gtk/gtk.h>\n# include <gio/gio.h>\n# include <glib.h>\n'
       '# define signals Q_SIGNALS  // %s: restore Qt\'s keyword\n') % (mark, mark)
assert old in s, 'glib include block not found'
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s.replace(old, new, 1))
PY
  info "cthemes.cpp: shield glib from Qt's signals macro"
fi

echo
if [ "$DRIFTED" -gt 0 ]; then
  printf '\033[31m%d patch(es) did not apply — upstream moved.\033[0m\n' "$DRIFTED" >&2
  printf 'Re-target the anchors above against the pinned tree before building.\n' >&2
  exit 1
fi
echo "Qt compatibility patches applied."
