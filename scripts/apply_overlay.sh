#!/usr/bin/env bash
#
# Apply the LightOffice customisation overlay onto a checked-out ONLYOFFICE tree.
#
# The overlay is deliberately additive and idempotent: every edit is fenced with
# a LIGHTOFFICE marker, so running this twice is a no-op and `git diff` in the
# upstream tree shows exactly what we changed. Nothing here forks upstream files
# wholesale — that keeps rebasing onto a new ONLYOFFICE release cheap.
#
# Usage: scripts/apply_overlay.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
OVERLAY="$ROOT/overlay"
MARK="LIGHTOFFICE-OVERLAY"

# Anchors that no longer match upstream. Counted rather than fatal on first hit,
# so a rebase reports every patch that needs re-targeting in one run.
DRIFTED=0

info() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
drift() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; DRIFTED=$((DRIFTED + 1)); }
skip() { printf '  \033[33m·\033[0m %s (already applied)\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Copy SRC to DST only when the content differs.
#
# `install` always rewrites, which always bumps the mtime. On a prebuilt tree
# that is expensive out of all proportion: grunt and make key off mtimes, so
# re-installing a byte-identical logo invalidates the whole web-apps/sdkjs JS
# build the image already did, and a release run pays ~25 minutes to redo work
# whose inputs never changed.
#
# cmp is content-exact, so this is not a heuristic: identical bytes are skipped,
# anything else is written. Destinations are reported as (unchanged) so a run
# still shows what the overlay covers rather than going silent.
UNCHANGED=0
install_if_changed() {
  local mode="$1" src="$2" dst="$3"
  # A destination ending in / (or an existing directory) means "into that dir".
  case "$dst" in
    */) dst="$dst$(basename "$src")" ;;
    *)  [ -d "$dst" ] && dst="$dst/$(basename "$src")" ;;
  esac
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    UNCHANGED=$((UNCHANGED + 1))
    return 0
  fi
  install -m "$mode" "$src" "$dst"
}

[ -d "$SRC/web-apps" ] && [ -d "$SRC/desktop-apps" ] \
  || die "not an ONLYOFFICE checkout: $SRC (expected web-apps/ and desktop-apps/)"

echo "Applying LightOffice overlay -> $SRC"

# ---------------------------------------------------------------- 1. theme ---
THEME_DIR="$SRC/web-apps/apps/common/main/resources/themes"
install_if_changed 0644 "$OVERLAY/web-apps/apps/common/main/resources/themes/theme_lightwps.json" "$THEME_DIR/"
info "theme_lightwps.json installed"

# Register the theme so the editors offer it in the appearance menu. themes.json
# ships as {"themes": []}; we append our id without disturbing anything present.
python3 - "$THEME_DIR/themes.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as fh:
    data = json.load(fh)
themes = data.setdefault('themes', [])
if 'theme_lightwps.json' not in themes:
    themes.append('theme_lightwps.json')
    with open(p, 'w', encoding='utf-8') as fh:
        json.dump(data, fh, ensure_ascii=False, indent=4)
        fh.write('\n')
    print('registered')
else:
    print('present')
PY

# ------------------------------------------------------------- 2. branding ---
install -d "$SRC/desktop-apps/win-linux/res/lightoffice"
install_if_changed 0644 "$OVERLAY/branding/splash.png"      "$SRC/desktop-apps/win-linux/res/lightoffice/"
install_if_changed 0644 "$OVERLAY/branding/about_logo.png"  "$SRC/desktop-apps/win-linux/res/lightoffice/"
install_if_changed 0644 "$OVERLAY/branding/lightoffice.ico" "$SRC/desktop-apps/win-linux/res/icons/desktopeditors.ico"
for png in "$OVERLAY"/branding/lightoffice_*.png; do
  install_if_changed 0644 "$png" "$SRC/desktop-apps/win-linux/res/lightoffice/"
done
info "splash / about logo / window icon installed"

# version_p.h is upstream's own vendor hook (see the __NCT block it replaces),
# so rebranding needs no edit to version.h itself.
install_if_changed 0644 "$OVERLAY/desktop-apps/win-linux/src/prop/version_p.h" \
                "$SRC/desktop-apps/win-linux/src/prop/version_p.h"
info "binary branding strings overridden (version_p.h)"

