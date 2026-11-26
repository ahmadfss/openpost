#!/usr/bin/env bash
# Restore SQLite onto a wiped or empty data directory from R2.
#
# Candidates, newest write first:
#   - each Litestream generation under $OPENPOST_LITESTREAM_GEN_ROOT/<gen>/
#   - the legacy Litestream path $OPENPOST_LITESTREAM_PREFIX (read-only now)
#   - sqlite .backup snapshots under $OPENPOST_BACKUP_PREFIX/. These can be up
#     to a day old (or empty, from the first boot), so a boot never picks one
#     on its own. They are used only with --from sqlite:KEY (or
#     OPENPOST_RESTORE_FROM), or with OPENPOST_RESTORE_ALLOW_SNAPSHOT=true.
# The first candidate that restores and passes an integrity check wins.
#
# Usage: restore.sh [--force] [--check] [--from litestream:PREFIX|sqlite:KEY]
#   --force  replace an existing local database
#   --check  restore every candidate into a temp dir, report, change nothing
#   --from   use only this source (operator override)
#
# Exit codes: 0 restored (or --check found a good candidate)
#             3 R2 has no backups at all (first boot; a fresh DB is fine)
#             1 backups exist but none restored cleanly (do NOT start fresh)
# Never prints secrets.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$here/common.sh"
# shellcheck disable=SC1091
source "$here/r2.sh"
amhar_load_pin
amhar_prepare_dirs
amhar_export_r2

force=0
check=0
from="${OPENPOST_RESTORE_FROM:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=1 ;;
    --check) check=1 ;;
    --from)
      from="${2:?--from needs a value}"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

db="$(amhar_db_path)"
if [[ "$check" -ne 1 && -f "$db" && "$force" -ne 1 ]]; then
  echo "database already exists at $db; pass --force to replace it" >&2
  exit 1
fi
if ! amhar_r2_configured; then
  echo "R2 credentials are not set; cannot restore" >&2
  exit 1
fi

ls_bin="${LITESTREAM_BIN:-$(amhar_bin_dir)/litestream}"
restore_timeout="${OPENPOST_RESTORE_TIMEOUT_SECONDS:-300}"
allow_snapshot="${OPENPOST_RESTORE_ALLOW_SNAPSHOT:-false}"
workdir="$(amhar_data_dir)/tmp/restore-$$"
mkdir -p "$workdir"
trap 'rm -rf "$workdir"' EXIT

redact() {
  # Hide the R2 account endpoint in anything Litestream prints.
  sed -E 's#endpoint=[^ &"]*#endpoint=<redacted>#g'
}

# Print "<newest LastModified>\t<object count>" for a prefix, or nothing if empty.
newest_under() {
  local listing
  listing="$(r2_list "$1")" || return 1
  [[ -n "$listing" ]] || return 0
  printf '%s\n' "$listing" | cut -f1 | sort | tail -n 1 | tr -d '\n'
  printf '\t%s\n' "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
}

# Print candidates as "<ts>\t<kind>\t<location>", newest first.
list_candidates() {
  local line gen snaps
  {
    while IFS=$'\t' read -r _ _ gen; do
      [[ -n "$gen" ]] || continue
      line="$(newest_under "$gen")" || return 1
      [[ -n "$line" ]] && printf '%s\tlitestream\t%s\n' "${line%%$'\t'*}" "${gen%/}"
    done < <(r2_list "${OPENPOST_LITESTREAM_GEN_ROOT%/}/" / | grep '^PREFIX' || true)

    line="$(newest_under "${OPENPOST_LITESTREAM_PREFIX%/}/")" || return 1
    [[ -n "$line" ]] && printf '%s\tlitestream\t%s\n' "${line%%$'\t'*}" "${OPENPOST_LITESTREAM_PREFIX%/}"

    snaps="$(r2_list "${OPENPOST_BACKUP_PREFIX%/}/" | grep -E '\.db$' || true)"
    if [[ -n "$snaps" ]]; then
      printf '%s\n' "$snaps" | sort -r | head -n 5 | awk -F'\t' '{print $1 "\tsqlite\t" $3}'
    fi
  } | sort -r
}

# Integrity check for a restored file when sqlite3 is available.
sqlite_ok() {
  local f="$1" out
  if ! command -v sqlite3 > /dev/null 2>&1; then
    return 0
  fi
  out="$(sqlite3 "$f" 'PRAGMA quick_check;' 2>&1 | head -n 3)" || return 1
  [[ "$out" == "ok" ]] || {
    echo "  quick_check failed: $(printf '%s' "$out" | head -n 1)" >&2
    return 1
  }
}

