#!/usr/bin/env bash
# tests/fm-classify-decision-key.test.sh - decision-key position tolerance in
# the open-decisions fold (bin/fm-classify-lib.sh). A "[key=<slug>]" token is
# documented between the verb and the colon (needs-decision [key=x]: note), but
# workers commonly write the colon first (needs-decision: [key=x] note); that
# stated key must be honored, never silently folded into the shared "default"
# bucket where an answer can close the wrong record (issue #2109). Also covers
# status_line_verb's bracket-tag stripping: a remote secondmate reply prepends
# a "[corr=...]" correlation tag before (or without) "[key=...]", and every
# such tag before the colon must be stripped so the leading word is the bare
# verb, regardless of order or count. These tests drive the REAL
# status_line_verb / status_open_decisions / status_open_decisions_incremental
# functions over crafted status files and assert their folded output, never the
# fold's own source text. Also covers status_key_closing_verb, which reports how
# the status side currently reads one key so a consumer can tell a settled key
# from one handed to a durable captain-held task (bin/fm-captain-hold.sh
# diverged). Cross-drain cursor persistence and the incremental
# cost bound live in tests/fm-wake-drain-open-decisions-cursor.test.sh; the
# drain wiring lives in tests/fm-wake-drain-open-decisions.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-decision-key-tests)

# Fresh per-case dir so each case's incremental cursor sidecar cannot leak into
# another case.
case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Assert the whole-file fold of <status-file> equals <expected>, and that the
# incremental fold agrees with it on the exact same input - the two consumption
# strategies must never diverge on what is open.
assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

test_stated_key_is_honored_in_both_positions() {
  local dir before after expected
  dir=$(case_dir positions)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/before.status"
  printf 'needs-decision: [key=api-shape] pick REST or RPC\n' > "$dir/after.status"
  expected=$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')

  assert_fold "$dir/before.status" "$expected" "documented before-colon form"
  assert_fold "$dir/after.status" "$expected" "colon-first form"

  # Equivalence is byte-for-byte: both positions yield the same key AND the
  # same note (a consumed note-head token is key metadata, not note text).
  before=$(status_open_decisions "$dir/before.status")
  after=$(status_open_decisions "$dir/after.status")
  [ "$before" = "$after" ] \
    || fail "the two key positions folded to different records: '$before' vs '$after'"
  pass "a stated [key=X] opens X whether it precedes or follows the verb colon"
}

test_bare_keyless_line_still_folds_to_default() {
  local dir
  dir=$(case_dir keyless)
  printf 'needs-decision: which color\n' > "$dir/bare.status"
  assert_fold "$dir/bare.status" "$(printf 'default\tneeds-decision\twhich color\n')" \
    "bare keyless line"

  # And a bare keyless resolution still closes it - the historical
  # one-open-decision-per-task behavior is unchanged.
  printf 'resolved: went with blue\n' >> "$dir/bare.status"
  assert_fold "$dir/bare.status" "" "bare keyless resolution"
  pass "a keyless needs-decision still opens and closes the default key"
}

test_resolution_closes_across_positions() {
  local dir
  dir=$(case_dir cross-close)
  # Opened colon-first, closed in the documented form (what fm-send's
  # --resolve-key writes): the exact failure from issue #2109.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$dir/a.status"
  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$dir/a.status"
  assert_fold "$dir/a.status" "" "documented resolution closing a colon-first open"

  # And the mirror: opened documented, closed colon-first.
  printf 'needs-decision [key=seam-max-bound]: pick the bound\n' > "$dir/b.status"
  printf 'resolved: [key=seam-max-bound] answered: use 4\n' >> "$dir/b.status"
  assert_fold "$dir/b.status" "" "colon-first resolution closing a documented open"
  pass "a resolution closes its decision regardless of either line's key position"
}

