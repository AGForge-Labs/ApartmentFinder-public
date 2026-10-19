#!/bin/bash
set -eu
[[ "${RUNNER_OS:-}" == "macOS" && "${GITHUB_ACTIONS:-}" == "true" ]] || exit 1
AF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AF_SIGNING_DIR="${RUNNER_TEMP:?}/apartmentfinder-signing"
python3 -B "$AF_ROOT/scripts/testflight.py" cleanup "$AF_SIGNING_DIR"
