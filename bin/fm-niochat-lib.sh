#!/usr/bin/env bash
# fm-niochat-lib.sh - the ONE owner of the nio-chat-agent worker runtime.
#
# nio-chat-agent is a harness-axis worker runtime whose worker is the NIO Chat
# desktop app's local agent (the company-internal Local Agent Protocol Server
# at 127.0.0.1:8765, HTTP+SSE, bearer-token auth). The agent has NO local
# filesystem access: it cannot read a brief file, append status events, or run
# commands. This library is therefore the worker's whole local half - it
# dispatches the brief as a run, captures the run's stream, classifies busy
# state from its own records, surfaces ask_user interrupts, delivers steers,
# enforces the run timeout, and writes the task's answer report.
#
# Protocol facts below are the empirically verified surface (five access
# experiments, 2026-09-02; the full evidence record lives in
# docs/nio-chat-agent-backend.md "Verification record"):
#   - Handshake ~/.nio-chat-desktop/agent-protocol.json carries
#     {base_url, token, updated_at}; the token rotates per app launch, so it is
#     re-read FRESH on every HTTP call. A wrong or stale token is HTTP 401.
#   - Input contract: POST runs/stream takes
#     {"input":{"messages":[{"role":"user","content":"..."}]},"stream_mode":["messages"]}.
#     The server does NOT validate the body shape - malformed input is coerced
#     to an empty message and still runs, so this library only ever sends the
#     canonical shape above.
#   - SSE grammar: data lines carry {type:"event",seq,method,params{data}}.
#     method=metadata carries run_id/thread_id; method=messages carries a LIST
#     of blocks whose discriminator is .event (content-block-delta with
#     .delta.type=="text-delta" is the visible reply text); method=lifecycle
#     carries event=started|interrupted|completed; method=done is terminal.
#   - ask_user does NOT hang headless: the run ends lifecycle=interrupted with
#     the question in GET threads/{id}/history under
#     .messages[-1].checkpoint.channel_values.__interrupt__[0].value
#     (question, options[{id,label}], selection). The answer is
#     POST threads/{id}/resume/stream {"command":{"resume":"<option-id>"}}.
#   - runs/{run_id}/cancel stops a run ({"ok":true,"status":"cancelling"}).
#   - The server runs concurrent runs on one thread without serializing them,
#     and GET threads/{id}.status stays "idle" while a run streams, so busy
#     truth is THIS library's run record - never thread status. GET on an
#     unknown thread id CREATES an empty thread, so liveness reads use
#     GET /api/agent/v1/capabilities only.
#
# Opt-in contract: the channel is default OFF. It dispatches only when
# config/nio-chat-worker exists and reads exactly "on", only on an explicit
# per-task harness choice (bin/fm-spawn.sh refuses a config-resolved
# selection), and only for tasks whose category passes the captain's data
# boundary (docs/nio-chat-agent-backend.md "Data boundary" owns the
# allowed/forbidden category table firstmate applies BEFORE dispatch). The
# app is never launched, restarted, updated, or quit by this library.
#
# Artifacts (all firstmate-owned, all removed by teardown):
#   state/<id>.niochat-run         the run record: one JSON line, atomically
#                                  replaced. Fields: task, thread, thread_owner
#                                  (created|adopted), run_id, status (streaming|
#                                  interrupted|done|cancelled|timeout|failed|
#                                  idle), started, deadline, pid, note,
#                                  announced (the last status+run_id surfaced
#                                  through a status append).
#   state/<id>.niochat-stream.log  the current run's raw SSE capture (truncated
#                                  per run; earlier turns stay in the thread's
#                                  server-side history).
#   state/<id>.niochat-pending/    queued steers, one numbered record each,
#                                  FIFO; emptied as each is dispatched.
#   state/<id>.niochat-wake-sent   the check script's dedupe marker: the last
#                                  "<status> <run_id>" a check wake surfaced or
#                                  reconcile acknowledged.
#   state/<id>.check.sh            the generated watcher check (registered
#                                  through bin/fm-check-register.sh); prints one
#                                  line when the run record reaches a state
#                                  firstmate must act on, nothing otherwise.
#   state/.niochat-channel.lock    the single-concurrency advisory lock; its
#                                  owner file names the task holding the
#                                  channel. Stale when the owner has no
#                                  streaming run record.
#
# Sourced by bin/fm-niochat.sh, bin/fm-spawn.sh, bin/fm-crew-state.sh,
# bin/backends/nio-chat.sh, and tests. fm_niochat_deliver_record additionally
# needs bin/fm-task-inbox-lib.sh sourced by its caller (the fm-send seam does).
# No side effects on source.
#
# Tunables (env):
#   FM_NIOCHAT_HANDSHAKE      default ~/.nio-chat-desktop/agent-protocol.json
#   FM_NIOCHAT_HTTP_TIMEOUT   per-call curl cap, seconds (default 20)
#   FM_NIOCHAT_RUN_TIMEOUT    run deadline, seconds (default 1800)
#   FM_NIOCHAT_DISPATCH_GRACE seconds to wait for the run's metadata event
#                             after dispatch before declaring the dispatch
#                             failed (default 30)
#   FM_NIOCHAT_RETRY_WINDOW   seconds added to the deadline when the server
#                             goes unreachable mid-finish, bounding how often
#                             the check retries (default 60)

_FM_NIOCHAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_niochat_handshake_path() {
  printf '%s' "${FM_NIOCHAT_HANDSHAKE:-$HOME/.nio-chat-desktop/agent-protocol.json}"
}

# The opt-in flag lives in the OPERATING HOME's config/, never the code root's
# (AGENTS.md section 2: FM_HOME selects config/ while scripts come from the
# tracked code root), resolved with the same override chain the house scripts
# use: FM_CONFIG_OVERRIDE, then FM_HOME, then FM_ROOT_OVERRIDE, then the repo
# this library ships in.
fm_niochat_config_dir() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s' "$FM_CONFIG_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/config' "$FM_HOME"
  elif [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
    printf '%s/config' "$FM_ROOT_OVERRIDE"
  else
    printf '%s/config' "$(cd "$_FM_NIOCHAT_LIB_DIR/.." && pwd)"
  fi
}