test_blocked_is_position_tolerant_like_needs_decision() {
  local dir expected
  dir=$(case_dir blocked)
  expected=$(printf 'creds\tblocked\twaiting on the deploy token\n')
  printf 'blocked [key=creds]: waiting on the deploy token\n' > "$dir/before.status"
  printf 'blocked: [key=creds] waiting on the deploy token\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "$expected" "documented blocked form"
  assert_fold "$dir/after.status" "$expected" "colon-first blocked form"
  pass "blocked [key=X] opens X in both key positions"
}

test_two_colon_form_decisions_stay_distinct() {
  local dir expected
  dir=$(case_dir distinct)
  # The concrete hazard behind the silent collapse: two colon-form decisions on
  # one task used to share the default bucket, so answering one could close the
  # other. They must stay independently open and independently closable.
  printf 'needs-decision: [key=alpha] first question\n' > "$dir/t.status"
  printf 'needs-decision: [key=beta] second question\n' >> "$dir/t.status"
  expected=$(printf 'alpha\tneeds-decision\tfirst question\nbeta\tneeds-decision\tsecond question\n')
  assert_fold "$dir/t.status" "$expected" "two colon-form decisions"

  printf 'resolved [key=alpha]: answered: yes\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "$(printf 'beta\tneeds-decision\tsecond question\n')" \
    "closing one of two colon-form decisions"
  pass "two colon-form keyed decisions never collapse into one shared bucket"
}

test_mid_note_prose_mention_is_not_a_stated_key() {
  local dir
  dir=$(case_dir prose)
  # Only a token at the head of the note states a key; a summary merely
  # mentioning "[key=x]" deeper in must neither open nor close that key.
  printf 'needs-decision: pick a [key=red] or [key=blue] theme\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\n')" \
    "mid-note prose mention"

  printf 'needs-decision [key=red]: which shade\n' >> "$dir/t.status"
  printf 'working: still thinking about [key=red] here\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\nred\tneeds-decision\twhich shade\n')" \
    "prose mention leaves the open set untouched"
  pass "a [key=x] mentioned mid-note is prose, never an opened or closed key"
}

test_malformed_stated_key_never_collapses_to_default() {
  local dir
  dir=$(case_dir malformed)
  # A stated-but-invalid slug is rejected in BOTH positions - identically,
  # and never rewritten into the shared default bucket.
  printf 'needs-decision [key=bad key]: before-colon malformed\n' > "$dir/before.status"
  printf 'needs-decision: [key=bad key] colon-first malformed\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "" "malformed before-colon key"
  assert_fold "$dir/after.status" "" "malformed colon-first key"
  pass "a malformed stated key is rejected in both positions, never folded as default"
}

