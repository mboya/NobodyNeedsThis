#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export API_BASE="${API_BASE:-https://nobody-needs-this-mboya-dev.vercel.app}"
export SKIP_WEBHOOKS="${SKIP_WEBHOOKS:-1}"
export CI_POLL_TIMEOUT="${CI_POLL_TIMEOUT:-20}"

if [[ -z "${API_KEY:-}" ]]; then
  echo "ERROR: API_KEY is required (set in Vercel project env, then export it here)." >&2
  echo "  export API_KEY='your-key'" >&2
  exit 1
fi

if [[ -z "${VERCEL_PROTECTION_BYPASS:-}" ]]; then
  echo "WARNING: VERCEL_PROTECTION_BYPASS not set." >&2
  echo "  If the deployment uses Vercel Authentication, get a bypass token from:" >&2
  echo "  Project → Settings → Deployment Protection → Protection Bypass for Automation" >&2
  echo "  export VERCEL_PROTECTION_BYPASS='your-token'" >&2
  echo "" >&2
fi

echo "Testing: $API_BASE"
echo "Auth: enabled"
echo "Webhooks: $([[ \"$SKIP_WEBHOOKS\" == \"1\" ]] && echo skipped || echo enabled)"
echo ""

bundle exec ruby test_e2e.rb
