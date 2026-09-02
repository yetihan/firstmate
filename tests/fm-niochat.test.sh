#!/usr/bin/env bash
# tests/fm-niochat.test.sh - the nio-chat-agent worker runtime
# (bin/fm-niochat-lib.sh) against a scripted fake curl standing in for the
# NIO Chat Local Agent Protocol Server.
#
# Covered surfaces, pinned to the empirically verified protocol grammar (the
# five access experiments; docs/nio-chat-agent-backend.md):
#   1. The default-off opt-in gate: absent means off, exactly "on" means on,
#      anything else is an invalid configuration error, and a dispatch without
#      the opt-in refuses before any HTTP traffic.
#   2. Handshake safety: re-read per call, loopback-only base_url, and the
#      exactly-once 401 retry across a token rotation.
#   3. SSE parsing on capture-shaped fixtures: run_id, terminal lifecycle,
#      visible text as separator-free delta concatenation, done detection, and
#      the data-line prefix stripping every jq consumer depends on.
#   4. The generated per-task check: one line per actionable state change,
#      silence for the marker it already surfaced, timeout past deadline.
#   5. The lifecycle: dispatch, reconcile to a report, ask_user interrupt and
#      answer, steer queueing and delivery, cancel, stop, timeout fallback,
#      teardown ownership, and single-concurrency channel locking.
#   6. The fm-send seam: the nio-chat ring IS the record delivery, with the
#      ordinary handled/ acknowledgement and a refusal that keeps the record.
#
# The fake curl is PATH-shadowed only inside the per-call subshells, so the
# test's own jq/grep never see it. Scripted responses are keyed by method and
# path with a pop counter per key, mirroring the orca fake-CLI model.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-niochat-lib.sh"
INBOX_LIB="$ROOT/bin/fm-task-inbox-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-niochat)

# --- case scaffolding --------------------------------------------------------

