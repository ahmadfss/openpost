#!/usr/bin/env bash
# Process-up check. Exit 0 if /api/v1/health responds.
set -euo pipefail
base="${OPENPOST_HEALTH_BASE:-${OPENPOST_APP_URL:-http://127.0.0.1:${OPENPOST_PORT:-8080}}}"
base="${base%/}"
curl -fsS --max-time 10 "${base}/api/v1/health"
echo
