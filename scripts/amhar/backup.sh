#!/usr/bin/env bash
# Take a consistent SQLite snapshot with sqlite3 .backup and upload it to R2
# with curl (scripts/amhar/r2.sh). The deploy image has no python3.
# Does not print secrets. Safe to run while OpenPost is up.
# Keys written:
#   $OPENPOST_BACKUP_PREFIX/<generation>/openpost-<UTC stamp>.db
#   $OPENPOST_BACKUP_PREFIX/openpost-latest.db
# Restores never pick these automatically; see restore.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$here/common.sh"
# shellcheck disable=SC1091
source "$here/r2.sh"
amhar_load_pin
amhar_prepare_dirs
amhar_export_r2

db="$(amhar_db_path)"
if [[ ! -f "$db" ]]; then
  echo "no database at $db; nothing to back up" >&2
  exit 1
fi
if ! amhar_r2_configured; then
  echo "R2 credentials are not set; cannot upload a backup" >&2
  exit 1
fi
if ! command -v sqlite3 > /dev/null 2>&1; then
  echo "sqlite3 is not installed (add pkgs.sqlite to replit.nix); cannot back up" >&2
  exit 1
fi

gen="$(amhar_current_generation)"
gen="${gen:-manual}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
snap="$(amhar_data_dir)/tmp/openpost-${stamp}.db"
latest_key="${OPENPOST_BACKUP_PREFIX%/}/openpost-latest.db"
dated_key="${OPENPOST_BACKUP_PREFIX%/}/${gen}/openpost-${stamp}.db"
trap 'rm -f "$snap"' EXIT

sqlite3 "$db" ".backup '$snap'"
check="$(sqlite3 "$snap" 'PRAGMA quick_check;' | head -n 1)"
if [[ "$check" != "ok" ]]; then
  echo "snapshot failed quick_check ($check); not uploading" >&2
  exit 1
fi
users="$(sqlite3 "$snap" 'SELECT count(*) FROM users;' 2> /dev/null || echo 0)"
r2_put "$snap" "$dated_key"
if [[ "$users" =~ ^[0-9]+$ && "$users" -gt 0 ]]; then
  r2_put "$snap" "$latest_key"
  echo "backup uploaded: $dated_key and $latest_key (UTC $stamp, $users users)"
else
  echo "backup uploaded: $dated_key (UTC $stamp); openpost-latest.db left alone because the snapshot has no users"
fi
