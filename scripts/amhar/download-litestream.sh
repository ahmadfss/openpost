#!/usr/bin/env bash
# Download the pinned Litestream linux-x86_64 release and verify size + sha256.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
amhar_load_pin
amhar_prepare_dirs

dest="$(amhar_bin_dir)/litestream"
if [[ -x "$dest" ]]; then
  echo "litestream already present at $dest"
  exit 0
fi

archive="$(amhar_data_dir)/tmp/$LITESTREAM_ASSET"
echo "downloading $LITESTREAM_ASSET_URL"
curl -fsSL --retry 3 -o "$archive" "$LITESTREAM_ASSET_URL"
if ! amhar_verify_file "$archive" "$LITESTREAM_ASSET_SIZE" "$LITESTREAM_ASSET_SHA256"; then
  rm -f "$archive"
  exit 1
fi
tar -xzf "$archive" -C "$(amhar_data_dir)/tmp"
# Archive layout is a single 'litestream' binary at the top level or in a folder.
found="$(find "$(amhar_data_dir)/tmp" -maxdepth 2 -type f -name litestream | head -n 1)"
if [[ -z "$found" ]]; then
  echo "litestream binary not found inside $LITESTREAM_ASSET" >&2
  exit 1
fi
chmod 0755 "$found"
mv -f "$found" "$dest"
rm -f "$archive"
echo "litestream ready at $dest ($LITESTREAM_VERSION)"
