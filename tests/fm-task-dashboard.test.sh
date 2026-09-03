#!/usr/bin/env bash
# Behavior tests for bin/fm-task-dashboard.sh: classification per dimension,
# manual-override precedence and disclosure, fail-closed config validation,
# deterministic HTML generation, and the rendered page (through the DOM-shim
# harness when node is available). Everything runs against a fabricated home
# through the public commands, never against the script's source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-task-dashboard.sh"
HARNESS="$ROOT/tests/assets/task-dashboard-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-task-dashboard)
PINNED_NOW=2026-09-03T00:00:00Z

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# Fake tmux whose live window list comes from the fixture's state/*.meta rows,
# minus any id listed in state/FAKE_TMUX_DEAD (one per line), so a fixture can
# drive both a live and a dead endpoint for the same backend. The existence
# probe the snapshot uses is display-message -p -t <session>:<window>, so that
# verb succeeds exactly for windows on the live list.
dead=""
if [ -r "${FM_HOME:?}/state/FAKE_TMUX_DEAD" ]; then
  dead=$(tr '\n' '|' < "$FM_HOME/state/FAKE_TMUX_DEAD" | sed 's/|$//')
fi
live_windows() {
  for meta in "$FM_HOME"/state/*.meta; do
    [ -r "$meta" ] || continue
    id=$(basename "$meta" .meta)
    win=$(sed -n 's/^window=//p' "$meta" | head -1)
    [ -n "$win" ] || continue
    if [ -n "$dead" ] && printf '%s' "$id" | grep -Eq "^($dead)$"; then
      continue
    fi
    printf '%s\n' "$win"
  done
}
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  display-message)
    [ -n "$target" ] || exit 1
    live_windows | grep -Fxq "$target" || exit 1
    printf '%%1\n'
    ;;
  list-windows|has-session)
    live_windows
    ;;
  capture-pane)
    printf 'work in progress\n> \n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config"
  make_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1 gen
  mkdir -p "$home/data/done-report"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] ship-live - Ship live battery worker (repo: alpha) (kind: ship) (since 2026-08-01)
  battery-powered subsystem body line the theme rule must find.
- [ ] scout-dead - Scout with a dead endpoint (repo: beta) (kind: scout) (since 2026-08-02)
- [ ] held-other - Held on infra (repo: alpha) (kind: ship) (hold: waiting on infra) (hold-kind: infra) (since 2026-08-03)

## Queued
- [ ] queued-captain - Queued captain call (repo: alpha) (kind: ship) (hold: pick a color) (hold-kind: captain) (since 2026-08-04)
- [ ] queued-blocked - Queued blocked task blocked-by: ship-live - needs the ship first (repo: beta) (kind: ship) (since 2026-08-05)
- [ ] queued-plain - Plain queued work (repo: beta) (kind: chore) (since 2026-08-06)
a free-form note line without canonical syntax

## Done
- [x] done-merged - Merged feature https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
- [x] done-report - Scout report delivered data/done-report/report.md (repo: beta) (kind: scout) (reported 2026-07-20)
EOF
  printf '# Report\n' > "$home/data/done-report/report.md"
  fm_write_meta "$home/state/ship-live.meta" \
    "window=firstmate:fm-ship-live" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: implementing\n' > "$home/state/ship-live.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-live)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-live busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/scout-dead.meta" \
    "window=firstmate:fm-scout-dead" \
    "worktree=$home/projects/scout-worktree" \
    "project=beta" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-dead.status"
  printf '%s\n' scout-dead > "$home/state/FAKE_TMUX_DEAD"
}

write_groups_config() {  # <home>
  cat > "$1/config/dashboard-groups.json" <<'EOF'
{
  "overrides": {
    "queued-plain": { "group": "手动特批组", "note": "队长点名归组" },
    "ghost-task": { "group": "幽灵组" }
  },
  "theme_keywords": [
    { "keyword": "battery", "group": "电池" },
    { "keyword": "scout", "group": "侦察" }
  ]
}
EOF
}

groups_json() {  # <home> <dim> [extra args...]
  local home=$1 dim=$2
  shift 2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    "$DASH" groups "$dim" --json "$@"
}

# --- classification ---------------------------------------------------------

test_status_classification_covers_every_rule() {
  local home out
  home=$(make_home classify)
  write_fixture "$home"
  out=$(groups_json "$home" status)
  printf '%s' "$out" | jq -e '
    [.classification[] | {key: .id, value: .group}] | from_entries as $c
    | $c["ship-live"] == "进行中"
      and $c["scout-dead"] == "在航·无活动端点"
      and $c["held-other"] == "已搁置"
      and $c["queued-captain"] == "等待队长"
      and $c["queued-blocked"] == "排队·被阻塞"
      and $c["queued-plain"] == "排队·就绪"
      and $c["done-merged"] == "已完成"
      and $c["done-report"] == "已完成"
      and $c["free-7"] == "自由文本行"
  ' >/dev/null || fail "status classification wrong: $out"
  printf '%s' "$out" | jq -e '
    [.classification[] | select(.id == "queued-blocked") | .reason][0]
      | contains("ship-live")
  ' >/dev/null || fail "blocked reason must name the unresolved blocker: $out"
  pass "status dimension classifies live, dead, held, captain, blocked, queued, done, free-form"
}

test_repo_kind_and_era_dimensions() {
  local home out
  home=$(make_home dims)
  write_fixture "$home"
  out=$(groups_json "$home" repo)
  printf '%s' "$out" | jq -e '
    [.classification[] | {key: .id, value: .group}] | from_entries as $c
    | $c["ship-live"] == "alpha" and $c["scout-dead"] == "beta"
  ' >/dev/null || fail "repo classification wrong: $out"
  out=$(groups_json "$home" era)
  printf '%s' "$out" | jq -e '
    [.classification[] | {key: .id, value: .group}] | from_entries as $c
    | $c["ship-live"] == "2026-08"
      and $c["queued-plain"] == "2026-08"
      and $c["done-merged"] == "2026-07"
      and $c["done-report"] == "2026-07"
  ' >/dev/null || fail "era classification wrong: $out"
  pass "repo and era dimensions group by record fields and anchor dates"
}

test_theme_keywords_and_first_hit_wins() {
  local home out
  home=$(make_home theme)
  write_fixture "$home"
  write_groups_config "$home"
  out=$(groups_json "$home" theme)
  printf '%s' "$out" | jq -e '
    [.classification[] | {key: .id, value: .group}] | from_entries as $c
    | $c["ship-live"] == "电池"
      and $c["scout-dead"] == "侦察"
      and $c["held-other"] == "其他"
  ' >/dev/null || fail "theme classification wrong: $out"
  printf '%s' "$out" | jq -e '
    [.classification[] | select(.id == "ship-live") | .reason][0] | contains("battery")
  ' >/dev/null || fail "theme reason must name the hit keyword: $out"
  pass "theme dimension matches body text case-insensitively and explains each hit"
}

test_manual_override_beats_auto_in_every_dimension() {
  local home out
  home=$(make_home override)
  write_fixture "$home"
  write_groups_config "$home"
  for dim in repo kind status era theme; do
    out=$(groups_json "$home" "$dim")
    printf '%s' "$out" | jq -e '
      [.classification[] | select(.id == "queued-plain")] == [{
        "id": "queued-plain", "group": "手动特批组", "source": "manual",
        "reason": "手动: 手动特批组 · 队长点名归组"}]
    ' >/dev/null || fail "override must replace the $dim group: $out"
  done
  printf '%s' "$out" | jq -e '.overrides_stale == ["ghost-task"]' >/dev/null \
    || fail "stale override ids must be disclosed, not dropped: $out"
  pass "manual overrides replace every automatic dimension and stale ids are disclosed"
}

test_malformed_config_fails_closed() {
  local home out code
  home=$(make_home badconfig)
  write_fixture "$home"
  for bad in '{"overrides": {"x": {"group": ""}}}' '{"bogus": 1}' 'not json'; do
    printf '%s\n' "$bad" > "$home/config/dashboard-groups.json"
    out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$DASH" render 2>&1)
    code=$?
    [ "$code" -eq 1 ] || fail "malformed config must stop the render (exit $code): $out"
    assert_contains "$out" "$home/config/dashboard-groups.json" \
      "the failing config file must be named in the refusal"
  done
  rm -f "$home/config/dashboard-groups.json"
  pass "malformed grouping configs stop the render with the file named"
}

# --- render -----------------------------------------------------------------

test_render_is_deterministic_and_carries_the_payload() {
  local home extracted
  home=$(make_home render)
  write_fixture "$home"
  PATH="$home/fakebin:$PATH" FM_SNAPSHOT_NOW="$PINNED_NOW" FM_HOME="$home" \
    "$DASH" render >/dev/null || fail "first render failed"
  cp "$home/data/dashboard.html" "$TMP_ROOT/render-a.html"
  PATH="$home/fakebin:$PATH" FM_SNAPSHOT_NOW="$PINNED_NOW" FM_HOME="$home" \
    "$DASH" render >/dev/null || fail "second render failed"
  cp "$home/data/dashboard.html" "$TMP_ROOT/render-b.html"
  cmp -s "$TMP_ROOT/render-a.html" "$TMP_ROOT/render-b.html" \
    || fail "two pinned renders must be byte-identical"
  assert_no_grep "__FM_TASK_DASHBOARD_DATA__" "$home/data/dashboard.html" \
    "the placeholder must be replaced in the published page"
  extracted=$(sed -n '/<script id="task-dashboard-data" type="application\/json">/,/<\/script>/p' \
    "$home/data/dashboard.html" | sed '1d;$d')
  printf '%s\n' "$extracted" | jq -e '.schema == "fm-task-dashboard.v1" and (.tasks | length) == 9' >/dev/null \
    || fail "the page payload must round-trip with all nine cards"
  pass "pinned renders are byte-identical and the page carries a readable payload"
}

test_open_command_opens_the_rendered_page() {
  local home out
  home=$(make_home open-cmd)
  write_fixture "$home"
  mkdir -p "$home/fakebin-open"
  cat > "$home/fakebin-open/open" <<'SH'
#!/usr/bin/env bash
printf 'fake-open:%s\n' "$*"
SH
  chmod +x "$home/fakebin-open/open"
  out=$(PATH="$home/fakebin-open:$home/fakebin:$PATH" FM_SNAPSHOT_NOW="$PINNED_NOW" \
    FM_HOME="$home" "$DASH" open 2>&1) || fail "open command failed: $out"
  assert_contains "$out" "fake-open:$home/data/dashboard.html" \
    "open must hand the rendered page path to the system opener"
  pass "open renders first and hands the page to the system opener"
}

test_rendered_page_groups_and_discloses() {
  local home out
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  home=$(make_home page)
  write_fixture "$home"
  write_groups_config "$home"
  PATH="$home/fakebin:$PATH" FM_SNAPSHOT_NOW="$PINNED_NOW" FM_HOME="$home" \
    "$DASH" render >/dev/null || fail "page render failed"
  out=$(node "$HARNESS" "$home/data/dashboard.html") || fail "the built page did not render: $out"
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null || fail "the page rendered its error state: $out"
  printf '%s' "$out" | jq -e '
    ([.sections[] | select(.name == "手动特批组") | .cards] | length) == 1
      and ([.sections[] | select(.name == "手动特批组") | .count] == ["1 项"])
  ' >/dev/null || fail "the manual group must lead the page with its card: $out"
  printf '%s' "$out" | jq -e '
    [.cards[] | select((.badges | map(.text) | index("手动")) != null) | .title] == ["Plain queued work"]
  ' >/dev/null || fail "only the overridden task carries the manual badge: $out"
  printf '%s' "$out" | jq -e '
    [.cards[] | select(.meta | contains("done-merged"))][0].outputs | join(" ")
      | contains("https://github.com/kunchenguid/firstmate/pull/7")
  ' >/dev/null || fail "the merged card must show its PR link: $out"
  printf '%s' "$out" | jq -e '
    [.cards[] | select(.meta | contains("done-report"))][0].outputs | join(" ")
      | contains("data/done-report/report.md") and contains("✓")
  ' >/dev/null || fail "the report card must show the present report path: $out"
  printf '%s' "$out" | jq -e '
    [.foot[] | select(contains("ghost-task"))] | length == 1
  ' >/dev/null || fail "the page footer must disclose the stale override: $out"
  printf '%s' "$out" | jq -e '
    [.stats[] | select(.label == "任务总数")][0].n == 9
  ' >/dev/null || fail "the stat strip must count all nine cards: $out"
  pass "the rendered page leads with manual groups, badges outputs, and discloses stale overrides"
}

test_empty_home_renders_an_empty_state() {
  local home out
  home=$(make_home empty)
  out=$(PATH="$home/fakebin:$PATH" FM_SNAPSHOT_NOW="$PINNED_NOW" FM_HOME="$home" \
    "$DASH" render 2>&1) || fail "an empty home must still render: $out"
  [ -f "$home/data/dashboard.html" ] || fail "the page must land in data/ for this home"
  if command -v node >/dev/null 2>&1; then
    out=$(node "$HARNESS" "$home/data/dashboard.html") || fail "the empty page did not render: $out"
    printf '%s' "$out" | jq -e '(.empty | length) == 1 and (.empty[0] | contains("暂无任务"))' >/dev/null \
      || fail "the empty page must say there are no tasks: $out"
  fi
  pass "an empty home renders its page with an explicit empty state"
}

test_a_live_pr_url_survives_injection_escaping() {
  local home extracted
  home=$(make_home pr-escape)
  write_fixture "$home"
  PATH="$home/fakebin:$PATH" FM_SNAPSHOT_NOW="$PINNED_NOW" FM_HOME="$home" \
    "$DASH" render >/dev/null || fail "render for the PR escape check failed"
  extracted=$(sed -n '/<script id="task-dashboard-data" type="application\/json">/,/<\/script>/p' \
    "$home/data/dashboard.html" | sed '1d;$d')
  printf '%s' "$extracted" \
    | jq -e '.tasks[] | select(.id == "done-merged") | .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"' >/dev/null \
    || fail "the PR URL must survive injection as data, not markup: $extracted"
  pass "PR URLs ride inside the JSON payload, never as markup"
}

test_status_classification_covers_every_rule
test_repo_kind_and_era_dimensions
test_theme_keywords_and_first_hit_wins
test_manual_override_beats_auto_in_every_dimension
test_malformed_config_fails_closed
test_render_is_deterministic_and_carries_the_payload
test_open_command_opens_the_rendered_page
test_rendered_page_groups_and_discloses
test_empty_home_renders_an_empty_state
test_a_live_pr_url_survives_injection_escaping
