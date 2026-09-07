#!/usr/bin/env bash
#
# Concurrent-write file locking check (AC 3.5).
#
# Nextcloud's app store is not reachable from every deployment, so the
# `files_lock` app (which implements WebDAV LOCK/UNLOCK) may be unavailable —
# without it a LOCK request answers 501. Core transactional locking
# (DBLockingProvider) still guards concurrent writes and is what returns 423,
# which is the behaviour a second editor actually hits when saving a file
# someone else is writing. This drives that path directly.
#
# Runs over TLS: WebDAV sends Basic-auth credentials, so a plaintext run of this
# test would put a real password on the wire.
#
# Usage: scripts/test_filelock.sh [--portal https://localhost] [--cacert PATH]
#                                 [--user alice] [--pass ...]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTAL="https://localhost"
CACERT="$ROOT/deploy/tls/fullchain.pem"
USER_="alice"
PASS="AlicePass!2345"
WRITERS=4
SIZE_MB=110

while [ $# -gt 0 ]; do
  case "$1" in
    --portal) PORTAL="$2"; shift 2 ;;
    --cacert) CACERT="$2"; shift 2 ;;
    --user) USER_="$2"; shift 2 ;;
    --pass) PASS="$2"; shift 2 ;;
    --writers) WRITERS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

OUT="$ROOT/baseline/filelock.result"
mkdir -p "$(dirname "$OUT")"

payload="$(mktemp)"
# The payload must be big enough that the writes genuinely overlap; a small file
# is committed faster than a competing request can arrive and nothing contends.
head -c $((SIZE_MB * 1024 * 1024)) /dev/urandom > "$payload"

URL="$PORTAL/remote.php/dav/files/$USER_/lightoffice-lock-test.bin"
echo "driving $WRITERS concurrent writers at $URL (${SIZE_MB}MB each)"

: > "$OUT"
for i in $(seq 1 "$WRITERS"); do
  (
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
             -u "$USER_:$PASS" -T "$payload" "$URL")
    echo "writer$i $code" >> "$OUT"
  ) &
done
wait
rm -f "$payload"

sort -o "$OUT" "$OUT"
cat "$OUT"

n423=$(grep -c ' 423' "$OUT")
n2xx=$(grep -cE ' (200|201|204)' "$OUT")
echo
echo "succeeded: $n2xx   locked(423): $n423"
if [ "$n423" -ge 1 ] && [ "$n2xx" -ge 1 ]; then
  echo "PASS — concurrent writers were serialised, losers received 423 Locked"
  exit 0
fi
echo "FAIL — expected at least one 2xx and at least one 423" >&2
exit 1
