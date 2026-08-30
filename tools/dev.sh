#!/usr/bin/env bash
# Development loop: build, start a loopback daemon in dry-run, run the protocol probe.
#
# Dry-run means no real input is ever posted, and loopback + --auto-approve means no
# approval prompt — both are refused together on any non-loopback interface, so this
# convenience cannot leak onto your LAN.
set -euo pipefail

cd "$(dirname "$0")/.."
STATE_DIR="${AIRPOINT_STATE_DIR:-$(mktemp -d)/airpoint}"
PORT="${AIRPOINT_PORT:-8443}"
LOG="$STATE_DIR/daemon.log"

echo "==> building"
swift build

echo "==> unit tests"
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1

echo "==> browser motion pipeline"
node tools/motion-check.mjs | tail -1

echo "==> controller sensor flow"
node tools/sensor-flow-check.mjs | tail -1

mkdir -p "$STATE_DIR"
echo "==> starting airpointd (dry-run, loopback, state in $STATE_DIR)"
./.build/debug/airpointd \
  --dry-run --bind 127.0.0.1 --auto-approve \
  --port "$PORT" --state-dir "$STATE_DIR" --log-level info > "$LOG" 2>&1 &
DAEMON_PID=$!
trap 'kill $DAEMON_PID 2>/dev/null || true' EXIT

# `grep -q ... && break` would trip `set -e` on every miss, so branch explicitly.
for _ in $(seq 1 40); do
  if grep -q "listening on port" "$LOG"; then break; fi
  sleep 0.2
done

CODE=$(grep -o 'Pairing code:  [0-9]*' "$LOG" | tail -1 | awk '{print $3}')
if [ -z "$CODE" ]; then
  echo "!! daemon did not start; log follows"
  cat "$LOG"
  exit 1
fi

echo "==> protocol probe (code $CODE)"
# The code is single-use by design, so each probe run needs a freshly started daemon.
node tools/probe.mjs --code "$CODE" --port "$PORT"
