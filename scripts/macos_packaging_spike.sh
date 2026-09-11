#!/usr/bin/env bash
#
# Prove the macOS signing and packaging path WITHOUT building ONLYOFFICE.
#
# WHY THIS EXISTS: the real macOS build is a long pole. ONLYOFFICE.xcodeproj is
# only the Cocoa shell — it references
# ../../build_tools/out/mac_64/onlyoffice/desktopeditors/{ascdocumentscore,
# ooxmlsignature,Chromium Embedded Framework}.framework and a build phase copies
# login/converter/editors/providers out of that same directory. So build_tools
# has to produce out/mac_arm64/onlyoffice/desktopeditors first: the macOS
# equivalent of the Linux core build, including v8 via depot_tools and CEF's
# macOS binaries. On Linux that is ~30 minutes only because a Docker image
# carries the prebuilt tree; macOS runners cannot use that image, so every run
# would build from scratch.
#
# Before spending hours on that, this proves the part that is unique to macOS
# and cheap to test: does ad-hoc signing actually produce something a fleet Mac
# will run, and does the .dmg step work once Ascensio's certificate is out of
# the picture. If either answers no, the core build would have been wasted.
#
# WHAT IT DELIBERATELY DOES NOT DO: build ONLYOFFICE, or pretend to. It signs
# and packages a minimal .app so the mechanism is exercised end to end. Every
# check reports what actually happened; nothing here is asserted from docs.
#
# Usage: scripts/macos_packaging_spike.sh [workdir]

set -uo pipefail

WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
APP="$WORK/SpikeApp.app"

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
note() { printf '  [note] %s\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "this spike only runs on macOS (host is $(uname -s))" >&2
  exit 2
fi

# --- 1. a minimal but real .app bundle ---------------------------------------
say "1. build a minimal .app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SpikeApp</string>
  <key>CFBundleIdentifier</key><string>com.lightoffice.spike</string>
  <key>CFBundleExecutable</key><string>SpikeApp</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
printf '#include <stdio.h>\nint main(void){puts("spike");return 0;}\n' > "$WORK/m.c"
if clang -o "$APP/Contents/MacOS/SpikeApp" "$WORK/m.c" 2>"$WORK/clang.err"; then
  ok "bundle built ($(du -sh "$APP" | cut -f1))"
else
  bad "could not compile the bundle executable"; sed -n '1,5p' "$WORK/clang.err"; exit 1
fi

# --- 2. ad-hoc signing --------------------------------------------------------
# This is the mechanism the whole fleet-only plan rests on. codesign -s - needs
# no Apple Developer account and no certificate in the keychain.
say "2. ad-hoc sign the bundle (codesign -s -)"
if codesign -s - --force --deep "$APP" 2>&1 | sed 's/^/  /'; then
  ok "codesign -s - accepted the bundle"
else
  bad "ad-hoc signing failed — the fleet-only plan does not work as designed"; exit 1
fi

say "3. verify the signature the way a machine will"
codesign -dvvv "$APP" 2>&1 | sed -n '1,10p' | sed 's/^/  /'
if codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'; then
  ok "signature verifies strictly"
else
  bad "signature does not verify"
fi

# --- 4. what Gatekeeper thinks ------------------------------------------------
# EXPECT A REJECTION HERE, and it is not a problem. spctl is the Gatekeeper
# assessment used for downloaded software: it demands notarization, which
# requires the Developer account this project deliberately does not have. What
# matters for fleet distribution is section 5.
say "4. Gatekeeper assessment (expected to reject — see 5)"
spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/  /'
note "a rejection here is expected for an ad-hoc signature and is not a blocker"

# --- 5. the question that actually matters ------------------------------------
# Gatekeeper only assesses files carrying com.apple.quarantine, which is set by
# browsers and mail clients — not by scp, rsync, an MDM push or a file share.
# So the real test is: does the binary execute, and does it still execute when
# quarantine is present or absent.
say "5. will it actually run on a fleet machine?"
if "$APP/Contents/MacOS/SpikeApp" >/dev/null 2>&1; then
  ok "runs when delivered without quarantine (scp / rsync / MDM / file share)"
else
  bad "does not run even without quarantine — this would be fatal"
fi
xattr -w com.apple.quarantine "0081;00000000;LightOfficeSpike;" "$APP/Contents/MacOS/SpikeApp" 2>/dev/null
if "$APP/Contents/MacOS/SpikeApp" >/dev/null 2>&1; then
  note "also runs WITH the quarantine attribute set on this runner"
else
  note "blocked when quarantine is set — deliver by a channel that does not set it,"
  note "or clear it once with: xattr -dr com.apple.quarantine /Applications/<app>"
fi
xattr -d com.apple.quarantine "$APP/Contents/MacOS/SpikeApp" 2>/dev/null || true

# --- 6. the .dmg, with Ascensio's certificate removed -------------------------
# Upstream's fastlane/resources/appdmg.json pins
#   "code-sign": { "signing-identity": "Developer ID Application: Ascensio System SIA (2WH24U26GJ)" }
# which cannot work anywhere but Ascensio's own machines. Dropping that block is
# the change the fleet build needs; this proves appdmg still works without it.
say "6. build a .dmg with appdmg, minus the hardcoded Developer ID"
cat > "$WORK/appdmg.json" <<JSON
{
  "title": "LightOffice",
  "icon-size": 128,
  "contents": [
    { "x": 193, "y": 210, "type": "file", "path": "$APP" },
    { "x": 445, "y": 212, "type": "link", "path": "/Applications" }
  ]
}
JSON
if npx --yes appdmg "$WORK/appdmg.json" "$WORK/LightOffice.dmg" 2>&1 | tail -5 | sed 's/^/  /'; then
  if [ -f "$WORK/LightOffice.dmg" ]; then
    ok "appdmg produced $(du -h "$WORK/LightOffice.dmg" | cut -f1) with no Apple account"
    if hdiutil attach -nobrowse -readonly -mountpoint "$WORK/mnt" "$WORK/LightOffice.dmg" >/dev/null 2>&1; then
      ok "the .dmg mounts and contains: $(ls "$WORK/mnt" | tr '\n' ' ')"
      hdiutil detach "$WORK/mnt" >/dev/null 2>&1 || true
    else
      bad "the .dmg does not mount"
    fi
  else
    bad "appdmg exited cleanly but produced no .dmg"
  fi
else
  bad "appdmg failed — the packaging step needs rework beyond removing code-sign"
fi

say "verdict"
echo "  If 2, 3, 5 and 6 are [ok], the macOS signing and packaging path is sound"
echo "  and the only remaining work is producing build_tools/out/mac_arm64."
exit 0
