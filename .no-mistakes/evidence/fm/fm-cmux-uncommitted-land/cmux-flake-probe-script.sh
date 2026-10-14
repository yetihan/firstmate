#!/usr/bin/env bash
# Flake-rate probe: repeat the smoke test's exact failing operation
# (fm_backend_cmux_current_path with no label, after cd /tmp) N times against
# the real app on one fm-test- workspace. Prints the empty-result rate.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source cmux || { echo "cannot source adapter"; exit 1; }
LABEL="fm-test-flake1"
N=${1:-30}
TASK_IDS=$(fm_backend_cmux_create_task "$LABEL" /tmp) || { echo "create failed"; exit 1; }
WS=$(printf '%s\n' "$TASK_IDS" | awk '{print $1}')
SF=$(printf '%s\n' "$TASK_IDS" | awk '{print $2}')
TARGET="$WS:$SF"
sleep 0.5
fm_backend_cmux_send_text_line "$TARGET" "cd /tmp" >/dev/null 2>&1
sleep 0.3
empty=0
for i in $(seq 1 "$N"); do
  p=$(fm_backend_cmux_current_path "$TARGET")
  [ -n "$p" ] || empty=$((empty + 1))
done
echo "adapter=$(basename "$ROOT") runs=$N empty=$empty"
. "$ROOT/tests/cmux-test-safety.sh"
cmux_safe_close_workspace "$WS" "$LABEL" >/dev/null 2>&1 && echo "closed" || echo "close refused"