# A remote secondmate reply routinely prepends a "[corr=<hex>]" correlation
# tag ahead of "[key=...]" (issue: a remote reply's "needs-decision
# [corr=d448ea86afa4bf67] [key=x]: ..." folded to no open decision at all,
# because the verb parser only stripped a leading "[key=...]" token and left
# the corr tag glued onto the returned verb word). These cases drive the real
# status_line_verb directly, over every bracket-tag shape that precedes the
# colon, to pin the general fix: strip EVERY "[name=value]" tag there, not
# just "[key=...]", regardless of order or count.
test_status_line_verb_strips_every_bracket_tag_before_colon() {
  local v

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-then-key tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [key=loan-installment-cadence-amount] [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "key-then-corr tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-only tag: got '$v'"

  v=$(status_line_verb 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token')
  [ "$v" = "blocked" ] || fail "blocked with corr+key: got '$v'"

  v=$(status_line_verb 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated')
  [ "$v" = "resolved" ] || fail "resolved with corr+key: got '$v'"

  pass "status_line_verb strips every bracket tag before the colon, in any order, and recovers the bare verb"
}

test_corr_and_key_tags_open_and_close_under_the_stated_key() {
  local dir expected
  dir=$(case_dir corr-and-key)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$dir/t.status"
  expected=$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')
  assert_fold "$dir/t.status" "$expected" "corr-then-key opens under the stated key"

  printf 'resolved [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: answered: monthly\n' \
    >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "corr-then-key resolution closes the same stated key"
  pass "a [corr=...] tag ahead of [key=...] no longer swallows the verb: opens and closes under the stated key"
}

test_corr_only_tag_opens_as_default_like_a_bare_line() {
  local dir bare corred
  dir=$(case_dir corr-only)
  printf 'needs-decision: which vendor\n' > "$dir/bare.status"
  printf 'needs-decision [corr=d448ea86afa4bf67]: which vendor\n' > "$dir/corred.status"

  bare=$(status_open_decisions "$dir/bare.status")
  corred=$(status_open_decisions "$dir/corred.status")
  [ "$corred" = "$bare" ] \
    || fail "a corr-only tag folded differently than the bare line: '$corred' vs '$bare'"
  assert_fold "$dir/corred.status" "$(printf 'default\tneeds-decision\twhich vendor\n')" "corr-only tag"
  pass "a [corr=...] tag with no stated key opens under 'default', exactly like a bare needs-decision line"
}

test_key_only_before_colon_still_opens_no_regression() {
  local dir
  dir=$(case_dir key-only-no-corr)
  printf 'needs-decision [key=loan-installment-cadence-amount]: pick the cadence\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')" \
    "key-only before colon, no corr tag"
  pass "a [key=x] tag alone (no corr tag) still opens x - no regression from the tag-stripping fix"
}

test_blocked_and_resolved_are_tag_order_independent() {
  local dir
  dir=$(case_dir blocked-tag-order)
  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/a.status"
  assert_fold "$dir/a.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked corr-then-key"

  printf 'blocked [key=creds] [corr=aaaa1111bbbb2222]: waiting on the deploy token\n' > "$dir/b.status"
  assert_fold "$dir/b.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked key-then-corr"

  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/c.status"
  printf 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated\n' >> "$dir/c.status"
  assert_fold "$dir/c.status" "" "blocked/resolved corr+key close together regardless of tag order"
  pass "blocked/resolved parse their bare verb with any bracket-tag order preceding the colon"
}

test_incremental_agrees_with_full_fold_across_appends() {
  local dir f expected
  dir=$(case_dir incremental)
  f="$dir/t.status"
  # assert_fold already pins incremental==full per snapshot; this case pins the
  # agreement ACROSS appends, where the incremental path folds only the new
  # bytes on top of its persisted open set while the full fold re-reads
  # everything from scratch.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\n')
  assert_fold "$f" "$expected" "colon-first open, first read"

  printf 'working: routine progress note\n' >> "$f"
  printf 'needs-decision: [key=other] a second colon-form question\n' >> "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\nother\tneeds-decision\ta second colon-form question\n')
  assert_fold "$f" "$expected" "colon-first opens buried under later appends"

  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$f"
  printf 'resolved: [key=other] cleared on its own\n' >> "$f"
  assert_fold "$f" "" "cross-position resolutions close both"
  pass "the incremental fold matches the full fold across appends in both key positions"
}

test_stated_key_is_honored_in_both_positions
test_bare_keyless_line_still_folds_to_default
test_resolution_closes_across_positions
test_blocked_is_position_tolerant_like_needs_decision
test_two_colon_form_decisions_stay_distinct
test_mid_note_prose_mention_is_not_a_stated_key
test_malformed_stated_key_never_collapses_to_default
test_status_line_verb_strips_every_bracket_tag_before_colon
test_corr_and_key_tags_open_and_close_under_the_stated_key
test_corr_only_tag_opens_as_default_like_a_bare_line
test_key_only_before_colon_still_opens_no_regression
test_blocked_and_resolved_are_tag_order_independent
test_incremental_agrees_with_full_fold_across_appends

# status_key_closing_verb reports HOW the status side currently reads one key,
# which is what lets a consumer tell a settled key from a key handed to a
# durable captain-held task. The two closing verbs must stay distinguishable:
# `resolved` claims the question is settled outright, while `captain-held` is
# the verified transfer to that task, so treating them alike would either lose
# the record-divergence signal or invent one on every correct transfer.
test_closing_verb_separates_resolution_from_durable_transfer() {
  local dir f
  dir=$(case_dir closing-verb)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
working: started
needs-decision [key=route]: north or south
resolved [key=route]: answered: north
needs-decision [key=access]: open or restricted
captain-held [key=access]: tracked by sample-access-call
blocked [key=creds]: need the deploy token
done: everything else shipped
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a resolved key did not report the resolve verb: '$(status_key_closing_verb "$f" route)'"
  [ "$(status_key_closing_verb "$f" access)" = captain-held ] \
    || fail "a durable-transfer close reported the wrong verb: '$(status_key_closing_verb "$f" access)'"
  [ "$(status_key_closing_verb "$f" creds)" = blocked ] \
    || fail "a still-open key must report its opening verb: '$(status_key_closing_verb "$f" creds)'"
  [ -z "$(status_key_closing_verb "$f" never-mentioned)" ] \
    || fail "a key with no transition line reported a verb"
  [ -z "$(status_key_closing_verb "$dir/absent.status" route)" ] \
    || fail "an absent status file reported a verb"
  pass "status_key_closing_verb separates resolution, durable transfer, and still-open"
}

# The reported verb is the LAST transition, read through the same fold rule as
# everything else: the colon-first key position counts, a re-opened key reports
# open again, and a prose mention is never a transition.
test_closing_verb_tracks_the_last_transition_in_both_positions() {
  local dir f
  dir=$(case_dir closing-verb-last)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
needs-decision: [key=route] colon-first open
resolved: [key=route] colon-first close
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a colon-first resolution was not seen: '$(status_key_closing_verb "$f" route)'"

  printf 'needs-decision [key=route]: re-opened after a bad answer\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = needs-decision ] \
    || fail "a re-opened key still reported closed: '$(status_key_closing_verb "$f" route)'"

  printf 'resolved [key=route]: answered: south after all\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "the last of several transitions was not reported: '$(status_key_closing_verb "$f" route)'"

  printf 'working: a later append that only mentions [key=route] as prose\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a prose mention changed the reported verb: '$(status_key_closing_verb "$f" route)'"
  pass "status_key_closing_verb reports the last real transition, in either key position"
}

test_closing_verb_separates_resolution_from_durable_transfer
test_closing_verb_tracks_the_last_transition_in_both_positions

# last_state_status_line reports the log's EFFECTIVE state line: keyed decision
# verbs are never state, so a `resolved`/`captain-held` answer landing after a
# real report must not become the line every state reader sees (the wedge-alarm
# fix's core predicate - a done-then-resolved task read its leftover pane as
# non-terminal and rode the wedge ladder), and a still-open needs-decision or
# blocked wait DOES report itself as the live state rather than an older report.
test_last_state_status_line_skips_decision_verbs_not_state() {
  local dir f
  dir=$(case_dir effective-line)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
working: implemented the fix
needs-decision [key=ship-now]: merge or hold
resolved [key=ship-now]: answered: merge
done: local-ready on fm/branch
EOF
  [ "$(last_state_status_line "$f")" = "done: local-ready on fm/branch" ] \
    || fail "last state line was not the report: '$(last_state_status_line "$f")'"

  # The answered decision sits under the report too - the walk must pass it.
  printf 'resolved [key=cleanup]: answered: teardown done\n' >> "$f"
  [ "$(last_state_status_line "$f")" = "done: local-ready on fm/branch" ] \
    || fail "a trailing resolution masked the report: '$(last_state_status_line "$f")'"

  # A captain-held close is just as much a decision verb.
  printf 'captain-held [key=hold-2]: tracked by sample-call\n' >> "$f"
  [ "$(last_state_status_line "$f")" = "done: local-ready on fm/branch" ] \
    || fail "a trailing captain-held masked the report: '$(last_state_status_line "$f")'"
  pass "last_state_status_line reports the newest state line under keyed decision verbs"
}

test_last_state_status_line_reports_open_waits_as_state() {
  local dir f
  dir=$(case_dir open-wait)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
done: first pass shipped
needs-decision [key=second-pass]: proceed or stop
EOF
  [ "$(last_state_status_line "$f")" = "needs-decision [key=second-pass]: proceed or stop" ] \
    || fail "an open decision did not report itself as state: '$(last_state_status_line "$f")'"

  # Keyless asks fold to the default bucket and still report as state.
  printf 'needs-decision: what about the docs\n' >> "$f"
  [ "$(last_state_status_line "$f")" = "needs-decision: what about the docs" ] \
    || fail "a keyless open ask did not report as state: '$(last_state_status_line "$f")'"

  # Blocked is the same kind of live wait.
  printf 'blocked [key=creds]: need a token\n' >> "$f"
  [ "$(last_state_status_line "$f")" = "blocked [key=creds]: need a token" ] \
    || fail "an open blocked wait did not report as state: '$(last_state_status_line "$f")'"
  pass "last_state_status_line reports still-open waits as the live state"
}

# status_current_line is the crew-state consumer of the same effective line: its
# nothing-open fallback must walk PAST an arbitrary run of trailing
# decision-closing verbs, not just the prev+latest window the tail scan emits.
# Two closing verbs after a report filled that window and re-masked the report -
# the exact defect the fallback exists to kill.
test_status_current_line_walks_past_trailing_closing_verbs() {
  local dir f
  dir=$(case_dir current-line-walk)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
needs-decision [key=a]: first call
needs-decision [key=b]: second call
done: local-ready on fm/branch
captain-held [key=a]: tracked by sample-call
resolved [key=b]: answered: merge
EOF
  [ "$(status_current_line "$f" ship)" = "done: local-ready on fm/branch" ] \
    || fail "two trailing closing verbs masked the state report: '$(status_current_line "$f" ship)'"

  # A longer run of closers walks just as far back.
  printf 'resolved [key=c]: answered: teardown\n' >> "$f"
  [ "$(status_current_line "$f" ship)" = "done: local-ready on fm/branch" ] \
    || fail "three trailing closing verbs masked the state report: '$(status_current_line "$f" ship)'"

  # A still-open ask under a trailing resolution still reports itself.
  cat > "$f" <<'EOF'
done: first pass shipped
needs-decision [key=second]: proceed or stop
resolved [key=older]: answered: yes
EOF
  [ "$(status_current_line "$f" ship)" = "needs-decision [key=second]: proceed or stop" ] \
    || fail "an open wait under a trailing resolution did not report itself: '$(status_current_line "$f" ship)'"
  pass "status_current_line walks past any run of trailing decision-closing verbs"
}

test_last_state_status_line_plain_and_empty_inputs() {
  local dir f
  dir=$(case_dir plain)
  f="$dir/a.status"
  printf 'working: mid run\n' > "$f"
  printf 'paused: waiting on CI until 18:00\n' >> "$f"
  [ "$(last_state_status_line "$f")" = "paused: waiting on CI until 18:00" ] \
    || fail "a plain paused line was not reported: '$(last_state_status_line "$f")'"

  # Blank and absent inputs report nothing, never an error line.
  : > "$dir/empty.status"
  [ -z "$(last_state_status_line "$dir/empty.status")" ] \
    || fail "an empty file reported a state line"
  [ -z "$(last_state_status_line "$dir/absent.status")" ] \
    || fail "an absent file reported a state line"

  # A file holding only decision verbs has no state line to report.
  printf 'resolved [key=x]: answered: yes\n' > "$dir/only-resolved.status"
  [ -z "$(last_state_status_line "$dir/only-resolved.status")" ] \
    || fail "a decision-only file reported a state line: '$(last_state_status_line "$dir/only-resolved.status")'"
  pass "last_state_status_line handles plain lines, empty files, and decision-only logs"
}

# crew_status_is_finished is the watcher's finished-pane gate: done/failed under
# any closed keyed verbs, never a wait, pause, or blank.
test_crew_status_is_finished_matches_reports_only() {
  local dir f
  dir=$(case_dir finished)
  f="$dir/done-resolved.status"
  cat > "$f" <<'EOF'
working: implemented the fix
done: local-ready on fm/branch
resolved [key=ship-now]: answered: merge
EOF
  crew_status_is_finished "$f" \
    || fail "done under a resolved answer did not read finished"
  [ "$(last_state_status_line "$f")" = "done: local-ready on fm/branch" ] \
    || fail "the finished gate did not agree with the effective-line walk"

  printf 'failed: tests red on fm/branch\n' > "$f"
  printf 'resolved [key=retry]: answered: later\n' >> "$f"
  crew_status_is_finished "$f" \
    || fail "failed under a resolved answer did not read finished"

  printf 'working: resumed after all\n' >> "$f"
  if crew_status_is_finished "$f"; then
    fail "a resumed working line still read finished"
  fi

  printf 'paused: waiting on a human reply\n' > "$dir/paused.status"
  if crew_status_is_finished "$dir/paused.status"; then
    fail "a declared pause read finished"
  fi

  printf 'needs-decision [key=open]: still waiting\n' > "$dir/waiting.status"
  if crew_status_is_finished "$dir/waiting.status"; then
    fail "an open decision read finished"
  fi

  if crew_status_is_finished "$dir/absent.status"; then
    fail "an absent status file read finished"
  fi
  pass "crew_status_is_finished matches done and failed reports only"
}

# A torn final append - a decision ask written without its closing newline - is
# still the log's newest line: the fold's read loop honors it, and the walk must
# agree instead of dropping it and reporting the finish underneath, which would
# put an interrupted ask on the watcher's finished cadence instead of surfacing
# its wait.
test_last_state_status_line_honors_a_torn_final_line() {
  local dir f expected_open
  dir=$(case_dir torn-final)
  f="$dir/a.status"
  printf 'working: mid run\ndone: local-ready on fm/branch\nneeds-decision [key=open-q]: please answer' > "$f"
  expected_open=$(printf 'open-q\tneeds-decision\tplease answer\n')
  [ "$(status_open_decisions "$f")" = "$expected_open" ] \
    || fail "the fold dropped a torn final ask: '$(status_open_decisions "$f")'"
  [ "$(last_state_status_line "$f")" = "needs-decision [key=open-q]: please answer" ] \
    || fail "the walk dropped a torn final ask: '$(last_state_status_line "$f")'"
  if crew_status_is_finished "$f"; then
    fail "a torn open ask over a done report read finished"
  fi
  pass "a torn final line is honored exactly like the fold honors it"
}

# A reserved-key line whose note does not speak the namespace vocabulary folds
# as ordinary status (the ownership rule _fm_decision_key_transition_allowed
# states), so the walk must report it as state too instead of skipping it as a
# closed decision and exposing an older report underneath.
test_last_state_status_line_reports_reserved_key_lines_as_state() {
  local dir f
  dir=$(case_dir reserved-impostor)
  f="$dir/a.status"
  printf 'working: mid run\ndone: local-ready on fm/branch\nneeds-decision [key=pending-reply-abc]: hand-written ask' > "$f"
  [ -z "$(status_open_decisions "$f")" ] \
    || fail "an impostor reserved-key ask opened a decision: '$(status_open_decisions "$f")'"
  [ "$(last_state_status_line "$f")" = "needs-decision [key=pending-reply-abc]: hand-written ask" ] \
    || fail "a reserved-key ask without the owner vocabulary was skipped: '$(last_state_status_line "$f")'"
  if crew_status_is_finished "$f"; then
    fail "a reserved-key impostor ask over a done report read finished"
  fi
  pass "a reserved-key line without the owner vocabulary reports as ordinary state"
}

test_last_state_status_line_skips_decision_verbs_not_state
test_last_state_status_line_reports_open_waits_as_state
test_status_current_line_walks_past_trailing_closing_verbs
test_last_state_status_line_plain_and_empty_inputs
test_crew_status_is_finished_matches_reports_only
test_last_state_status_line_honors_a_torn_final_line
test_last_state_status_line_reports_reserved_key_lines_as_state

# The per-key read pre-selects candidate lines by their leading verb before the
# bash fold sees them, and the resolve/durable-transfer verbs are overridable, so
# an overridden verb buried behind unrelated history must still close its key.
test_closing_verb_honors_overridden_transition_verbs() {
  local dir f i
  dir=$(case_dir closing-verb-overrides)
  f="$dir/task.status"
  printf 'kind=ship\n' > "$dir/task.meta"
  printf 'blocked [key=route]: waiting\n' > "$f"
  for ((i = 0; i < 200; i++)); do
    printf 'note: routine reply\nworking: still going\nContinuation prose here.\n' >> "$f"
  done
  printf 'answered [key=route]: settled\n' >> "$f"
  [ "$(FM_CLASSIFY_RESOLVE_VERB=answered status_key_closing_verb "$f" route)" = answered ] \
    || fail "an overridden resolve verb stopped closing its key"
  [ "$(status_key_closing_verb "$f" route)" = blocked ] \
    || fail "without the override the same line must leave the key open"
  printf 'blocked [key=access]: waiting\nawaiting-captain [key=access]: handed off\n' >> "$f"
  [ "$(FM_CLASSIFY_CAPTAIN_HELD_VERB=awaiting-captain status_key_closing_verb "$f" access)" = awaiting-captain ] \
    || fail "an overridden durable-transfer verb stopped closing its key"
  pass "overridden resolve and durable-transfer verbs still close keys behind unrelated history"
}

test_closing_verb_filters_unrelated_history_without_subshell_growth() {
  local dir f want tag size i level small large
  dir=$(case_dir closing-verb-processes)
  f="$dir/task.status"
  printf 'kind=secondmate\n' > "$dir/task.meta"
  for want in route default; do
    tag="[key=$want]"
    [ "$want" != default ] || tag=''
    for size in 1 1000; do
      printf 'blocked corr=0123456789abcdef %s: waiting\n' "$tag" > "$f"
      for ((i = 0; i < size; i++)); do
        printf 'note: routine reply\nworking: mentions [key=%s] in prose\ndone: another task finished\nfailed: unrelated work\nPR ready https://example.com/pull/1\n\n' "$want" >> "$f"
        if [ "$want" != default ]; then
          printf 'blocked [key=other]: another question\nresolved [key=other]: answered\n' >> "$f"
        fi
      done
      printf 'resolved corr=0123456789abcdef: %s answered\nnote: cleanup complete\n' "$tag" >> "$f"
      : > "$dir/children-$size"
      (
        level=$BASH_SUBSHELL
        set -T
        trap 'if [ "$BASH_SUBSHELL" -gt "$level" ]; then printf x >> "$dir/children-$size"; fi' DEBUG
        status_key_closing_verb "$f" "$want" > "$dir/output"
      )
      [ "$(cat "$dir/output")" = resolved ] || fail "$want lost its resolution behind unrelated history"
    done
    small=$(wc -c < "$dir/children-1")
    large=$(wc -c < "$dir/children-1000")
    [ "$large" -le "$((small + 20))" ] || fail "$want launches subprocess work for unrelated history ($small -> $large)"
  done
  pass "per-key reads retain resolutions without subprocess work growing with unrelated history"
}

test_closing_verb_filter_preserves_terminal_chronology() {
  local dir f kind want tag terminal expected
  dir=$(case_dir closing-verb-terminals)
  f="$dir/task.status"
  for kind in ship scout secondmate; do
    printf 'kind=%s\n' "$kind" > "$dir/task.meta"
    for want in access default; do
      tag="[key=$want]"
      [ "$want" != default ] || tag=''
      for terminal in 'done' failed; do
        printf 'blocked %s: waiting\n' "$tag" > "$f"
        case "$terminal" in
          done) printf 'done: report saved\n' >> "$f" ;;
          failed) printf 'failed corr=0123456789abcdef [key=other]: task failed\n' >> "$f" ;;
        esac
        printf 'note: cleanup complete\n' >> "$f"
        expected=$terminal
        [ "$kind" != secondmate ] || expected=blocked
        [ "$(status_key_closing_verb "$f" "$want")" = "$expected" ] || fail "$kind/$want lost $terminal chronology"
        printf 'needs-decision: [key=%s] reopened\nnote: more cleanup\n' "$want" >> "$f"
        [ "$(status_key_closing_verb "$f" "$want")" = needs-decision ] || fail "$kind/$want lost a post-terminal reopening"
      done
    done
  done
  pass "per-key filtering retains ship/scout terminals, reopenings, and secondmate blockers"
}

