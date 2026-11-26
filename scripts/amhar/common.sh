#!/usr/bin/env bash
# Shared paths and helpers for the Amhar OpenPost deploy scripts.
# Safe to source. Does not print secret values.

amhar_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s\n' "$here"
}

amhar_load_pin() {
  local root pin
  root="$(amhar_root)"
  pin="$root/deploy/replit/pin.env"
  # shellcheck disable=SC1090
  set -a
  source "$pin"
  set +a
}

amhar_data_dir() {
  # Local SQLite and working files. On a published Replit Reserved VM this
  # directory survives ordinary process restarts but is wiped on every
  # republish or VM recreation (Replit docs, "file system in published apps
  # is not persistent"). Boot must restore from R2 when the DB is missing.
  printf '%s\n' "${OPENPOST_DATA_DIR:-${HOME}/openpost-data}"
}

amhar_bin_dir() {
  printf '%s\n' "$(amhar_root)/bin"
}

amhar_db_path() {
  printf '%s\n' "$(amhar_data_dir)/db/openpost.db"
}

amhar_prepare_dirs() {
  mkdir -p "$(amhar_data_dir)/db" "$(amhar_data_dir)/media" "$(amhar_data_dir)/tmp" "$(amhar_bin_dir)"
}

# Verify a downloaded file against the pinned size and optional sha256.
# Usage: amhar_verify_file PATH SIZE [SHA256]
amhar_verify_file() {
  local path="$1" expected_size="$2" expected_sha="${3:-}"
  local actual_size actual_sha
  if [[ ! -f "$path" ]]; then
    echo "missing file: $path" >&2
    return 1
  fi
  actual_size="$(wc -c < "$path" | tr -d ' ')"
  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "size mismatch for $path: got $actual_size, expected $expected_size" >&2
    return 1
  fi
  if [[ -n "$expected_sha" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual_sha="$(sha256sum "$path" | awk '{print $1}')"
    else
      actual_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$path")"
    fi
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      echo "sha256 mismatch for $path" >&2
      return 1
    fi
  fi
  return 0
}

# Map OpenPost R2 secrets to the names Litestream and the backup script expect.
# Never echoes values.
amhar_export_r2() {
  if [[ -n "${OPENPOST_S3_ACCESS_KEY_ID:-}" && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    export AWS_ACCESS_KEY_ID="$OPENPOST_S3_ACCESS_KEY_ID"
  fi
  if [[ -n "${OPENPOST_S3_SECRET_ACCESS_KEY:-}" && -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    export AWS_SECRET_ACCESS_KEY="$OPENPOST_S3_SECRET_ACCESS_KEY"
  fi
  if [[ -n "${OPENPOST_S3_ENDPOINT:-}" && -z "${AWS_ENDPOINT_URL:-}" ]]; then
    export AWS_ENDPOINT_URL="$OPENPOST_S3_ENDPOINT"
  fi
  if [[ -n "${OPENPOST_S3_REGION:-}" && -z "${AWS_REGION:-}" ]]; then
    export AWS_REGION="$OPENPOST_S3_REGION"
  fi
  export AWS_REGION="${AWS_REGION:-auto}"
  export OPENPOST_BACKUP_BUCKET="${OPENPOST_BACKUP_BUCKET:-${OPENPOST_S3_BUCKET:-}}"
  export OPENPOST_BACKUP_PREFIX="${OPENPOST_BACKUP_PREFIX:-backups/sqlite}"
  export OPENPOST_LITESTREAM_PREFIX="${OPENPOST_LITESTREAM_PREFIX:-backups/litestream}"
}

amhar_r2_configured() {
  [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" && -n "${AWS_ENDPOINT_URL:-}" && -n "${OPENPOST_BACKUP_BUCKET:-}" ]]
}
