#!/usr/bin/env bash
# Restore SQLite onto a wiped or empty data directory.
# Prefers Litestream if a replica exists; falls back to the latest nightly .backup object.
# Refuses to overwrite an existing database unless --force is passed.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
amhar_load_pin
amhar_prepare_dirs
amhar_export_r2

force=0
if [[ "${1:-}" == "--force" ]]; then
  force=1
fi

db="$(amhar_db_path)"
if [[ -f "$db" && "$force" -ne 1 ]]; then
  echo "database already exists at $db; pass --force to replace it" >&2
  exit 1
fi
if ! amhar_r2_configured; then
  echo "R2 credentials are not set; cannot restore" >&2
  exit 1
fi

ls_bin="$(amhar_bin_dir)/litestream"
workdir="$(amhar_data_dir)/tmp/restore-$$"
mkdir -p "$workdir"

restored=0
if [[ -x "$ls_bin" ]]; then
  cfg="$(amhar_data_dir)/litestream.yml"
  if [[ ! -f "$cfg" ]]; then
    bash "$(amhar_root)/scripts/amhar/write-litestream-config.sh" "$cfg"
  fi
  if "$ls_bin" restore -config "$cfg" -o "$workdir/openpost.db" "$db" 2>"$workdir/litestream.err"; then
    restored=1
    echo "restored with litestream"
  else
    echo "litestream restore skipped or failed; trying latest nightly snapshot" >&2
  fi
fi

if [[ "$restored" -eq 0 ]]; then
  python3 "$(amhar_root)/scripts/amhar/r2_sync.py" get "${OPENPOST_BACKUP_PREFIX}/openpost-latest.db" "$workdir/openpost.db"
  restored=1
  echo "restored from ${OPENPOST_BACKUP_PREFIX}/openpost-latest.db"
fi

if [[ "$restored" -ne 1 || ! -f "$workdir/openpost.db" ]]; then
  echo "restore failed" >&2
  exit 1
fi

# Replace the live files only after a successful download.
rm -f "$db" "$db-wal" "$db-shm"
mv -f "$workdir/openpost.db" "$db"
rm -rf "$workdir"
echo "database restored to $db"