fm_niochat_http_timeout() {
  local t=${FM_NIOCHAT_HTTP_TIMEOUT:-20}
  case "$t" in ''|*[!0-9]*) t=20 ;; esac
  printf '%s' "$t"
}

fm_niochat_run_timeout() {
  local t=${FM_NIOCHAT_RUN_TIMEOUT:-1800}
  case "$t" in ''|*[!0-9]*) t=1800 ;; esac
  printf '%s' "$t"
}

fm_niochat_dispatch_grace() {
  local t=${FM_NIOCHAT_DISPATCH_GRACE:-30}
  case "$t" in ''|*[!0-9]*) t=30 ;; esac
  printf '%s' "$t"
}

fm_niochat_retry_window() {
  local t=${FM_NIOCHAT_RETRY_WINDOW:-60}
  case "$t" in ''|*[!0-9]*) t=60 ;; esac
  printf '%s' "$t"
}

fm_niochat_run_path() {  # <state-dir> <id>
  printf '%s/%s.niochat-run' "$1" "$2"
}

fm_niochat_stream_path() {  # <state-dir> <id>
  printf '%s/%s.niochat-stream.log' "$1" "$2"
}

fm_niochat_pending_dir() {  # <state-dir> <id>
  printf '%s/%s.niochat-pending' "$1" "$2"
}

fm_niochat_wake_marker_path() {  # <state-dir> <id>
  printf '%s/%s.niochat-wake-sent' "$1" "$2"
}

fm_niochat_channel_lock_dir() {  # <state-dir>
  printf '%s/.niochat-channel.lock' "$1"
}

# --- opt-in gate -------------------------------------------------------------

# The gate's single owner. Prints "on" when the channel is opted in, "off"
# when the config file is absent (the default), and returns 1 with the reason
# on stdout when the file exists but is not a valid opt-in value.
fm_niochat_gate() {  # <config-dir>
  local file=$1 value
  [ ! -L "$file/nio-chat-worker" ] || { printf 'invalid: config/nio-chat-worker is a symlink'; return 1; }
  [ -f "$file/nio-chat-worker" ] || { printf 'off'; return 0; }
  value=$(tr -d '[:space:]' < "$file/nio-chat-worker" 2>/dev/null || true)
  case "$value" in
    on) printf 'on'; return 0 ;;
    '') printf 'invalid: config/nio-chat-worker is empty; write exactly "on" to opt in, or remove the file'; return 1 ;;
    *) printf 'invalid: config/nio-chat-worker reads "%s"; the only valid opt-in value is "on"' "$value"; return 1 ;;
  esac
}

# --- handshake and HTTP ------------------------------------------------------

# fm_niochat_handshake: read the handshake FRESH (never cached - the token
# rotates per app launch). Prints "base_url token" and returns 0, or returns 1
# with the reason on stderr. The base_url must be a loopback http(s) URL: the
# protocol server is a localhost companion of the desktop app, and a handshake
# pointing anywhere else is treated as corrupt rather than dialed.
fm_niochat_handshake() {
  local path base token
  path=$(fm_niochat_handshake_path)
  [ -f "$path" ] && [ ! -L "$path" ] || { echo "nio-chat handshake file is absent or a symlink at $path (start the NIO Chat desktop app by hand; firstmate never launches it)" >&2; return 1; }
  base=$(jq -r '.base_url // empty' "$path" 2>/dev/null)
  token=$(jq -r '.token // empty' "$path" 2>/dev/null)
  [ -n "$base" ] && [ -n "$token" ] || { echo "nio-chat handshake file at $path is not readable JSON with base_url and token" >&2; return 1; }
  case "$base" in
    http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*|http://localhost|http://localhost:*|http://localhost/*|https://127.0.0.1|https://127.0.0.1:*|https://127.0.0.1/*|https://localhost|https://localhost:*|https://localhost/*) ;;
    *) echo "nio-chat handshake base_url '$base' is not a loopback address; refusing to dial it" >&2; return 1 ;;
  esac
  printf '%s %s' "$base" "$token"
}

