#!/usr/bin/env bash
#
# Produce the delivery archive and its manifest.
#
# What goes in is the overlay and its documentation, not the upstream tree.
# LightOffice is maintained as an idempotent patch over a pinned ONLYOFFICE
# checkout, so shipping a 3GB copy of upstream would obscure the only thing
# that is actually ours and would go stale the moment the pin moves. The
# manifest records the pin instead, and scripts/bootstrap.sh reconstructs the
# tree from it.
#
# The manifest carries the git commit ID alongside the checksums. A checksum
# says the file is intact; the commit ID says which source it was built from.
# Without it a recipient can verify they received what was sent but not what
# was sent — which is the question that matters when a bug report arrives.
#
# A dirty or untagged working tree is recorded as such rather than quietly
# labelled with the nearest tag: an archive that claims a clean provenance it
# does not have is worse than one that admits to being a work in progress.
#
# Usage: scripts/archive.sh [--version X.Y.Z] [--out DIR]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

VERSION=""
OUT="$ROOT/artifacts"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$VERSION" ] || VERSION="$(python3 -c 'import json;print(json.load(open("package.json"))["version"])' 2>/dev/null || echo 1.0.0)"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
mkdir -p "$OUT"

COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY=false
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=true
TAG="$(git describe --tags --exact-match 2>/dev/null || echo '')"

NAME="lightoffice-${VERSION}-${SHORT}"
TARBALL="$OUT/${NAME}.tar.gz"
MANIFEST="$OUT/${NAME}.manifest.json"

echo "archiving $NAME"
[ "$DIRTY" = true ] && echo "  WARNING: working tree is dirty; the archive will not match commit $SHORT exactly"

# git archive would silently drop anything uncommitted. Because a dirty tree is
# reported rather than refused, build the list from the working tree instead so
# the tarball matches what is actually here.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  git ls-files --cached --others --exclude-standard \
    -- overlay scripts tests docs deploy .github \
       package.json package-lock.json README.md VERSION_LOCK baseline_metrics.json 2>/dev/null | sort
)
[ "${#FILES[@]}" -gt 0 ] || { echo "nothing to archive" >&2; exit 1; }

# Reproducible: fixed mtime/owner and a sorted file list, so two archives of the
# same commit hash identically. Otherwise the checksum verifies the transfer but
# says nothing about the content.
MT="$(git log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="$MT" -czf "$TARBALL" -- "${FILES[@]}" || { echo "tar failed" >&2; exit 1; }

SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$TARBALL")"

# Installers, when this host has produced any.
INSTALLERS=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  INSTALLERS+=("$(printf '{"file":"%s","bytes":%s,"sha256":"%s"}' \
    "$(basename "$f")" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)")")
done < <(find "$OUT" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.exe' -o -name '*.dmg' \) | sort)

python3 - "$MANIFEST" "$NAME" "$VERSION" "$COMMIT" "$BRANCH" "$DIRTY" "$TAG" \
         "$(basename "$TARBALL")" "$SHA" "$SIZE" "${#FILES[@]}" "${INSTALLERS[@]}" <<'PY'
import json, sys, datetime, os

(m, name, version, commit, branch, dirty, tag, tarball, sha, size, nfiles) = sys.argv[1:12]
installers = [json.loads(x) for x in sys.argv[12:]]

lock = {}
if os.path.exists('VERSION_LOCK'):
    for line in open('VERSION_LOCK'):
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            lock[k] = v

doc = {
    "schema": "lightoffice/manifest@1",
    "name": name,
    "version": version,
    "created": datetime.datetime.now(datetime.timezone.utc)
                .replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    "source": {
        "commit": commit,
        "branch": branch,
        "tag": tag or None,
        "dirty": dirty == "true",
        "note": ("Built from an uncommitted working tree; the commit ID identifies the "
                 "nearest ancestor, not the exact contents."
                 if dirty == "true" else
                 "The archive contents correspond exactly to this commit."),
    },
    # Which upstream this overlay is meant to be applied to. An overlay without
    # its pin is not reproducible.
    "upstream": lock or None,
    "archive": {"file": tarball, "sha256": sha, "bytes": int(size), "file_count": int(nfiles)},
    "installers": installers,
}
with open(m, 'w', encoding='utf-8') as fh:
    json.dump(doc, fh, indent=2)
    fh.write('\n')
print("manifest:", m)
PY

# A checksum file in the conventional format, so `sha256sum -c` works directly.
( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "${NAME}.sha256" )

echo
echo "archive  : $TARBALL"
printf 'size     : %s bytes (%.1f MB)\n' "$SIZE" "$(awk -v s="$SIZE" 'BEGIN{print s/1048576}')"
echo "files    : ${#FILES[@]}"
echo "commit   : $COMMIT$([ "$DIRTY" = true ] && echo ' (dirty)')"
echo "sha256   : $SHA"
echo "verify   : cd $OUT && sha256sum -c ${NAME}.sha256"
