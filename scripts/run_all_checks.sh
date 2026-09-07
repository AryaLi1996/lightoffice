#!/usr/bin/env bash
#
# Run every check the project has and print one pass/fail table.
#
# This is the single command a reviewer runs to see where the project stands.
# It deliberately distinguishes four outcomes, because collapsing them to
# pass/fail is how a suite starts lying:
#
#   PASS     the check ran and succeeded
#   FAIL     the check ran and failed — actionable, and fails this script
#   SKIP     the check's prerequisites are absent (no upstream checkout, no
#            running stack, no browser). Not a defect, and not a pass either.
#   MISSING  the check itself is not present. Reported loudly rather than
#            silently counted as a skip: a suite that quietly stops running a
#            check is indistinguishable from one that passes it.
#
# Only FAIL sets a non-zero exit status. SKIP and MISSING are printed with
# their reason so nobody mistakes an unrun suite for a green one.
#
# Usage: scripts/run_all_checks.sh [--json PATH] [--quick] [/path/to/onlyoffice-src]
#   --quick  static checks only; skip anything needing a browser or the stack

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

JSON_OUT="$ROOT/baseline/all_checks.json"
QUICK=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT="$2"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
SRC="${ARGS[0]:-${LIGHTOFFICE_SRC:-$(dirname "$ROOT")/onlyoffice-src}}"
export LIGHTOFFICE_SRC="$SRC"

C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_M=$'\033[35m'; C_0=$'\033[0m'
LOGDIR="$ROOT/baseline/checks"
mkdir -p "$LOGDIR" "$(dirname "$JSON_OUT")"

pass=0; fail=0; skip=0; missing=0
ROWS=()
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

emit() {
  local name="$1" status="$2" note="$3" log="${4:-}"
  local colour=""
  case "$status" in
    PASS)    colour="$C_G"; pass=$((pass+1)) ;;
    FAIL)    colour="$C_R"; fail=$((fail+1)) ;;
    SKIP)    colour="$C_Y"; skip=$((skip+1)) ;;
    MISSING) colour="$C_M"; missing=$((missing+1)) ;;
  esac
  printf '  %-28s %s%-8s%s %s\n' "$name" "$colour" "$status" "$C_0" "$note"
  ROWS+=("$(printf '{"check":%s,"status":"%s","note":%s,"log":%s}' \
    "$(json_str "$name")" "$status" "$(json_str "$note")" "$(json_str "$log")")")
}

# Run one check. The command's output goes to a log file rather than the
# terminal so the table stays readable; the path is printed on failure.
run() {
  local name="$1"; shift
  local log
  log="$LOGDIR/$(echo "$name" | tr ' /' '__').log"
  local start; start=$(date +%s)
  if "$@" >"$log" 2>&1; then
    emit "$name" PASS "$(($(date +%s) - start))s" "$log"
  else
    local rc=$?
    emit "$name" FAIL "exit $rc — see $log" "$log"
  fi
}

need_src()   { [ -d "$SRC/web-apps" ] && [ -d "$SRC/desktop-apps" ]; }
need_stack() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q lightoffice-documentserver; }
need_chrome() { [ -x "${CHROME_PATH:-/opt/pw-browsers/chromium-1194/chrome-linux/chrome}" ]; }

printf '\033[1mLightOffice — all checks\033[0m\n'
printf 'upstream: %s%s\n' "$SRC" "$(need_src || echo '  (absent)')"
printf 'mode    : %s\n\n' "$([ "$QUICK" -eq 1 ] && echo 'quick (static only)' || echo 'full')"

printf '\033[1mstatic\033[0m\n'
if [ -x scripts/lint.sh ]; then run "shell + workflow lint" scripts/lint.sh
else emit "shell + workflow lint" MISSING "scripts/lint.sh not found"; fi

# Through npm rather than a second `node --test` invocation: two definitions of
# how the tests run will eventually disagree, and the one here would be the one
# nobody notices is wrong.
if [ -d tests/unit ]; then run "unit tests" npm test --silent
else emit "unit tests" MISSING "tests/unit not found"; fi

if [ -f VERSION_LOCK ]; then
  if [ -x scripts/gen_version_lock.sh ]; then
    # A drifted lock is a real failure: the tree is no longer the tree the
    # measurements were taken against.
    if need_src; then run "version lock matches tree" scripts/gen_version_lock.sh --check
    else emit "version lock matches tree" SKIP "no upstream checkout at $SRC"; fi
  else emit "version lock matches tree" MISSING "scripts/gen_version_lock.sh not found"; fi
