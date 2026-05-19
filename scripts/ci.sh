#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

API_PORT="${API_PORT:-3000}"
WEBHOOK_PORT="${WEBHOOK_PORT:-4567}"
API_HOST="127.0.0.1"
API_LOG="${TMPDIR:-/tmp}/payment-simulator-api.log"
WEBHOOK_LOG="${TMPDIR:-/tmp}/payment-simulator-webhook.log"

for port in "$API_PORT" "$WEBHOOK_PORT"; do
  if command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -ti:"$port" 2>/dev/null || true)
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
  fi
done
sleep 1

cleanup() {
  [[ -n "${API_PID:-}" ]] && kill "$API_PID" 2>/dev/null || true
  [[ -n "${WEBHOOK_PID:-}" ]] && kill "$WEBHOOK_PID" 2>/dev/null || true
}
trap cleanup EXIT

: >"$API_LOG"
: >"$WEBHOOK_LOG"

export RACK_ENV="${RACK_ENV:-development}"

echo "Starting payment simulator on ${API_HOST}:${API_PORT} (RACK_ENV=${RACK_ENV})..."
bundle exec rackup config.ru -p "$API_PORT" -o "$API_HOST" >>"$API_LOG" 2>&1 &
API_PID=$!

echo "Starting webhook receiver on ${API_HOST}:${WEBHOOK_PORT}..."
bundle exec ruby webhook_receiver.rb >>"$WEBHOOK_LOG" 2>&1 &
WEBHOOK_PID=$!

api_ready() {
  curl -sf "http://${API_HOST}:${API_PORT}/api/health" >/dev/null
}

webhook_ready() {
  curl -sf "http://${API_HOST}:${WEBHOOK_PORT}/" >/dev/null
}

echo "Waiting for services..."
for i in $(seq 1 45); do
  api_ok=false
  webhook_ok=false
  api_ready && api_ok=true
  webhook_ready && webhook_ok=true

  if $api_ok && $webhook_ok; then
    echo "Services ready."
    break
  fi

  if ! kill -0 "$API_PID" 2>/dev/null; then
    echo "API process exited unexpectedly. Log:" >&2
    cat "$API_LOG" >&2
    exit 1
  fi
  if ! kill -0 "$WEBHOOK_PID" 2>/dev/null; then
    echo "Webhook receiver exited unexpectedly. Log:" >&2
    cat "$WEBHOOK_LOG" >&2
    exit 1
  fi

  if [[ "$i" -eq 45 ]]; then
    echo "Services failed to start within 45s (api=$api_ok webhook=$webhook_ok)" >&2
    echo "--- API log ---" >&2
    cat "$API_LOG" >&2
    echo "--- Webhook log ---" >&2
    cat "$WEBHOOK_LOG" >&2
    exit 1
  fi
  sleep 1
done

export API_BASE="http://${API_HOST}:${API_PORT}"
export WEBHOOK_BASE="http://${API_HOST}:${WEBHOOK_PORT}"
export CI_POLL_TIMEOUT="${CI_POLL_TIMEOUT:-15}"

echo "Running E2E suite..."
bundle exec ruby test_e2e.rb