# fm_niochat_call <method> <path> [extra curl args...]: one authenticated API
# call. Prints the body, then one final line "HTTP <code>" - the code rides on
# stdout because callers capture the call in a command substitution, where an
# environment side-channel would die with the subshell. fm_niochat_call_code
# and fm_niochat_call_body split a capture back apart. Returns 0 for any HTTP
# response (the caller judges the code), 1 for a transport failure (server
# unreachable = app not running). A 401 retries exactly once after re-reading
# the handshake, covering a token rotation racing the call; a second 401
# stands (the app relaunched with a token this machine's handshake file does
# not know, or the app is gone).
fm_niochat_call() {  # <method> <path> [curl-args...]
  local method=$1 path=$2 body code attempt=0 hs base token
  shift 2
  while :; do
    hs=$(fm_niochat_handshake) || return 1
    base=${hs%% *}
    token=${hs#* }
    body=$(curl -sS -N --max-time "$(fm_niochat_http_timeout)" \
      -H "Authorization: Bearer $token" -X "$method" "$@" \
      -w '\n%{http_code}' "$base$path" 2>/dev/null) || { echo "nio-chat server unreachable at $base (is the NIO Chat desktop app running?)" >&2; return 1; }
    code=${body##*$'\n'}
    body=${body%$'\n'*}
    if [ "$code" = 401 ] && [ "$attempt" = 0 ]; then
      attempt=1
      continue
    fi
    printf '%s\nHTTP %s\n' "$body" "$code"
    return 0
  done
}

fm_niochat_call_code() {  # <raw capture from fm_niochat_call> -> the HTTP code
  local last=${1##*$'\n'}
  printf '%s' "${last#HTTP }"
}

fm_niochat_call_body() {  # <raw capture from fm_niochat_call> -> the body
  printf '%s' "${1%$'\n'*}"
}

# fm_niochat_ready: liveness and compatibility. Returns 0 and prints a short
# capability summary when the server answers capabilities with a 0.2-line
# protocol_version, 1 when unreachable or rejected. This is the ONLY liveness
# read - GET /threads/{id} is create-on-demand and must never be probed.
fm_niochat_ready() {
  local raw body code version
  raw=$(fm_niochat_call GET /api/agent/v1/capabilities) || return 1
  code=$(fm_niochat_call_code "$raw")
  body=$(fm_niochat_call_body "$raw")
  [ "$code" = 200 ] || { echo "nio-chat capabilities answered HTTP $code" >&2; return 1; }
  version=$(printf '%s' "$body" | jq -r '.protocol_version // empty' 2>/dev/null)
  [ -n "$version" ] || { echo "nio-chat capabilities body is not readable JSON" >&2; return 1; }
  case "$version" in
    0.2*) ;;
    *) echo "nio-chat server speaks protocol_version $version; this runtime is verified for 0.2 only" >&2; return 1 ;;
  esac
  printf 'protocol %s, server %s' "$version" "$(printf '%s' "$body" | jq -r '.server.name // "unknown"' 2>/dev/null)"
}

# --- run record --------------------------------------------------------------

fm_niochat_record_read() {  # <state-dir> <id> -> JSON on stdout, or fail
  local rec
  rec=$(fm_niochat_run_path "$1" "$2")
  [ -f "$rec" ] || return 1
  jq -e . "$rec" >/dev/null 2>&1 || return 1
  cat "$rec"
}

fm_niochat_record_field() {  # <record-json> <field>
  printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // empty' 2>/dev/null
}

fm_niochat_record_write() {  # <state-dir> <id> <record-json>
  local state=$1 id=$2 json=$3 tmp
  [ -d "$state" ] || return 1
  tmp=$(mktemp "$state/.$id.niochat-run.XXXXXX") || return 1
  printf '%s\n' "$json" | jq -c . > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$(fm_niochat_run_path "$state" "$id")"
}

fm_niochat_record_set() {  # <state-dir> <id> <field> <value> [more field value...]
  local state=$1 id=$2 json
  json=$(fm_niochat_record_read "$state" "$id") || return 1
  shift 2
  while [ "$#" -ge 2 ]; do
    json=$(printf '%s' "$json" | jq -c --arg k "$1" --arg v "$2" '.[$k]=$v') || return 1
    shift 2
  done
  fm_niochat_record_write "$state" "$id" "$json"
}

# fm_niochat_run_state: the busy-classification fold over the run record.
# Prints busy while a run streams and settled once it ended (including a
# pending ask_user interrupt, which is a parked turn, not a running one).
# Fails when there is no record or it is unparseable - never guesses idle.
fm_niochat_run_state() {  # <state-dir> <id>
  local status
  status=$(fm_niochat_record_read "$1" "$2" | jq -r '.status // empty' 2>/dev/null) || return 1
  case "$status" in
    streaming) printf 'busy' ;;
    interrupted|done|cancelled|timeout|failed|idle) printf 'settled' ;;
    *) return 1 ;;
  esac
}

# --- stream parsing ----------------------------------------------------------

fm_niochat_stream_done() {  # <stream-log> -> 0 when the terminal done event is present
  grep -q '"method": *"done"' "$1" 2>/dev/null
}

# The raw capture holds SSE framing ("event: agent_event" then "data: {JSON}");
# every jq consumer reads payloads through this prefix stripper.
fm_niochat_stream_data_lines() {  # <stream-log> -> JSON payloads, one per line
  grep '^data:' "$1" 2>/dev/null | sed 's/^data: *//'
}

fm_niochat_stream_run_id() {  # <stream-log> -> run_id from the metadata event
  fm_niochat_stream_data_lines "$1" | grep '"method": *"metadata"' | head -1 \
    | jq -r '.params.data.run_id // empty' 2>/dev/null
}

fm_niochat_stream_lifecycle_last() {  # <stream-log> -> started|interrupted|completed|''
  fm_niochat_stream_data_lines "$1" | grep '"method": *"lifecycle"' | tail -1 \
    | jq -r '.params.data.event // empty' 2>/dev/null
}

# The visible reply text: text-delta fragments concatenated WITHOUT inserted
# separators (they are word fragments of one message, verified).
fm_niochat_stream_final_text() {  # <stream-log>
  fm_niochat_stream_data_lines "$1" \
    | jq -j 'select(.type == "event" and .method == "messages")
             | .params.data[]?
             | select(.event == "content-block-delta" and .delta.type == "text-delta")
             | .delta.text' 2>/dev/null
}

# --- channel lock (single concurrency) ---------------------------------------

# The server accepts concurrent runs without serializing them (verified), and
# interleaved runs on one thread tangle the conversation, so this library
# serializes dispatch itself: one streaming run per HOME at a time. The lock
# is an atomic mkdir whose owner file names the holding task. Reclaiming a
# stale holder swaps the directory aside with mv (atomic), re-verifies the
# owner it moved, and only then claims - so two reclaimers can never delete
# each other's fresh lock, and a crash mid-swap leaves at most an inert
# .niochat-channel.lock.stale.* directory that nothing reads.
fm_niochat_channel_try_acquire() {  # <state-dir> <id>
  local state=$1 id=$2 lock owner holder_state moved_owner aside
  lock=$(fm_niochat_channel_lock_dir "$state")
  if mkdir "$lock" 2>/dev/null; then
    printf '%s' "$id" > "$lock/owner"
    return 0
  fi
  owner=$(cat "$lock/owner" 2>/dev/null || true)
  [ -n "$owner" ] || owner=unknown
  [ "$owner" != "$id" ] || return 0
  # Refuse only while the holder is genuinely busy; a settled holder (or one
  # whose record is gone, e.g. a teardown that crashed before release) is
  # reclaimable.
  holder_state=$(fm_niochat_run_state "$state" "$owner" 2>/dev/null) || holder_state=
  [ "$holder_state" = busy ] && return 1
  aside="$lock.stale.$id.$RANDOM$RANDOM"
  mv "$lock" "$aside" 2>/dev/null || return 1
  moved_owner=$(cat "$aside/owner" 2>/dev/null || true)
  if [ "$moved_owner" != "$owner" ]; then
    # The lock changed hands between the staleness read and the swap: put it
    # back for its live holder and decline.
    mv "$aside" "$lock" 2>/dev/null || true
    return 1
  fi
  rm -rf "$aside"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s' "$id" > "$lock/owner"
  return 0
}

