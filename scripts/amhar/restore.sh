#!/usr/bin/env bash
# Restore SQLite onto a wiped or empty data directory from R2.
#
# Candidates:
#   - each Litestream generation under $OPENPOST_LITESTREAM_GEN_ROOT/<gen>/
#   - the legacy Litestream path $OPENPOST_LITESTREAM_PREFIX (read-only now)
#   - sqlite .backup snapshots under $OPENPOST_BACKUP_PREFIX/. These can be up
#     to a day old (or empty, from the first boot), so a boot never picks one
#     on its own. They are used only with --from sqlite:KEY (or
#     OPENPOST_RESTORE_FROM), or with OPENPOST_RESTORE_ALLOW_SNAPSHOT=true.
# The first candidate that restores and passes an integrity check wins.
#
# Boot path (default, --list, --check-fast): one delimiter listing of the
# generation root, then the newest write of each generation and of the legacy
# path (a VM on the old start.sh writes there), all inside
# OPENPOST_RESTORE_LIST_BUDGET_SECONDS (default 150; over budget fails
# closed). Each R2 request has hard timeouts (scripts/amhar/r2.sh) and logs one
# progress line. Candidates are then tried newest write first; the next one is
# tried only if a restore fails.
# --check keeps the full report: every candidate, every snapshot.
#
# Usage: restore.sh [--force] [--check|--check-fast|--list] [--from litestream:PREFIX|sqlite:KEY]
#   --force       replace an existing local database
#   --check       restore every candidate into a temp dir, report, change nothing
#   --check-fast  do exactly what a boot does (same listing, same order, stop at
#                 the first good candidate) but into a temp dir; change nothing
#   --list        print the boot-path candidates and timings only; no restore
#   --from        use only this source (operator override)
# --check, --check-fast and --list never write to R2 or to the live database.
#
# Exit codes: 0 restored (or a check/list found a good candidate)
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
mode=boot
from="${OPENPOST_RESTORE_FROM:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=1 ;;
    --check)
      check=1
      mode=check
      ;;
    --check-fast) mode="check-fast" ;;
    --list) mode=list ;;
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
if [[ "$mode" == "boot" && -f "$db" && "$force" -ne 1 ]]; then
  echo "database already exists at $db; pass --force to replace it" >&2
  exit 1
fi
if ! amhar_r2_configured; then
  echo "R2 credentials are not set; cannot restore" >&2
  exit 1
fi

ls_bin="${LITESTREAM_BIN:-$(amhar_bin_dir)/litestream}"
restore_timeout="${OPENPOST_RESTORE_TIMEOUT_SECONDS:-300}"
restore_attempts="${OPENPOST_RESTORE_ATTEMPTS:-3}"
list_budget="${OPENPOST_RESTORE_LIST_BUDGET_SECONDS:-150}"
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

gen_root="${OPENPOST_LITESTREAM_GEN_ROOT%/}"
legacy="${OPENPOST_LITESTREAM_PREFIX%/}"
snap_root="${OPENPOST_BACKUP_PREFIX%/}"

# Print the newest 5 sqlite snapshots as candidates.
list_snapshots() {
  local snaps
  snaps="$(r2_list "$snap_root/" | grep -E '\.db$' || true)"
  if [[ -n "$snaps" ]]; then
    printf '%s\n' "$snaps" | sort -r | head -n 5 | awk -F'\t' '{print $1 "\tsqlite\t" $3}'
  fi
}

# Generation prefixes ("<root>/<gen>/"), newest name first.
list_generations() {
  r2_list "$gen_root/" / | awk -F'\t' '$1 == "PREFIX" { print $3 }' | sort -r
}

# --check: every candidate, ordered by newest write.
# Prints "<ts>\t<kind>\t<location>", newest first.
list_candidates_full() {
  local line gen gens
  gens="$(list_generations)" || return 1
  {
    while IFS= read -r gen; do
      [[ -n "$gen" ]] || continue
      line="$(newest_under "$gen")" || return 1
      [[ -n "$line" ]] && printf '%s\tlitestream\t%s\n' "${line%%$'\t'*}" "${gen%/}"
    done <<< "$gens"

    line="$(newest_under "$legacy/")" || return 1
    [[ -n "$line" ]] && printf '%s\tlitestream\t%s\n' "${line%%$'\t'*}" "$legacy"

    list_snapshots || return 1
  } | sort -r
}

