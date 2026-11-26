#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
# Local end-to-end test of the Replit blue-green boot path. No R2, no Replit.
#
# Runs a throwaway S3 server (rclone serve s3) and two "VMs" (separate data
# dirs and ports) with the real start.sh, the pinned OpenPost binary and the
# pinned Litestream binary, then checks:
#   1. first boot on an empty bucket starts fresh (restore exit 3)
#   2. a second VM restores VM A's data while A keeps running and writing,
#      and replicates to its own generation path (no shared path)
#   3. a third boot restores the newest generation cleanly
#   4. a boot whose only replica is broken fails closed (exit 1), never empty
#   5. backup.sh uploads with curl (no python3)
#
# Usage: AMHAR_TEST_BIN_DIR=/path/with/openpost-server+litestream \
#          bash scripts/amhar/tests/blue-green-local.sh
# Needs: rclone, curl, sqlite3. Takes about six minutes.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
bin_src="${AMHAR_TEST_BIN_DIR:?set AMHAR_TEST_BIN_DIR to a dir holding openpost-server and litestream}"
for b in openpost-server litestream; do
  [[ -x "$bin_src/$b" ]] || {
    echo "missing $bin_src/$b" >&2
    exit 2
  }
done
for c in rclone curl sqlite3; do
  command -v "$c" > /dev/null || {
    echo "missing $c" >&2
    exit 2
  }
done

work="$(mktemp -d /tmp/amhar-bg-XXXXXX)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  wait 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() { echo "PASS: $*"; }

# Fake S3.
mkdir -p "$work/s3/openpost-backups"
s3_port=19100
rclone serve s3 --auth-key testkey,testsecret --addr "127.0.0.1:$s3_port" "$work/s3" > "$work/s3.log" 2>&1 &
pids+=($!)
sleep 2

export AWS_ACCESS_KEY_ID=testkey AWS_SECRET_ACCESS_KEY=testsecret
export AWS_ENDPOINT_URL="http://127.0.0.1:$s3_port" AWS_REGION=us-east-1
export OPENPOST_BACKUP_BUCKET=openpost-backups
unset OPENPOST_S3_ACCESS_KEY_ID OPENPOST_S3_SECRET_ACCESS_KEY OPENPOST_S3_ENDPOINT OPENPOST_S3_REGION

# A "VM" is a copy of the deploy scripts with its own bin/ and data dir.
make_vm() {
  local name="$1"
  mkdir -p "$work/$name/repo/bin" "$work/$name/repo/deploy/replit"
  cp -r "$repo/scripts" "$work/$name/repo/"
  cp "$repo/deploy/replit/pin.env" "$work/$name/repo/deploy/replit/"
  ln -s "$bin_src/openpost-server" "$work/$name/repo/bin/openpost-server"
  ln -s "$bin_src/litestream" "$work/$name/repo/bin/litestream"
}

start_vm() {
  local name="$1" port="$2"
  (
    cd "$work/$name/repo"
    export OPENPOST_DATA_DIR="$work/$name/data" OPENPOST_PORT="$port"
    export OPENPOST_STORAGE_DRIVER=local OPENPOST_DISABLE_REGISTRATIONS=false
    export OPENPOST_JWT_SECRET=test-jwt-secret-test-jwt-secret-0001
    export OPENPOST_ENCRYPTION_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=
    export OPENPOST_DIAGNOSTICS_ENABLED=false OPENPOST_BACKUP_FIRST_DELAY_SECONDS=86400
    # download-binary.sh verifies the pinned sha256; the symlinked binary passes.
    exec bash scripts/amhar/start.sh
  ) > "$work/$name.log" 2>&1 &
  pids+=($!)
  echo $! > "$work/$name.pid"
}

