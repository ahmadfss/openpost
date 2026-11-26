#!/usr/bin/env bash
# Start OpenPost on the Replit Reserved VM.
# Downloads the pinned binary if needed, restores SQLite from R2 after a
# republish wipe, then serves HTTP and background jobs in one process.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
cd "$(amhar_root)"
amhar_load_pin
amhar_prepare_dirs
amhar_export_r2

bash scripts/amhar/download-binary.sh
bash scripts/amhar/download-litestream.sh || echo "litestream download failed; continuous replication will be skipped" >&2

# OpenPost ignores Replit's $PORT unless OPENPOST_PORT is set.
export OPENPOST_PORT="${OPENPOST_PORT:-${PORT:-8080}}"
export OPENPOST_EDITION="${OPENPOST_EDITION:-selfhost}"
export OPENPOST_DATABASE_DRIVER="${OPENPOST_DATABASE_DRIVER:-sqlite}"
export OPENPOST_DATABASE_PATH="${OPENPOST_DATABASE_PATH:-$(amhar_db_path)}"
export OPENPOST_STORAGE_DRIVER="${OPENPOST_STORAGE_DRIVER:-s3}"
export OPENPOST_MEDIA_PATH="${OPENPOST_MEDIA_PATH:-$(amhar_data_dir)/media}"
export OPENPOST_APP_URL="${OPENPOST_APP_URL:-http://127.0.0.1:${OPENPOST_PORT}}"
export OPENPOST_PUBLIC_URL="${OPENPOST_PUBLIC_URL:-$OPENPOST_APP_URL}"
export OPENPOST_MEDIA_URL="${OPENPOST_MEDIA_URL:-${OPENPOST_S3_PUBLIC_BASE_URL:-${OPENPOST_PUBLIC_URL}/media}}"
export TZ="${TZ:-Asia/Baghdad}"
export OPENPOST_TELEMETRY_ENABLED="${OPENPOST_TELEMETRY_ENABLED:-false}"
export OPENPOST_WORKFLOWS_AI_ENABLED="${OPENPOST_WORKFLOWS_AI_ENABLED:-false}"
export OPENPOST_EMAIL_VERIFICATION_REQUIRED="${OPENPOST_EMAIL_VERIFICATION_REQUIRED:-false}"

db="$(amhar_db_path)"
if [[ ! -f "$db" ]]; then
  if amhar_r2_configured; then
    echo "no local database; attempting restore from R2"
    if ! bash scripts/amhar/restore.sh; then
      echo "no backup found; starting with a fresh SQLite database at $db"
    fi
  else
    echo "no local database and R2 is not configured; starting with a fresh SQLite database at $db"
  fi
fi

if amhar_r2_configured && [[ -x "$(amhar_bin_dir)/litestream" ]]; then
  bash scripts/amhar/write-litestream-config.sh "$(amhar_data_dir)/litestream.yml"
  "$(amhar_bin_dir)/litestream" replicate -config "$(amhar_data_dir)/litestream.yml" &
  LITESTREAM_PID=$!
  echo "litestream replicate started (pid $LITESTREAM_PID)"
  (
    # First snapshot shortly after boot, then nightly.
    sleep 300
    bash scripts/amhar/backup.sh || true
    while true; do
      sleep 86400
      bash scripts/amhar/backup.sh || true
    done
  ) &
  BACKUP_PID=$!
  echo "nightly sqlite backup loop started (pid $BACKUP_PID)"
  trap 'kill "$LITESTREAM_PID" "$BACKUP_PID" 2>/dev/null || true' TERM INT
fi

echo "starting openpost $OPENPOST_RELEASE on 0.0.0.0:${OPENPOST_PORT} (sqlite $db)"
exec "$(amhar_bin_dir)/openpost-server"
