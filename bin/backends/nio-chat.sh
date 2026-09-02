#!/usr/bin/env bash
# bin/backends/nio-chat.sh - the nio-chat-agent session-provider adapter.
#
# nio-chat is not a terminal multiplexer: its "endpoint" is the NIO Chat
# desktop app's local agent thread owned by bin/fm-niochat-lib.sh. This
# adapter is the thin bridge that lets the generic per-op dispatchers in
# bin/fm-backend.sh speak to that library with the target string
# "fm-<task-id>" - the virtual window name fm-spawn.sh records for nio-chat
# tasks (the task label is the endpoint; no pane exists).
#
# Not supported, deliberately, and therefore absent from the dispatcher arms:
# send_key (no keyboard), composer_state (no composer - the agent reads its
# input from the run stream, so the shared doorbell model has nothing to
# classify), and native event push (the generated per-task check script is
# the wake path instead). busy_state and agent_state read ONLY the local run
# record - never the server - because the thread's server-side status stays
# "idle" while a run streams (verified; docs/nio-chat-agent-backend.md
# "Verification record").

# shellcheck source=bin/fm-niochat-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-niochat-lib.sh"

# The home resolution contract every bin/fm-*.sh CLI uses, restated for a
# sourced adapter: explicit overrides first, then FM_HOME, then the repo root
# that ships this file.
_fm_niochat_state_dir() {
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then printf '%s' "$FM_STATE_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then printf '%s' "$FM_HOME/state"
  else printf '%s' "$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/state"; fi
}

_fm_niochat_data_dir() {
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then printf '%s' "$FM_DATA_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then printf '%s' "$FM_HOME/data"
  else printf '%s' "$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/data"; fi
}

fm_backend_niochat_tool_check() {
  command -v jq >/dev/null 2>&1 || { echo "error: backend=nio-chat selected but 'jq' is not installed" >&2; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "error: backend=nio-chat selected but 'curl' is not installed" >&2; return 1; }
}

# Target string -> task id ("fm-<id>" or bare "<id>").
_fm_niochat_task_of_target() {  # <target>
  local t=$1
  case "$t" in
    fm-*) printf '%s' "${t#fm-}" ;;
    *) printf '%s' "$t" ;;
  esac
}

# fm_backend_niochat_capture: a bounded human-readable tail of the run's SSE
# capture - one line per event (seq, method, and for message events the newly
# streamed text). Local read only; no network.
fm_backend_niochat_capture() {  # <target> <lines>
  local id stream lines=${2:-40}
  fm_backend_niochat_tool_check || return 1
  id=$(_fm_niochat_task_of_target "$1")
  stream="$(fm_niochat_stream_path "$(_fm_niochat_state_dir)" "$id")"
  [ -f "$stream" ] || { echo "error: no nio-chat stream capture for task $id" >&2; return 1; }
  grep '^data:' "$stream" | sed 's/^data: *//' | jq -r '
    select(.type == "event")
    | (.seq | tostring) + " " + .method +
      (if .method == "lifecycle" then " " + (.params.data.event // "")
       elif .method == "messages" then " " + ([ .params.data[]?
            | select(.event == "content-block-delta" and .delta.type == "text-delta")
            | .delta.text ] | join(""))
       else "" end)' 2>/dev/null | tail -n "$lines"
}

# fm_backend_niochat_busy_state: the local run record folded to the shared
# busy/idle/unknown vocabulary; interrupted (a parked ask_user turn) is idle
# because no run is consuming the channel.
fm_backend_niochat_busy_state() {  # <target>
  local id
  id=$(_fm_niochat_task_of_target "$1")
  case "$(fm_niochat_run_state "$(_fm_niochat_state_dir)" "$id" 2>/dev/null)" in
    busy) printf 'busy' ;;
    settled) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_niochat_send_text_submit: deliver steer text to the thread
# (dispatch now, or queue when busy). Verdict contract: exactly empty output
# means confirmed delivery, matching the pane backends' proof-carrying
# verdicts - "queued" is a real non-delivery outcome the caller must see.
fm_backend_niochat_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local id text=$2 out
  fm_backend_niochat_tool_check || { printf 'send-failed'; return 0; }
  id=$(_fm_niochat_task_of_target "$1")
  out=$(fm_niochat_steer_text "$(_fm_niochat_state_dir)" "$(_fm_niochat_data_dir)" "$id" "$text" 2>&1) || {
    printf '%s' "$out"
    return 0
  }
  case "$out" in
    delivered:*) printf '' ;;
    *) printf '%s' "$out" ;;
  esac
  return 0
}

# fm_backend_niochat_kill: the cleanup verb - cancel any active run, delete a
# firstmate-created thread, and clear the task's local channel artifacts.
# Best-effort by contract, like every backend's kill.
fm_backend_niochat_kill() {  # <target>
  local id
  id=$(_fm_niochat_task_of_target "$1")
  fm_niochat_teardown "$(_fm_niochat_state_dir)" "$id" >/dev/null 2>&1 || true
}

# fm_backend_niochat_target_exists: read-only - the local run record IS the
# endpoint. Never dials the server (GET /threads/{id} is create-on-demand and
# must never be probed).
fm_backend_niochat_target_exists() {  # <target>
  local id
  id=$(_fm_niochat_task_of_target "$1")
  [ -f "$(fm_niochat_run_path "$(_fm_niochat_state_dir)" "$id")" ]
}

# fm_backend_niochat_agent_state: recovery-grade endpoint state from the local
# record. A streaming run is a live worker; a settled record is an endpoint
# with no active run (dead licenses recovery, missing marks the endpoint
# authoritatively absent); an unreadable record is unreadable.
fm_backend_niochat_agent_state() {  # <target>
  local id state
  id=$(_fm_niochat_task_of_target "$1")
  state=$(_fm_niochat_state_dir)
  [ -f "$(fm_niochat_run_path "$state" "$id")" ] || { printf 'missing'; return 0; }
  case "$(fm_niochat_run_state "$state" "$id" 2>/dev/null)" in
    busy) printf 'alive' ;;
    settled) printf 'dead' ;;
    *) printf 'unreadable' ;;
  esac
}