wait_ready() {
  local port="$1"
  for _ in $(seq 1 120); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/api/v1/ready" 2> /dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

register() {
  local port="$1" who="$2"
  curl -fsS -o /dev/null -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$port" \
    -d "{\"email\":\"$who@example.com\",\"username\":\"$who\",\"password\":\"long-password-123\",\"accepted_legal\":true}" \
    "http://127.0.0.1:$port/api/v1/auth/register"
}

users_in() {
  sqlite3 "file:$1?mode=ro" 'SELECT group_concat(username, ",") FROM (SELECT username FROM users ORDER BY username);'
}

gen_of() { tr -d ' \n' < "$work/$1/data/generation"; }

# 1. First boot on an empty bucket.
make_vm a
start_vm a 18181
wait_ready 18181 || {
  tail -40 "$work/a.log"
  fail "VM a never became ready"
}
grep -q "R2 has no backups yet" "$work/a.log" || fail "VM a did not take the first-boot path"
register 18181 alice
register 18181 bob
sleep 5 # let Litestream sync
pass "first boot fresh, 2 users created on VM a (gen $(gen_of a))"

# 2. Blue-green: VM b boots while VM a is still running and writing.
make_vm b
start_vm b 18182
wait_ready 18182 || {
  tail -40 "$work/b.log"
  fail "VM b never became ready"
}
grep -q "database restored to" "$work/b.log" || fail "VM b did not restore"
[[ "$(gen_of a)" != "$(gen_of b)" ]] || fail "VM a and VM b share a generation"
[[ "$(users_in "$work/b/data/db/openpost.db")" == "alice,bob" ]] || fail "VM b restored the wrong users: $(users_in "$work/b/data/db/openpost.db")"
pass "VM b restored alice,bob from gen $(gen_of a) and writes to its own gen $(gen_of b)"

# Both VMs keep writing for a while, like a real promote overlap.
sleep 40
# Cut over: stop VM a (Replit stops the old VM after the promote).
kill -TERM "$(cat "$work/a.pid")" 2> /dev/null || true
sleep 3
register 18182 carol
sleep 5

# 3. A third boot restores the newest generation (VM b's) cleanly.
make_vm c
start_vm c 18183
wait_ready 18183 || {
  tail -40 "$work/c.log"
  fail "VM c never became ready"
}
grep -q "from litestream backups/litestream-gen/$(gen_of b)" "$work/c.log" || {
  grep -E "restore|trying|OK|FAILED" "$work/c.log" | head -20
  fail "VM c did not pick VM b's generation"
}
[[ "$(users_in "$work/c/data/db/openpost.db")" == "alice,bob,carol" ]] || fail "VM c users: $(users_in "$work/c/data/db/openpost.db")"
[[ "$(sqlite3 "$work/c/data/db/openpost.db" 'PRAGMA integrity_check;')" == "ok" ]] || fail "VM c integrity_check"
pass "VM c restored alice,bob,carol from the newest generation, integrity ok"

# 5. backup.sh with curl.
(
  cd "$work/c/repo"
  OPENPOST_DATA_DIR="$work/c/data" bash scripts/amhar/backup.sh
) > "$work/backup.log" 2>&1 || {
  cat "$work/backup.log"
  fail "backup.sh failed"
}
grep -q "backup uploaded" "$work/backup.log" || fail "backup.sh did not upload"
[[ -f "$work/s3/openpost-backups/backups/sqlite/openpost-latest.db" ]] || fail "openpost-latest.db missing"
pass "backup.sh uploaded with curl: $(grep 'backup uploaded' "$work/backup.log")"

# Stop everything that writes before the negative test.
for n in b c; do kill -TERM "$(cat "$work/$n.pid")" 2> /dev/null || true; done
sleep 3

# 4. Fail closed: only a broken replica is left.
rm -rf "$work/s3/openpost-backups/backups/litestream-gen"
mkdir -p "$work/s3/openpost-backups/backups/litestream/0000"
printf 'not an ltx file' > "$work/s3/openpost-backups/backups/litestream/0000/0000000000000001-0000000000000001.ltx"
make_vm d
rc=0
(
  cd "$work/d/repo"
  export OPENPOST_DATA_DIR="$work/d/data" OPENPOST_PORT=18184 OPENPOST_STORAGE_DRIVER=local
  bash scripts/amhar/start.sh
) > "$work/d.log" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "VM d started even though no replica restores"
grep -q "FATAL: backups exist in R2 but none restored cleanly" "$work/d.log" || fail "VM d did not fail closed"
grep -q "skipped: sqlite snapshots are never restored automatically" "$work/d.log" || fail "VM d did not skip the sqlite snapshot"
[[ ! -f "$work/d/data/db/openpost.db" ]] || fail "VM d created a database"
pass "VM d failed closed (exit $rc) and did not create an empty database"

echo "ALL PASSED"
