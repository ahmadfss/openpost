#!/usr/bin/env bash
# Minimal S3/R2 client on top of curl --aws-sigv4. Replaces r2_sync.py on the
# deploy, because the Replit Reserved VM image has no python3.
# Source this file, or run: r2.sh get KEY DEST | put SRC KEY | list PREFIX [DELIM]
# Credentials are passed to curl on stdin (-K -), never on the command line,
# and are never printed.
# Needs: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL,
#        OPENPOST_BACKUP_BUCKET, AWS_REGION (default auto).

_r2_curl() {
  # Usage: _r2_curl CURL_ARGS... ; URL must be in the args.
  printf 'user = "%s:%s"\n' "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" |
    curl -sS --fail --retry 3 --retry-delay 2 --max-time "${R2_CURL_MAX_TIME:-300}" \
      --aws-sigv4 "aws:amz:${AWS_REGION:-auto}:s3" -K - "$@"
}

_r2_base() {
  printf '%s/%s' "${AWS_ENDPOINT_URL%/}" "${OPENPOST_BACKUP_BUCKET:?}"
}

# Percent-encode a query value (keys here are plain ASCII paths).
_r2_qs() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# r2_get KEY DEST : download one object. Fails (non-zero) on 404.
r2_get() {
  local key="$1" dest="$2"
  _r2_curl -o "$dest.partial" "$(_r2_base)/${key}" && mv -f "$dest.partial" "$dest"
}

# r2_put SRC KEY : upload one object (single PUT; fine for files < 5 GB).
r2_put() {
  local src="$1" key="$2"
  _r2_curl -o /dev/null -X PUT -H "Content-Type: application/octet-stream" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" --upload-file "$src" "$(_r2_base)/${key}"
}

_r2_field() {
  # Usage: _r2_field TAG LINE ; value of the first <TAG>value</TAG> in LINE.
  local m
  m="$(printf '%s' "$2" | grep -o "<$1>[^<]*</$1>" | head -n 1)" || true
  m="${m#<"$1">}"
  printf '%s' "${m%</"$1">}"
}

# r2_list PREFIX [DELIMITER]
# Prints one line per object: "<LastModified>\t<Size>\t<Key>", and one line per
# common prefix: "PREFIX\t-\t<Prefix>". Follows pagination.
r2_list() {
  local prefix="$1" delim="${2:-}" token="" body qs
  while :; do
    qs="list-type=2&prefix=$(_r2_qs "$prefix")"
    [[ -n "$delim" ]] && qs+="&delimiter=$(_r2_qs "$delim")"
    [[ -n "$token" ]] && qs+="&continuation-token=$(_r2_qs "$token")"
    [[ -n "${R2_LIST_MAX_KEYS:-}" ]] && qs+="&max-keys=${R2_LIST_MAX_KEYS}"
    body="$(_r2_curl "$(_r2_base)?${qs}")" || return 1
    # One record per line, then pull each field on its own (S3 and R2 order
    # the child elements differently). No XML parser needed.
    { printf '%s' "$body" | tr -d '\r\n'; echo; } | sed -e 's#<Contents>#\n<Contents>#g' -e 's#<CommonPrefixes>#\n<CommonPrefixes>#g' |
      while IFS= read -r line; do
        case "$line" in
          "<Contents>"*)
            printf '%s\t%s\t%s\n' \
              "$(_r2_field LastModified "$line")" "$(_r2_field Size "$line")" "$(_r2_field Key "$line")"
            ;;
          "<CommonPrefixes>"*)
            printf 'PREFIX\t-\t%s\n' "$(_r2_field Prefix "$line")"
            ;;
        esac
      done
    if printf '%s' "$body" | grep -q '<IsTruncated>true</IsTruncated>'; then
      token="$(printf '%s' "$body" | sed -n 's#.*<NextContinuationToken>\([^<]*\)</NextContinuationToken>.*#\1#p')"
      [[ -n "$token" ]] || return 1
    else
      return 0
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    get) r2_get "$@" ;;
    put) r2_put "$@" ;;
    list) r2_list "$@" ;;
    *)
      echo "usage: r2.sh get KEY DEST | put SRC KEY | list PREFIX [DELIM]" >&2
      exit 2
      ;;
  esac
fi