test_closing_verb_filters_unrelated_history_without_subshell_growth
test_closing_verb_honors_overridden_transition_verbs
test_closing_verb_filter_preserves_terminal_chronology

test_bare_prose_cannot_impersonate_a_terminal_declaration() {
  local dir f kind word open
  dir=$(case_dir prose-terminal)
  open=$(printf 'route\tneeds-decision\tA or B?\n')
  for kind in ship scout; do
    for word in 'done' failed; do
      f="$dir/$kind-$word.status"
      printf 'kind=%s\n' "$kind" > "$dir/$kind-$word.meta"
      printf 'needs-decision [key=route]: A or B?\npaused: waiting on the vendor\nSteps remaining:\n %s\n' \
        "$word" > "$f"
      assert_fold "$f" "$open" "$kind: bare '$word' prose"
      [ "$(status_key_closing_verb "$f" route)" = needs-decision ] \
        || fail "$kind: bare '$word' prose closed a still-open key"
      f="$dir/$kind-$word-real.status"
      printf 'kind=%s\n' "$kind" > "$dir/$kind-$word-real.meta"
      printf 'needs-decision [key=route]: A or B?\n%s: real outcome\n' "$word" > "$f"
      assert_fold "$f" '' "$kind: genuine $word supersedes"
      [ "$(status_key_closing_verb "$f" route)" = "$word" ] \
        || fail "$kind: genuine $word no longer supersedes the open key"
    done
  done
  pass "prose without a colon cannot impersonate a ship or scout terminal declaration"
}