fm_niochat_channel_release() {  # <state-dir> <id>
  local lock owner
  lock=$(fm_niochat_channel_lock_dir "$1")
  owner=$(cat "$lock/owner" 2>/dev/null || true)
  [ "$owner" = "$2" ] && rm -rf "$lock"
  return 0
}

fm_niochat_channel_holder() {  # <state-dir>
  cat "$(fm_niochat_channel_lock_dir "$1")/owner" 2>/dev/null || true
}

# --- queued steers -----------------------------------------------------------

# Steers arrive through the task inbox record path, whose text may span lines,
# so each queued steer is its own numbered record file, FIFO.
fm_niochat_steer_queue() {  # <state-dir> <id> <text>
  local dir n
  dir=$(fm_niochat_pending_dir "$1" "$2")
  mkdir -p "$dir" || return 1
  n=0
  while [ -e "$dir/$(printf '%03d' "$n").steer" ]; do n=$((n + 1)); done
  printf '%s' "$3" > "$dir/$(printf '%03d' "$n").steer"
}

fm_niochat_steer_peek() {  # <state-dir> <id> -> oldest queued text, or fail
  local first
  first=$(find "$(fm_niochat_pending_dir "$1" "$2")" -name '*.steer' -maxdepth 1 2>/dev/null | sort | head -1)
  [ -n "$first" ] || return 1
  cat "$first"
}

fm_niochat_steer_pop() {  # <state-dir> <id>
  local first
  first=$(find "$(fm_niochat_pending_dir "$1" "$2")" -name '*.steer' -maxdepth 1 2>/dev/null | sort | head -1)
  [ -n "$first" ] && rm -f "$first"
  return 0
}

fm_niochat_steer_queued() {  # <state-dir> <id>
  find "$(fm_niochat_pending_dir "$1" "$2")" -name '*.steer' -maxdepth 1 2>/dev/null | grep -q .
}

# --- launching a streaming run ----------------------------------------------

