#!/usr/bin/env bash
# tests/fm-harness-liveness-drift-live-e2e.test.sh - default-on drift guard proving
# every INSTALLED harness is still classified `alive` by the tmux liveness
# probe (bin/backends/tmux.sh) AND still identified by the harness-detection
# ancestry walk (bin/fm-harness.sh).
#
# Why this file exists: both verdicts depend on how a harness names its own
# process, which is a surface the harness vendor controls and changes without
# notice. Claude Code began reporting its version string as its process name and
# became unattributable, which silently degraded supervision. A regression that
# only a real harness release can cause needs a check that runs real harnesses;
# a stubbed agent cannot see it, and neither can a table of names transcribed
# from a previous release.
#
# Detection carries the same exposure for a second reason: a structural ancestor
# now outranks an environment marker (bin/fm-harness.sh owns that boundary), so
# a harness whose process name stops matching no longer merely loses a fast
# path - the walk keeps climbing and can reach a DIFFERENT harness that really
# is further up the tree. This guard is what catches that at the release that
# causes it.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. The launch uses whatever credentials the harness already has; an
# unauthenticated harness still starts its process, which is all the liveness
# probe reads.
#
# Portable serial CI installs the public Pi package but no credentials, so this
# guard checks that available token-free surface there and runs against every installed
# harness on more capable hosts.
#
# Two dependency assumptions this guard refuses to make silently:
#
# - A resolved candidate must EXECUTE. `command -v`-style first-match
#   resolution can return a stale shim or wrapper whose target is gone (an
#   observed case: a dead cmux-cli temp shim shadowing a working codex install
#   reachable only through the macOS ChatGPT-app bundle), so every PATH match
#   and documented install root is tried in order and the first candidate that
#   runs `--version` hosts the probe. A candidate that exists but never
#   executes is a launch failure, never identity drift.
#
# - A probe that exits instantly is NOT identity evidence. tmux destroys the
#   window of an exited process and then silently answers raw pane reads for
#   the absent target from the client's ACTIVE window, so an ungated title
#   read can report the control pane's idle `zsh` as the harness's identity.
#   Dead probes keep their pane (`remain-on-exit`), evidence reads are gated
#   on exact window membership, and a probe that never ran fails as a probe
#   launch failure with its own exit status instead of teaching the classifier
#   a phantom identity.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. The portable counterpart in
# tests/fm-tmux-agent-liveness.test.sh pins the classifier logic in CI. Run this
# guard after any harness upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HARNESS_LIVENESS_DRIFT tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-liveness-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness-drift.XXXXXX")
SESSION=drift

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cursor-lib.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Dead probes keep their pane and their exit status instead of letting tmux
# destroy the window, so a probe that never starts is diagnosed from its own
# death rather than from inventory absence.
"$REAL_TMUX" -L "$SOCKET" set-window-option -g remain-on-exit on \
  || fail "could not arm dead-probe diagnosis"

# Every executable PATH match for <harness>, in PATH order, one per line.
# Resolution must not stop at the first match: a stale wrapper earlier in PATH
# can shadow a working install later in it. This mirrors the plain-<harness>
# launch surface fm-spawn resolves through the same PATH, while surviving a
# shadowed entry instead of probing a binary that never runs.
# cursor is the deliberate exception: it resolves ONLY through the verified
# owner fm-spawn uses (install_roots below), never through a PATH match. The
# Cursor agent never installs as `cursor`: it installs as `cursor-agent` plus
# the legacy alias `agent`. A machine that also has the Cursor editor does have
# an executable `cursor` on PATH, and launching that one exits immediately,
# leaving a bare shell in the pane that this guard then reports as liveness
# drift the classifier can do nothing about.
path_matches() {  # <harness> -> executable matches, one per line, PATH order
  local harness=$1 dir cand
  [ "$harness" != cursor ] || return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    cand=$dir/$harness
    [ -f "$cand" ] && [ -x "$cand" ] && printf '%s\n' "$cand"
  done < <(LC_ALL=C printf '%s\n' "$PATH" | tr ':' '\n' | awk '!seen[$0]++')
}

# Install roots that can carry a working candidate when every PATH match is
# broken or absent, mirroring the per-harness fallbacks a real launch uses
# where one exists. Kimi's home install is bin/fm-spawn.sh's own fallback, and
# cursor resolves through the same verified owner fm-spawn uses, so this guard
# covers the same binaries firstmate would actually launch. The codex row is
# the macOS ChatGPT-app bundle, which ships the codex CLI with no PATH symlink
# of its own (verified 2026-09-02: codex-cli 0.152.0 classifies alive from that
# path while a dead cmux-cli temp shim shadowed the name `codex` in PATH).
install_roots() {  # <harness> -> extra candidate paths, one per line
  local harness=$1
  case "$harness" in
    kimi)
      [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ] && printf '%s\n' "$HOME/.kimi-code/bin/kimi"
      ;;
    codex)
      [ -x /Applications/ChatGPT.app/Contents/Resources/codex ] \
        && printf '%s\n' /Applications/ChatGPT.app/Contents/Resources/codex
      ;;
    cursor)
      fm_cursor_resolve_binary 2>/dev/null || true
      ;;
  esac
  return 0
}

