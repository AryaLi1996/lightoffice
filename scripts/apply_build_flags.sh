#!/usr/bin/env bash
#
# Wire the LightOffice size-optimisation profile into the upstream build.
#
# Idempotent: the include is fenced with a marker, so re-running is a no-op.
#
# Usage: scripts/apply_build_flags.sh [/path/to/onlyoffice-src]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${LIGHTOFFICE_SRC:-/home/user/onlyoffice-src}}"
MARK="LIGHTOFFICE-SIZE-OPT"
DEFAULTS="$SRC/desktop-apps/win-linux/defaults.pri"

[ -f "$DEFAULTS" ] || { echo "not found: $DEFAULTS" >&2; exit 1; }

install -d "$SRC/desktop-apps/win-linux/lightoffice"
install -m 0644 "$ROOT/overlay/build/lightoffice_size_opt.pri"   "$SRC/desktop-apps/win-linux/lightoffice/"
install -m 0644 "$ROOT/overlay/build/lightoffice_size_opt.cmake" "$SRC/desktop-apps/win-linux/lightoffice/"

if grep -q "$MARK" "$DEFAULTS"; then
  echo "· size-opt profile already included in defaults.pri"
else
  cat >> "$DEFAULTS" <<EOF

# $MARK: LightOffice size-optimisation profile (-Os, section GC, strip).
include(\$\$PWD/lightoffice/lightoffice_size_opt.pri)
EOF
  echo "✓ size-opt profile included from defaults.pri"
fi

echo
echo "Effective release flags:"
sed -n '/CONFIG(release/,/^}/p' "$SRC/desktop-apps/win-linux/lightoffice/lightoffice_size_opt.pri" \
  | grep -E 'QMAKE_(C|CXX|L)FLAGS' | sed 's/^ */  /'