# _fm_niochat_launch_stream <state> <id> <endpoint-path> <body-file> <note>:
# the shared streaming scaffolding for dispatch and answer-resume. Launches
# one detached curl SSE capture bounded by --max-time = the run deadline (so a
# wedged run cannot outlive its timeout at the transport layer either), waits
# for the metadata event, and publishes the streaming run record. Returns 0
# with "pid<TAB>run_id" on stdout; 1 with the reason on stderr, leaving the
# previous record untouched. The caller owns the channel lock.
_fm_niochat_launch_stream() {  # <state> <id> <endpoint-path> <body-file> <note>
  local state=$1 id=$2 endpoint=$3 bodyfile=$4 note=$5
  local hs base token stream pid run_id waited=0 grace
  hs=$(fm_niochat_handshake) || return 1
  base=${hs%% *}
  token=${hs#* }
  stream=$(fm_niochat_stream_path "$state" "$id")
  : > "$stream"
  (
    curl -sS -N --max-time "$(fm_niochat_run_timeout)" \
      -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      -X POST --data-binary "@$bodyfile" \
      "$base$endpoint" > "$stream" 2>/dev/null
  ) &
  pid=$!
  grace=$(fm_niochat_dispatch_grace)
  run_id=
  while [ "$waited" -lt "$grace" ]; do
    sleep 1
    waited=$((waited + 1))
    run_id=$(fm_niochat_stream_run_id "$stream")
    [ -n "$run_id" ] && break
    kill -0 "$pid" 2>/dev/null || break
  done
  if [ -z "$run_id" ]; then
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    echo "nio-chat run at $endpoint produced no metadata event within ${grace}s; dispatch refused" >&2
    return 1
  fi
  fm_niochat_record_write "$state" "$id" "$(jq -cn \
    --arg task "$id" --arg run "$run_id" --arg status streaming --arg note "$note" \
    --argjson started "$(date +%s)" \
    --argjson deadline "$(( $(date +%s) + $(fm_niochat_run_timeout) ))" \
    --argjson pid "$pid" --arg announced '' \
    '{task:$task,run_id:$run,status:$status,started:$started,deadline:$deadline,pid:$pid,note:$note,announced:$announced}')"
  printf '%s\t%s\n' "$pid" "$run_id"
}

# --- thread primitives -------------------------------------------------------

fm_niochat_thread_create() {
  local raw body code
  raw=$(fm_niochat_call POST /api/agent/v1/threads -H 'Content-Type: application/json' -d '{}') || return 1
  code=$(fm_niochat_call_code "$raw")
  [ "$code" = 200 ] || { echo "nio-chat thread create answered HTTP $code" >&2; return 1; }
  body=$(fm_niochat_call_body "$raw")
  printf '%s' "$body" | jq -r '.thread_id // empty'
}

fm_niochat_thread_delete() {  # <thread-id>
  local raw
  raw=$(fm_niochat_call DELETE "/api/agent/v1/threads/$1") || return 1
  [ "$(fm_niochat_call_code "$raw")" = 200 ]
}

fm_niochat_cancel_run() {  # <thread-id> <run-id>
  fm_niochat_call POST "/api/agent/v1/threads/$1/runs/$2/cancel" -H 'Content-Type: application/json' -d '{}'
}

# fm_niochat_pending_question: the thread's open ask_user interrupt, printed
# as tab-separated "id<TAB>question<TAB>option_id=label;..." from the history
# endpoint's checkpoint. Empty (return 0) when the thread has no open
# interrupt. Returns 2 when the server is unreachable so the caller can
# distinguish "no question" from "cannot read right now" - the SSE stream
# never carries the question, so this read is the only source (verified).
fm_niochat_pending_question() {  # <thread-id>
  local raw body qs
  raw=$(fm_niochat_call GET "/api/agent/v1/threads/$1/history") || return 2
  [ "$(fm_niochat_call_code "$raw")" = 200 ] || return 0
  body=$(fm_niochat_call_body "$raw")
  qs=$(printf '%s' "$body" | jq -r '
    (.messages // [])[-1]
    | .checkpoint.channel_values.__interrupt__ // []
    | .[0]
    | if . == null then empty else
        (.id // "") + "\t" + (.value.question // "") + "\t" +
        ([ .value.options[]? | (.id // "") + "=" + (.label // "") ] | join(";"))
      end' 2>/dev/null)
  [ -n "$qs" ] && printf '%s' "$qs"
  return 0
}

# --- dispatch ----------------------------------------------------------------

# fm_niochat_dispatch <state> <id> <prompt-file> [thread]:
# the spawn entrypoint. Gates the channel opt-in (the operating home's
# config/), verifies readiness, takes the single-concurrency channel (creating
# a fresh thread, or adopting the given one for a relaunch without deleting it
# at teardown), sends the prompt file's text as the run, writes the generated
# check, and prints "dispatched thread=<t> run=<r>" on stdout. The prompt is
# the task's brief text; the agent cannot read files, so the whole brief
# travels as the run's user message.
fm_niochat_dispatch() {  # <state-dir> <id> <prompt-file> [thread]
  local state=$1 id=$2 prompt=$3 thread=${4:-}
  local gate tmp out run owner
  gate=$(fm_niochat_gate "$(fm_niochat_config_dir)") || { echo "refused: $gate" >&2; return 1; }
  [ "$gate" = on ] || { echo 'refused: the nio-chat channel is not opted in (config/nio-chat-worker must read exactly "on")' >&2; return 1; }
  [ -f "$prompt" ] || { echo "refused: prompt file $prompt is absent" >&2; return 1; }
  # Local refusals precede the network: a held channel refuses even when the app is closed.
  fm_niochat_channel_try_acquire "$state" "$id" || { echo "refused: the nio-chat channel is held by task $(fm_niochat_channel_holder "$state")" >&2; return 1; }
  fm_niochat_ready >/dev/null || { fm_niochat_channel_release "$state" "$id"; echo "refused: the nio-chat server is not usable right now (start the NIO Chat desktop app by hand; firstmate never launches it)" >&2; return 1; }
  owner=created
  if [ -z "$thread" ]; then
    thread=$(fm_niochat_thread_create) || { fm_niochat_channel_release "$state" "$id"; echo 'refused: thread creation failed' >&2; return 1; }
  else
    owner=adopted
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-niochat-$id.XXXXXX") || { fm_niochat_channel_release "$state" "$id"; return 1; }
  jq -cn --rawfile text "$prompt" '{input:{messages:[{role:"user",content:$text}]},stream_mode:["messages"]}' > "$tmp/niochat-input.json"
  out=$(_fm_niochat_launch_stream "$state" "$id" "/api/agent/v1/threads/$thread/runs/stream" "$tmp/niochat-input.json" "dispatch") || {
    rm -rf "$tmp"
    fm_niochat_channel_release "$state" "$id"
    echo "refused: $out" >&2
    return 1
  }
  rm -rf "$tmp"
  run=${out#*$'\t'}
  fm_niochat_record_set "$state" "$id" thread "$thread" thread_owner "$owner"
  fm_niochat_write_check "$state" "$id"
  fm_niochat_status_append "$state" "$id" "working: nio-chat run dispatched on thread $thread (run $run)"
  printf 'dispatched thread=%s run=%s\n' "$thread" "$run"
}

# --- the check script (watcher wake path) ------------------------------------

# One generated per task at dispatch, registered with
# bin/fm-check-register.sh. It does local reads only - no network, no
# mutation - and prints exactly one line when the run record holds a state
# firstmate must act on that differs from the last surfaced marker, nothing
# otherwise. A streaming run past its deadline prints a timeout event;
# reconcile owns the actual cancel and the marker that quiets this check.
fm_niochat_write_check() {  # <state-dir> <id>
  local state=$1 id=$2 check
  check="$state/$id.check.sh"
  cat > "$check" <<EOF
#!/usr/bin/env bash
# Generated by bin/fm-niochat-lib.sh for task $id. Registered byte-trust via
# bin/fm-check-register.sh; regenerate and re-register, never hand-edit.
set -u
STATE=$(printf '%q' "$state")
ID=$(printf '%q' "$id")
REC="\$STATE/\$ID.niochat-run"
STREAM="\$STATE/\$ID.niochat-stream.log"
MARK="\$STATE/\$ID.niochat-wake-sent"
[ -f "\$REC" ] || exit 0
status=\$(jq -r '.status // empty' "\$REC" 2>/dev/null) || exit 0
run=\$(jq -r '.run_id // empty' "\$REC" 2>/dev/null) || exit 0
now=\$(date +%s)
deadline=\$(jq -r '.deadline // 0' "\$REC" 2>/dev/null) || deadline=0
case "\$status" in
  interrupted|done|cancelled|timeout|failed) event=\$status ;;
  streaming)
    # The record is the busy truth, but nothing else ever moves it off
    # streaming: a finished run must wake firstmate from its own terminal
    # capture, or a successful run would sit silent until its deadline.
    term=\$(sed -n 's/^data: *//p' "\$STREAM" 2>/dev/null | grep '"method": *"lifecycle"' | tail -1 | jq -r '.params.data.event // empty' 2>/dev/null)
    event=
    case "\$term" in
      completed) event=done ;;
      interrupted) event=interrupted ;;
    esac
    [ -n "\$event" ] && grep -qxF "\$event \$run" "\$MARK" 2>/dev/null && event=
    if [ -z "\$event" ]; then
      # No unacknowledged terminal signal: the deadline is the retry nudge -
      # both for a hung run and for a deferred question whose retry window
      # has passed (reconcile decides by the capture, never by the wake type).
      [ "\$deadline" -gt 0 ] 2>/dev/null || exit 0
      [ "\$now" -ge "\$deadline" ] 2>/dev/null || exit 0
      grep -qxF "timeout \$run" "\$MARK" 2>/dev/null && exit 0
      event=timeout
    fi
    ;;
  *) exit 0 ;;
esac
grep -qxF "\$event \$run" "\$MARK" 2>/dev/null && exit 0
printf 'niochat %s %s\\n' "\$ID" "\$event"
EOF
  chmod 0700 "$check"
}

# --- status appends and reporting --------------------------------------------

fm_niochat_status_append() {  # <state-dir> <id> <line>
  printf '%s\n' "$3" >> "$1/$2.status"
}

# The wake marker holds every acknowledged "<event> <run>" line, not just the
# latest: a deferred question must quiet its terminal signal without silencing
# the deadline's later retry nudge, and those are two different keys.
fm_niochat_wake_ack() {  # <state-dir> <id> <status> <run-id>
  local mark key
  mark=$(fm_niochat_wake_marker_path "$1" "$2")
  key="$3 $4"
  grep -qxF "$key" "$mark" 2>/dev/null && return 0
  printf '%s\n' "$key" >> "$mark"
}

fm_niochat_write_report() {  # <data-dir> <id> <thread> <run> <captured> <text>
  mkdir -p "$1/$2"
  {
    printf '# nio-chat answer for %s\n\n' "$2"
    printf 'Deliverable: the NIO Chat agent answer below, captured from the run stream.\n\n'
    printf -- '- thread: %s\n- run: %s\n- captured: %s\n\n' "$3" "$4" "$5"
    printf '%s\n' "$6"
  } > "$1/$2/report.md"
}

# --- reconcile ---------------------------------------------------------------

# The one finalizer. Called on a check wake (or by hand via bin/fm-niochat.sh
# reconcile) to move a finished capture into its records: a completed run
# becomes the answer report and a done status; an interrupted run surfaces
# its ask_user question as a blocked status for the captain; a run past its
# deadline is cancelled and failed; a settled run with queued steers starts
# the next one. Idempotent: every transition is announced in the record, and
# every handled wake acknowledges its marker, so reconciling twice appends
# nothing and re-fires no wake. Prints one line per action taken.
fm_niochat_reconcile() {  # <state-dir> <data-dir> <id>
  local state=$1 data=$2 id=$3
  local rec status stream thread run note qline rc text now deadline
  rec=$(fm_niochat_record_read "$state" "$id") || return 0
  status=$(fm_niochat_record_field "$rec" status)
  stream=$(fm_niochat_stream_path "$state" "$id")
  thread=$(fm_niochat_record_field "$rec" thread)
  run=$(fm_niochat_record_field "$rec" run_id)
  case "$status" in
    streaming)
      if fm_niochat_stream_done "$stream"; then
        if [ "$(fm_niochat_stream_lifecycle_last "$stream")" = interrupted ]; then
          qline=''
          fm_niochat_pending_question "$thread" >/dev/null 2>&1
          rc=$?
          if [ "$rc" = 0 ]; then
            qline=$(fm_niochat_pending_question "$thread")
          elif [ "$rc" = 2 ]; then
            # The run finished interrupted but the app is unreachable now:
            # quiet the terminal wake for one retry window - acking the
            # interrupted signal, never the timeout key, whose fire after the
            # window IS the retry nudge.
            fm_niochat_record_set "$state" "$id" deadline "$(( $(date +%s) + $(fm_niochat_retry_window) ))"
            fm_niochat_wake_ack "$state" "$id" interrupted "$run"
            printf 'retry: server unreachable while reading the question; retrying after the retry window\n'
            return 0
          fi
          if [ -n "$qline" ]; then
            note=$(printf '%s' "$qline" | cut -f2)
            fm_niochat_record_set "$state" "$id" status interrupted note "$note"
            fm_niochat_wake_ack "$state" "$id" interrupted "$run"
            fm_niochat_channel_release "$state" "$id"
            fm_niochat_status_append "$state" "$id" "blocked: nio-chat asks the captain: $note (answer with bin/fm-niochat.sh answer $id <option-id>; options: $(printf '%s' "$qline" | cut -f3))"
            printf 'interrupted: %s\n' "$note"
          else
            fm_niochat_record_set "$state" "$id" status failed note 'interrupted without a readable question'
            fm_niochat_wake_ack "$state" "$id" failed "$run"
            fm_niochat_channel_release "$state" "$id"
            fm_niochat_status_append "$state" "$id" "failed: nio-chat run interrupted but its question could not be read from the thread history"
            printf 'failed: interrupt without a readable question\n'
          fi
        else
          text=$(fm_niochat_stream_final_text "$stream")
          fm_niochat_write_report "$data" "$id" "$thread" "$run" \
            "$(fm_niochat_record_field "$rec" started)" "$text"
          fm_niochat_record_set "$state" "$id" status "done" announced "done $run"
          fm_niochat_wake_ack "$state" "$id" "done" "$run"
          fm_niochat_channel_release "$state" "$id"
          fm_niochat_status_append "$state" "$id" "done: nio-chat answer delivered (data/$id/report.md)"
          printf 'done: report at data/%s/report.md\n' "$id"
          if fm_niochat_steer_queued "$state" "$id"; then
            fm_niochat_deliver_pending "$state" "$id" || true
          fi
        fi
      else
        now=$(date +%s)
        deadline=$(fm_niochat_record_field "$rec" deadline)
        if [ "${deadline:-0}" -gt 0 ] 2>/dev/null && [ "$now" -ge "$deadline" ]; then
          fm_niochat_cancel_run "$thread" "$run" >/dev/null 2>&1 || true
          fm_niochat_record_set "$state" "$id" status timeout note 'run deadline passed and the run was cancelled'
          fm_niochat_wake_ack "$state" "$id" timeout "$run"
          fm_niochat_channel_release "$state" "$id"
          fm_niochat_status_append "$state" "$id" "failed: nio-chat run exceeded its timeout and was cancelled (thread $thread)"
          printf 'timeout: run %s cancelled\n' "$run"
        fi
      fi
      ;;
    interrupted|done|cancelled|timeout|failed|idle)
      # Terminal states were announced at their transition; the marker is
      # synced here so a first poll after a lost marker stays silent.
      fm_niochat_wake_ack "$state" "$id" "$status" "$run"
      if [ "$status" = "done" ] && fm_niochat_steer_queued "$state" "$id"; then
        fm_niochat_deliver_pending "$state" "$id" || true
      fi
      ;;
  esac
  return 0
}

# --- steer delivery (the fm-send data plane) ---------------------------------

# fm_niochat_steer_text <state-dir> <id> <text>: deliver one steer
# to the task's thread. A streaming run or a busy channel queues the text; an
# idle or ended task starts a new run carrying it. A task parked on an
# ask_user question refuses the steer - the captain's answer is the only
# valid next turn.
fm_niochat_steer_text() {  # <state-dir> <id> <text>
  local state=$1 id=$2 text=$3 rec status holder thread tmp out owner
  rec=$(fm_niochat_record_read "$state" "$id") || { echo "error: task $id has no nio-chat run record" >&2; return 1; }
  status=$(fm_niochat_record_field "$rec" status)
  case "$status" in
    streaming)
      fm_niochat_steer_queue "$state" "$id" "$text"
      printf 'queued: task %s is mid-run; the steer runs when it settles\n' "$id"
      return 0
      ;;
    interrupted)
      echo "error: task $id is waiting on the captain's answer to its ask_user question; answer it with bin/fm-niochat.sh answer, not a steer" >&2
      return 1
      ;;
  esac
  holder=$(fm_niochat_channel_holder "$state")
  if [ -n "$holder" ] && [ "$holder" != "$id" ]; then
    fm_niochat_steer_queue "$state" "$id" "$text"
    printf 'queued: the nio-chat channel is held by task %s; the steer runs when it settles\n' "$holder"
    return 0
  fi
  fm_niochat_channel_try_acquire "$state" "$id" || {
    fm_niochat_steer_queue "$state" "$id" "$text"
    printf 'queued: the nio-chat channel is busy\n'
    return 0
  }
  thread=$(fm_niochat_record_field "$rec" thread)
  owner=$(fm_niochat_record_field "$rec" thread_owner)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-niochat-$id.XXXXXX") || return 1
  jq -cn --arg text "$text" '{input:{messages:[{role:"user",content:$text}]},stream_mode:["messages"]}' > "$tmp/niochat-input.json"
  out=$(_fm_niochat_launch_stream "$state" "$id" "/api/agent/v1/threads/$thread/runs/stream" "$tmp/niochat-input.json" "steer") || {
    rm -rf "$tmp"
    fm_niochat_channel_release "$state" "$id"
    echo "error: $out" >&2
    return 1
  }
  rm -rf "$tmp"
  fm_niochat_record_set "$state" "$id" thread "$thread" thread_owner "$owner"
  printf 'delivered: steer started a run on thread %s\n' "$thread"
  return 0
}

