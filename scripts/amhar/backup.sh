#!/usr/bin/env bash
# Take a consistent SQLite snapshot with sqlite3 .backup and upload it to R2.
# Does not print secrets. Safe to run while OpenPost is up.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
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

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
snap="$(amhar_data_dir)/tmp/openpost-${stamp}.db"
latest_key="${OPENPOST_BACKUP_PREFIX}/openpost-latest.db"
dated_key="${OPENPOST_BACKUP_PREFIX}/openpost-${stamp}.db"

sqlite3 "$db" ".backup '$snap'"
python3 "$(amhar_root)/scripts/amhar/r2_sync.py" put "$snap" "$dated_key"
python3 "$(amhar_root)/scripts/amhar/r2_sync.py" put "$snap" "$latest_key"
rm -f "$snap"
echo "backup uploaded: $dated_key and $latest_key (UTC $stamp)"
