#!/usr/bin/env bash
# Litestream -exec target when the sign-in background overlay is enabled.
# Starts nginx in front of openpost-server and exits if either process dies.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/signin-bg-overlay.sh"

cd "$(amhar_root)"

server_bin="${AMHAR_OPENPOST_BIN:-$(amhar_bin_dir)/openpost-server}"
nginx_bin="$(amhar_signin_bg_nginx_bin)"
conf="${AMHAR_SIGNIN_BG_NGINX_CONF:-}"
runtime="${AMHAR_SIGNIN_BG_RUNTIME_DIR:-$(amhar_signin_bg_runtime_dir)}"

if [[ ! -x "$server_bin" ]]; then
  echo "FATAL: openpost-server is not executable at $server_bin" >&2
  exit 1
fi
if [[ ! -x "$nginx_bin" || ! -f "$conf" ]]; then
  echo "FATAL: nginx overlay is not ready (bin or config missing)" >&2
  exit 1
fi

nginx_pid=""
server_pid=""

shutdown() {
  local code="${1:-0}"
  trap - EXIT TERM INT
  if [[ -n "$nginx_pid" ]] && kill -0 "$nginx_pid" 2>/dev/null; then
    kill -TERM "$nginx_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
  fi
  wait || true
  exit "$code"
}

trap 'shutdown 143' TERM INT

"$nginx_bin" -c "$conf" -e "$runtime/error.log" &
nginx_pid=$!

"$server_bin" &
server_pid=$!

echo "signin-bg overlay: nginx pid ${nginx_pid}, openpost pid ${server_pid}"

while true; do
  if ! kill -0 "$nginx_pid" 2>/dev/null; then
    echo "FATAL: nginx exited" >&2
    wait "$nginx_pid" || true
    shutdown 1
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "FATAL: openpost-server exited" >&2
    wait "$server_pid" || true
    shutdown 1
  fi
  sleep 1
done