# fm_niochat_deliver_pending <state-dir> <id>: start the oldest
# queued steer, if any. Called from reconcile after a run settles and by hand.
# One per call: the started run's own completion wakes the next delivery.
fm_niochat_deliver_pending() {  # <state-dir> <id>
  local state=$1 id=$2 text status
  fm_niochat_steer_queued "$state" "$id" || return 1
  status=$(fm_niochat_record_read "$state" "$id" | jq -r '.status // empty' 2>/dev/null)
  [ "$status" = streaming ] && return 1
  text=$(fm_niochat_steer_peek "$state" "$id") || return 1
  if fm_niochat_steer_text "$state" "$id" "$text"; then
    fm_niochat_steer_pop "$state" "$id"
    printf 'pending steer dispatched\n'
    return 0
  fi
  return 1
}

# fm_niochat_deliver_record <state-dir> <task-id> <record-path>:
# the nio-chat "ring": a pane worker gets a doorbell line, but the nio-chat
# agent cannot read a filesystem inbox, so delivering the steer IS the ring.
# The durable inbox record is acknowledged by moving it to handled/ exactly
# as a pane worker's mv would, keeping the inbox contract whole. Requires
# bin/fm-task-inbox-lib.sh sourced by the caller for fm_task_inbox_body.
fm_niochat_deliver_record() {  # <state-dir> <task-id> <record-path>
  local state=$1 id=$2 recpath=$3 text inbox
  [ -f "$recpath" ] || return 1
  text=$(fm_task_inbox_body "$recpath" 2>/dev/null) || return 1
  fm_niochat_steer_text "$state" "$id" "$text" || return 1
  inbox=$(dirname "$recpath")
  mkdir -p "$inbox/handled"
  mv -f "$recpath" "$inbox/handled/$(basename "$recpath")"
  return 0
}