test_bare_prose_cannot_impersonate_a_terminal_declaration

test_bare_prose_cannot_open_or_close_a_decision() {
  local dir f word blocked
  dir=$(case_dir prose-decision)
  blocked=$(printf 'default\tblocked\tneed release access\n')
  for word in blocked needs-decision resolved; do
    f="$dir/open-$word.status"
    printf 'kind=ship\n' > "$dir/open-$word.meta"
    printf 'working: investigating the deploy\nOptions considered:\n %s\n' "$word" > "$f"
    assert_fold "$f" '' "bare '$word' prose opened a decision"

    f="$dir/close-$word.status"
    printf 'kind=ship\n' > "$dir/close-$word.meta"
    printf 'blocked: need release access\nSteps remaining:\n %s\n' "$word" > "$f"
    assert_fold "$f" "$blocked" "bare '$word' prose moved an open decision"
  done

  f="$dir/keyed-colonless.status"
  printf 'kind=ship\n' > "$dir/keyed-colonless.meta"
  printf 'blocked [key=access]\n' > "$f"
  assert_fold "$f" "$(printf 'access\tblocked\tblocked [key=access]\n')" \
    "a keyed colonless line stopped opening its key"
  printf 'resolved [key=access]\n' >> "$f"
  assert_fold "$f" '' "a keyed colonless line stopped closing its key"

  f="$dir/real-resolution.status"
  printf 'kind=ship\n' > "$dir/real-resolution.meta"
  printf 'blocked: need release access\nresolved: access granted\n' > "$f"
  assert_fold "$f" '' "a genuine resolution stopped closing its decision"
  pass "only a colon-bearing or keyed line is a decision transition in the fold"
}

test_bare_prose_cannot_open_or_close_a_decision
