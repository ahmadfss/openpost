#!/usr/bin/env bash
# Minimal S3/R2 client on top of curl --aws-sigv4. Replaces r2_sync.py on the
# deploy, because the Replit Reserved VM image has no python3.
# Source this file, or run: r2.sh get KEY DEST | put SRC KEY | list PREFIX [DELIM]
# Credentials are passed to curl on stdin (-K -), never on the command line,
# and are never printed. The R2 account endpoint is redacted from errors.
# Needs: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL,
#        OPENPOST_BACKUP_BUCKET, AWS_REGION (default auto).
#
# Every call has hard limits, so a stalled network shows up as an error in the
# deploy log instead of a silent hang:
#   R2_CONNECT_TIMEOUT   seconds to connect (DNS + TCP + TLS), default 10
#   R2_LIST_MAX_TIME     seconds per list request attempt, default 30
#   R2_CURL_MAX_TIME     seconds per get/put attempt, default 300
#   R2_CURL_RETRIES      curl --retry count, default 2
#   R2_LIST_MAX_PAGES    pagination guard per listing, default 200 (200k keys)
#   R2_IP_RESOLVE        set to 4 or 6 to force curl -4 / -6 (default: both)
#   R2_QUIET=1           no progress lines on stderr

_r2_now() { date +%s; }

_r2_log() {
  [[ "${R2_QUIET:-0}" == "1" ]] || echo "r2: $*" >&2
}

_r2_redact() {
  # Hide the account endpoint host (it identifies the R2 account).
  local host="${AWS_ENDPOINT_URL#*://}"
  host="${host%%/*}"
  if [[ -n "$host" ]]; then
    sed -e "s#${host//./\\.}#<r2-endpoint>#g"
  else
    cat
  fi
}

_r2_curl() {
  # Usage: _r2_curl MAX_TIME CURL_ARGS... ; URL must be in the args.
  local max_time="$1" retries="${R2_CURL_RETRIES:-2}" rc=0 errf hard
  shift
  local -a ipr=()
  case "${R2_IP_RESOLVE:-}" in
    4) ipr=(-4) ;;
    6) ipr=(-6) ;;
  esac
  # curl's own limits bound each attempt; the outer timeout is a backstop for
  # anything curl does not cover. Worst case per call: (retries+1)*max_time
  # plus retry delays.
  hard=$(((retries + 1) * (max_time + 5) + 15))
  errf="$(mktemp "${TMPDIR:-/tmp}/r2-err.XXXXXX")"
  printf 'user = "%s:%s"\n' "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" |
    timeout --kill-after=5 "$hard" \
      curl -sS --fail "${ipr[@]}" --connect-timeout "${R2_CONNECT_TIMEOUT:-10}" \
      --max-time "$max_time" --retry "$retries" --retry-delay 2 --retry-connrefused \
      --aws-sigv4 "aws:amz:${AWS_REGION:-auto}:s3" -K - "$@" 2> "$errf" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      echo "r2: request killed after ${hard}s (hard timeout)" >&2
    fi
    _r2_redact < "$errf" | tail -n 3 >&2
  fi
  rm -f "$errf"
  return "$rc"
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
  local key="$1" dest="$2" t0
  t0="$(_r2_now)"
  if _r2_curl "${R2_CURL_MAX_TIME:-300}" -o "$dest.partial" "$(_r2_base)/${key}"; then
    mv -f "$dest.partial" "$dest"
    _r2_log "get $key ok ($(($(_r2_now) - t0))s)"
  else
    rm -f "$dest.partial"
    _r2_log "get $key FAILED after $(($(_r2_now) - t0))s"
    return 1
  fi
}

# r2_put SRC KEY : upload one object (single PUT; fine for files < 5 GB).
r2_put() {
  local src="$1" key="$2"
  _r2_curl "${R2_CURL_MAX_TIME:-300}" -o /dev/null -X PUT -H "Content-Type: application/octet-stream" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" --upload-file "$src" "$(_r2_base)/${key}"
}

# Parse one ListObjectsV2 XML page on stdin. One awk process per page (the old
# per-object $(...) field extraction forked ~16 processes per key, which took
# minutes on the Reserved VM for a few thousand Litestream LTX files).
# Output: "<LastModified>\t<Size>\t<Key>" per object, "PREFIX\t-\t<Prefix>"
# per common prefix. S3 and R2 order child elements differently; handled.
_r2_parse_list() {
  tr -d '\r\n' | sed -e 's#<Contents>#\n<Contents>#g' -e 's#<CommonPrefixes>#\n<CommonPrefixes>#g' |
    awk '
      function field(tag, s,   a, b, otag, ctag) {
        otag = "<" tag ">"; ctag = "</" tag ">"
        a = index(s, otag)
        if (a == 0) return ""
        s = substr(s, a + length(otag))
        b = index(s, ctag)
        return b ? substr(s, 1, b - 1) : ""
      }
      /^<Contents>/ { printf "%s\t%s\t%s\n", field("LastModified", $0), field("Size", $0), field("Key", $0); next }
      /^<CommonPrefixes>/ { printf "PREFIX\t-\t%s\n", field("Prefix", $0) }
    '
}

# r2_list PREFIX [DELIMITER]
# Prints one line per object: "<LastModified>\t<Size>\t<Key>", and one line per
# common prefix: "PREFIX\t-\t<Prefix>". Follows pagination, bounded by
# R2_LIST_MAX_PAGES. Logs one progress line to stderr per listing.
r2_list() {
  local prefix="$1" delim="${2:-}" token="" prev_token="" body qs page=0 count=0 n t0
  local max_pages="${R2_LIST_MAX_PAGES:-200}"
  t0="$(_r2_now)"
  while :; do
    page=$((page + 1))
    if [[ "$page" -gt "$max_pages" ]]; then
      _r2_log "list $prefix: more than $max_pages pages; giving up"
      return 1
    fi
    qs="list-type=2&prefix=$(_r2_qs "$prefix")"
    [[ -n "$delim" ]] && qs+="&delimiter=$(_r2_qs "$delim")"
    [[ -n "$token" ]] && qs+="&continuation-token=$(_r2_qs "$token")"
    [[ -n "${R2_LIST_MAX_KEYS:-}" ]] && qs+="&max-keys=${R2_LIST_MAX_KEYS}"
    body="$(_r2_curl "${R2_LIST_MAX_TIME:-30}" "$(_r2_base)?${qs}")" || {
      _r2_log "list $prefix FAILED on page $page after $(($(_r2_now) - t0))s"
      return 1
    }
    n=0
    if [[ "$body" == *"<Contents>"* || "$body" == *"<CommonPrefixes>"* ]]; then
      printf '%s' "$body" | _r2_parse_list
      n="$(printf '%s' "$body" | grep -o '<Contents>\|<CommonPrefixes>' | wc -l | tr -d ' ')"
    fi
    count=$((count + n))
    if [[ "$body" == *"<IsTruncated>true</IsTruncated>"* ]]; then
      token="$(printf '%s' "$body" | sed -n 's#.*<NextContinuationToken>\([^<]*\)</NextContinuationToken>.*#\1#p')"
      if [[ -z "$token" || "$token" == "$prev_token" ]]; then
        _r2_log "list $prefix: truncated page without a new continuation token; giving up"
        return 1
      fi
      prev_token="$token"
    else
      _r2_log "list $prefix: $count entries, $page page(s), $(($(_r2_now) - t0))s"
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
