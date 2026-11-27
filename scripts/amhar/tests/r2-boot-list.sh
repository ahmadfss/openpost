#!/usr/bin/env bash
# Fast test of the boot-path R2 listing. No R2, no Replit, no OpenPost binary.
#
# Uses a throwaway S3 server (rclone serve s3) with a synthetic bucket shaped
# like production (13 Litestream generations, a big frozen legacy path, sqlite
# snapshots) and checks:
#   1. the awk list parser matches the old per-object parser byte for byte
#   2. r2_list follows pagination (small max-keys)
#   3. restore.sh --list orders generations and the legacy path by newest
#      write (an unpromoted, newer-named generation does not win) and is fast
#   4. --list and --check-fast write nothing to the bucket or the live DB path
#   5. over the listing budget, the boot fails closed instead of guessing
#   6. a stalled endpoint fails with a clear timeout instead of hanging
#   7. a legacy path still written by an old-code VM wins over generations
#   8. no generations: legacy is listed and wins
#
# Usage: bash scripts/amhar/tests/r2-boot-list.sh
# Needs: rclone, curl, awk. Optional: LITESTREAM_BIN for the --check-fast case,
#        python3 for the stalled-endpoint case. Takes under a minute.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
for c in rclone curl awk; do
  command -v "$c" > /dev/null || {
    echo "missing $c" >&2
    exit 2
  }
done

