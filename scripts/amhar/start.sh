#!/usr/bin/env bash
# Start OpenPost on the Replit Reserved VM.
# Downloads the pinned binary if needed, restores SQLite from R2 after a
# republish wipe (fail closed if backups exist but none restore), then runs
# OpenPost under Litestream, replicating to a per-boot generation path.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/signin-bg-overlay.sh"
cd "$(amhar_root)"
amhar_load_pin
amhar_prepare_dirs
amhar_export_r2

bash scripts/amhar/download-binary.sh
bash scripts/amhar/download-litestream.sh

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

# Public port stays at $PORT (8080). When the sign-in overlay is on,
# OpenPost itself moves to 127.0.0.1:18080 and nginx listens on 8080.
overlay=0
_amhar_orig_port="$OPENPOST_PORT"
_amhar_orig_cidrs="${OPENPOST_TRUSTED_PROXY_CIDRS-}"
if amhar_signin_bg_enabled && amhar_signin_bg_nginx_bin >/dev/null; then
  amhar_signin_bg_prepare
  if amhar_signin_bg_test_config; then
    overlay=1
  else
    echo "WARNING: signin-bg nginx config is invalid; serving OpenPost directly on ${_amhar_orig_port}" >&2
    export OPENPOST_PORT="$_amhar_orig_port"
    if [[ -n "$_amhar_orig_cidrs" ]]; then
      export OPENPOST_TRUSTED_PROXY_CIDRS="$_amhar_orig_cidrs"
    else
      unset OPENPOST_TRUSTED_PROXY_CIDRS
    fi
    unset AMHAR_SIGNIN_BG_NGINX_CONF
  fi
elif amhar_signin_bg_enabled; then
  echo "WARNING: signin-bg overlay assets are present but nginx is not installed; serving OpenPost directly" >&2
fi
unset _amhar_orig_port _amhar_orig_cidrs

db="$(amhar_db_path)"
gen_file="$(amhar_generation_file)"

# 1. Get a database.
#    - Local file present: an ordinary process restart on the same VM disk.
#      Keep writing to this VM's own generation.
#    - No local file (new VM after a republish): restore from R2. If R2 has
#      backups but none restore cleanly, stop here (fail closed). Starting an
#      empty database would lose every user, and Replit would promote it.
if [[ -f "$db" ]]; then
  echo "local database present at $db; not restoring"
  if [[ ! -s "$gen_file" ]]; then
    amhar_new_generation > "$gen_file"
  fi
elif amhar_r2_configured; then
  echo "no local database; restoring from R2"
  rc=0
  bash scripts/amhar/restore.sh || rc=$?
  case "$rc" in
    0) ;;
    3) echo "R2 has no backups yet (first boot); starting with a fresh SQLite database at $db" ;;
    *)
      if [[ "${OPENPOST_ALLOW_FRESH_DB:-false}" == "true" ]]; then
        echo "WARNING: restore failed and OPENPOST_ALLOW_FRESH_DB=true; starting with an EMPTY database" >&2
      else
        echo "FATAL: backups exist in R2 but none restored cleanly; refusing to start with an empty database." >&2
        echo "FATAL: the previous deployment keeps serving. See docs/amhar/backup-and-restore.md." >&2
        exit 1
      fi
      ;;
  esac
  # Every restored or fresh database replicates to a brand-new path, so it can
  # never interleave with the VM that is still serving during a promote.
  amhar_new_generation > "$gen_file"
else
  echo "no local database and R2 is not configured; starting with a fresh SQLite database at $db"
fi

ls_bin="$(amhar_bin_dir)/litestream"
server_bin="$(amhar_bin_dir)/openpost-server"

if amhar_r2_configured && [[ -x "$ls_bin" ]]; then
  gen="$(amhar_current_generation)"
  bash scripts/amhar/write-litestream-config.sh "$(amhar_data_dir)/litestream.yml"
  echo "litestream generation $gen -> ${OPENPOST_LITESTREAM_GEN_ROOT%/}/$gen"
  (
    # First snapshot shortly after boot, then nightly. Never fatal.
    sleep "${OPENPOST_BACKUP_FIRST_DELAY_SECONDS:-600}"
    bash scripts/amhar/backup.sh || echo "backup failed (see above)" >&2
    while true; do
      sleep 86400
      bash scripts/amhar/backup.sh || echo "backup failed (see above)" >&2
    done
  ) &
  echo "nightly sqlite backup loop started (pid $!)"
  if [[ "$overlay" == 1 ]]; then
    export AMHAR_OPENPOST_BIN="$server_bin"
    echo "starting openpost $OPENPOST_RELEASE behind signin-bg nginx on 0.0.0.0:${AMHAR_PUBLIC_PORT} (openpost 127.0.0.1:${OPENPOST_PORT}, sqlite $db) under litestream replicate -exec"
    exec "$ls_bin" replicate -config "$(amhar_data_dir)/litestream.yml" -exec "$(amhar_root)/scripts/amhar/signin-bg-run.sh"
  fi
  echo "starting openpost $OPENPOST_RELEASE on 0.0.0.0:${OPENPOST_PORT} (sqlite $db) under litestream replicate -exec"
  # Litestream runs OpenPost as its child: on SIGTERM it stops OpenPost, does
  # a final sync, and exits; if OpenPost exits, Litestream exits too.
  exec "$ls_bin" replicate -config "$(amhar_data_dir)/litestream.yml" -exec "$server_bin"
fi

echo "WARNING: litestream is not running; the database is NOT being replicated" >&2
if [[ "$overlay" == 1 ]]; then
  export AMHAR_OPENPOST_BIN="$server_bin"
  echo "starting openpost $OPENPOST_RELEASE behind signin-bg nginx on 0.0.0.0:${AMHAR_PUBLIC_PORT} (openpost 127.0.0.1:${OPENPOST_PORT}, sqlite $db)"
  exec bash "$(amhar_root)/scripts/amhar/signin-bg-run.sh"
fi
echo "starting openpost $OPENPOST_RELEASE on 0.0.0.0:${OPENPOST_PORT} (sqlite $db)"
exec "$server_bin"