# --- answer, cancel, stop ----------------------------------------------------

# fm_niochat_answer <state-dir> <data-dir> <id> <choice>: resume the parked
# ask_user interrupt with the captain's option id. Proven shape:
# {"command":{"resume":"<option-id>"}} (verified end to end).
fm_niochat_answer() {  # <state-dir> <data-dir> <id> <choice>
  local state=$1 data=$2 id=$3 choice=$4
  local rec thread qid qline options tmp out run owner rest opt ok
  rec=$(fm_niochat_record_read "$state" "$id") || { echo "error: task $id has no nio-chat run record" >&2; return 1; }
  [ "$(fm_niochat_record_field "$rec" status)" = interrupted ] || { echo "error: task $id is not parked on an ask_user question (status $(fm_niochat_record_field "$rec" status))" >&2; return 1; }
  thread=$(fm_niochat_record_field "$rec" thread)
  qline=$(fm_niochat_pending_question "$thread") || { echo 'error: the nio-chat server is unreachable; answer once the app is running' >&2; return 1; }
  [ -n "$qline" ] || { echo "error: task $id's thread has no open interrupt to answer" >&2; return 1; }
  qid=$(printf '%s' "$qline" | cut -f1)
  options=$(printf '%s' "$qline" | cut -f3)
  ok=
  rest=$options
  while :; do
    opt=${rest%%;*}
    if [ "${opt%%=*}" = "$choice" ]; then
      ok=1
      break
    fi
    if [ "$rest" = "$opt" ]; then
      break
    fi
    rest=${rest#*;}
  done
  [ -n "$ok" ] || { echo "error: '$choice' is not one of the open question's options ($options)" >&2; return 1; }
  fm_niochat_channel_try_acquire "$state" "$id" || { echo "error: the nio-chat channel is held by task $(fm_niochat_channel_holder "$state")" >&2; return 1; }
  owner=$(fm_niochat_record_field "$rec" thread_owner)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-niochat-$id.XXXXXX") || return 1
  jq -cn --arg c "$choice" '{command:{resume:$c},stream_mode:["messages"]}' > "$tmp/niochat-input.json"
  out=$(_fm_niochat_launch_stream "$state" "$id" "/api/agent/v1/threads/$thread/resume/stream" "$tmp/niochat-input.json" "resume:$qid=$choice") || {
    rm -rf "$tmp"
    fm_niochat_channel_release "$state" "$id"
    echo "error: $out" >&2
    return 1
  }
  rm -rf "$tmp"
  run=${out#*$'\t'}
  fm_niochat_record_set "$state" "$id" thread "$thread" thread_owner "$owner"
  fm_niochat_status_append "$state" "$id" "working: nio-chat resumed with the captain's answer ($choice)"
  printf 'resumed: run %s\n' "$run"
}

# fm_niochat_cancel <state-dir> <id>: cancel the task's own active run (only
# its own - the run_id comes from this task's record, never another's).
fm_niochat_cancel() {  # <state-dir> <id>
  local state=$1 id=$2 rec thread run out
  rec=$(fm_niochat_record_read "$state" "$id") || { echo "error: task $id has no nio-chat run record" >&2; return 1; }
  [ "$(fm_niochat_record_field "$rec" status)" = streaming ] || { printf 'idle: task %s has no active run\n' "$id"; return 0; }
  thread=$(fm_niochat_record_field "$rec" thread)
  run=$(fm_niochat_record_field "$rec" run_id)
  out=$(fm_niochat_cancel_run "$thread" "$run") || { echo "error: cancel of run $run on thread $thread failed ($(fm_niochat_call_code "$out"))" >&2; return 1; }
  fm_niochat_record_set "$state" "$id" status cancelled note 'cancelled by supervisor'
  fm_niochat_wake_ack "$state" "$id" cancelled "$run"
  fm_niochat_channel_release "$state" "$id"
  fm_niochat_status_append "$state" "$id" "failed: nio-chat run cancelled by supervisor (run $run)"
  printf 'cancelled: run %s\n' "$run"
}

# fm_niochat_stop <state-dir> <id>: the exit verb. No persistent agent process
# exists (runs are transient), so exiting means: cancel any active run, settle
# the record to idle, and keep the thread for a later relaunch.
fm_niochat_stop() {  # <state-dir> <id>
  local state=$1 id=$2 rec status thread run
  rec=$(fm_niochat_record_read "$state" "$id") || { echo "error: task $id has no nio-chat run record" >&2; return 1; }
  status=$(fm_niochat_record_field "$rec" status)
  thread=$(fm_niochat_record_field "$rec" thread)
  run=$(fm_niochat_record_field "$rec" run_id)
  if [ "$status" = streaming ]; then
    fm_niochat_cancel_run "$thread" "$run" >/dev/null 2>&1 || true
    fm_niochat_status_append "$state" "$id" "failed: nio-chat run stopped by supervisor (run $run)"
  fi
  fm_niochat_channel_release "$state" "$id"
  fm_niochat_record_set "$state" "$id" status idle note 'stopped by supervisor; thread retained'
  printf 'stopped: task %s settled (thread retained)\n' "$id"
}

# --- teardown ----------------------------------------------------------------

# fm_niochat_teardown <state-dir> <id>: release everything the channel holds
# for the task. Service side: cancel a streaming run, and delete the thread
# ONLY when this library created it (an adopted thread belongs to the captain
# - a finished task must never destroy a conversation it did not start). Local
# side: the run record, stream capture, steer queue, wake marker, and channel
# lock. The registered check is retired by bin/fm-teardown.sh's ordinary
# custom-check path. Idempotent.
fm_niochat_teardown() {  # <state-dir> <id>
  local state=$1 id=$2 rec thread run status owner
  rec=$(fm_niochat_record_read "$state" "$id") || rec=
  if [ -n "$rec" ]; then
    thread=$(fm_niochat_record_field "$rec" thread)
    status=$(fm_niochat_record_field "$rec" status)
    run=$(fm_niochat_record_field "$rec" run_id)
    owner=$(fm_niochat_record_field "$rec" thread_owner)
    if [ "$status" = streaming ] && [ -n "$run" ]; then
      fm_niochat_cancel_run "$thread" "$run" >/dev/null 2>&1 || true
    fi
    if [ -n "$thread" ] && [ "$owner" = created ]; then
      fm_niochat_thread_delete "$thread" >/dev/null 2>&1 || true
    fi
  fi
  fm_niochat_channel_release "$state" "$id"
  rm -f -- "$(fm_niochat_run_path "$state" "$id")" \
    "$(fm_niochat_stream_path "$state" "$id")" \
    "$(fm_niochat_wake_marker_path "$state" "$id")" 2>/dev/null || true
  rm -rf -- "$(fm_niochat_pending_dir "$state" "$id")" 2>/dev/null || true
  printf 'nio-chat channel cleared for %s\n' "$id"
}
