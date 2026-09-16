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

# Locate Inno Setup -- every copy of it, not the first thing called iscc.
#
# THE SECOND FAILURE (run 35022661292): this step passed in seventeen seconds
# reporting "all 40 referenced language files are present", and the build died
# 174 minutes later on the very same missing Greek.isl. The files were real;
# the directory was not the one ISCC reads.
#
# `choco install innosetup` drops a SHIM at C:\ProgramData\chocolatey\bin\iscc.exe
# and that is what is on PATH -- the job's PATH has no "Inno Setup 6" entry at
# all. So `command -v iscc` resolved the shim, and the forty language files
# landed in C:\ProgramData\chocolatey\bin\Languages. Meanwhile make_inno.ps1
# resolves the real installation from $env:INNOPATH or the registry key
# HKLM\...\Uninstall\Inno Setup 6_is1 -> "Inno Setup: App Path", prepends THAT
# to PATH, and runs iscc from there.
#
# This is the same shape as the Git-for-Windows shadowing that cost this build
# link.exe, perl and more: the tool is present, and the one that answers is the
# wrong one. So: collect candidates, keep only directories that actually hold
# ISCC.exe (a shim directory does not), and populate all of them.
candidates=""
[ -n "${INNOPATH:-}" ] && candidates="$candidates
$(command -v cygpath >/dev/null 2>&1 && cygpath -u "$INNOPATH" 2>/dev/null || echo "$INNOPATH")"

# The registry value make_inno.ps1 itself uses. reg.exe prints
#   "    Inno Setup: App Path    REG_SZ    C:\Program Files (x86)\Inno Setup 6"
if command -v reg >/dev/null 2>&1 || [ -x /c/Windows/System32/reg.exe ]; then
  _reg="$(command -v reg 2>/dev/null || echo /c/Windows/System32/reg.exe)"
  for _key in \
    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1' \
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1'; do
    _val="$("$_reg" query "$_key" /v "Inno Setup: App Path" 2>/dev/null \
            | sed -n 's/.*REG_SZ[[:space:]]*//p' | tr -d '\r')"
    [ -n "$_val" ] || continue
    candidates="$candidates
$(command -v cygpath >/dev/null 2>&1 && cygpath -u "$_val" 2>/dev/null || echo "$_val")"
  done
fi

candidates="$candidates
/c/Program Files (x86)/Inno Setup 6
/c/Program Files/Inno Setup 6"

# Keep the real installations: a directory holding ISCC.exe. The chocolatey
# shim directory does not, which is exactly how it is rejected here.
INNO_DIRS=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ -e "$d/ISCC.exe" ] || [ -e "$d/iscc.exe" ] || continue
  case "
$INNO_DIRS" in *"
$d
"*) continue ;; esac
  INNO_DIRS="$INNO_DIRS$d
"
done <<EOF
$candidates
EOF

[ -n "$INNO_DIRS" ] || { bad "no directory containing ISCC.exe found — cannot install language files"; exit 1; }
while IFS= read -r d; do [ -n "$d" ] && ok "Inno Setup: $d"; done <<EOF
$INNO_DIRS
EOF

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
#
# Downloaded once into a staging directory and then copied into every Inno
# Setup installation found, so it does not matter which one make_inno.ps1
# resolves from the registry.
ISSRC="https://raw.githubusercontent.com/jrsoftware/issrc/main/Files/Languages"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

have_everywhere() {
  _f="$1"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -s "$d/Languages/$_f" ] || return 1
  done <<EOF
$INNO_DIRS
EOF
  return 0
}

fetched=0
for f in $needed; do
  have_everywhere "$f" && continue
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
    if curl -fsSL --retry 5 --retry-delay 2 --max-time 60 -o "$STAGE/$f" "$url" 2>/dev/null; then
      got="$url"; break
    fi
    rm -f "$STAGE/$f"
  done
  if [ -z "$got" ]; then
    warn "could not fetch $f from either issrc languages directory"
    continue
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -s "$d/Languages/$f" ] && continue
    mkdir -p "$d/Languages"
    cp "$STAGE/$f" "$d/Languages/$f" || warn "could not write $d/Languages/$f"
  done <<EOF
$INNO_DIRS
EOF
  ok "installed $f"
  fetched=$((fetched + 1))
done
[ "$fetched" -eq 0 ] && ok "nothing to fetch — all present already"

# Prove it, rather than assume the downloads covered everything. Checked in
# every installation directory, because the one ISCC uses is chosen later by
# make_inno.ps1 from the registry, not here.
rc=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  missing=""
  for f in $needed; do
    [ -s "$d/Languages/$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    bad "$d is missing language files common.iss requires:$missing"
    rc=1
  else
    ok "$d/Languages: all $(printf '%s\n' "$needed" | wc -l | tr -d ' ') referenced language files present"
  fi
done <<EOF
$INNO_DIRS
EOF
if [ "$rc" -ne 0 ]; then
  echo "      Packaging is the last step of a ~150 minute build, so this would" >&2
  echo "      otherwise surface as 'Couldn't open include file' at the very end." >&2
  exit 1
fi

# Say where the files went somewhere that survives the log. A GitHub Actions
# job log is served as a ~45KB tail and the Windows MSVC env echo alone is
# ~40KB per step, so this step's own output is unreadable after the fact --
# which is how the chocolatey shim went unnoticed for a 174 minute build. The
# step summary is not truncated.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Inno Setup language files"
    echo
    while IFS= read -r d; do
      [ -n "$d" ] && echo "- \`$d/Languages\` — $(printf '%s\n' "$needed" | wc -l | tr -d ' ') files"
    done <<INNOEOF
$INNO_DIRS
INNOEOF
  } >> "$GITHUB_STEP_SUMMARY"
fi
