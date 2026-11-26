#!/usr/bin/env bash
# Download the pinned OpenPost linux-amd64 release and verify size + sha256.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
amhar_load_pin
amhar_prepare_dirs

dest="$(amhar_bin_dir)/openpost-server"
if [[ -x "$dest" ]] && amhar_verify_file "$dest" "$OPENPOST_ASSET_SIZE" "$OPENPOST_ASSET_SHA256"; then
  echo "openpost-server already present and verified ($OPENPOST_RELEASE)"
  exit 0
fi

tmp="$dest.partial"
echo "downloading $OPENPOST_ASSET_URL"
curl -fsSL --retry 3 -o "$tmp" "$OPENPOST_ASSET_URL"
if ! amhar_verify_file "$tmp" "$OPENPOST_ASSET_SIZE" "$OPENPOST_ASSET_SHA256"; then
  rm -f "$tmp"
  exit 1
fi
chmod 0755 "$tmp"
mv -f "$tmp" "$dest"
echo "openpost-server ready at $dest ($OPENPOST_RELEASE, $OPENPOST_ASSET_SIZE bytes)"