nio_case() {  # <name>: fresh fake server, state, data, and config dirs
  CASE="$TMP_ROOT/$1"
  RESP="$CASE/resp"
  STATE="$CASE/state"
  DATA="$CASE/data"
  CFG="$CASE/config"
  HS="$CASE/agent-protocol.json"
  FAKE_LOG="$CASE/curl.log"
  mkdir -p "$RESP/reqbodies" "$STATE" "$DATA" "$CFG"
  printf '{"base_url":"http://127.0.0.1:59999","token":"token-one","updated_at":1}\n' > "$HS"
  : > "$FAKE_LOG"
  FB=$(fm_fakebin "$CASE")
  cat > "$FB/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl standing in for the NIO Chat Local Agent Protocol Server.
# A scripted response lives at $FM_NIO_FAKE_RESP/<METHOD>_<path with / as _>/
# as <n>.out (body), plus optional <n>.code (HTTP status, default 200),
# <n>.exit (curl exit code for transport failure), and <n>.hook (a sourced
# snippet that may rewrite the handshake file and set CODE). Invocations are
# logged with \x1f argument separators, and a --data-binary body is copied out
# before the caller deletes its temp file.
set -u
log=${FM_NIO_FAKE_LOG:?}
resp=${FM_NIO_FAKE_RESP:?}
method=GET
url=
token=
warg=
datafile=
{
  printf 'curl'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$log"
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -H)
      case "$2" in
        'Authorization: Bearer '*) token=${2#'Authorization: Bearer '} ;;
      esac
      shift 2
      ;;
    -w) warg=$2; shift 2 ;;
    --data-binary) datafile=${2#@}; shift 2 ;;
    -d|--max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "fake curl: refusing non-loopback $url" >&2; exit 3 ;;
esac
path=/${url#*://*/}
key=${method}_${path//\//_}
dir=$resp/$key
n=$(cat "$dir/.next" 2>/dev/null || printf 1)
printf '%s' "$((n + 1))" > "$dir/.next" 2>/dev/null || true
[ -f "$dir/$n.out" ] || { echo "fake curl: no scripted response $n for $method $path" >&2; exit 22; }
[ -z "$datafile" ] || cp "$datafile" "$resp/reqbodies/$key.$n.json" 2>/dev/null || true
code=200
exitcode=0
[ -f "$dir/$n.code" ] && code=$(cat "$dir/$n.code")
[ -f "$dir/$n.exit" ] && exitcode=$(cat "$dir/$n.exit")
if [ -f "$dir/$n.hook" ]; then
  # Plain assignments, not a prefix on the source: bash restores prefix
  # variables around the '.' builtin, which would wipe the hook's CODE write.
  CODE=$code
  TOKEN=$token
  HANDSHAKE=${FM_NIOCHAT_HANDSHAKE:?}
  . "$dir/$n.hook"
  code=$CODE
fi
if [ -n "$warg" ]; then
  printf '%s\n%s' "$(cat "$dir/$n.out")" "$code"
else
  cat "$dir/$n.out"
fi
exit "$exitcode"
SH
  chmod +x "$FB/curl"
}

# Run one library function against the current case. FM_CONFIG_OVERRIDE pins
# the gate to the case config so an ambient FM_HOME can never leak the real
# home's opt-in into a test, and NIO_HANDSHAKE plus the NIO_GRACE,
# NIO_RUN_TIMEOUT, and NIO_RETRY_WINDOW knobs override the per-case fixtures.
nio() {  # <function> [args...]
  PATH="$FB:$PATH" \
  FM_CONFIG_OVERRIDE="$CFG" \
  FM_NIOCHAT_HANDSHAKE="${NIO_HANDSHAKE:-$HS}" \
  FM_NIOCHAT_HTTP_TIMEOUT=10 \
  FM_NIOCHAT_DISPATCH_GRACE="${NIO_GRACE:-5}" \
  FM_NIOCHAT_RUN_TIMEOUT="${NIO_RUN_TIMEOUT:-600}" \
  FM_NIOCHAT_RETRY_WINDOW="${NIO_RETRY_WINDOW:-60}" \
  FM_NIO_FAKE_LOG="$FAKE_LOG" \
  FM_NIO_FAKE_RESP="$RESP" \
  bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}

nio_key() {  # <method> <path> -> the fake's response-directory key
  printf '%s_%s' "$1" "${2//\//_}"
}

# .next holds the index of the next response the fake will serve; scripting a
# response lowers it to that index so pop order follows script order.
nio_next_floor() {  # <dir> <n>
  local cur
  cur=$(cat "$1/.next" 2>/dev/null || true)
  case "$cur" in ''|*[!0-9]*) cur=999999 ;; esac
  [ "$2" -lt "$cur" ] || return 0
  printf '%s' "$2" > "$1/.next"
}

nio_resp() {  # <method> <path> <n>: script the body on stdin as response n
  local dir
  dir=$RESP/$(nio_key "$1" "$2")
  mkdir -p "$dir"
  cat > "$dir/$3.out"
  nio_next_floor "$dir" "$3"
}

nio_status() {  # <method> <path> <n> <http-code> [curl-exit]
  local dir
  dir=$RESP/$(nio_key "$1" "$2")
  mkdir -p "$dir"
  printf '%s\n' "$4" > "$dir/$3.code"
  [ $# -lt 5 ] || printf '%s\n' "$5" > "$dir/$3.exit"
  nio_next_floor "$dir" "$3"
}

nio_exit() {  # <method> <path> <n> <curl-exit>: transport failure
  local dir
  dir=$RESP/$(nio_key "$1" "$2")
  mkdir -p "$dir"
  printf '%s\n' "$4" > "$dir/$3.exit"
  nio_next_floor "$dir" "$3"
}

nio_hook() {  # <method> <path> <n>: sourced hook script on stdin
  local dir
  dir=$RESP/$(nio_key "$1" "$2")
  mkdir -p "$dir"
  cat > "$dir/$3.hook"
  nio_next_floor "$dir" "$3"
}

nio_body_file() {  # <method> <path> <n> -> the captured request-body path
  printf '%s/reqbodies/%s.%s.json' "$RESP" "$(nio_key "$1" "$2")" "$3"
}

nio_record() {  # <id> <record-json>: write a run record through the library
  nio fm_niochat_record_write "$STATE" "$1" "$2" >/dev/null
}

nio_resp_repeat() {  # <method> <path> <n>: replay body n for pops n..n+3
  # Reconcile probes then reads the question, and each answer attempt re-reads
  # fresh options server-side, so one parked question costs up to four pops.
  local dir i
  dir=$RESP/$(nio_key "$1" "$2")
  mkdir -p "$dir"
  for i in $(( $3 + 1 )) $(( $3 + 2 )) $(( $3 + 3 )); do
    cp "$dir/$3.out" "$dir/$i.out"
  done
  nio_next_floor "$dir" "$3"
}

# --- SSE body builders (capture-shaped; text args stay JSON-plain words) -----

nio_sse_meta() {  # <run-id> <thread-id>
  printf 'event: agent_event\ndata: {"type":"event","seq":1,"method":"metadata","params":{"data":{"run_id":"%s","thread_id":"%s"}}}\n\n' "$1" "$2"
}

nio_sse_delta() {  # <seq> <text-fragment>
  printf 'event: agent_event\ndata: {"type":"event","seq":%s,"method":"messages","params":{"data":[{"event":"content-block-delta","delta":{"type":"text-delta","text":"%s"}}]}}\n\n' "$1" "$2"
}

nio_sse_lifecycle() {  # <seq> <started|interrupted|completed>
  printf 'event: agent_event\ndata: {"type":"event","seq":%s,"method":"lifecycle","params":{"data":{"event":"%s"}}}\n\n' "$1" "$2"
}

nio_sse_done() {  # <seq>
  printf 'event: agent_event\ndata: {"type":"event","seq":%s,"method":"done","params":{}}\n' "$1"
}

nio_sse_completed() {  # <run-id> <thread-id> <final-word>
  nio_sse_meta "$1" "$2"
  nio_sse_delta 2 'Hel'
  nio_sse_delta 3 'lo '
  nio_sse_delta 4 "$3"
  nio_sse_lifecycle 5 completed
  nio_sse_done 6
}

nio_sse_interrupted() {  # <run-id> <thread-id>
  nio_sse_meta "$1" "$2"
  nio_sse_lifecycle 2 interrupted
  nio_sse_done 3
}

nio_sse_hang() {  # <run-id> <thread-id>: metadata only, never terminal
  nio_sse_meta "$1" "$2"
}

CAP_PATH=/api/agent/v1/capabilities
THREADS_PATH=/api/agent/v1/threads
STREAM_PATH=/api/agent/v1/threads/th-1/runs/stream
RESUME_PATH=/api/agent/v1/threads/th-1/resume/stream
HISTORY_PATH=/api/agent/v1/threads/th-1/history
CANCEL_PATH=/api/agent/v1/threads/th-1/runs/run-1/cancel

nio_capable() {  # script a 0.2 capabilities answer as response <n>
  nio_resp GET "$CAP_PATH" "${1:-1}" <<'EOF'
{"protocol_version":"0.2.3","server":{"name":"mock-nio"}}
EOF
}

nio_thread_create() {  # script a thread-create answer as response <n>
  nio_resp POST "$THREADS_PATH" "${1:-1}" <<'EOF'
{"thread_id":"th-1"}
EOF
}

# --- 1. the opt-in gate ------------------------------------------------------

test_gate_off_by_default_and_refusal_before_dial() {
  local out err
  nio_case gate-off
  out=$(nio fm_niochat_gate "$CFG")
  [ "$out" = off ] || fail "absent gate must read off, got '$out'"
  printf 'TASK BRIEF: pick a color.\n' > "$CASE/brief.txt"
  err=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt" 2>&1 >/dev/null)
  expect_code 1 $? "dispatch without the opt-in must refuse"
  assert_contains "$err" 'not opted in' "dispatch refusal must name the opt-in"
  [ ! -s "$FAKE_LOG" ] || fail "refused dispatch must not touch the network"
  pass "gate: absent config means off, and dispatch refuses before dialing"
}

test_gate_accepts_exactly_on() {
  local out
  nio_case gate-on
  printf 'on\n' > "$CFG/nio-chat-worker"
  out=$(nio fm_niochat_gate "$CFG")
  [ "$out" = on ] || fail "gate must accept exactly on, got '$out'"
  printf '  on  \n' > "$CFG/nio-chat-worker"
  out=$(nio fm_niochat_gate "$CFG")
  [ "$out" = on ] || fail "gate must tolerate surrounding whitespace, got '$out'"
  pass "gate: exactly on opts in"
}

test_gate_invalid_values_are_errors() {
  local out
  nio_case gate-invalid
  for value in 'yes' 'ON' 'on please'; do
    printf '%s\n' "$value" > "$CFG/nio-chat-worker"
    out=$(nio fm_niochat_gate "$CFG" 2>/dev/null)
    expect_code 1 $? "gate value '$value' must be invalid"
    assert_contains "$out" 'invalid' "gate value '$value' must report invalid"
  done
  : > "$CFG/nio-chat-worker"
  out=$(nio fm_niochat_gate "$CFG" 2>/dev/null)
  expect_code 1 $? "empty gate file must be invalid"
  assert_contains "$out" 'empty' "empty gate file must report itself empty"
  rm "$CFG/nio-chat-worker"
  ln -s /nonexistent "$CFG/nio-chat-worker"
  out=$(nio fm_niochat_gate "$CFG" 2>/dev/null)
  expect_code 1 $? "symlink gate file must be invalid"
  assert_contains "$out" 'symlink' "symlink gate must report itself a symlink"
  pass "gate: wrong, empty, and symlinked values are invalid, never silently off"
}

test_config_dir_resolves_the_operating_home() {
  local out
  nio_case config-dir
  mkdir -p "$CASE/a" "$CASE/b" "$CASE/c"
  cfg_dir() {
    # shellcheck disable=SC2016 # The env passthrough trips the heuristic; the body is a literal mini-script.
    env -u FM_CONFIG_OVERRIDE -u FM_HOME -u FM_ROOT_OVERRIDE "$@" \
      bash -c '. "$1"; fm_niochat_config_dir' _ "$LIB"
  }
  out=$(cfg_dir FM_CONFIG_OVERRIDE="$CASE/a" FM_HOME="$CASE/b" FM_ROOT_OVERRIDE="$CASE/c")
  [ "$out" = "$CASE/a" ] || fail "FM_CONFIG_OVERRIDE must win, got '$out'"
  out=$(cfg_dir FM_HOME="$CASE/b" FM_ROOT_OVERRIDE="$CASE/c")
  [ "$out" = "$CASE/b/config" ] || fail "FM_HOME must follow, got '$out'"
  out=$(cfg_dir FM_ROOT_OVERRIDE="$CASE/c")
  [ "$out" = "$CASE/c/config" ] || fail "FM_ROOT_OVERRIDE must follow, got '$out'"
  out=$(cfg_dir)
  [ "$out" = "$ROOT/config" ] || fail "default must be the repo config, got '$out'"
  pass "config dir: the gate reads the operating home, never the code root"
}

# --- 2. handshake safety -----------------------------------------------------

test_handshake_refusals() {
  local out err
  nio_case handshake
  NIO_HANDSHAKE="$CASE/absent.json"
  err=$(nio fm_niochat_handshake 2>&1 >/dev/null)
  expect_code 1 $? "absent handshake must fail"
  assert_contains "$err" 'handshake' "absent handshake must name the handshake file"
  printf '{"base_url":"https://example.com/api","token":"t"}\n' > "$CASE/remote.json"
  NIO_HANDSHAKE="$CASE/remote.json"
  err=$(nio fm_niochat_handshake 2>&1 >/dev/null)
  expect_code 1 $? "non-loopback base_url must fail"
  assert_contains "$err" 'loopback' "non-loopback base_url must be refused as loopback"
  printf '{"base_url":"http://127.0.0.1:59999"}\n' > "$CASE/no-token.json"
  NIO_HANDSHAKE="$CASE/no-token.json"
  err=$(nio fm_niochat_handshake 2>&1 >/dev/null)
  expect_code 1 $? "handshake without a token must fail"
  NIO_HANDSHAKE=
  out=$(nio fm_niochat_handshake 2>/dev/null)
  [ "$out" = 'http://127.0.0.1:59999 token-one' ] || fail "valid handshake must print base and token, got '$out'"
  printf '{"base_url":"http://localhost:59999/","token":"t2"}\n' > "$HS"
  out=$(nio fm_niochat_handshake 2>/dev/null)
  [ "$out" = 'http://localhost:59999/ t2' ] || fail "localhost base_url must pass, got '$out'"
  pass "handshake: absent, remote, and tokenless files refuse; loopback passes"
}

test_ready_refuses_wrong_protocol_and_http() {
  local err
  nio_case ready-refuse
  nio_resp GET "$CAP_PATH" 1 <<'EOF'
{"protocol_version":"0.3.0","server":{"name":"mock-nio"}}
EOF
  err=$(nio fm_niochat_ready 2>&1 >/dev/null)
  expect_code 1 $? "protocol 0.3 must refuse"
  assert_contains "$err" 'verified for 0.2 only' "protocol refusal must name the 0.2 bound"
  nio_case ready-http
  nio_resp GET "$CAP_PATH" 1 <<'EOF'
{"protocol_version":"0.2.3"}
EOF
  nio_status GET "$CAP_PATH" 1 503
  err=$(nio fm_niochat_ready 2>&1 >/dev/null)
  expect_code 1 $? "HTTP 503 must refuse"
  assert_contains "$err" 'HTTP 503' "HTTP refusal must name the code"
  nio_case ready-unreachable
  nio_exit GET "$CAP_PATH" 1 7
  err=$(nio fm_niochat_ready 2>&1 >/dev/null)
  expect_code 1 $? "unreachable server must refuse"
  assert_contains "$err" 'unreachable' "unreachable server must be reported as unreachable"
  pass "ready: wrong protocol, error status, and unreachable server all refuse"
}

test_token_rotation_retries_exactly_once() {
  local out err cap_lines
  nio_case rotate-once
  nio_resp GET "$CAP_PATH" 1 </dev/null
  nio_hook GET "$CAP_PATH" 1 <<'EOF'
jq -c '.token="token-two"' "$HANDSHAKE" > "$HANDSHAKE.tmp" && mv "$HANDSHAKE.tmp" "$HANDSHAKE"
CODE=401
EOF
  nio_capable 2
  nio_thread_create 1
  nio_sse_completed run-rot th-1 world | nio_resp POST "$STREAM_PATH" 1
  printf 'TASK BRIEF: pick a color.\n' > "$CASE/brief.txt"
  printf 'on\n' > "$CFG/nio-chat-worker"
  out=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt" 2>"$CASE/err")
  expect_code 0 $? "dispatch must survive a rotation racing the call"
  assert_contains "$out" 'thread=th-1' "rotated dispatch must still land"
  cap_lines=$(grep -cF "$CAP_PATH" "$FAKE_LOG")
  [ "$cap_lines" = 2 ] || fail "capabilities must be dialed exactly twice, got $cap_lines"
  assert_grep 'Bearer token-one' "$FAKE_LOG" "first attempt must carry the stale token"
  assert_grep 'Bearer token-two' "$FAKE_LOG" "retry must carry the rotated token"
  nio_case rotate-stuck
  printf '{"base_url":"http://127.0.0.1:59999","token":"token-stale"}\n' > "$HS"
  nio_resp GET "$CAP_PATH" 1 </dev/null
  nio_status GET "$CAP_PATH" 1 401
  nio_resp GET "$CAP_PATH" 2 </dev/null
  nio_status GET "$CAP_PATH" 2 401
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: pick a color.\n' > "$CASE/brief.txt"
  err=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt" 2>&1 >/dev/null)
  expect_code 1 $? "a permanently stale token must refuse"
  cap_lines=$(grep -cF "$CAP_PATH" "$FAKE_LOG")
  [ "$cap_lines" = 2 ] || fail "a second 401 must stand after exactly one retry, got $cap_lines dials"
  pass "handshake: one rotation is absorbed with one retry, a stuck 401 stands"
}

# --- 3. SSE parsing on capture-shaped fixtures -------------------------------

test_stream_parsers() {
  local stream
  nio_case parsers
  stream=$CASE/stream.log
  {
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":1,"method":"metadata","params":{"data":{"run_id":"run-77","thread_id":"th-1"}}}\n'
    printf '\n'
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":2,"method":"messages","params":{"data":[{"event":"content-block-delta","delta":{"type":"text-delta","text":"Hel"}}]}}\n'
    printf '\n'
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":3,"method":"messages","params":{"data":[{"event":"content-block-delta","delta":{"type":"text-delta","text":"lo "}}]}}\n'
    printf '\n'
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":4,"method":"messages","params":{"data":[{"event":"content-block-delta","delta":{"type":"text-delta","text":"wo"}}]}}\n'
    printf '\n'
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":5,"method":"messages","params":{"data":[{"event":"content-block-delta","delta":{"type":"tool-call-delta"}}]}}\n'
    printf '\n'
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":6,"method":"lifecycle","params":{"data":{"event":"started"}}}\n'
    printf '\n'
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":7,"method":"lifecycle","params":{"data":{"event":"completed"}}}\n'
    printf '\n'
    printf 'event: agent_event\n'
    printf 'data: {"type":"event","seq":8,"method":"done","params":{}}\n'
  } > "$stream"
  out=$(nio fm_niochat_stream_run_id "$stream")
  [ "$out" = run-77 ] || fail "run_id must come from the metadata event, got '$out'"
  out=$(nio fm_niochat_stream_lifecycle_last "$stream")
  [ "$out" = completed ] || fail "lifecycle must read the last event, got '$out'"
  out=$(nio fm_niochat_stream_final_text "$stream")
  [ "$out" = 'Hello wo' ] || fail "text deltas must concatenate without separators, got '$out'"
  nio fm_niochat_stream_done "$stream"
  expect_code 0 $? "done event must be detected"
  nio_sse_interrupted run-78 th-1 > "$CASE/interrupted.log"
  out=$(nio fm_niochat_stream_lifecycle_last "$CASE/interrupted.log")
  [ "$out" = interrupted ] || fail "interrupted lifecycle must read back, got '$out'"
  nio_sse_hang run-79 th-1 > "$CASE/hang.log"
  nio fm_niochat_stream_done "$CASE/hang.log"
  expect_code 1 $? "a metadata-only stream must not read as done"
  pass "parsers: run_id, terminal lifecycle, separator-free text, and done"
}

# --- 4. the generated check --------------------------------------------------

test_check_script_events_and_marker() {
  local check out
  nio_case check
  check=$STATE/t1.check.sh
  nio fm_niochat_write_check "$STATE" t1
  [ -x "$check" ] || fail "the generated check must exist and be executable"
  fm_record() {  # <status> <run-id> <deadline>
    nio_record t1 "$(printf '{"task":"t1","thread":"th-1","thread_owner":"created","run_id":"%s","status":"%s","deadline":%s}' "$2" "$1" "$3")"
  }
  # Streaming before the deadline stays silent.
  fm_record streaming run-1 $(( $(date +%s) + 600 ))
  out=$(bash "$check")
  [ -z "$out" ] || fail "streaming before deadline must print nothing, got '$out'"
  # A terminal lifecycle event in the capture wakes without waiting out the
  # deadline: nothing else ever moves the record off streaming, so the check
  # must read the finished run's own capture (real-server e2e finding).
  nio_sse_completed run-1 th-1 world > "$STATE/t1.niochat-stream.log"
  out=$(bash "$check")
  [ "$out" = 'niochat t1 done' ] || fail "a completed capture must print done before the deadline, got '$out'"
  nio fm_niochat_wake_ack "$STATE" t1 'done' run-1
  out=$(bash "$check")
  [ -z "$out" ] || fail "the marker must suppress the capture-derived done, got '$out'"
  nio_sse_interrupted run-1 th-1 > "$STATE/t1.niochat-stream.log"
  rm -f "$STATE/t1.niochat-wake-sent"
  out=$(bash "$check")
  [ "$out" = 'niochat t1 interrupted' ] || fail "an interrupted capture must print its event, got '$out'"
  nio fm_niochat_wake_ack "$STATE" t1 interrupted run-1
  # A deferred question keeps its interrupted capture: the markered terminal
  # signal stays quiet, and once the retry window passes the deadline fires
  # the timeout nudge - the deferral acked interrupted, never timeout.
  fm_record streaming run-1 1
  out=$(bash "$check")
  [ "$out" = 'niochat t1 timeout' ] || fail "a markered terminal signal must still allow the deadline nudge, got '$out'"
  nio fm_niochat_wake_ack "$STATE" t1 timeout run-1
  out=$(bash "$check")
  [ -z "$out" ] || fail "the acked timeout nudge must stay silent, got '$out'"
  # A hung run with no terminal capture times out the same way.
  nio_sse_hang run-9 th-1 > "$STATE/t1.niochat-stream.log"
  rm -f "$STATE/t1.niochat-wake-sent"
  out=$(bash "$check")
  [ "$out" = 'niochat t1 timeout' ] || fail "past-deadline streaming must print the timeout event, got '$out'"
  nio fm_niochat_wake_ack "$STATE" t1 timeout run-1
  out=$(bash "$check")
  [ -z "$out" ] || fail "a markered event must stay silent, got '$out'"
  # A new terminal state for a new run prints once.
  fm_record 'done' run-2 0
  out=$(bash "$check")
  [ "$out" = 'niochat t1 done' ] || fail "a fresh done state must print its event, got '$out'"
  nio fm_niochat_wake_ack "$STATE" t1 'done' run-2
  out=$(bash "$check")
  [ -z "$out" ] || fail "the acked done event must stay silent, got '$out'"
  # No record at all stays silent.
  rm -f "$STATE/t1.niochat-run"
  out=$(bash "$check")
  [ -z "$out" ] || fail "an absent record must keep the check silent, got '$out'"
  pass "check: one line per actionable change, marker-suppressed, absent-safe"
}

# --- 5. lifecycle ------------------------------------------------------------

test_dispatch_reconcile_done() {
  local out rec
  nio_case happy
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: name a warm color.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  nio_sse_completed run-1 th-1 world | nio_resp POST "$STREAM_PATH" 1
  out=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt")
  expect_code 0 $? "a gated dispatch must succeed"
  [ "$out" = 'dispatched thread=th-1 run=run-1' ] || fail "dispatch must print thread and run, got '$out'"
  assert_present "$STATE/t1.check.sh" "dispatch must write the check"
  assert_grep 'working: nio-chat run dispatched' "$STATE/t1.status" "dispatch must append a working status"
  rec=$(cat "$STATE/t1.niochat-run")
  jq -e '.status == "streaming" and .thread == "th-1" and .thread_owner == "created" and .deadline > 0' \
    >/dev/null <<<"$rec" || fail "the run record must hold the streaming dispatch: $rec"
  [ "$(nio fm_niochat_channel_holder "$STATE")" = t1 ] || fail "dispatch must hold the channel lock"
  # The run's user message is exactly the brief text in the canonical shape.
  jq -e '.input.messages == [{"role":"user","content":"TASK BRIEF: name a warm color.\n"}] and .stream_mode == ["messages"]' \
    "$(nio_body_file POST "$STREAM_PATH" 1)" >/dev/null || fail "the run body must be the canonical input shape"
  assert_grep 'Bearer token-one' "$FAKE_LOG" "the run must authenticate with the handshake token"
  out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  assert_contains "$out" 'done: report at data/t1/report.md' "reconcile must report the answer"
  assert_grep 'Hello world' "$DATA/t1/report.md" "the report must carry the captured answer text"
  rec=$(cat "$STATE/t1.niochat-run")
  jq -e '.status == "done"' >/dev/null <<<"$rec" || fail "reconcile must settle the record to done: $rec"
  assert_grep 'done: nio-chat answer delivered' "$STATE/t1.status" "reconcile must append the done status"
  [ -z "$(nio fm_niochat_channel_holder "$STATE")" ] || fail "reconcile must release the channel lock"
  out=$(bash "$STATE/t1.check.sh")
  [ -z "$out" ] || fail "an acked done run must keep the check silent, got '$out'"
  out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  [ -z "$out" ] || fail "a second reconcile must be a silent no-op, got '$out'"
  pass "lifecycle: dispatch, done reconcile, report, lock release, idempotence"
}

test_dispatch_refusals() {
  local err
  nio_case refuse-no-meta
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: name a cold color.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  : | nio_resp POST "$STREAM_PATH" 1
  NIO_GRACE=2 err=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt" 2>&1 >/dev/null)
  expect_code 1 $? "a run without a metadata event must refuse dispatch"
  assert_contains "$err" 'no metadata event' "the refusal must name the missing metadata event"
  [ ! -e "$STATE/t1.niochat-run" ] || fail "a refused dispatch must leave no run record"
  [ -z "$(nio fm_niochat_channel_holder "$STATE")" ] || fail "a refused dispatch must release the channel"
  nio_case refuse-no-prompt
  printf 'on\n' > "$CFG/nio-chat-worker"
  nio_capable 1
  err=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/absent-brief.txt" 2>&1 >/dev/null)
  expect_code 1 $? "an absent prompt must refuse"
  assert_contains "$err" 'prompt file' "the refusal must name the prompt file"
  pass "dispatch: missing metadata and missing prompt both refuse cleanly"
}

test_channel_single_concurrency_and_reclaim() {
  local out
  nio_case concurrency
  printf 'on\n' > "$CFG/nio-chat-worker"
  nio_record ta "$(printf '{"task":"ta","thread":"th-1","thread_owner":"created","run_id":"run-a","status":"streaming","deadline":%s}' $(( $(date +%s) + 600 )))"
  nio fm_niochat_channel_try_acquire "$STATE" ta >/dev/null || fail "ta must take the channel for its streaming run"
  nio fm_niochat_channel_try_acquire "$STATE" tb >/dev/null 2>&1
  expect_code 1 $? "a second task must not take a live channel"
  printf 'TASK BRIEF: queue behind ta.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  out=$(nio fm_niochat_dispatch "$STATE" tb "$CASE/brief.txt" 2>&1 >/dev/null)
  expect_code 1 $? "dispatch under a held channel must refuse"
  assert_contains "$out" 'held by task ta' "the refusal must name the holding task"
  # Once ta settles, tb reclaims the channel end to end.
  nio_record ta '{"task":"ta","thread":"th-1","thread_owner":"created","run_id":"run-a","status":"done"}'
  nio_sse_completed run-b th-1 world | nio_resp POST "$STREAM_PATH" 1
  out=$(nio fm_niochat_dispatch "$STATE" tb "$CASE/brief.txt")
  expect_code 0 $? "a settled holder must be reclaimable"
  [ "$(nio fm_niochat_channel_holder "$STATE")" = tb ] || fail "tb must now hold the channel"
  pass "channel: one live holder, refusal names the holder, stale holders are reclaimed"
}

test_ask_user_interrupt_answer_and_steer_refusal() {
  local out err rec
  nio_case askuser
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: pick a color.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  nio_sse_interrupted run-1 th-1 | nio_resp POST "$STREAM_PATH" 1
  nio_resp GET "$HISTORY_PATH" 1 <<'EOF'
{"messages":[{"role":"assistant","checkpoint":{"channel_values":{"__interrupt__":[{"id":"q-1","value":{"question":"Which color?","options":[{"id":"red","label":"Red"},{"id":"blue","label":"Blue"}]}}]}}}]}
EOF
  # Reconcile reads the question twice (probe then read) and answer once more.
  nio_resp_repeat GET "$HISTORY_PATH" 1
  nio_sse_completed run-2 th-1 blue | nio_resp POST "$RESUME_PATH" 1
  out=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt")
  expect_code 0 $? "the ask_user dispatch must succeed"
  out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  assert_contains "$out" 'interrupted: Which color?' "reconcile must surface the question"
  rec=$(cat "$STATE/t1.niochat-run")
  jq -e '.status == "interrupted" and .note == "Which color?"' >/dev/null <<<"$rec" || fail "the record must park on the question: $rec"
  assert_grep 'blocked: nio-chat asks the captain: Which color?' "$STATE/t1.status" "the blocked status must carry the question"
  assert_grep 'red=Red;blue=Blue' "$STATE/t1.status" "the blocked status must carry the options"
  # A steer during the parked question refuses; the captain's answer is next.
  err=$(nio fm_niochat_steer_text "$STATE" t1 'more context' 2>&1 >/dev/null)
  expect_code 1 $? "a steer must refuse while a question is open"
  assert_contains "$err" 'not a steer' "the refusal must point at the answer command"
  # A wrong option id refuses with the open options.
  err=$(nio fm_niochat_answer "$STATE" "$DATA" t1 green 2>&1 >/dev/null)
  expect_code 1 $? "an unknown option must refuse"
  assert_contains "$err" 'red=Red;blue=Blue' "the refusal must list the open options"
  # The captain's answer resumes the thread and the run settles to a report.
  out=$(nio fm_niochat_answer "$STATE" "$DATA" t1 blue)
  assert_contains "$out" 'resumed: run run-2' "the answer must resume and report the run"
  rec=$(cat "$STATE/t1.niochat-run")
  jq -e '.status == "streaming" and .run_id == "run-2"' >/dev/null <<<"$rec" || fail "the resume must start a streaming run: $rec"
  assert_grep "working: nio-chat resumed with the captain's answer (blue)" "$STATE/t1.status" "the resume must append a working status"
  out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  assert_contains "$out" 'done: report' "the resumed run must settle to a report"
  assert_grep 'Hello blue' "$DATA/t1/report.md" "the report must carry the resumed answer"
  jq -e '.input.messages == [] ' "$(nio_body_file POST "$RESUME_PATH" 1)" >/dev/null 2>&1 \
    && fail "the resume body must not be an input message"
  jq -e '.command == {"resume":"blue"} and .stream_mode == ["messages"]' \
    "$(nio_body_file POST "$RESUME_PATH" 1)" >/dev/null || fail "the resume body must be the proven command shape"
  pass "ask_user: question surfaced, steer refused, wrong option refused, answer resumes"
}

test_reconcile_unreachable_question_retries_within_window() {
  local out rec now
  nio_case askuser-unreachable
  printf 'on\n' > "$CFG/nio-chat-worker"
  nio_record t1 "$(printf '{"task":"t1","thread":"th-1","thread_owner":"created","run_id":"run-1","status":"streaming","deadline":%s,"started":1}' $(( $(date +%s) + 600 )))"
  nio fm_niochat_write_check "$STATE" t1
  nio_sse_interrupted run-1 th-1 > "$STATE/t1.niochat-stream.log"
  nio_exit GET "$HISTORY_PATH" 1 7
  NIO_RETRY_WINDOW=120 out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  assert_contains "$out" 'retry: server unreachable' "an unreachable server must defer, not fail"
  rec=$(cat "$STATE/t1.niochat-run")
  now=$(date +%s)
  jq -e --argjson now "$now" '.status == "streaming" and .deadline > $now' >/dev/null <<<"$rec" \
    || fail "the deadline must be bumped by the retry window: $rec"
  assert_present "$STATE/t1.check.sh" "the deferred-retry case must exercise a real check"
  out=$(bash "$STATE/t1.check.sh")
  [ -z "$out" ] || fail "the deferred retry must quiet the check, got '$out'"
  pass "reconcile: an unreachable server defers the question read within a window"
}

test_steer_queues_mid_run_and_delivers_on_settle() {
  local out rec
  nio_case steer-queue
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: wait for a steer.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  nio_sse_hang run-1 th-1 | nio_resp POST "$STREAM_PATH" 1
  nio_sse_completed run-3 th-1 steered | nio_resp POST "$STREAM_PATH" 2
  out=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt")
  expect_code 0 $? "the hang-run dispatch must succeed"
  out=$(nio fm_niochat_steer_text "$STATE" t1 'prefer warm colors')
  assert_contains "$out" 'queued: task t1 is mid-run' "a mid-run steer must queue"
  assert_present "$STATE/t1.niochat-pending/000.steer" "the queued steer must be durable"
  assert_grep 'prefer warm colors' "$STATE/t1.niochat-pending/000.steer" "the queued text must be byte-exact"
  # The run settles (the capture lands) and reconcile delivers the queue.
  nio_sse_completed run-1 th-1 world > "$STATE/t1.niochat-stream.log"
  out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  assert_contains "$out" 'pending steer dispatched' "reconcile must start the queued steer"
  [ ! -e "$STATE/t1.niochat-pending/000.steer" ] || fail "the delivered steer must leave the queue"
  rec=$(cat "$STATE/t1.niochat-run")
  jq -e '.status == "streaming" and .run_id == "run-3" and .note == "steer"' >/dev/null <<<"$rec" \
    || fail "the steer run must be streaming under its own id: $rec"
  jq -e '.input.messages[0].content == "prefer warm colors"' \
    "$(nio_body_file POST "$STREAM_PATH" 2)" >/dev/null || fail "the steer body must be the queued text"
  out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  assert_contains "$out" 'done: report' "the steer run must settle to a report"
  pass "steer: mid-run queueing, delivery on settle, byte-exact text"
}

test_timeout_cancels_and_fails() {
  local out rec
  nio_case timeout
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: run forever.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  nio_sse_hang run-1 th-1 | nio_resp POST "$STREAM_PATH" 1
  nio_resp POST "$CANCEL_PATH" 1 <<'EOF'
{"ok":true,"status":"cancelling"}
EOF
  NIO_RUN_TIMEOUT=2 out=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt")
  expect_code 0 $? "the hang dispatch itself must succeed"
  sleep 3
  out=$(bash "$STATE/t1.check.sh")
  [ "$out" = 'niochat t1 timeout' ] || fail "the check must fire the timeout event past deadline, got '$out'"
  out=$(nio fm_niochat_reconcile "$STATE" "$DATA" t1)
  assert_contains "$out" 'timeout: run run-1 cancelled' "reconcile must cancel the overdue run"
  rec=$(cat "$STATE/t1.niochat-run")
  jq -e '.status == "timeout"' >/dev/null <<<"$rec" || fail "the record must settle to timeout: $rec"
  assert_grep 'failed: nio-chat run exceeded its timeout and was cancelled' "$STATE/t1.status" "the timeout must fail the task"
  [ -z "$(nio fm_niochat_channel_holder "$STATE")" ] || fail "the timeout must release the channel"
  out=$(bash "$STATE/t1.check.sh")
  [ -z "$out" ] || fail "the acked timeout must quiet the check, got '$out'"
  pass "timeout: the deadline fires, the run is cancelled, the task fails"
}

test_cancel_stop_and_teardown_ownership() {
  local out
  nio_case cancel-stop
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: wait.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  nio_sse_hang run-1 th-1 | nio_resp POST "$STREAM_PATH" 1
  nio_resp POST "$CANCEL_PATH" 1 <<'EOF'
{"ok":true,"status":"cancelling"}
EOF
  nio_resp DELETE "$THREADS_PATH/th-1" 1 <<'EOF'
{}
EOF
  out=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt")
  expect_code 0 $? "the hang dispatch must succeed"
  out=$(nio fm_niochat_cancel "$STATE" t1)
  assert_contains "$out" 'cancelled: run run-1' "cancel must address the task's own run"
  jq -e '.status == "cancelled"' >/dev/null < "$STATE/t1.niochat-run" || fail "cancel must settle the record"
  assert_grep 'failed: nio-chat run cancelled by supervisor' "$STATE/t1.status" "cancel must append its status"
  # Stop: a second hang run is cancelled, the record settles idle, thread kept.
  nio_sse_hang run-1 th-1 | nio_resp POST "$STREAM_PATH" 2
  nio_resp POST "$CANCEL_PATH" 2 <<'EOF'
{"ok":true,"status":"cancelling"}
EOF
  out=$(nio fm_niochat_steer_text "$STATE" t1 'run again')
  assert_contains "$out" 'delivered:' "a settled task must start a steer run"
  out=$(nio fm_niochat_stop "$STATE" t1)
  assert_contains "$out" 'stopped: task t1 settled' "stop must settle the task"
  jq -e '.status == "idle"' >/dev/null < "$STATE/t1.niochat-run" || fail "stop must settle the record to idle"
  assert_grep 'failed: nio-chat run stopped by supervisor' "$STATE/t1.status" "stop must cancel the live run"
  assert_no_grep $'-X\x1fDELETE' "$FAKE_LOG" "stop must retain the thread"
  # Teardown of a created thread deletes it and clears every local artifact.
  out=$(nio fm_niochat_teardown "$STATE" t1)
  assert_contains "$out" 'cleared for t1' "teardown must report the clear"
  assert_grep 'DELETE' "$FAKE_LOG" "teardown must delete a thread firstmate created"
  assert_absent "$STATE/t1.niochat-run" "teardown must remove the run record"
  assert_absent "$STATE/t1.niochat-stream.log" "teardown must remove the stream capture"
  assert_absent "$STATE/t1.niochat-wake-sent" "teardown must remove the wake marker"
  assert_absent "$STATE/.niochat-channel.lock" "teardown must release the channel lock"
  out=$(nio fm_niochat_teardown "$STATE" t1)
  expect_code 0 $? "teardown must be idempotent"
  # An adopted thread is the captain's conversation and is never destroyed.
  nio_case teardown-adopted
  nio_record t9 "$(printf '{"task":"t9","thread":"th-9","thread_owner":"adopted","run_id":"run-9","status":"streaming","deadline":%s}' $(( $(date +%s) + 600 )))"
  nio_resp POST "/api/agent/v1/threads/th-9/runs/run-9/cancel" 1 <<'EOF'
{"ok":true,"status":"cancelling"}
EOF
  out=$(nio fm_niochat_teardown "$STATE" t9)
  expect_code 0 $? "an adopted-thread teardown must succeed"
  assert_no_grep 'DELETE' "$FAKE_LOG" "an adopted thread must never be deleted"
  assert_absent "$STATE/t9.niochat-run" "the adopted teardown must still clear local artifacts"
  pass "cancel, stop, teardown: own-run only, thread retained on stop, ownership-gated delete"
}

test_run_state_fold() {
  local out
  nio_case run-state
  nio_record t1 '{"task":"t1","status":"streaming"}'
  out=$(nio fm_niochat_run_state "$STATE" t1)
  [ "$out" = busy ] || fail "streaming must fold to busy, got '$out'"
  for status in interrupted 'done' cancelled timeout failed idle; do
    nio_record t1 "$(printf '{"task":"t1","status":"%s"}' "$status")"
    out=$(nio fm_niochat_run_state "$STATE" t1)
    [ "$out" = settled ] || fail "$status must fold to settled, got '$out'"
  done
  nio_record t1 '{"task":"t1"}'
  nio fm_niochat_run_state "$STATE" t1 >/dev/null 2>&1
  expect_code 1 $? "a statusless record must fail rather than guess idle"
  nio fm_niochat_run_state "$STATE" absent >/dev/null 2>&1
  expect_code 1 $? "an absent record must fail rather than guess idle"
  pass "run state: busy while streaming, settled after, never a guessed idle"
}

# --- 6. the fm-send ring seam ------------------------------------------------

test_ring_delivers_and_acknowledges() {
  local out rec
  nio_case ring
  printf 'on\n' > "$CFG/nio-chat-worker"
  printf 'TASK BRIEF: wait for a steer.\n' > "$CASE/brief.txt"
  nio_capable 1
  nio_thread_create 1
  nio_sse_hang run-1 th-1 | nio_resp POST "$STREAM_PATH" 1
  out=$(nio fm_niochat_dispatch "$STATE" t1 "$CASE/brief.txt")
  expect_code 0 $? "the ring fixture dispatch must succeed"
  nio_inbox() {  # run an inbox-library call in the same jail as nio
    PATH="$FB:$PATH" \
    FM_CONFIG_OVERRIDE="$CFG" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_NIOCHAT_HANDSHAKE="$HS" \
    FM_NIOCHAT_HTTP_TIMEOUT=10 \
    FM_NIOCHAT_DISPATCH_GRACE="${NIO_GRACE:-5}" \
    FM_NIOCHAT_RUN_TIMEOUT="${NIO_RUN_TIMEOUT:-600}" \
    FM_NIO_FAKE_LOG="$FAKE_LOG" \
    FM_NIO_FAKE_RESP="$RESP" \
    bash -c '. "$1"; shift; "$@"' _ "$INBOX_LIB" "$@"
  }
  rec=$(nio_inbox fm_task_inbox_write "$STATE" t1 'please prefer warm colors')
  assert_present "$rec" "the inbox record must be written"
  # The nio-chat ring IS the delivery: the record lands as a queued steer and
  # its move to handled/ is the ordinary inbox acknowledgement.
  nio_inbox fm_task_inbox_ring nio-chat ignore "$rec" '' >/dev/null 2>&1
  expect_code 0 $? "the nio-chat ring must succeed while the run is streaming"
  assert_absent "$rec" "the delivered record must leave the inbox"
  assert_present "${rec%/*}/handled/$(basename "$rec")" "the delivered record must be acknowledged in handled/"
  assert_grep 'please prefer warm colors' "$STATE/t1.niochat-pending/000.steer" "the ring must queue the record body"
  # While a question is open the ring refuses and the record stays durable.
  nio_record t1 '{"task":"t1","thread":"th-1","thread_owner":"created","run_id":"run-1","status":"interrupted","note":"q"}'
  rm -rf "$STATE/t1.niochat-pending"
  rec=$(nio_inbox fm_task_inbox_write "$STATE" t1 'one more nudge')
  nio_inbox fm_task_inbox_ring nio-chat ignore "$rec" '' >/dev/null 2>&1
  expect_code 2 $? "the ring must fail with the watcher's retry code while a question is open"
  assert_present "$rec" "the refused record must stay in the inbox for the re-ring ladder"
  pass "ring: delivery is the acknowledgement, refusal keeps the record for re-ring"
}

# --- run ---------------------------------------------------------------------

test_gate_off_by_default_and_refusal_before_dial
test_gate_accepts_exactly_on
test_gate_invalid_values_are_errors
test_config_dir_resolves_the_operating_home
test_handshake_refusals
test_ready_refuses_wrong_protocol_and_http
test_token_rotation_retries_exactly_once
test_stream_parsers
test_check_script_events_and_marker
test_dispatch_reconcile_done
test_dispatch_refusals
test_channel_single_concurrency_and_reclaim
test_ask_user_interrupt_answer_and_steer_refusal
test_reconcile_unreachable_question_retries_within_window
test_steer_queues_mid_run_and_delivers_on_settle
test_timeout_cancels_and_fails
test_cancel_stop_and_teardown_ownership
test_run_state_fold
test_ring_delivers_and_acknowledges
