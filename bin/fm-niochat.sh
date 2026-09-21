#!/usr/bin/env bash
# fm-niochat.sh - the operator CLI for the nio-chat-agent worker runtime.
#
# One entry point for everything an operator does with a nio-chat task beyond
# the ordinary spawn/steer/teardown lifecycle: health checks, reading a run,
# answering an ask_user question, cancelling, and cleanup. Every real behavior
# lives in bin/fm-niochat-lib.sh; this file only resolves the home and
# dispatches subcommands.
#
# Usage:
#   fm-niochat.sh doctor                 gate, handshake, and server readiness
#   fm-niochat.sh status <id>            the run record folded to one line
#   fm-niochat.sh peek <id> [lines]      bounded tail of the run's stream capture
#   fm-niochat.sh reconcile <id>         finalize a finished run (report,
#                                        question, timeout, queued steer)
#   fm-niochat.sh answer <id> <choice>   resume a parked ask_user with an option
#   fm-niochat.sh steer <id> <text|->    deliver a steer now or queue it
#   fm-niochat.sh cancel <id>            cancel the task's active run
#   fm-niochat.sh stop <id>              exit verb: settle idle, keep the thread
#   fm-niochat.sh teardown <id>          clear everything the channel holds
#
# The channel's data boundary and opt-in contract are owned by
# docs/nio-chat-agent-backend.md; in particular, task-category gatekeeping
# happens in firstmate BEFORE dispatch, never in this CLI.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-niochat-lib.sh
. "$SCRIPT_DIR/fm-niochat-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-niochat.sh doctor                 gate, handshake, and server readiness
  fm-niochat.sh status <id>            the run record folded to one line
  fm-niochat.sh peek <id> [lines]      bounded tail of the run's stream capture
  fm-niochat.sh reconcile <id>         finalize a finished run (report,
                                       question, timeout, queued steer)
  fm-niochat.sh answer <id> <choice>   resume a parked ask_user with an option
  fm-niochat.sh steer <id> <text|->    deliver a steer now or queue it
  fm-niochat.sh cancel <id>            cancel the task's active run
  fm-niochat.sh stop <id>              exit verb: settle idle, keep the thread
  fm-niochat.sh teardown <id>          clear everything the channel holds
EOF
  exit 2
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  doctor)
    gate=$(fm_niochat_gate "$(fm_niochat_config_dir)") || { echo "gate: $gate"; exit 1; }
    echo "gate: $gate"
    [ "$gate" = on ] || exit 0
    ready=$(fm_niochat_ready) || { echo "server: unreachable ($ready)"; exit 1; }
    echo "server: ready ($ready)"
    holder=$(fm_niochat_channel_holder "$STATE")
    [ -n "$holder" ] && echo "channel: held by task $holder" || echo 'channel: free'
    ;;
  status)
    [ $# -ge 1 ] || usage
    id=$1
    rec=$(fm_niochat_record_read "$STATE" "$id") || { echo "error: task $id has no nio-chat run record" >&2; exit 1; }
    jq -r '"status=" + (.status // "?") + " thread=" + (.thread // "?") + " run=" + (.run_id // "?") + " note=" + (.note // "")' <<<"$rec"
    ;;
  peek)
    [ $# -ge 1 ] || usage
    id=$1
    lines=${2:-40}
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    fm_backend_capture nio-chat "fm-$id" "$lines"
    ;;
  reconcile)
    [ $# -ge 1 ] || usage
    fm_niochat_reconcile "$STATE" "$DATA" "$1"
    ;;
  answer)
    [ $# -ge 2 ] || usage
    fm_niochat_answer "$STATE" "$DATA" "$1" "$2"
    ;;
  steer)
    [ $# -ge 2 ] || usage
    id=$1
    text=$2
    [ "$text" = - ] && text=$(cat)
    fm_niochat_steer_text "$STATE" "$id" "$text"
    ;;
  cancel)
    [ $# -ge 1 ] || usage
    fm_niochat_cancel "$STATE" "$1"
    ;;
  stop)
    [ $# -ge 1 ] || usage
    fm_niochat_stop "$STATE" "$1"
    ;;
  teardown)
    [ $# -ge 1 ] || usage
    fm_niochat_teardown "$STATE" "$1"
    ;;
  *)
    usage
    ;;
esac
