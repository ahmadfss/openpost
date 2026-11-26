#!/usr/bin/env bash
# Write a 0600 Litestream config from environment values. Never echoes secrets.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
amhar_prepare_dirs
amhar_export_r2

dest="${1:-$(amhar_data_dir)/litestream.yml}"
if ! amhar_r2_configured; then
  echo "R2 credentials are not set; cannot write litestream config" >&2
  exit 1
fi

endpoint="${AWS_ENDPOINT_URL}"
bucket="${OPENPOST_BACKUP_BUCKET}"
prefix="${OPENPOST_LITESTREAM_PREFIX}"
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
  interval: 24h
  retention: 168h
YML
chmod 0600 "$dest"
echo "wrote $dest"
