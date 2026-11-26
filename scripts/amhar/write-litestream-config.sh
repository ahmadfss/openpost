#!/usr/bin/env bash
# Write a 0600 Litestream config from environment values. Never echoes secrets.
# Usage: write-litestream-config.sh [DEST] [REPLICA_PREFIX]
# REPLICA_PREFIX defaults to this VM's generation path
# ($OPENPOST_LITESTREAM_GEN_ROOT/<generation>). Only one VM may ever write a
# given prefix: Litestream 0.5.18 has no writer lock, and two writers on one
# path interleave LTX files and break restores.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
amhar_prepare_dirs
amhar_export_r2

dest="${1:-$(amhar_data_dir)/litestream.yml}"
prefix="${2:-}"
if ! amhar_r2_configured; then
  echo "R2 credentials are not set; cannot write litestream config" >&2
  exit 1
fi
if [[ -z "$prefix" ]]; then
  gen="$(amhar_current_generation)"
  if [[ -z "$gen" ]]; then
    echo "no generation chosen yet ($(amhar_generation_file) is empty)" >&2
    exit 1
  fi
  prefix="${OPENPOST_LITESTREAM_GEN_ROOT%/}/${gen}"
fi

endpoint="${AWS_ENDPOINT_URL}"
bucket="${OPENPOST_BACKUP_BUCKET}"
db="$(amhar_db_path)"
# Access keys are read from the process environment by Litestream when omitted.
umask 077
cat > "$dest" << YML
# Generated at boot. Do not commit. Keys come from the process environment.
dbs:
  - path: ${db}
    replica:
      url: s3://${bucket}/${prefix}?endpoint=${endpoint}
      region: ${AWS_REGION:-auto}
snapshot:
  # Litestream aligns this to UTC midnight. A boot also gets a full snapshot
  # in its first sync, because every boot starts a new generation path.
  interval: 24h
  retention: 168h
YML
chmod 0600 "$dest"
echo "wrote $dest (replica prefix ${prefix})"