# ---------------------------------------------------------- 3. cloud config ---
PROV="$SRC/desktop-apps/common/loginpage/providers/lightoffice"
install -d "$PROV/assets"
install_if_changed 0644 "$OVERLAY/desktop-apps/common/loginpage/providers/lightoffice/config.json" "$PROV/"
for svg in "$OVERLAY"/desktop-apps/common/loginpage/providers/lightoffice/assets/*.svg; do
  install_if_changed 0644 "$svg" "$PROV/assets/"
done
install_if_changed 0644 "$OVERLAY/desktop-apps/common/loginpage/src/lightoffice-cloud.js" \
                "$SRC/desktop-apps/common/loginpage/src/"
info "intranet cloud provider installed (10.0.7.10:8080)"

# Point the stock Nextcloud provider at the intranet host too, so an operator who
# picks "Nextcloud" rather than "LightOffice 内网云" still lands on-premises.
python3 - "$SRC/desktop-apps/common/loginpage/providers/nextcloud/config.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as fh:
    cfg = json.load(fh)
if cfg.get('defaultUrl') != 'http://10.0.7.10:8080':
    cfg['defaultUrl'] = 'http://10.0.7.10:8080'
    with open(p, 'w', encoding='utf-8') as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=4)
        fh.write('\n')
    print('repointed')
else:
    print('present')
PY

# Load the defaults before the connect dialog script.
CONNECT_HTML=$(grep -rl 'dialogconnect.js' "$SRC/desktop-apps/common/loginpage" --include='*.html' 2>/dev/null | head -1 || true)
if [ -n "$CONNECT_HTML" ]; then
  if grep -q "$MARK" "$CONNECT_HTML"; then
    skip "connect page script injection"
  else
    if python3 - "$CONNECT_HTML" "$MARK" <<'PY'
import sys, re
path, mark = sys.argv[1], sys.argv[2]
html = open(path, encoding='utf-8').read()
inject = f'<!-- {mark} --><script src="lightoffice-cloud.js"></script>\n'
m = re.search(r'[ \t]*<script[^>]*dialogconnect\.js', html)
if m:
    line_start = html.rfind('\n', 0, m.start()) + 1
    indent = re.match(r'[ \t]*', html[line_start:]).group(0)
    html = html[:line_start] + indent + inject + html[line_start:]
    open(path, 'w', encoding='utf-8').write(html)
    print('injected')
else:
    print('anchor-not-found'); sys.exit(1)
PY
    then
      info "cloud defaults injected into $(basename "$CONNECT_HTML")"
    else
      drift "connect page anchor not found in $(basename "$CONNECT_HTML") — upstream moved dialogconnect.js"
    fi
  fi
fi

# ------------------------------------------------- 4. trim collaboration tab ---
# Upstream gates this tab on LayoutManager.isElementVisible('toolbar-collaboration'),
# but that gate only applies when the branding licence (canBrandingExt) is active.
# For an on-premises build we force it off at source so the trim always holds.
trim_collab() {
  local f="$1"
  local ed="${2:-$f}"
  [ -f "$f" ] || return 0
  if grep -q "$MARK-collab" "$f"; then
    skip "collaboration tab in $(basename "$(dirname "$(dirname "$f")")")"
    return 0
  fi
  if python3 - "$f" "$MARK" <<'PY'
import re, sys
path, mark = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8').read()
# Anchor on the setVisible('review', ...) call that reveals the tab.
pat = re.compile(r"(\n(\s*)me\.toolbar\.setVisible\('review',\s*)(.*?)(\);)", re.S)
m = pat.search(src)
if not m:
    print('anchor-not-found'); sys.exit(1)
indent = m.group(2)
original = ' '.join(m.group(3).split())
replacement = (
    f"\n{indent}/* {mark}-collab: LightOffice ships without the advanced\n"
    f"{indent}   collaboration tab. Upstream gate, recorded so a rebase shows\n"
    f"{indent}   any change to it:\n"
    f"{indent}     {original}\n"
    f"{indent}*/\n"
    f"{indent}me.toolbar.setVisible('review', false"
)
src = src[:m.start()] + replacement + m.group(4) + src[m.end():]
open(path, 'w', encoding='utf-8').write(src)
print('trimmed')
PY
  then
    info "collaboration tab hidden in $ed"
  else
    drift "collaboration tab anchor not found in $ed — upstream changed setVisible('review', …)"
  fi
}

for ed in documenteditor spreadsheeteditor presentationeditor pdfeditor; do
  trim_collab "$SRC/web-apps/apps/$ed/main/app/controller/Toolbar.js" "$ed"
done

# ------------------------------------------------------ 5. disable plugins ----
# The AI assistant ships as a plugin, so disabling plugin loading removes it
# along with every other non-core marketplace add-in.
PLUGINS="$SRC/web-apps/apps/common/main/lib/controller/Plugins.js"
if grep -q "$MARK-plugins" "$PLUGINS" 2>/dev/null; then
  skip "plugin loading"
else
  if python3 - "$PLUGINS" "$MARK" <<'PY'
import sys
path, mark = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8').read()
needle = "if (!this.appOptions.customization || (this.appOptions.customization.plugins!==false)) {"
if needle not in src:
    print('anchor-not-found'); sys.exit(1)
repl = (f"/* {mark}-plugins: LightOffice is a lightweight on-premises build and\n"
        f"           does not ship the plugin host (this also removes the AI\n"
        f"           assistant, which upstream delivers as a plugin). */\n"
        f"            if (false && (!this.appOptions.customization || (this.appOptions.customization.plugins!==false))) {{")
src = src.replace(needle, repl, 1)
open(path, 'w', encoding='utf-8').write(src)
print('disabled')
PY
  then
    info "plugin host disabled (removes AI assistant)"
  else
    drift "plugin host anchor not found — upstream changed the customization.plugins guard"
  fi
fi

echo
if [ "$UNCHANGED" -gt 0 ]; then
  printf '  \033[33m·\033[0m %d file(s) already byte-identical — left untouched so the\n' "$UNCHANGED"
  printf '    prebuilt JS and resource output stays valid\n'
fi
if [ "$DRIFTED" -ne 0 ]; then
  echo "OVERLAY INCOMPLETE: $DRIFTED patch anchor(s) no longer match upstream." >&2
  echo "Those customisations were NOT applied. Re-target them before shipping a" >&2
  echo "build: skipping them silently would ship the collaboration tab and the" >&2
  echo "plugin host still enabled." >&2
  exit 1
fi
echo "Overlay applied. Review with:  git -C \"$SRC\" diff --stat"
