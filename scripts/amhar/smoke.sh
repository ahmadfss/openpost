#!/usr/bin/env bash
# Smoke the running instance: health plus readiness (database and storage).
# Usage: OPENPOST_HEALTH_BASE=https://post.amhar.co bash scripts/amhar/smoke.sh
set -euo pipefail
base="${OPENPOST_HEALTH_BASE:-${OPENPOST_APP_URL:-http://127.0.0.1:${OPENPOST_PORT:-8080}}}"
base="${base%/}"

echo "GET ${base}/api/v1/health"
health="$(curl -fsS --max-time 15 "${base}/api/v1/health")"
echo "$health"

echo "GET ${base}/api/v1/ready"
ready="$(curl -fsS --max-time 15 "${base}/api/v1/ready")"
echo "$ready"

python3 - "$ready" << 'PY'
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"ready response is not JSON: {exc}") from exc
status = data.get("status")
database = data.get("database")
# Storage field names vary slightly by edition; accept common spellings.
storage = data.get("storage") or data.get("media") or data.get("s3")
problems = []
if status not in ("ready", "ok", True):
    problems.append(f"status={status!r}")
if database not in ("ok", "ready", True, "connected"):
    problems.append(f"database={database!r}")
# If the payload has no storage key, still pass on status+database but warn.
if "storage" in data or "media" in data or "s3" in data:
    if storage not in ("ok", "ready", True, "connected"):
        problems.append(f"storage={storage!r}")
if problems:
    raise SystemExit("smoke failed: " + ", ".join(problems))
print("smoke ok")
PY
