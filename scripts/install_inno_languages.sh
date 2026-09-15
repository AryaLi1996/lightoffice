#!/usr/bin/env bash
#
# Install the Inno Setup language files desktop-apps/package/inno/common.iss
# asks for, and prove they are all there before a build spends two hours
# getting to the packaging step.
#
# THE FAILURE (run 35006043988, 149 minutes in -- the whole build compiled,
# including core, doctrenderer and every DLL, and only packaging was left):
#
#   Error on line 128 in ...\inno\common.iss: Couldn't open include file
#     "C:\Program Files (x86)\Inno Setup 6\Languages\Greek.isl":
#     The system cannot find the file specified.
#   Compile aborted.
#
# Inno Setup 6 ships about twenty-five translations. common.iss names around
# forty-five. The rest -- Greek, Arabic, Korean, Swedish, Vietnamese, both
# Chinese, and more -- are "unofficial" translations that live in the Inno
# Setup source repository and are not part of the installer.
#
# They are downloaded rather than the language list trimmed: these are the
# installer wizard's own languages, and dropping them would narrow what the
# product offers to users who need them.
#
# The verification at the end is the point. Packaging is the LAST step of a
# two-and-a-half hour build, so a missing file there is the most expensive
# possible place to find out. Checking in the dependency step turns that into
# a failure about ninety seconds in.
#
# Usage: scripts/install_inno_languages.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

ISS="$SRC/desktop-apps/package/inno/common.iss"
[ -f "$ISS" ] || { warn "no $ISS — nothing to do"; exit 0; }

# Locate Inno Setup. iscc.exe on PATH wins; otherwise the default location.
INNO_DIR=""
if command -v iscc >/dev/null 2>&1; then
  INNO_DIR="$(dirname "$(command -v iscc)")"
elif command -v iscc.exe >/dev/null 2>&1; then
  INNO_DIR="$(dirname "$(command -v iscc.exe)")"
elif [ -d "/c/Program Files (x86)/Inno Setup 6" ]; then
  INNO_DIR="/c/Program Files (x86)/Inno Setup 6"
elif [ -d "/c/Program Files/Inno Setup 6" ]; then
  INNO_DIR="/c/Program Files/Inno Setup 6"
fi
[ -n "$INNO_DIR" ] || { bad "Inno Setup not found — cannot install language files"; exit 1; }
LANG_DIR="$INNO_DIR/Languages"
mkdir -p "$LANG_DIR"
ok "Inno Setup: $INNO_DIR"

# Which .isl files does common.iss actually reference?
#
# Only lines that are live: a leading ';' comments a language out. The .islu
# variants sit inside "#if Int(DecodeVer(PREPROCVER,1)) < 6", so they belong
# to Inno Setup 5 and are skipped -- this is 6.
# Two steps on purpose. A single regex cannot span the ';' that separates
# "Name: bg" from "MessagesFile:", and matching '\.isl' alone also matches the
# '.isl' prefix of '.islu' -- both caught by testing the parse against the real
# common.iss rather than reading it.
needed="$(grep -E '^[[:space:]]*Name:' "$ISS" \
          | grep -oE 'Languages\\[A-Za-z]+\.islu?' \
          | grep -vE '\.islu$' \
          | sed 's#.*\\##' | sort -u)"
[ -n "$needed" ] || { warn "common.iss references no Languages\\*.isl — nothing to install"; exit 0; }
printf '  %s referenced\n' "$(printf '%s\n' "$needed" | wc -l | tr -d ' ')"

# Fetch the unofficial translations that are missing. They are not in the
# installer; they live in the Inno Setup source tree.
# Two directories, and they are complementary rather than one being a superset:
# Greek and Vietnamese are only in Unofficial/, while Korean, ChineseSimplified
# and Swedish are only in Languages/. Checked by asking for each, not assumed.
ISSRC="https://raw.githubusercontent.com/jrsoftware/issrc/main/Files/Languages"
fetched=0
for f in $needed; do
  if [ -s "$LANG_DIR/$f" ]; then continue; fi
  got=""
  for url in "$ISSRC/Unofficial/$f" "$ISSRC/$f"; do
    # -f so a 404 fails instead of writing "404: Not Found" into a .isl, and
    # stderr dropped because the first URL 404ing is the normal path for every
    # official language -- curl noise here would bury the errors that matter.
    # --retry (not --retry-all-errors) on purpose: curl's plain --retry covers
    # connection failures and 408/429/5xx but NOT 404, which is exactly right
    # here. Adding --retry-all-errors made every official language retry its
    # expected 404 on the Unofficial URL five times over, turning a ninety
    # second step into a five minute one -- caught by timing it, not reading it.
    if curl -fsSL --retry 5 --retry-delay 2 --max-time 60 -o "$LANG_DIR/$f" "$url" 2>/dev/null; then
      got="$url"; break
    fi
    rm -f "$LANG_DIR/$f"
  done
  if [ -n "$got" ]; then
    ok "fetched $f"
    fetched=$((fetched + 1))
  else
    warn "could not fetch $f from either issrc languages directory"
  fi
done
[ "$fetched" -eq 0 ] && ok "nothing to fetch — all present already"

# Prove it, rather than assume the downloads covered everything.
missing=""
for f in $needed; do
  if [ ! -s "$LANG_DIR/$f" ]; then missing="$missing $f"; fi
done
if [ -n "$missing" ]; then
  bad "Inno Setup is missing language files common.iss requires:$missing"
  echo "      Packaging is the last step of a ~150 minute build, so this would" >&2
  echo "      otherwise surface as 'Couldn't open include file' at the very end." >&2
  exit 1
fi
ok "all $(printf '%s\n' "$needed" | wc -l | tr -d ' ') referenced language files are present"
