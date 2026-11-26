#!/usr/bin/env bash
# Local tests for the Amhar sign-in background nginx overlay.
# Does not start the OpenPost binary or talk to production.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck disable=SC1091
source "$root/scripts/amhar/common.sh"
# shellcheck disable=SC1091
source "$root/scripts/amhar/signin-bg-overlay.sh"

cd "$root"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# Isolated ports and data dir so this can run on the box alongside other work.
export OPENPOST_DATA_DIR="${OPENPOST_DATA_DIR:-$(mktemp -d /tmp/amhar-signin-bg-test.XXXXXX)}"
export AMHAR_PUBLIC_PORT="${AMHAR_PUBLIC_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
export OPENPOST_INTERNAL_PORT="${OPENPOST_INTERNAL_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
export OPENPOST_TRUSTED_PROXY_CIDRS="10.0.0.1/32"
export AMHAR_NGINX_BIN="${AMHAR_NGINX_BIN:-$(amhar_signin_bg_nginx_bin)}"
export OPENPOST_SIGNIN_BG_OVERLAY=1

cleanup() {
  if [[ -n "${upstream_pid:-}" ]]; then kill "$upstream_pid" 2>/dev/null || true; fi
  if [[ -n "${nginx_pid:-}" ]]; then kill "$nginx_pid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT

amhar_signin_bg_enabled || fail "overlay should be enabled with assets present"

export OPENPOST_PORT=8080
amhar_signin_bg_prepare
[[ "$OPENPOST_PORT" == "$OPENPOST_INTERNAL_PORT" ]] || fail "prepare should move OPENPOST_PORT to the internal port"
[[ "$OPENPOST_TRUSTED_PROXY_CIDRS" == *10.0.0.1/32* ]] || fail "existing trusted CIDR was dropped"
[[ "$OPENPOST_TRUSTED_PROXY_CIDRS" == *127.0.0.1/32* ]] || fail "loopback was not appended to trusted CIDRs"

amhar_signin_bg_test_config || fail "nginx -t rejected the generated config"
pass "nginx config is valid (public ${AMHAR_PUBLIC_PORT}, internal ${OPENPOST_INTERNAL_PORT})"

python3 "$root/scripts/amhar/tests/signin-bg-dummy-upstream.py" &

upstream_pid=$!
sleep 0.2
kill -0 "$upstream_pid" 2>/dev/null || fail "dummy upstream did not start"

"$AMHAR_NGINX_BIN" -c "$AMHAR_SIGNIN_BG_NGINX_CONF" -e "${AMHAR_SIGNIN_BG_RUNTIME_DIR}/error.log" &
nginx_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf -o /dev/null "http://127.0.0.1:${AMHAR_PUBLIC_PORT}/api/v1/ready"; then
    break
  fi
  sleep 0.2
done

base="http://127.0.0.1:${AMHAR_PUBLIC_PORT}"

login="$(curl -sS -D - "$base/login" -H "Accept: text/html")"
echo "$login" | rg -q 'amhar-signin-bg/auth.css' || fail "login HTML is missing the stylesheet link"
echo "$login" | rg -q 'amhar-signin-bg/auth.js' || fail "login HTML is missing the script tag"
echo "$login" | rg -q '</head>' || fail "login HTML lost </head>"
pass "login HTML is injected"

register="$(curl -sS "$base/register" -H "Accept: text/html")"
echo "$register" | rg -q 'amhar-signin-bg/auth.css' || fail "register HTML is not injected"
pass "register HTML is injected"

# Onboarding also gets the tags (shared SPA HTML); auth.js keeps the class off.
onboarding="$(curl -sS "$base/onboarding" -H "Accept: text/html")"
echo "$onboarding" | rg -q 'amhar-signin-bg/auth.js' || fail "onboarding HTML should still receive the script"
pass "onboarding HTML receives the script (JS gates the class)"

ready="$(curl -sS "$base/api/v1/ready")"
[[ "$ready" == '{"status":"ok","echo":"</head>"}' ]] || fail "API body was rewritten: $ready"
pass "JSON API is passed through unchanged"

js="$(curl -sS "$base/assets/app.js" -H "Accept: */*")"
[[ "$js" == "console.log('app');" ]] || fail "JS asset was rewritten: $js"
pass "JS assets are not injected"

css="$(curl -sS -D - "$base/amhar-signin-bg/auth.css" -o /tmp/amhar-auth.css)"
echo "$css" | rg -qi 'HTTP/1.1 200' || fail "auth.css was not served"
rg -q 'amhar-auth-bg' /tmp/amhar-auth.css || fail "auth.css content looks wrong"
pass "auth.css is served from the overlay"

webp_len="$(curl -sS -o /tmp/amhar-bg.webp -w '%{http_code} %{size_download}' "$base/amhar-signin-bg/option-f-riverside-morning.webp")"
[[ "$webp_len" == 200* ]] || fail "webp was not served: $webp_len"
# under 500 KB
size="$(wc -c < /tmp/amhar-bg.webp | tr -d ' ')"
(( size > 10000 && size < 512000 )) || fail "webp size unexpected: $size"
pass "webp background is served (${size} bytes)"

# Forwarded headers: document request with X-Forwarded-* from the "edge".
hdrs="$(curl -sS -D - -o /dev/null "$base/login" \
  -H "Accept: text/html" \
  -H "X-Forwarded-Proto: https" \
  -H "X-Forwarded-Host: post.amhar.co")"
echo "$hdrs" | rg -qi 'X-Upstream-Fwd-Proto: https' || fail "X-Forwarded-Proto was not passed to upstream: $hdrs"
echo "$hdrs" | rg -qi 'X-Upstream-Fwd-Host: post.amhar.co' || fail "X-Forwarded-Host was not passed to upstream: $hdrs"
pass "forwarded proto and host reach OpenPost"

# Disable flag
export OPENPOST_SIGNIN_BG_OVERLAY=0
amhar_signin_bg_enabled && fail "OPENPOST_SIGNIN_BG_OVERLAY=0 should disable the overlay"
pass "OPENPOST_SIGNIN_BG_OVERLAY=0 disables the overlay"

echo "ALL PASSED"