else emit "version lock matches tree" MISSING "VERSION_LOCK not found — run scripts/gen_version_lock.sh"; fi

printf '\n\033[1mupstream tree\033[0m\n'
if need_src; then
  if [ -x scripts/check_i18n.sh ]; then run "zh locale coverage" scripts/check_i18n.sh --min 95 "$SRC"
  else emit "zh locale coverage" MISSING "scripts/check_i18n.sh not found"; fi
  if [ -x scripts/count_toolbar.sh ]; then run "toolbar reduction" scripts/count_toolbar.sh --min 20 "$SRC"
  else emit "toolbar reduction" MISSING "scripts/count_toolbar.sh not found"; fi
else
  emit "zh locale coverage" SKIP "no upstream checkout at $SRC"
  emit "toolbar reduction" SKIP "no upstream checkout at $SRC"
fi

printf '\n\033[1mlive stack\033[0m\n'
for spec in "co-editing:tests/coedit_browser.js" \
            "offline behaviour:tests/offline_test.js" \
            "file locking:scripts/test_filelock.sh"; do
  name="${spec%%:*}"; script="${spec#*:}"
  if [ ! -f "$script" ]; then emit "$name" MISSING "$script not found"; continue; fi
  if [ "$QUICK" -eq 1 ]; then emit "$name" SKIP "--quick"; continue; fi
  if ! need_stack; then emit "$name" SKIP "stack not running — deploy/docker-compose.nextcloud.yml"; continue; fi
  if [[ "$script" == *.js ]] && ! need_chrome; then emit "$name" SKIP "no chromium at CHROME_PATH"; continue; fi
  # These need the live JWT secret; without it the editors fail with the
  # unhelpful errorCode -20 rather than an obvious credential error.
  if [ -z "${JWT_SECRET:-}" ] && [ -f deploy/.env ]; then
    JWT_SECRET="$(grep '^DOCSERVER_JWT_SECRET=' deploy/.env | cut -d= -f2-)"
    export JWT_SECRET
  fi
  if [ -z "${JWT_SECRET:-}" ]; then emit "$name" SKIP "no JWT_SECRET and no deploy/.env"; continue; fi
  if [[ "$script" == *.js ]]; then run "$name" node "$script"; else run "$name" bash "$script"; fi
done

printf '\n\033[1macceptance criteria\033[0m\n'
if [ -x scripts/verify_ac.sh ]; then
  # verify_ac.sh exits non-zero only on FAIL; BLOCKED and SKIPPED are expected
  # here and must not be reported as a failure of this script.
  run "acceptance criteria" scripts/verify_ac.sh "$SRC"
  if [ -f baseline/ac_report.json ] && command -v jq >/dev/null; then
    jq -r '[.criteria[]?] | group_by(.verdict)[] | "        \(.[0].verdict): \(length)"' \
      baseline/ac_report.json 2>/dev/null || true
  fi
else
  emit "acceptance criteria" MISSING "scripts/verify_ac.sh not found"
fi

{
  printf '{\n  "generated": "%s",\n  "upstream": %s,\n  "quick": %s,\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_str "$SRC")" "$([ "$QUICK" -eq 1 ] && echo true || echo false)"
  printf '  "summary": {"pass": %d, "fail": %d, "skip": %d, "missing": %d},\n  "checks": [\n' \
    "$pass" "$fail" "$skip" "$missing"
  for i in "${!ROWS[@]}"; do
    printf '    %s' "${ROWS[$i]}"
    [ "$i" -lt $((${#ROWS[@]} - 1)) ] && printf ','
    printf '\n'
  done
  printf '  ]\n}\n'
} > "$JSON_OUT"

printf '\n\033[1msummary\033[0m\n'
printf '  %sPASS %d%s  %sFAIL %d%s  %sSKIP %d%s  %sMISSING %d%s\n' \
  "$C_G" "$pass" "$C_0" "$C_R" "$fail" "$C_0" "$C_Y" "$skip" "$C_0" "$C_M" "$missing" "$C_0"
printf '  report: %s\n' "$JSON_OUT"
[ "$missing" -gt 0 ] && printf '  %s%d check(s) are missing — the suite is not complete%s\n' "$C_M" "$missing" "$C_0"
[ "$skip" -gt 0 ] && printf '  %d check(s) skipped for missing prerequisites; a skip is not a pass\n' "$skip"

exit $(( fail > 0 ? 1 : 0 ))
