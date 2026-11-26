#!/usr/bin/env bash
# Replit Reserved VM build command. Downloads pinned binaries only.
# Does not compile OpenPost and does not install the JS monorepo.
set -euo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"
bash scripts/amhar/download-binary.sh
bash scripts/amhar/download-litestream.sh
