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
# WHAT COUNTS AS SUCCESS
# ----------------------
# The first version of this test demanded at least one 2xx among the concurrent
# writers, assuming a winner always emerges. It does not: DBLockingProvider can
# reject every writer in a round when each takes a shared lock and then fails to
# upgrade it, and an observed run had all four receive 423. That is still
# correct locking — nobody interleaved a write — so failing on it reported a
# defect that was not there.
#
# What actually needs distinguishing is contention from a target that is simply
# stuck locked. So after the concurrent burst a single sequential write is made:
# if a lone writer succeeds, the 423s were contention; if it does not, the file
# is genuinely wedged and that is a real failure.
#
# Each run uses its own file and deletes it afterwards. A test whose result
# depends on what the previous run left behind is not a test.
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

TARGET="lightoffice-lock-test-$$-$(date +%s).bin"
URL="$PORTAL/remote.php/dav/files/$USER_/$TARGET"
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

cleanup() {
  curl -s -o /dev/null --cacert "$CACERT" -u "$USER_:$PASS" -X DELETE "$URL" 2>/dev/null
}

# 000 means curl never completed a request — wrong portal address, a certificate
# that does not match it, or nothing listening. Reporting that as "locking is not
# working" sends the reader after the wrong problem entirely.
n000=$(grep -c ' 000' "$OUT")
if [ "$n000" -eq "$WRITERS" ]; then
  echo "BLOCKED — no writer reached the server (all 000). Check --portal ($PORTAL)," >&2
  echo "          whether --cacert ($CACERT) matches that hostname, and that the port is published." >&2
  cleanup
  exit 2
fi

if [ "$n423" -lt 1 ]; then
  echo "FAIL — no writer was rejected with 423; concurrent writes were not serialised" >&2
  echo "       responses: $(tr '\n' ' ' < "$OUT")" >&2
  cleanup
  exit 1
fi

if [ "$n2xx" -ge 1 ]; then
  echo "PASS — concurrent writers were serialised, losers received 423 Locked"
  cleanup
  exit 0
fi

# Every writer lost. Establish whether the locks release: a lone writer must be
# able to write once the contention is over.
echo "every concurrent writer was rejected; checking whether a lone writer succeeds"
solo=""
for attempt in 1 2 3; do
  sleep 5
  solo=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" \
           -u "$USER_:$PASS" -T /dev/null "$URL")
  echo "  sequential attempt $attempt: $solo"
  case "$solo" in 200|201|204) break ;; esac
done
echo "sequential write: $solo" >> "$OUT"

case "$solo" in
  200|201|204)
    echo "PASS — all $WRITERS concurrent writers were rejected with 423 and a lone writer then succeeded ($solo);"
    echo "       the locks are contention, not a wedged file"
    cleanup
    exit 0 ;;
  *)
    echo "FAIL — the target stayed locked ($solo) after the contention ended; the lock did not release" >&2
    cleanup
    exit 1 ;;
esac
