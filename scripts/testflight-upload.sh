#!/bin/bash
# Retryable upload of the exact signed artifact from the successful build job.
set -euo pipefail
umask 077

if [[ "${RUNNER_OS:-}" != "macOS" || "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo 'This script requires the private GitHub-hosted macOS job.' >&2
  exit 1
fi

AF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AF_OUTPUT="$AF_ROOT/build/testflight"
AF_IPA="$AF_OUTPUT/ApartmentFinder-TestFlight.ipa"
python3 -B "$AF_ROOT/scripts/testflight-artifact.py" "$AF_ROOT/build" \
  "${AF_EXPECTED_BUILD_VERSION:?}" "${AF_EXPECTED_IPA_SHA256:?}"

AF_UPLOAD_DIR="${RUNNER_TEMP:?}/apartmentfinder-upload"
trap 'rm -rf -- "$AF_UPLOAD_DIR"' EXIT
python3 -B "$AF_ROOT/scripts/testflight.py" prepare-upload-key "$AF_UPLOAD_DIR"
unset APP_STORE_CONNECT_KEY_BASE64

# altool discovers AuthKey_<ID>.p8 in ./private_keys. No Apple Account password.
# Upload only; tester invitations and public submission are separate.
cd "$AF_UPLOAD_DIR"
python3 -B "$AF_ROOT/scripts/testflight.py" deliver "$AF_IPA"
{
  echo "Uploaded the preserved ApartmentFinder $AF_EXPECTED_BUILD_VERSION IPA to Apple."
  echo 'Apple processing, export-compliance answers, owner-only internal tester assignment, and physical iPhone installation must still be checked.'
} >> "${GITHUB_STEP_SUMMARY:?}"
