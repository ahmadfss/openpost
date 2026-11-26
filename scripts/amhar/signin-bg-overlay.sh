#!/usr/bin/env bash
# Helpers for the Amhar sign-in background nginx overlay.
# Source from start.sh after common.sh. Does not print secret values.
# shellcheck disable=SC1091

amhar_signin_bg_asset_root() {
  printf '%s\n' "$(amhar_root)/branding/amhar-signin-bg"
}

amhar_signin_bg_nginx_bin() {
  if [[ -n "${AMHAR_NGINX_BIN:-}" && -x "${AMHAR_NGINX_BIN}" ]]; then
    printf '%s\n' "$AMHAR_NGINX_BIN"
    return 0
  fi
  if command -v nginx >/dev/null 2>&1; then
    command -v nginx
    return 0
  fi
  if [[ -x /usr/sbin/nginx ]]; then
    printf '%s\n' /usr/sbin/nginx
    return 0
  fi
  return 1
}

# Overlay is on by default when the assets exist, unless explicitly disabled.
amhar_signin_bg_enabled() {
  local flag="${OPENPOST_SIGNIN_BG_OVERLAY:-1}"
  case "$flag" in
    0|false|FALSE|off|OFF|no|NO) return 1 ;;
  esac
  [[ -f "$(amhar_signin_bg_asset_root)/auth.css" && -f "$(amhar_signin_bg_asset_root)/auth.js" ]]
}

amhar_signin_bg_public_port() {
  printf '%s\n' "${AMHAR_PUBLIC_PORT:-${PORT:-8080}}"
}

amhar_signin_bg_internal_port() {
  printf '%s\n' "${OPENPOST_INTERNAL_PORT:-18080}"
}

amhar_signin_bg_runtime_dir() {
  printf '%s\n' "$(amhar_data_dir)/signin-bg-nginx"
}

# Point OpenPost at the internal port and trust the local nginx hop, keeping
# any already-configured trusted proxy CIDRs (values never printed).
amhar_signin_bg_prepare() {
  local root tmpl conf runtime asset public internal loopback
  root="$(amhar_root)"
  tmpl="$root/scripts/amhar/signin-bg-overlay.conf.tmpl"
  runtime="$(amhar_signin_bg_runtime_dir)"
  asset="$(amhar_signin_bg_asset_root)"
  public="$(amhar_signin_bg_public_port)"
  internal="$(amhar_signin_bg_internal_port)"
  conf="$runtime/nginx.conf"

  if [[ ! -f "$tmpl" ]]; then
    echo "signin-bg overlay: missing $tmpl" >&2
    return 1
  fi

  mkdir -p "$runtime/tmp/body" "$runtime/tmp/proxy" "$runtime/tmp/fastcgi" \
    "$runtime/tmp/uwsgi" "$runtime/tmp/scgi"

  # Replace placeholders. Paths may contain slashes; use a control delimiter.
  sed \
    -e "s#__PUBLIC_PORT__#${public}#g" \
    -e "s#__INTERNAL_PORT__#${internal}#g" \
    -e "s#__ASSET_ROOT__#${asset}#g" \
    -e "s#__TEMP_DIR__#${runtime}/tmp#g" \
    -e "s#__PID_FILE__#${runtime}/nginx.pid#g" \
    -e "s#__ERROR_LOG__#${runtime}/error.log#g" \
    "$tmpl" > "$conf"

  export OPENPOST_PORT="$internal"
  export AMHAR_PUBLIC_PORT="$public"
  export AMHAR_SIGNIN_BG_NGINX_CONF="$conf"
  export AMHAR_SIGNIN_BG_RUNTIME_DIR="$runtime"

  loopback="127.0.0.1/32,::1/128"
  if [[ -n "${OPENPOST_TRUSTED_PROXY_CIDRS:-}" ]]; then
    case ",${OPENPOST_TRUSTED_PROXY_CIDRS}," in
      *",127.0.0.1/32,"*) ;;
      *) export OPENPOST_TRUSTED_PROXY_CIDRS="${OPENPOST_TRUSTED_PROXY_CIDRS},${loopback}" ;;
    esac
  else
    export OPENPOST_TRUSTED_PROXY_CIDRS="$loopback"
  fi

  echo "signin-bg overlay: nginx will listen on 0.0.0.0:${public}; openpost on 127.0.0.1:${internal}"
}

amhar_signin_bg_test_config() {
  local bin conf
  bin="$(amhar_signin_bg_nginx_bin)" || return 1
  conf="${AMHAR_SIGNIN_BG_NGINX_CONF:-}"
  "$bin" -t -c "$conf" -e "${AMHAR_SIGNIN_BG_RUNTIME_DIR}/error.log"
}