# Boot path. Same output format and order as --check, but with progress
# lines and a total time budget. Over budget means fail closed: guessing a
# candidate by name could promote stale data (a newer-named generation from a
# boot that was never promoted, or a legacy path still being written).
list_candidates_fast() {
  local gens gen line t0 probed="" n_gens=0
  t0="$(date +%s)"
  over_budget() {
    if (($(date +%s) - t0 > list_budget)); then
      echo "listing R2 took longer than OPENPOST_RESTORE_LIST_BUDGET_SECONDS=${list_budget}s; refusing to guess" >&2
      echo "set OPENPOST_RESTORE_FROM=litestream:<prefix> to restore one known path, or raise the budget" >&2
      return 0
    fi
    return 1
  }
  gens="$(list_generations)" || return 1
  while IFS= read -r gen; do
    [[ -n "$gen" ]] || continue
    n_gens=$((n_gens + 1))
    over_budget && return 1
    line="$(newest_under "$gen")" || return 1
    [[ -n "$line" ]] && probed+="$(printf '%s\tlitestream\t%s' "${line%%$'\t'*}" "${gen%/}")"$'\n'
  done <<< "$gens"
  echo "found $n_gens generation(s) under $gen_root/ in $(($(date +%s) - t0))s" >&2

  # The legacy path is always probed. It is read-only for the new scripts, but
  # a VM still running the pre-generation start.sh (the one serving before the
  # first per-generation publish goes live) keeps writing there, so it can be
  # the newest data.
  over_budget && return 1
  line="$(newest_under "$legacy/")" || return 1
  [[ -n "$line" ]] && probed+="$(printf '%s\tlitestream\t%s' "${line%%$'\t'*}" "$legacy")"$'\n'
  over_budget && return 1

  [[ -n "$probed" ]] && printf '%s' "$probed" | sort -r

  # Snapshots come last. A boot skips them unless allowed, but they still
  # decide "first boot" (exit 3) versus "fail closed" (exit 1). One small call.
  list_snapshots || return 1
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
  local prefix="$1" out="$2" attempt t0
  if [[ ! -x "$ls_bin" ]]; then
    echo "  litestream binary missing at $ls_bin" >&2
    return 1
  fi
  for ((attempt = 1; attempt <= restore_attempts; attempt++)); do
    rm -f "$out" "$out-wal" "$out-shm" "$out-txid"
    t0="$(date +%s)"
    echo "  litestream restore attempt $attempt/$restore_attempts (timeout ${restore_timeout}s)"
    if timeout --kill-after=10 "$restore_timeout" "$ls_bin" restore -integrity-check quick -o "$out" \
      "$(amhar_litestream_url "$prefix")" < /dev/null > "$workdir/ls.out" 2> "$workdir/ls.err"; then
      echo "  litestream restore finished in $(($(date +%s) - t0))s"
      sqlite_ok "$out" && return 0
    else
      echo "  litestream restore attempt $attempt failed after $(($(date +%s) - t0))s: $(tail -n 1 "$workdir/ls.err" | redact)" >&2
    fi
    # Files can move under a live writer's compaction; retry a little later.
    [[ "$attempt" -lt "$restore_attempts" ]] && sleep $((attempt * 3))
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
  list_t0="$(date +%s)"
  echo "listing restore candidates in R2 (mode $mode)"
  if [[ "$mode" == "check" ]]; then
    candidates="$(list_candidates_full)" || candidates_rc=1
  else
    candidates="$(list_candidates_fast)" || candidates_rc=1
  fi
  if [[ "${candidates_rc:-0}" -ne 0 ]]; then
    echo "could not list backups in R2 after $(($(date +%s) - list_t0))s; refusing to guess" >&2
    exit 1
  fi
  echo "listed candidates in $(($(date +%s) - list_t0))s"
fi

if [[ -z "$candidates" ]]; then
  echo "no backups found in R2 (first boot)"
  exit 3
fi

echo "restore candidates (newest first):"
printf '%s\n' "$candidates" | sed 's/^/  /'

if [[ "$mode" == "list" ]]; then
  if printf '%s\n' "$candidates" | cut -f2 | grep -qx litestream; then
    echo "list: a boot would try $(printf '%s\n' "$candidates" | awk -F'\t' '$2 == "litestream" { print $3; exit }') first"
  else
    echo "list: no Litestream candidate; a boot would FAIL CLOSED unless a snapshot is allowed" >&2
  fi
  exit 0
fi

good=0
boot_choice=""
n=0
while IFS=$'\t' read -r ts kind loc; do
  n=$((n + 1))
  out="$workdir/candidate-$n.db"
  echo "trying $kind $loc (last write $ts)"
  if [[ "$kind" == "sqlite" && "$ts" != "override" && "$allow_snapshot" != "true" && "$mode" != "check" ]]; then
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
  if [[ "$mode" == "check-fast" ]]; then
    echo "check-fast: a boot would restore from: $kind $loc (total $((SECONDS))s; nothing changed)"
    exit 0
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
if [[ "$mode" == "check-fast" ]]; then
  echo "check-fast: a boot would FAIL CLOSED (no candidate restores cleanly)" >&2
  exit 1
fi
echo "restore failed: backups exist in R2 but none restored cleanly" >&2
exit 1