work="$(mktemp -d /tmp/amhar-r2list-XXXXXX)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  wait 2> /dev/null || true
  if [[ -n "${KEEP_LOGS:-}" ]]; then cp "$work"/*.log "$KEEP_LOGS"/ 2> /dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() { echo "PASS: $*"; }

# shellcheck disable=SC1091
source "$repo/scripts/amhar/r2.sh"

# 1. Parser equivalence against the previous implementation.
old_field() {
  local m
  m="$(printf '%s' "$2" | grep -o "<$1>[^<]*</$1>" | head -n 1)" || true
  m="${m#<"$1">}"
  printf '%s' "${m%</"$1">}"
}
old_parse() {
  { tr -d '\r\n'; echo; } | sed -e 's#<Contents>#\n<Contents>#g' -e 's#<CommonPrefixes>#\n<CommonPrefixes>#g' |
    while IFS= read -r line; do
      case "$line" in
        "<Contents>"*) printf '%s\t%s\t%s\n' "$(old_field LastModified "$line")" "$(old_field Size "$line")" "$(old_field Key "$line")" ;;
        "<CommonPrefixes>"*) printf 'PREFIX\t-\t%s\n' "$(old_field Prefix "$line")" ;;
      esac
    done
}
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<ListBucketResult><Name>b</Name><IsTruncated>false</IsTruncated>'
  for i in $(seq 1 200); do
    # R2 order (Key first) and S3 order (LastModified first), mixed.
    if ((i % 2)); then
      printf '<Contents><Key>g/ltx/0/%016x.ltx</Key><LastModified>2026-11-26T12:%02d:00.000Z</LastModified><ETag>"x"</ETag><Size>%d</Size></Contents>\n' "$i" $((i % 60)) "$i"
    else
      printf '<Contents><LastModified>2026-11-26T13:%02d:00.000Z</LastModified><Size>%d</Size><Key>g/ltx/1/%016x.ltx</Key></Contents>' $((i % 60)) "$i" "$i"
    fi
  done
  printf '<CommonPrefixes><Prefix>g/a/</Prefix></CommonPrefixes><CommonPrefixes><Prefix>g/b/</Prefix></CommonPrefixes></ListBucketResult>'
} > "$work/page.xml"
old_parse < "$work/page.xml" > "$work/old.out"
_r2_parse_list < "$work/page.xml" > "$work/new.out"
[[ "$(wc -l < "$work/new.out")" -eq 202 ]] || fail "parser: expected 202 rows, got $(wc -l < "$work/new.out")"
cmp -s "$work/old.out" "$work/new.out" || fail "parser output differs from the old parser"
pass "awk parser matches the old parser (202 rows, both element orders)"

# Synthetic bucket.
b="$work/s3/openpost-backups"
mkfiles() { # DIR COUNT MTIME
  mkdir -p "$1"
  local i
  for ((i = 1; i <= $2; i++)); do printf x > "$1/$(printf '%016x-%016x' "$i" "$i").ltx"; done
  find "$1" -type f -exec touch -d "$3" {} +
}
# Generations: names from 15 Nov to 27 Nov. The serving VM is 20261125...,
# a later boot (20261127...) restored but was never promoted, so its last
# write is older than the serving generation's.
day=15
for g in 20261115T080000Z-aaaaa1 20261116T080000Z-aaaaa2 20261117T080000Z-aaaaa3 20261118T080000Z-aaaaa4 \
  20261119T080000Z-aaaaa5 20261120T080000Z-aaaaa6 20261121T080000Z-aaaaa7 20261122T080000Z-aaaaa8 \
  20261123T080000Z-aaaaa9 20261124T080000Z-aaaab0 20261126T080000Z-aaaab2; do
  mkfiles "$b/backups/litestream-gen/$g/ltx/0" 150 "2026-11-$day 09:00:00Z"
  day=$((day + 1))
done
serving=20261125T080000Z-aaaab1
mkfiles "$b/backups/litestream-gen/$serving/ltx/0" 300 "2026-11-27 10:59:00Z"
mkfiles "$b/backups/litestream-gen/$serving/ltx/1" 50 "2026-11-27 10:00:00Z"
unpromoted=20261127T090000Z-aaaab3
mkfiles "$b/backups/litestream-gen/$unpromoted/ltx/9" 2 "2026-11-27 09:01:00Z"
mkfiles "$b/backups/litestream/ltx/0" 3000 "2026-11-26 12:10:00Z"
mkdir -p "$b/backups/sqlite"
for d in 20261120 20261121 20261122; do printf x > "$b/backups/sqlite/openpost-$d.db"; done

s3_port=19210
rclone serve s3 --dir-cache-time 0s --auth-key testkey,testsecret --addr "127.0.0.1:$s3_port" "$work/s3" > "$work/s3.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$s3_port/" && break; sleep 0.2; done

export AWS_ACCESS_KEY_ID=testkey AWS_SECRET_ACCESS_KEY=testsecret
export AWS_ENDPOINT_URL="http://127.0.0.1:$s3_port" AWS_REGION=us-east-1
export OPENPOST_BACKUP_BUCKET=openpost-backups
unset OPENPOST_S3_ACCESS_KEY_ID OPENPOST_S3_SECRET_ACCESS_KEY OPENPOST_S3_ENDPOINT OPENPOST_S3_REGION
export OPENPOST_DATA_DIR="$work/data"

# 2. Pagination.
n="$(R2_QUIET=1 R2_LIST_MAX_KEYS=100 r2_list backups/litestream/ | wc -l | tr -d ' ')"
[[ "$n" -eq 3000 ]] || fail "pagination: expected 3000 keys, got $n"
pass "r2_list follows pagination (3000 keys at max-keys=100)"

snapshot_tree() { (cd "$work/s3" && find . -type f -printf '%p %s %T@\n' | sort); }
before="$(snapshot_tree)"

# 3. --list ordering and speed.
t0="$(date +%s)"
bash "$repo/scripts/amhar/restore.sh" --list > "$work/list.log" 2>&1 || {
  cat "$work/list.log"
  fail "--list failed"
}
dt=$(($(date +%s) - t0))
first="$(sed -n '/^restore candidates/{n;p;q}' "$work/list.log")"
[[ "$first" == *"litestream	backups/litestream-gen/$serving" ]] || {
  cat "$work/list.log"
  fail "--list: first candidate should be the serving generation, got: $first"
}
grep -q "r2: list backups/litestream/: 3000 entries" "$work/list.log" || fail "--list did not probe the legacy path"
grep -qP '^\s+2026-11-26T12:10:00Z\tlitestream\tbackups/litestream$' "$work/list.log" || fail "--list: legacy row missing or unprobed"
grep -q "found 13 generation(s)" "$work/list.log" || fail "--list did not find 13 generations"
grep -q "list: a boot would try backups/litestream-gen/$serving first" "$work/list.log" || fail "--list summary line"
[[ "$dt" -le 20 ]] || fail "--list took ${dt}s (expected well under 20s)"
pass "--list picks the serving generation over a newer, unpromoted one; legacy probed; ${dt}s"

# 5. Over the listing budget: fail closed, never guess by name.
rc=0
OPENPOST_RESTORE_LIST_BUDGET_SECONDS=-1 bash "$repo/scripts/amhar/restore.sh" --list > "$work/budget.log" 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] || fail "over budget: expected exit 1, got $rc"
grep -q "refusing to guess" "$work/budget.log" || fail "over budget: no clear message"
pass "over the listing budget fails closed with a clear message"

# 4b. --check-fast (needs Litestream; the synthetic LTX files are not real, so
#     every candidate fails and it must report fail closed, changing nothing).
if [[ -n "${LITESTREAM_BIN:-}" && -x "${LITESTREAM_BIN}" ]]; then
  rc=0
  OPENPOST_RESTORE_ATTEMPTS=1 OPENPOST_RESTORE_TIMEOUT_SECONDS=20 \
    bash "$repo/scripts/amhar/restore.sh" --check-fast > "$work/cf.log" 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || {
    cat "$work/cf.log"
    fail "--check-fast on broken replicas should exit 1, got $rc"
  }
  grep -q "check-fast: a boot would FAIL CLOSED" "$work/cf.log" || fail "--check-fast summary"
  grep -q "skipped: sqlite snapshots are never restored automatically" "$work/cf.log" || fail "--check-fast did not skip snapshots"
  pass "--check-fast follows the boot order and reports fail closed"
else
  echo "SKIP: --check-fast case (set LITESTREAM_BIN)"
fi

# 4. Nothing written.
[[ "$(snapshot_tree)" == "$before" ]] || fail "the bucket changed during --list/--check-fast"
[[ ! -e "$work/data/db/openpost.db" ]] || fail "a live database file was created"
[[ ! -e "$work/data/generation" ]] || fail "a generation file was created"
pass "--list and --check-fast wrote nothing to the bucket or the live DB path"

# 6. Stalled endpoint: accepts TCP, never answers.
if command -v python3 > /dev/null; then
  stall_port=19211
  python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
held = []
while True:
    c, _ = s.accept(); held.append(c)
' "$stall_port" &
  pids+=($!)
  sleep 0.5
  t0="$(date +%s)"
  rc=0
  AWS_ENDPOINT_URL="http://127.0.0.1:$stall_port" R2_LIST_MAX_TIME=3 R2_CURL_RETRIES=1 \
    bash "$repo/scripts/amhar/restore.sh" --list > "$work/stall.log" 2>&1 || rc=$?
  dt=$(($(date +%s) - t0))
  [[ "$rc" -eq 1 ]] || fail "stalled endpoint: expected exit 1, got $rc"
  grep -q "could not list backups in R2" "$work/stall.log" || fail "stalled endpoint: no clear error"
  grep -qi "timed out\|timeout" "$work/stall.log" || fail "stalled endpoint: no timeout in the log"
  grep -q "127.0.0.1:$stall_port" "$work/stall.log" && fail "stalled endpoint: endpoint not redacted"
  [[ "$dt" -le 20 ]] || fail "stalled endpoint took ${dt}s"
  pass "stalled endpoint fails in ${dt}s with a clear, redacted timeout"
else
  echo "SKIP: stalled endpoint case (no python3)"
fi

# 7. Legacy still being written (old start.sh on the serving VM) wins.
find "$b/backups/litestream/ltx/0" -name '0000000000000bb8-*' -exec touch -d "2026-11-27 11:05:00Z" {} +
bash "$repo/scripts/amhar/restore.sh" --list > "$work/legacy-live.log" 2>&1 || fail "--list (live legacy) failed"
first="$(sed -n '/^restore candidates/{n;p;q}' "$work/legacy-live.log")"
[[ "$first" == *"2026-11-27T11:05:00Z	litestream	backups/litestream" ]] || fail "live legacy should be first, got: $first"
pass "a legacy path written by an old-code VM is newest and wins"

# 8. No generations: the legacy path is listed and wins.
OPENPOST_LITESTREAM_GEN_ROOT=backups/no-generations-here bash "$repo/scripts/amhar/restore.sh" --list > "$work/legacy.log" 2>&1 || fail "--list (no generations) failed"
first="$(sed -n '/^restore candidates/{n;p;q}' "$work/legacy.log")"
[[ "$first" == *"	litestream	backups/litestream" && "$first" != *unprobed* ]] || fail "no generations: legacy should be probed and first, got: $first"
grep -q "found 0 generation(s)" "$work/legacy.log" || fail "no generations: count line"
pass "no generations: legacy path is listed and first"

echo "ALL PASSED"