# A candidate hosts a liveness probe only if it executes: `--version` must
# exit 0 with a non-empty first line. This is the same read the guard already
# uses for its version label, promoted to the pre-flight that decides whether
# a match is a live harness at all. A candidate that fails it is recorded and
# passed over, never probed and never diagnosed as identity drift.
usable_candidate() {  # <bin> -> status 0 when the binary runs
  local out rc
  out=$("$1" --version 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$(printf '%s\n' "$out" | head -1 | tr -d '[:space:]')" ]
}

# Exact-window membership in this lab's inventory, the same precondition the
# tmux backend's classifier enforces before trusting any pane read: tmux
# answers a read for an absent window from the client's active window instead
# of failing, so ungated evidence can describe a completely different pane.
window_exists() {  # <window>
  tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -Fqx "$1"
}

pane_dead() {  # <target> -> 1 when the pane's process has exited, else 0 or empty
  tmux display-message -p -t "$1" '#{pane_dead}' 2>/dev/null
}

CHECKED=0
SKIPPED=

# The verified adapters, in the order the harness-adapters skill router records
# them. An adapter that gains a verified launch path belongs here too.
# muse matters most of all here: its launcher execs a VERSION-SUFFIXED binary,
# so the live process name changes on every auto-update and its install path
# carries no `muse` component to fall back on. That is precisely the drift this
# guard exists to catch, and only a real muse release can produce it.
# cursor matters for the same reason muse does, from the other direction: it
# runs as a bundled node script, so its pane title is a bare `node` that no name
# pattern can own, and identity has to come from its install path or argv[0].
for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  candidates=$(path_matches "$harness"; install_roots "$harness")
  if [ -z "$(printf '%s' "$candidates")" ]; then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its classification is unverified here"
    continue
  fi

  bin_path='' rejected=''
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if usable_candidate "$cand"; then bin_path=$cand; break; fi
    rejected="$rejected $cand"
  done <<EOF
$candidates
EOF

  if [ -z "$bin_path" ]; then
    SKIPPED="$SKIPPED $harness"
    note "skip: every $harness candidate on this machine fails to execute:$rejected - there is no live $harness process to classify, and a plain-$harness launch here would fail until the install or PATH is fixed"
    continue
  fi
  if [ -n "$rejected" ]; then
    note "$harness: passed over non-executing candidate(s):$rejected - probing $bin_path instead. firstmate launches the first PATH match, so fix PATH before relying on $harness launches in this environment"
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  # cursor blocks on a workspace-trust prompt in a directory it has never seen,
  # which would hang this probe rather than classify anything; --trust is the
  # same flag fm-spawn passes for the same reason.
  launch_args=""
  [ "$harness" = cursor ] && launch_args="--trust"
  # shellcheck disable=SC2086  # deliberate: an empty value must add no argument
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" $launch_args \
    || fail "$harness ($version): could not launch a window for the liveness probe"

  state=
  probe_exited=
  for _ in $(seq 1 300); do
    state=$(fm_backend_agent_state tmux "$target")
    [ "$state" = alive ] && break
    # A probe whose window is gone or whose pane died can never classify
    # alive; stop waiting and diagnose the launch instead of burning the full
    # wait budget. pane_dead is read only after window_exists, because a read
    # for an absent window silently describes the active window's pane.
    if ! window_exists "$harness" || [ "$(pane_dead "$target")" = 1 ]; then
      probe_exited=1
      break
    fi
    sleep 0.2
  done

  if [ "$state" != alive ]; then
    # Evidence separation: a probe that never ran must fail as a probe launch
    # failure, because tmux answers raw pane reads for an absent or dead
    # window from the live active window and would attribute the control
    # pane's identity to the harness.
    if [ -n "$probe_exited" ] || ! window_exists "$harness" || [ "$(pane_dead "$target")" = 1 ]; then
      dead_status=
      if window_exists "$harness"; then
        dead_status=$(tmux display-message -p -t "$target" '#{pane_dead_status}' 2>/dev/null)
      fi
      fail "PROBE LAUNCH FAILURE, not identity drift: $harness $version ($bin_path) exited before any identity could be observed${dead_status:+ (exit status $dead_status)}. The '$state' verdict describes an endpoint whose process is gone, which is correct; fix the binary or its environment and rerun this guard."
    fi
    title=$(fm_backend_tmux_current_command "$target")
    comms=$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')
    fail "LIVENESS DRIFT: $harness $version ($bin_path) is running but classifies '$state', not 'alive'. Supervision and lifecycle control treat this endpoint as unattributable. Observed process title '$title'; observed foreground process names [$comms]. Teach bin/fm-agent-process-lib.sh's fm_agent_process_classify_name the identity this release actually reports."
  fi

  title=$(fm_backend_tmux_current_command "$target")
  comms=$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')
  note "$harness $version ($bin_path): title='$title' foreground=[$comms]"

  pass "harness liveness: $harness $version classifies alive"

  # Detection: ask the ancestry walk what it makes of this real harness process.
  # Both Pi identities share one launcher name, so ancestry can only ever prove
  # the family; only the launch-boundary marker selects the signed identity.
  expect_harness=$harness
  [ "$harness" = pi-signed ] && expect_harness=pi
  pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_pid}' 2>/dev/null | tr -d ' ')
  [ -n "$pane_pid" ] || fail "$harness ($version): could not read the pane pid for the detection probe"
  # Probe from BELOW the pane process, not the pane process alone. The shipped
  # guarantee is a strength claim: detect_own hands an args-strength verdict back
  # to a retained foreign marker, so a harness is only protected where the walk
  # reaches it at comm strength. A harness that ships as a thin interpreter shim
  # spawning its native binary as a CHILD is args strength from the pane process
  # and comm strength from below that child - which is where firstmate's own
  # detection actually runs, as a tool subprocess. Probing only the pane would
  # therefore pass on evidence the guarantee does not rest on, and would keep
  # passing if a release stopped spawning the native child at all.
  #
  # The vantage set is the UPWARD path from the deepest foreground descendant, not
  # every descendant in the subtree, because harness_ancestry only ever climbs: a
  # sibling branch is a vantage firstmate's own detection can never occupy.
  # Restricting the deepest descendant to the pane tty's foreground process group
  # keeps a process left running in the background out of the selection as well.
  #
  # The reject-other-harness cross-check below judges COMM-strength vantages only.
  # An args-strength verdict is path-ambiguous by construction: harness_ancestry's
  # bare-interpreter branch matches a harness name anywhere in the script path, so a
  # harness-spawned MCP server running as `node <home>/.claude/mcp/<server>.js`
  # answers `args claude` purely from the .claude path component, and such a server
  # is normally a child of the agent binary rather than a sibling of it, so it can
  # be the deepest descendant and sit ON this path. That ambiguity is the sole source
  # of the false failure; a comm-strength verdict carries the real process name and
  # cannot be produced that way. The comm-strength REQUIREMENT is unchanged - some
  # vantage on the path must still name the expected harness at comm strength,
  # because detect_own hands an args-strength verdict straight back to a retained
  # foreign marker.
  # The native binary can take a moment to appear, so poll for it.
  pane_tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_tty}' 2>/dev/null | tr -d ' ')
  verdicts=
  for _ in $(seq 1 150); do
    fg_pids=
    if [ -n "$pane_tty" ]; then
      fg_pids=$(LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null \
        | while read -r fg_pid fg_pgid fg_tpgid; do
            [ -n "$fg_pid" ] || continue
            [ "$fg_pgid" = "$fg_tpgid" ] || continue
            printf '%s ' "$fg_pid"
          done)
    fi
    # shellcheck disable=SC2086  # deliberate: the foreground pids are separate arguments
    verdicts=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" $fg_pids 2>/dev/null || true)
    case "$verdicts" in *"comm $expect_harness"*) break ;; esac
    sleep 0.2
  done

  drift_context="Observed process title '$title'; observed foreground process names [$comms]; observed ancestry verdicts [$(printf '%s' "$verdicts" | tr '\n' ';')]."

  [ -n "$verdicts" ] || fail \
    "DETECTION DRIFT: $harness $version is running but the ancestry walk reports nothing from the pane process or any vantage below it, so firstmate cannot identify this session at all. $drift_context Teach bin/fm-harness.sh's harness_ancestry the name this release actually reports."

  SAW_COMM=0
  while read -r strength named; do
    [ -n "$strength" ] || continue
    [ "$strength" = comm ] || continue
    [ "$named" = "$expect_harness" ] || fail \
      "DETECTION DRIFT: $harness $version is running but a comm-strength vantage point on the upward path through its own session resolves to '$named', not '$expect_harness'. bin/fm-harness.sh lets a structural ancestor outrank an environment marker, so an unmatched process name can resolve to a DIFFERENT harness further up the tree instead of merely losing a fast path. $drift_context Teach bin/fm-harness.sh's harness_ancestry the name this release actually reports."
    SAW_COMM=1
  done <<EOF
$verdicts
EOF

  [ "$SAW_COMM" = 1 ] || fail \
    "DETECTION DRIFT: $harness $version is identified only at interpreter-args strength, from no vantage point on the upward path through its session at comm strength. detect_own hands an args-strength verdict back to a retained foreign marker, so a stale CLAUDECODE would silently rename this session even though this guard sees the right identity. $drift_context Restore a process name bin/fm-harness.sh's harness_ancestry can match structurally, or teach it the name this release reports."

  note "$harness $version: ancestry verdicts=[$(printf '%s' "$verdicts" | tr '\n' ';')]"
  pass "harness detection: $harness $version is identified by the ancestry walk at comm strength"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