describe() {
  local f="$1" users=""
  if command -v sqlite3 > /dev/null 2>&1; then
    users="$(sqlite3 "$f" 'SELECT count(*) FROM users;' 2> /dev/null || echo '?')"
  elif command -v python3 > /dev/null 2>&1; then
    users="$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from users").fetchone()[0])' "$f" 2> /dev/null || echo '?')"
  fi
  [[ -n "$users" ]] && echo "  users in restored database: $users"
  return 0
}

try_litestream() {
  local prefix="$1" out="$2" attempt
  if [[ ! -x "$ls_bin" ]]; then
    echo "  litestream binary missing at $ls_bin" >&2
    return 1
  fi
  for attempt in 1 2 3; do
    rm -f "$out" "$out-wal" "$out-shm" "$out-txid"
    if timeout "$restore_timeout" "$ls_bin" restore -integrity-check quick -o "$out" \
      "$(amhar_litestream_url "$prefix")" > "$workdir/ls.out" 2> "$workdir/ls.err"; then
      sqlite_ok "$out" && return 0
    else
      echo "  litestream restore attempt $attempt failed: $(tail -n 1 "$workdir/ls.err" | redact)" >&2
    fi
    # Files can move under a live writer's compaction; retry a little later.
    sleep $((attempt * 3))
  done
  return 1
}

try_sqlite() {
  local key="$1" out="$2"
  rm -f "$out"
  if ! r2_get "$key" "$out"; then
    echo "  download failed for $key" >&2
    return 1
  fi
  sqlite_ok "$out"
}

if [[ -n "$from" ]]; then
  candidates="$(printf 'override\t%s\t%s\n' "${from%%:*}" "${from#*:}")"
else
  candidates="$(list_candidates)" || {
    echo "could not list backups in R2; refusing to guess" >&2
    exit 1
  }
fi

if [[ -z "$candidates" ]]; then
  echo "no backups found in R2 (first boot)"
  exit 3
fi

echo "restore candidates (newest first):"
printf '%s\n' "$candidates" | sed 's/^/  /'

good=0
boot_choice=""
n=0
while IFS=$'\t' read -r ts kind loc; do
  n=$((n + 1))
  out="$workdir/candidate-$n.db"
  echo "trying $kind $loc (last write $ts)"
  if [[ "$kind" == "sqlite" && "$ts" != "override" && "$allow_snapshot" != "true" && "$check" -ne 1 ]]; then
    echo "  skipped: sqlite snapshots are never restored automatically (set OPENPOST_RESTORE_FROM=sqlite:$loc to use it)"
    continue
  fi
  ok=1
  case "$kind" in
    litestream) try_litestream "$loc" "$out" || ok=0 ;;
    sqlite) try_sqlite "$loc" "$out" || ok=0 ;;
    *)
      echo "  unknown source kind: $kind" >&2
      ok=0
      ;;
  esac
  if [[ "$ok" -ne 1 ]]; then
    echo "  FAILED: $kind $loc"
    continue
  fi
  echo "  OK: $kind $loc"
  describe "$out"
  good=$((good + 1))
  if [[ "$check" -eq 1 ]]; then
    if [[ -z "$boot_choice" && ("$kind" == "litestream" || "$ts" == "override" || "$allow_snapshot" == "true") ]]; then
      boot_choice="$kind $loc"
    fi
    continue
  fi
  # Replace the live files only after a successful, checked restore.
  rm -f "$db" "$db-wal" "$db-shm"
  rm -rf "$(dirname "$db")/.$(basename "$db")-litestream" "$db-litestream"
  mv -f "$out" "$db"
  printf '%s\t%s\n' "$kind" "$loc" > "$(amhar_data_dir)/restored-from"
  echo "database restored to $db from $kind $loc"
  exit 0
done <<< "$candidates"

if [[ "$check" -eq 1 ]]; then
  echo "check: $good candidate(s) restore cleanly"
  if [[ -n "$boot_choice" ]]; then
    echo "check: a boot would restore from: $boot_choice"
    exit 0
  fi
  echo "check: a boot would FAIL CLOSED (no Litestream candidate restores cleanly)" >&2
  exit 1
fi
echo "restore failed: backups exist in R2 but none restored cleanly" >&2
exit 1
