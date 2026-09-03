#!/usr/bin/env bash
# fm-task-dashboard.sh - classify this home's tasks and render the one-page dashboard.
#
# A read-only view OVER bin/fm-fleet-snapshot.sh: this script never parses
# data/backlog.md, state/<id>.meta, or state/<id>.status itself. It projects the
# canonical snapshot (schema fm-fleet-snapshot.v1) down to one dashboard payload
# (schema fm-task-dashboard.v1), applies the local grouping overrides, and
# renders that payload into a single self-contained HTML page with inline
# CSS/JS and no network requests. The page is regenerated wholesale; it keeps
# no state of its own.
#
# Usage:
#   fm-task-dashboard.sh render            build data/dashboard.html (default)
#   fm-task-dashboard.sh open              render, then open the page locally
#   fm-task-dashboard.sh path              print the page path for this home
#   fm-task-dashboard.sh groups [dim]      print the classification (TOON)
#                                          dim: repo|kind|status|era|theme
#                                          (default repo); add --json for the
#                                          same classification as JSON
#
# Classification. Every task carries a group for each dimension plus the
# reason it was placed there, so the rules stay explainable:
#   repo     record's (repo: ...) field, "-" or absent -> "(未标仓库)".
#   kind     record's (kind: ...) field, absent -> "(未标类型)".
#   status   done -> 已完成; in flight with a live endpoint -> 进行中;
#            in flight without a live endpoint -> 在航·无活动端点;
#            held for the captain (hold-kind: captain) -> 等待队长;
#            held otherwise -> 已搁置; queued and captain-actionable ->
#            等待队长; queued with unresolved blockers -> 排队·被阻塞;
#            otherwise -> 排队·就绪. Unstructured backlog rows -> 自由文本行.
#   era      YYYY-MM of the anchor date - the completion date for done rows,
#            otherwise the since date; neither -> 未知时段.
#   theme    first keyword in config/dashboard-groups.json theme_keywords
#            whose keyword (case-insensitively) appears in the title or body;
#            no hit -> 其他. Free-form rows never join keyword groups.
# A manual override in config/dashboard-groups.json replaces the automatic
# group in EVERY dimension: overridden tasks carry group_source "manual" and a
# 手动 badge on the page. Overrides are keyed by task id, so changed rules or
# regeneration never move a saved adjustment. Override ids that no current
# task carries are disclosed as stale instead of silently dropped.
#
# Configuration. docs/configuration.md "Task dashboard groups" owns the schema
# of optional local gitignored config/dashboard-groups.json:
#   { "overrides": { "<task-id>": { "group": "...", "note": "..." } },
#     "theme_keywords": [ { "keyword": "...", "group": "..." } ] }
# An absent file classifies purely automatically. A present file is validated
# fail-closed: unknown keys, non-string groups, or malformed keyword entries
# stop the render with the file named rather than being skipped quietly.
#
# Enrichment beyond the snapshot is deliberately tiny and read-only: the mtime
# of state/<id>.status (when a task id has one) as last_event_at, and existence
# of a declared data/<id>/report.md as report_present. Both are presentation
# facts for the cards; the snapshot stays the only state authority.
#
# Determinism. The rendered page embeds the payload verbatim, and the payload
# embeds the snapshot's own generated timestamp, so pinning FM_SNAPSHOT_NOW
# (plus stable home files) makes two renders byte-identical; tests rely on
# that. FM_TASK_DASHBOARD_TEMPLATE overrides the embedded template (tests
# only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"
CONFIG_FILE="$CONFIG/dashboard-groups.json"
OUT="$DATA/dashboard.html"
PLACEHOLDER='__FM_TASK_DASHBOARD_DATA__'
DASH_SCHEMA=fm-task-dashboard.v1
DIMENSIONS='repo kind status era theme'
TEMPLATE="${FM_TASK_DASHBOARD_TEMPLATE:-}"
TMP_FILES=()

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    if [ -n "$f" ]; then rm -f -- "$f"; fi
  done
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

fail() {
  printf 'fm-task-dashboard: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

new_tmp() {  # <var-name>
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/fm-task-dashboard.XXXXXX") || fail "cannot create a temp file"
  TMP_FILES+=("$f")
  printf -v "$1" '%s' "$f"
}

# --- configuration ----------------------------------------------------------

validate_config() {  # <file>
  jq -e '
    (.overrides // {}) as $ov
    | (.theme_keywords // []) as $kw
    | type == "object"
    and ((keys_unsorted | map(select(. != "overrides" and . != "theme_keywords"))) | length == 0)
    and ($ov | type == "object")
    and ([ $ov | keys[] as $id
           | $ov[$id]
           | type == "object"
             and (.group | (type == "string" and length > 0))
             and ((keys_unsorted | map(select(. != "group" and . != "note"))) | length == 0)
             and ((has("note") | not) or (.note | type == "string")) ] | all)
    and ($kw | type == "array")
    and ([ $kw[]
           | type == "object"
             and (.keyword | (type == "string" and length > 0))
             and (.group | (type == "string" and length > 0))
             and ((keys_unsorted | map(select(. != "keyword" and . != "group"))) | length == 0) ] | all)
  ' "$1" >/dev/null 2>&1
}

load_config_json() {
  if [ ! -f "$CONFIG_FILE" ]; then
    printf '{"overrides":{},"theme_keywords":[]}'
    return 0
  fi
  if [ -L "$CONFIG_FILE" ]; then
    fail "grouping config must be a regular file: $CONFIG_FILE"
  fi
  jq -c . "$CONFIG_FILE" >/dev/null 2>&1 || fail "grouping config is not valid JSON: $CONFIG_FILE"
  validate_config "$CONFIG_FILE" \
    || fail "grouping config does not satisfy its schema (docs/configuration.md): $CONFIG_FILE"
  jq -c '{overrides:(.overrides // {}), theme_keywords:(.theme_keywords // [])}' "$CONFIG_FILE"
}

# --- read-only enrichment ---------------------------------------------------

# One "id<TAB>epoch" line per task id whose state/<id>.status exists.
status_epochs_tsv() {  # <ids...>
  local id f epoch
  for id in "$@"; do
    [ -n "$id" ] || continue
    f="$STATE/$id.status"
    [ -f "$f" ] || continue
    epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || printf '')
    [ -n "$epoch" ] && printf '%s\t%s\n' "$id" "$epoch" || true
  done
}

# One "id<TAB>present" line per declared report path, resolving the snapshot's
# data/-relative report paths against the addressing root that owns data/.
report_presence_tsv() {  # <snapshot-file>
  local root id path
  root="${DATA%/data}"
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] && [ -n "$path" ] || continue
    if [ -f "$root/${path#data/}" ] || [ -f "$root/$path" ]; then
      printf '%s\t1\n' "$id"
    else
      printf '%s\t0\n' "$id"
    fi
  done < <(jq -r '.backlog.records[]
                   | select(.structured and .report_path != null)
                   | "\(.id)\t\(.report_path)"' "$1" 2>/dev/null)
}

tsv_to_object() {  # <value-when-present>
  jq -Rn --arg when "$1" '
    reduce (inputs | select(length > 0) | split("\t")) as [$id, $value]
      ({}; .[$id] = ($value == $when))
  '
}

# --- payload projection -----------------------------------------------------

# The single classification owner: snapshot + config + enrichment -> payload.
# shellcheck disable=SC2016  # jq program: its $cfg/$r/$snap sigils are jq bindings, not shell expansions.
PROJECT_JQ='
  def status_label($key):
    {working:"进行中", waiting_captain:"等待队长", held:"已搁置",
     inflight_stale:"在航·无活动端点", queued_blocked:"排队·被阻塞",
     queued:"排队·就绪", done:"已完成", freeform:"自由文本行"}[$key];
  def status_of($live_ep):
    if .structured == false then {key:"freeform"}
    elif .state == "done" then {key:"done"}
    elif .current_role == "held" and .hold_kind == "captain" then {key:"waiting_captain"}
    elif .current_role == "held" then {key:"held"}
    elif .state == "in_flight" and $live_ep then {key:"working"}
    elif .state == "in_flight" then {key:"inflight_stale"}
    elif .captain_actionable then {key:"waiting_captain"}
    elif ((.unresolved_blocker_ids | length) > 0) then {key:"queued_blocked"}
    else {key:"queued"} end;
  def status_reason($key):
    if $key == "freeform" then "非结构化 backlog 行,不参与自动归类"
    elif $key == "done" then "完成行 (" + ((.completion.verb // "done") + " " + (.completion.date // "")) + ")"
    elif $key == "waiting_captain" then "搁置待队长 (hold-kind: captain)"
    elif $key == "held" then "搁置 (hold-kind: 其他)"
    elif $key == "working" then "在航行 + 活动端点"
    elif $key == "inflight_stale" then "在航行,但无活动端点"
    elif $key == "queued_blocked" then "排队 + 未解除阻塞: " + (.unresolved_blocker_ids | join(" "))
    else "排队就绪" end;
  def era_of:
    if .state == "done" then {date: (.done // .reported // .merged), why: "完成日"}
    else {date: (.since // .done), why: "开始日"} end
    | if .date != null then {group: .date[0:7], reason: .why + " " + .date}
      else {group: "未知时段", reason: "无 since/完成日期"} end;
  def theme_of($cfg):
    ((.title + " " + (.body_excerpt // "")) | ascii_downcase) as $hay
    | ([ $cfg.theme_keywords[]
         | . as $entry
         | ($entry.keyword | ascii_downcase) as $needle
         | select($hay | contains($needle))
         | $entry ][0] // null) as $hit
    | if $hit != null then {group: $hit.group, reason: "关键词命中: " + $hit.keyword + " → " + $hit.group}
      else {group: "其他", reason: "无关键词命中 → 其他"} end;
  . as $snap
  | ($snap.tasks | reduce .[] as $t ({}; .[$t.id] = $t)) as $live
  | ($live | map_values(.endpoint.exists == true)) as $live_ep
  | [ $snap.backlog.records[] | select(.structured) | .id ] as $ids
  | [ $snap.backlog.records[]
      | . as $r
      | ($live[$r.id // ""] // null) as $t
      | ($live_ep[$r.id // ""] // false) as $ep_alive
      | ($r | status_of($ep_alive)) as $st
      | ($r | era_of) as $era
      | (if $r.structured then ($r | theme_of($cfg)) else {group:"自由文本行", reason:"非结构化行"} end) as $theme
      | (if $r.structured then
          {id: $r.id, title: ($r.title // $r.raw), structured: true, state: $r.state,
           status_key: $st.key, status: status_label($st.key),
           kind: ($r.kind // "(未标类型)"),
           repo: (if ($r.repo // null) == null or $r.repo == "-" then "(未标仓库)" else $r.repo end),
           since: $r.since, done: ($r.done // $r.reported // $r.merged // null),
           completion: $r.completion,
           pr_url: ($r.pr_url // (if $t != null then ($t.pr.url // null) else null end) // null),
           report_path: ($r.report_path
                         // (if ($t != null and ($t.paths.report.present // false))
                            then $t.paths.report.path else null end) // null),
           report_present: (if $r.report_path != null then ($reports[$r.id] // false)
                            else ($t != null and ($t.paths.report.present // false)) end),
           links: ($r.links // []),
           body_excerpt: $r.body_excerpt,
           hold: {kind: $r.hold_kind, reason: $r.hold_reason, until: $r.hold_until},
           blocked_by: $r.unresolved_blocker_ids,
           blocked_reason: $r.blocked_reason,
           live: (if $t == null then null else
             {state: $t.current_state.state, detail: $t.current_state.detail,
              backend: $t.backend, harness: $t.harness, mode: $t.mode,
              endpoint_alive: $ep_alive,
              last_event: (if ($t.hints.last_event_text // "") != "" then $t.hints.last_event_text else null end),
              last_event_at: ($epochs[$r.id] // null)} end),
           manual: ($cfg.overrides[$r.id // ""] // null)}
        else
          {id: ("free-" + (($r.order // 0) | tostring)), title: ($r.raw | .[0:160]), structured: false,
           state: $r.state, status_key: "freeform", status: status_label("freeform"),
           kind: "(自由文本)", repo: "(自由文本)", since: null, done: null, completion: null,
           pr_url: null, report_path: null, report_present: false, links: [],
           body_excerpt: null, hold: {kind: null, reason: null, until: null},
           blocked_by: [], blocked_reason: null, live: null, manual: null}
        end)
      | .groups = {repo: .repo, kind: .kind, status: .status, era: $era.group, theme: $theme.group}
      | .reasons = {repo: (if ($r.repo // null) == null or $r.repo == "-"
                          then "未标 repo" else "repo 字段: " + $r.repo end),
                    kind: (if ($r.kind // null) != null then "kind 字段: " + $r.kind else "未标 kind" end),
                    status: ($r | status_reason($st.key)),
                    era: $era.reason, theme: $theme.reason}
      | .group_source = (if .manual != null then "manual" else "auto" end) ]
  | {schema: "fm-task-dashboard.v1",
     home: $snap.fm_home,
     generated: $snap.generated,
     backlog_present: ($snap.backlog.present // false),
     dimensions: ["repo", "kind", "status", "era", "theme"],
     theme_keywords: $cfg.theme_keywords,
     overrides_total: ($cfg.overrides | length),
     overrides_stale: ([ $cfg.overrides | keys[] | select(. as $k | $ids | index($k) | not) ]),
     tasks: .}
'

validate_payload() {  # <payload-file>
  jq -e --arg schema "$DASH_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def https_url: type == "null" or (type == "string" and startswith("https://"));
    def task_item:
      type == "object"
      and (.id | nonempty_string)
      and (.title | nonempty_string)
      and (.structured | type == "boolean")
      and (.state | nonempty_string)
      and (.status_key | nonempty_string)
      and (.status | nonempty_string)
      and (.group_source == "auto" or .group_source == "manual")
      and (.groups | type == "object" and ([.[] | nonempty_string] | all))
      and (.reasons | type == "object" and ([.[] | type == "string"] | all))
      and ((.manual == null) or (.manual | type == "object" and (.group | nonempty_string)))
      and (.pr_url | https_url)
      and ((.report_path == null) or (.report_path | nonempty_string))
      and (.report_present | type == "boolean")
      and (.links | type == "array" and ([.[] | type == "string"] | all))
      and ((.live == null) or (.live | type == "object" and (.endpoint_alive | type == "boolean")))
      and (.blocked_by | type == "array");
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.dimensions | type == "array")
    and (.tasks | type == "array" and ([.[] | task_item] | all))
  ' "$1" >/dev/null
}

payload_to_file() {  # <result-var>
  local dest=$1
  local snap snap_err cfg epochs_tsv epochs_json reports_tsv reports_json payload_file ids
  [ -f "$SNAPSHOT" ] || fail "fleet snapshot helper is missing: $SNAPSHOT"
  new_tmp snap
  new_tmp snap_err
  if ! "$SNAPSHOT" --json > "$snap" 2>"$snap_err"; then
    sed 's/^/fm-fleet-snapshot: /' "$snap_err" >&2 || true
    fail "cannot read the fleet snapshot"
  fi
  cfg=$(load_config_json) || exit 1

  new_tmp epochs_tsv
  ids=$(jq -r '.backlog.records[] | select(.structured) | .id' "$snap")
  # shellcheck disable=SC2086  # task ids are slug-like tokens without spaces
  status_epochs_tsv $ids > "$epochs_tsv" || true
  epochs_json=$(jq -Rn 'reduce (inputs | select(length > 0) | split("\t")) as [$id, $epoch] ({}; .[$id] = ($epoch | tonumber))' < "$epochs_tsv")

  new_tmp reports_tsv
  report_presence_tsv "$snap" > "$reports_tsv"
  reports_json=$(tsv_to_object 1 < "$reports_tsv")

  new_tmp payload_file
  jq --argjson cfg "$cfg" --argjson reports "$reports_json" --argjson epochs "$epochs_json" \
    "$PROJECT_JQ" "$snap" > "$payload_file" \
    || fail "cannot project the snapshot into a dashboard payload"
  validate_payload "$payload_file" || fail "dashboard payload does not satisfy $DASH_SCHEMA"
  printf -v "$dest" '%s' "$payload_file"
}

# --- page template ----------------------------------------------------------

template() {
  [ -n "$TEMPLATE" ] && { cat -- "$TEMPLATE"; return 0; }
  cat <<'FM_TASK_DASHBOARD_TEMPLATE'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Firstmate 任务看板</title>
<style>
/* Firstmate Design System tokens, inlined from the bearings board template.
   No external requests: system font stacks replace the webfont import. */
:root {
  --rust-700: #8f2f17; --rust-600: #a93a1f; --rust-500: #c0452a;
  --rust-100: #f4d8c9; --rust-050: #fbece3;
  --navy-700: #1a2238; --navy-300: #6c7796;
  --gold-600: #b5791c; --gold-500: #e0a52e; --gold-100: #f8ecc9;
  --ocean-600: #2f6688; --ocean-500: #3c7ea6; --ocean-050: #e8f1f5;
  --sea-500: #2f6b4f; --sea-050: #e9f2ec;
  --paper-000: #fbf4e2; --paper-100: #f6ecd3; --paper-200: #f0e3c4; --paper-300: #e7d6ae;
  --cream-line: #ddc89c;
  --ink-900: #241c14; --ink-700: #3f3224; --ink-500: #6f5e46; --ink-300: #9c8a6c;
  --white: #fffdf7;
  --bg-page: var(--paper-100);
  --surface-card: var(--white);
  --surface-card-warm: var(--paper-000);
  --text-strong: var(--ink-900); --text-body: var(--ink-700);
  --text-muted: var(--ink-500); --text-faint: var(--ink-300);
  --border-default: var(--cream-line); --border-soft: var(--paper-300);
  --status-online: var(--sea-500); --status-online-soft: var(--sea-050);
  --status-warn: var(--gold-600); --status-warn-soft: var(--gold-100);
  --status-danger: var(--rust-600); --status-danger-soft: var(--rust-050);
  --status-info: var(--ocean-500); --status-info-soft: var(--ocean-050);
  --font-display: "Cooper Black", Rockwell, Georgia, serif;
  --font-sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto,
               "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  --font-mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --fs-h3: 1.4rem; --fs-h4: 1.1rem; --fs-base: 1rem; --fs-sm: 0.9rem;
  --fs-xs: 0.8rem; --fs-2xs: 0.7rem;
  --radius-sm: 8px; --radius-md: 12px; --radius-lg: 16px;
  --shadow-sm: 0 1px 2px rgba(36,28,20,.06), 0 4px 10px rgba(36,28,20,.06);
  --shadow-hard: 3px 3px 0 var(--ink-900);
  --focus-ring: 0 0 0 3px var(--gold-100);
  --container-app: 1180px;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: var(--font-sans); color: var(--text-body);
  background: var(--bg-page); line-height: 1.55;
  -webkit-font-smoothing: antialiased;
}
a { color: var(--ocean-600); text-decoration: none; }
a:hover { text-decoration: underline; }
.dash-nav {
  position: sticky; top: 0; z-index: 20;
  background: var(--paper-100);
  border-bottom: 1px solid var(--border-default);
}
.dash-nav__inner {
  max-width: var(--container-app); margin: 0 auto; padding: 12px 24px;
  display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap;
}
.dash-brand { display: inline-flex; align-items: center; gap: 12px; }
.dash-brand__disc {
  display: grid; place-items: center; width: 36px; height: 36px; flex: none;
  border-radius: 999px; background: var(--rust-500); color: var(--paper-000);
  border: 2px solid var(--ink-900); box-shadow: var(--shadow-hard);
  font-family: var(--font-display); font-size: 16px;
}
.dash-brand__wm { font-family: var(--font-display); font-size: 22px; color: var(--text-strong); line-height: 1.1; }
.dash-brand__sub {
  font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-faint);
  letter-spacing: .06em; text-transform: uppercase;
}
.dash-meta { font-family: var(--font-mono); font-size: var(--fs-xs); color: var(--text-muted); text-align: right; }
.dash-main { max-width: var(--container-app); margin: 0 auto; padding: 20px 24px 64px; display: flex; flex-direction: column; gap: 18px; }
.fm-badge {
  display: inline-flex; align-items: center; gap: 6px; flex: none;
  font-size: var(--fs-2xs); font-weight: 800; line-height: 1;
  padding: 4px 8px 3px; letter-spacing: .05em;
  border-radius: 6px; border: 1.5px solid var(--ink-900);
  box-shadow: 2px 2px 0 var(--ink-900); white-space: nowrap;
}
.fm-badge--online { background: var(--status-online); color: var(--paper-000); }
.fm-badge--warn   { background: var(--gold-500); color: var(--navy-700); }
.fm-badge--danger { background: var(--rust-600); color: var(--paper-000); }
.fm-badge--info   { background: var(--ocean-500); color: var(--paper-000); }
.fm-badge--neutral{ background: var(--paper-000); color: var(--ink-900); }
.fm-badge--manual { background: var(--gold-100); color: var(--ink-900); border-style: dashed; }
.dash-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 10px; }
.dash-stat {
  display: flex; flex-direction: column; gap: 4px; padding: 12px 14px; min-width: 0;
  background: var(--surface-card-warm); border: 1px solid var(--border-soft); border-radius: var(--radius-md);
}
.dash-stat__num { font-family: var(--font-mono); font-size: var(--fs-h3); font-weight: 600; color: var(--text-strong); line-height: 1.1; }
.dash-stat__label { font-family: var(--font-mono); font-size: var(--fs-2xs); letter-spacing: .04em; color: var(--text-muted); text-transform: uppercase; }
.dash-controls {
  display: flex; flex-wrap: wrap; gap: 10px 14px; align-items: center;
  padding: 12px 14px; background: var(--surface-card);
  border: 1px solid var(--border-default); border-radius: var(--radius-md);
}
.dash-tabs { display: inline-flex; flex-wrap: wrap; gap: 6px; }
.dash-tab {
  font-family: var(--font-sans); font-size: var(--fs-xs); font-weight: 800;
  padding: 7px 13px; cursor: pointer; color: var(--text-muted);
  background: var(--paper-000); border: 1.5px solid var(--border-soft); border-radius: 999px;
  transition: background 120ms, color 120ms, border-color 120ms;
}
.dash-tab:hover { border-color: var(--ink-500); }
.dash-tab[aria-pressed="true"] { background: var(--rust-500); color: var(--paper-000); border-color: var(--ink-900); box-shadow: 2px 2px 0 var(--ink-900); }
.dash-tab:focus-visible, .dash-chip:focus-visible, .dash-toggle:focus-visible, .dash-search:focus-visible {
  outline: none; box-shadow: var(--focus-ring);
}
.dash-chip {
  font-family: var(--font-mono); font-size: var(--fs-2xs); font-weight: 700; cursor: pointer;
  padding: 5px 10px; color: var(--text-muted);
  background: var(--paper-000); border: 1.5px solid var(--border-soft); border-radius: 6px;
}
.dash-chip[aria-pressed="true"] { background: var(--navy-700); color: var(--paper-000); border-color: var(--ink-900); }
.dash-search {
  font-family: var(--font-sans); font-size: var(--fs-sm); min-width: 180px; flex: 1 1 200px; max-width: 320px;
  padding: 8px 12px; color: var(--text-strong);
  background: var(--paper-000); border: 1.5px solid var(--border-default); border-radius: var(--radius-sm);
}
.dash-toggle {
  font-family: var(--font-sans); font-size: var(--fs-xs); font-weight: 800; cursor: pointer;
  display: inline-flex; align-items: center; gap: 8px;
  padding: 7px 13px; color: var(--text-muted);
  background: var(--paper-000); border: 1.5px solid var(--border-soft); border-radius: 999px;
}
.dash-toggle__box { width: 14px; height: 14px; border: 1.5px solid var(--ink-500); border-radius: 4px; display: inline-block; }
.dash-toggle[aria-pressed="true"] { color: var(--text-strong); border-color: var(--ink-900); }
.dash-toggle[aria-pressed="true"] .dash-toggle__box { background: var(--rust-500); border-color: var(--ink-900); }
.dash-section { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.dash-section__head {
  display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap;
  border-bottom: 2px solid var(--border-default); padding-bottom: 6px;
}
.dash-section__name { font-size: var(--fs-h4); font-weight: 800; color: var(--text-strong); }
.dash-section__count { font-family: var(--font-mono); font-size: var(--fs-xs); color: var(--text-faint); }
.dash-section__why { font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-faint); }
.dash-cards {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr));
  gap: 12px;
}
.fm-card {
  display: flex; flex-direction: column; gap: 8px; min-width: 0;
  background: var(--surface-card); border: 1.5px solid var(--border-default);
  border-radius: var(--radius-md); box-shadow: var(--shadow-sm);
  padding: 14px 16px 12px;
}
.fm-card--manual { border: 2px solid var(--gold-600); }
.dash-card__top { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.dash-card__spacer { flex: 1 1 auto; }
.dash-card__id {
  font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-faint);
  overflow-wrap: anywhere;
}
.dash-card__title {
  margin: 0; font-size: var(--fs-base); font-weight: 800; color: var(--text-strong);
  line-height: 1.35; overflow-wrap: anywhere;
}
.dash-card__meta {
  display: flex; flex-wrap: wrap; gap: 4px 14px;
  font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-muted);
}
.dash-card__outputs { display: flex; flex-direction: column; gap: 3px; font-size: var(--fs-sm); }
.dash-card__outputs a { font-weight: 700; overflow-wrap: anywhere; }
.dash-out { display: flex; gap: 6px; align-items: baseline; min-width: 0; }
.dash-out__k {
  font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-faint);
  flex: none; width: 3.2em; text-transform: uppercase; letter-spacing: .04em;
}
.dash-out__v { min-width: 0; overflow-wrap: anywhere; color: var(--text-body); font-size: var(--fs-xs); }
.dash-out__v--missing { color: var(--text-faint); }
.dash-live {
  font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-muted);
  background: var(--paper-000); border: 1px solid var(--border-soft);
  border-radius: 6px; padding: 6px 8px; overflow-wrap: anywhere;
}
details.dash-card__detail { font-size: var(--fs-xs); color: var(--text-muted); }
details.dash-card__detail summary { cursor: pointer; font-weight: 700; color: var(--ink-500); }
details.dash-card__detail div { margin-top: 6px; display: flex; flex-direction: column; gap: 5px; }
.dash-reason { font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-faint); overflow-wrap: anywhere; }
.dash-empty {
  padding: 26px; text-align: center; color: var(--text-muted);
  background: var(--surface-card-warm); border: 1.5px dashed var(--border-default); border-radius: var(--radius-md);
}
.dash-error {
  margin: 40px auto; max-width: 560px; padding: 22px 26px;
  background: var(--rust-050); border: 2px solid var(--rust-600); border-radius: var(--radius-md);
  font-size: var(--fs-sm); color: var(--rust-700);
}
.dash-foot {
  margin-top: 10px; padding-top: 12px; border-top: 1px solid var(--border-default);
  font-family: var(--font-mono); font-size: var(--fs-2xs); color: var(--text-faint);
  display: flex; flex-direction: column; gap: 3px; overflow-wrap: anywhere;
}
[hidden] { display: none !important; }
</style>
</head>
<body>
<nav class="dash-nav">
  <div class="dash-nav__inner">
    <div class="dash-brand">
      <span class="dash-brand__disc">FM</span>
      <div>
        <div class="dash-brand__wm">任务看板</div>
        <div class="dash-brand__sub" id="homeLabel">firstmate</div>
      </div>
    </div>
    <div class="dash-meta" id="generatedLabel"></div>
  </div>
</nav>
<main class="dash-main" id="app">
  <div class="dash-stats" id="stats"></div>
  <div class="dash-controls">
    <div class="dash-tabs" id="tabs" role="group" aria-label="归类维度"></div>
    <div id="chips" class="dash-tabs"></div>
    <input class="dash-search" id="search" type="search" placeholder="搜索 id / 标题 / 仓库 / 摘要…" aria-label="搜索任务" />
    <button class="dash-toggle" id="doneToggle" aria-pressed="true"><span class="dash-toggle__box"></span>显示已完成</button>
  </div>
  <div id="sections"></div>
  <footer class="dash-foot" id="foot"></footer>
</main>
<script id="task-dashboard-data" type="application/json">
__FM_TASK_DASHBOARD_DATA__
</script>
<script>
"use strict";
var DIM_LABELS = {repo: "仓库", kind: "类型", status: "状态", era: "时段", theme: "主题"};
var STATUS_TONE = {
  working: "online", waiting_captain: "warn", held: "warn",
  inflight_stale: "danger", queued_blocked: "danger", queued: "info",
  done: "neutral", freeform: "neutral"
};

function el(tag, cls, text) {
  var node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}
function badge(text, tone) {
  return el("span", "fm-badge fm-badge--" + tone, text);
}
function readData() {
  try {
    return {data: JSON.parse(document.getElementById("task-dashboard-data").textContent), error: ""};
  } catch (err) {
    return {data: null, error: String(err)};
  }
}

var state = {dimension: "repo", hidden: {}, query: "", showDone: true};
var DATA = null;

function counts(tasks) {
  var c = {total: tasks.length, working: 0, waiting: 0, queued: 0, blocked: 0, done: 0, manual: 0};
  tasks.forEach(function (t) {
    if (t.status_key === "working") c.working++;
    if (t.status_key === "waiting_captain") c.waiting++;
    if (t.status_key === "queued") c.queued++;
    if (t.status_key === "queued_blocked") c.blocked++;
    if (t.status_key === "done") c.done++;
    if (t.group_source === "manual") c.manual++;
  });
  return c;
}

function renderStats() {
  var c = counts(DATA.tasks);
  var stats = el("div", "dash-stats");
  [
    [c.total, "任务总数"], [c.working, "进行中"], [c.waiting, "等待队长"],
    [c.queued + c.blocked, "排队中"], [c.done, "已完成"], [c.manual, "手动归类"]
  ].forEach(function (pair) {
    var stat = el("div", "dash-stat");
    stat.appendChild(el("div", "dash-stat__num", String(pair[0])));
    stat.appendChild(el("div", "dash-stat__label", pair[1]));
    stats.appendChild(stat);
  });
  document.getElementById("stats").replaceChildren(stats);
}

function renderTabs() {
  var host = document.getElementById("tabs");
  var fresh = el("div", "dash-tabs");
  DATA.dimensions.forEach(function (dim) {
    var tab = el("button", "dash-tab", DIM_LABELS[dim] || dim);
    tab.type = "button";
    tab.setAttribute("aria-pressed", state.dimension === dim ? "true" : "false");
    tab.addEventListener("click", function () {
      state.dimension = dim;
      renderTabs(); renderChips(); renderSections();
    });
    fresh.appendChild(tab);
  });
  host.replaceChildren(fresh);
}

function statusKeys() {
  var seen = {};
  DATA.tasks.forEach(function (t) { seen[t.status_key] = t.status; });
  var order = ["working", "waiting_captain", "held", "inflight_stale",
               "queued_blocked", "queued", "done", "freeform"];
  return order.filter(function (k) { return seen[k]; })
    .map(function (k) { return {key: k, label: seen[k]}; });
}

function renderChips() {
  var host = document.getElementById("chips");
  var fresh = el("div", "dash-tabs");
  statusKeys().forEach(function (st) {
    var chip = el("button", "dash-chip", st.label);
    chip.type = "button";
    chip.setAttribute("aria-pressed", state.hidden[st.key] ? "false" : "true");
    chip.addEventListener("click", function () {
      if (state.hidden[st.key]) delete state.hidden[st.key];
      else state.hidden[st.key] = true;
      renderChips(); renderSections();
    });
    fresh.appendChild(chip);
  });
  host.replaceChildren(fresh);
}

function matchesQuery(task) {
  if (!state.query) return true;
  var hay = [task.id, task.title, task.repo, task.kind,
             task.body_excerpt || "", task.pr_url || ""].join(" ").toLowerCase();
  return hay.indexOf(state.query) !== -1;
}

function visibleTasks() {
  return DATA.tasks.filter(function (t) {
    if (!state.showDone && t.status_key === "done") return false;
    if (state.hidden[t.status_key]) return false;
    return matchesQuery(t);
  });
}

function groupOf(task) {
  if (task.manual) return task.manual.group;
  return task.groups[state.dimension];
}

function groupSections(tasks) {
  var manualGroups = {}, autoGroups = {};
  tasks.forEach(function (t) {
    var name = groupOf(t);
    var sink = t.manual ? manualGroups : autoGroups;
    (sink[name] = sink[name] || []).push(t);
  });
  var sections = [];
  Object.keys(manualGroups).sort().forEach(function (name) {
    sections.push({name: name, source: "manual", tasks: manualGroups[name]});
  });
  Object.keys(autoGroups).sort(function (a, b) {
    return autoGroups[b].length - autoGroups[a].length || a.localeCompare(b);
  }).forEach(function (name) {
    sections.push({name: name, source: "auto", tasks: autoGroups[name]});
  });
  return sections;
}

function sectionWhy(section) {
  if (section.source === "manual") return "手动归类 (config/dashboard-groups.json)";
  var dim = state.dimension;
  if (dim === "repo") return "自动: 按行内 repo 字段";
  if (dim === "kind") return "自动: 按行内 kind 字段";
  if (dim === "status") return "自动: 按行状态 + 端点 + 搁置/阻塞";
  if (dim === "era") return "自动: 按锚点日期 (完成日/开始日) 的月份";
  if (dim === "theme") return "自动: 按主题关键词 (config/dashboard-groups.json)";
  return "";
}

function outRow(key, valueNode) {
  var row = el("div", "dash-out");
  row.appendChild(el("span", "dash-out__k", key));
  row.appendChild(valueNode);
  return row;
}

function card(task) {
  var node = el("article", "fm-card" + (task.manual ? " fm-card--manual" : ""));
  var top = el("div", "dash-card__top");
  top.appendChild(badge(task.status, STATUS_TONE[task.status_key] || "neutral"));
  if (task.manual) top.appendChild(badge("手动", "manual"));
  if (task.kind) top.appendChild(badge(task.kind, "neutral"));
  top.appendChild(el("span", "dash-card__spacer"));
  if (task.groups.era) top.appendChild(el("span", "dash-card__id", task.groups.era));
  node.appendChild(top);

  node.appendChild(el("h3", "dash-card__title", task.title));

  var meta = el("div", "dash-card__meta");
  meta.appendChild(el("span", null, "id: " + task.id));
  if (task.repo) meta.appendChild(el("span", null, "repo: " + task.repo));
  if (task.since || task.done) {
    var wrap = el("span");
    wrap.appendChild(document.createTextNode(task.done ? "完成: " : "since: "));
    var span = task.done || task.since || "?";
    if (task.since && task.done && task.since !== task.done) span = task.since + " → " + task.done;
    wrap.appendChild(el("b", null, span));
    meta.appendChild(wrap);
  }
  node.appendChild(meta);

  var outputs = el("div", "dash-card__outputs");
  var hasOutput = false;
  if (task.pr_url) {
    var link = el("a", null, task.pr_url);
    link.href = task.pr_url;
    link.target = "_blank";
    link.rel = "noopener";
    outputs.appendChild(outRow("PR", link));
    hasOutput = true;
  }
  if (task.report_path) {
    var value = task.report_path + (task.report_present ? " ✓" : " (文件缺失)");
    outputs.appendChild(outRow("报告",
      el("span", "dash-out__v" + (task.report_present ? "" : " dash-out__v--missing"), value)));
    hasOutput = true;
  }
  if (task.completion && task.completion.verb) {
    var verb = {merged: "已合并", reported: "已交报告", done: "已完成"}[task.completion.verb] || task.completion.verb;
    outputs.appendChild(outRow("结果", el("span", "dash-out__v",
      verb + (task.completion.date ? " · " + task.completion.date : ""))));
    hasOutput = true;
  }
  var otherLinks = (task.links || []).filter(function (l) { return l !== task.pr_url; });
  if (otherLinks.length > 0) {
    outputs.appendChild(outRow("链接", el("span", "dash-out__v", otherLinks.join("  "))));
    hasOutput = true;
  }
  if (hasOutput) node.appendChild(outputs);

  if (task.live && task.live.endpoint_alive) {
    node.appendChild(el("div", "dash-live",
      "活动: " + (task.live.state || "?") + " · " + (task.live.backend || "?")
      + "/" + (task.live.harness || "?")
      + (task.live.last_event ? " · 最近: " + task.live.last_event : "")));
  }
  if (task.live && !task.live.endpoint_alive && task.status_key === "inflight_stale") {
    node.appendChild(el("div", "dash-live", "记录在航,但端点不存在 - 待对账"));
  }

  var detail = el("details", "dash-card__detail");
  detail.appendChild(el("summary", null, "详情 / 归类理由"));
  var body = el("div");
  if (task.body_excerpt) body.appendChild(el("div", null, task.body_excerpt));
  var reasonText = task.manual
    ? "手动: " + task.manual.group + (task.manual.note ? " · " + task.manual.note : "")
    : (DIM_LABELS[state.dimension] || state.dimension) + ": " + task.reasons[state.dimension];
  body.appendChild(el("div", "dash-reason", "归类: " + reasonText));
  if (!task.manual) body.appendChild(el("div", "dash-reason", "状态: " + task.reasons.status));
  if ((task.blocked_by || []).length > 0) {
    body.appendChild(el("div", "dash-reason", "阻塞于: " + task.blocked_by.join(" ")
      + (task.blocked_reason ? " - " + task.blocked_reason : "")));
  }
  if (task.hold && task.hold.reason) {
    body.appendChild(el("div", "dash-reason", "搁置 (" + (task.hold.kind || "?") + "): " + task.hold.reason
      + (task.hold.until ? " · until " + task.hold.until : "")));
  }
  detail.appendChild(body);
  node.appendChild(detail);
  return node;
}

function renderSections() {
  var host = document.getElementById("sections");
  var tasks = visibleTasks();
  var root = el("div");
  if (tasks.length === 0) {
    root.appendChild(el("div", "dash-empty",
      DATA.tasks.length === 0 ? "本 home 暂无任务记录。" : "没有匹配当前筛选的任务。"));
    host.replaceChildren(root);
    return;
  }
  groupSections(tasks).forEach(function (section) {
    var sec = el("section", "dash-section");
    var head = el("div", "dash-section__head");
    head.appendChild(el("span", "dash-section__name", section.name));
    head.appendChild(el("span", "dash-section__count", section.tasks.length + " 项"));
    head.appendChild(el("span", "dash-section__why", sectionWhy(section)));
    sec.appendChild(head);
    var cards = el("div", "dash-cards");
    section.tasks.forEach(function (task) { cards.appendChild(card(task)); });
    sec.appendChild(cards);
    root.appendChild(sec);
  });
  host.replaceChildren(root);
}

function renderFoot() {
  var c = counts(DATA.tasks);
  var lines = [
    "生成于 " + DATA.generated + " · bin/fm-task-dashboard.sh · 数据源 fm-fleet-snapshot.v1 (只读)",
    "归类: 手动 " + c.manual + " 条 (config/dashboard-groups.json, 优先于自动规则) · 其余自动归类,页面内可切换维度",
  ];
  if ((DATA.theme_keywords || []).length > 0) {
    lines.push("主题关键词: " + DATA.theme_keywords.map(function (k) {
      return k.keyword + " → " + k.group;
    }).join(" · "));
  } else {
    lines.push("主题关键词: 未配置 (config/dashboard-groups.json theme_keywords)");
  }
  if ((DATA.overrides_stale || []).length > 0) {
    lines.push("注意: " + DATA.overrides_stale.length + " 条手动归类指向当前不存在的任务: "
      + DATA.overrides_stale.join(" "));
  }
  var foot = document.getElementById("foot");
  foot.replaceChildren.apply(foot, lines.map(function (line) { return el("div", null, line); }));
}

function renderError(message) {
  document.getElementById("app").replaceChildren(
    el("div", "dash-error", "任务看板渲染失败: " + message));
}

function boot() {
  var parsed = readData();
  if (!parsed.data) {
    renderError("内嵌数据不是有效 JSON (" + parsed.error + ")");
    return;
  }
  DATA = parsed.data;
  var shortHome = (DATA.home || "").split("/").filter(Boolean).slice(-2).join("/");
  document.getElementById("homeLabel").textContent = shortHome || "firstmate";
  document.getElementById("generatedLabel").textContent = "生成于 " + DATA.generated;
  renderStats();
  renderTabs();
  renderChips();
  renderSections();
  renderFoot();
  var search = document.getElementById("search");
  search.addEventListener("input", function () {
    state.query = search.value.trim().toLowerCase();
    renderSections();
  });
  var toggle = document.getElementById("doneToggle");
  toggle.addEventListener("click", function () {
    state.showDone = !state.showDone;
    toggle.setAttribute("aria-pressed", state.showDone ? "true" : "false");
    renderSections();
  });
}

boot();
</script>
</body>
</html>
FM_TASK_DASHBOARD_TEMPLATE
}

# --- commands ---------------------------------------------------------------

command_render() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  local payload json tmpl out tmp extracted
  payload_to_file payload
  new_tmp tmpl
  template > "$tmpl" || fail "cannot produce the page template"
  out=$OUT
  json=$(jq -c . "$payload") || fail "cannot compact the dashboard payload"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  (umask 077; mkdir -p "${out%/*}") || fail "cannot create ${out%/*}"
  tmp=$(umask 077; mktemp "${out%/*}/.dashboard.XXXXXX") || fail "cannot stage the dashboard"
  if ! DASHBOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{DASHBOARD_JSON}/" "$tmpl" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the dashboard data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the dashboard data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a page that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="task-dashboard-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$DASH_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built page does not carry a readable $DASH_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$out"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the dashboard"
  fi
  printf 'dashboard: %s\n' "$out"
}

command_open() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  command_render
  if command -v open >/dev/null 2>&1; then
    open "$OUT" || fail "cannot open the dashboard: $OUT"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$OUT" || fail "cannot open the dashboard: $OUT"
  else
    printf 'open-unavailable: %s\n' "$OUT"
    return 0
  fi
  printf 'opened: %s\n' "$OUT"
}

command_groups() {
  local dimension=repo want_json=0 arg payload
  for arg in "$@"; do
    case "$arg" in
      repo|kind|status|era|theme) dimension=$arg ;;
      --json) want_json=1 ;;
      *) fail "unknown groups argument: $arg (expected a dimension among: $DIMENSIONS, or --json)" ;;
    esac
  done
  payload_to_file payload
  if [ "$want_json" -eq 1 ]; then
    jq --arg dim "$dimension" '
      {schema, home, generated, dimension: $dim, overrides_stale,
       manual: [.tasks[] | select(.group_source == "manual")
                | {id, group: .manual.group, note: (.manual.note // null),
                   auto_group: .groups[$dim]}],
       groups: [.tasks[]
                 | (if .manual then .manual.group else .groups[$dim] end) as $g
                 | {group: $g, source: .group_source, id: .id}]
                 | group_by(.group)
                 | map({group: .[0].group, source: .[0].source, count: length, tasks: map(.id)}),
       classification: [.tasks[]
         | {id,
            group: (if .manual then .manual.group else .groups[$dim] end),
            source: .group_source,
            reason: (if .manual
                     then "手动: " + .manual.group + (if .manual.note then " · " + .manual.note else "" end)
                     else .reasons[$dim] end)}]}
    ' "$payload"
    return 0
  fi
  jq -r --arg dim "$dimension" '
    def group_of: (if .manual then .manual.group else .groups[$dim] end);
    "schema: " + .schema,
      "home: " + .home,
      "generated: \"" + .generated + "\"",
      "tasks: " + (.tasks | length | tostring)
        + " (" + ([.tasks[] | select(.structured)] | length | tostring) + " structured, "
        + ([.tasks[] | select(.structured | not)] | length | tostring) + " free-form)",
      "overrides: " + (.overrides_total | tostring)
        + (if (.overrides_stale | length) > 0
           then " (" + (.overrides_stale | length | tostring) + " stale)"
           else "" end),
      "dimension: " + $dim,
      (if (.theme_keywords | length) > 0
       then "theme_keywords: " + ([.theme_keywords[] | .keyword + " → " + .group] | join(", "))
       else empty end),
      (.tasks
       | map({group: group_of, source: .group_source, id: .id})
       | group_by(.group)
       | "groups[\(length)]{group,source,count}:",
         (.[] | "  " + .[0].group + "," + .[0].source + "," + (length | tostring))),
      "classification[\(.tasks | length)]{id,group,source,reason}:",
      (.tasks[]
       | "  " + .id + "," + group_of + "," + .group_source + ","
         + (if .manual
            then "手动: " + .manual.group + (if .manual.note then " · " + .manual.note else "" end)
            else .reasons[$dim] end)
         | gsub("[\n\t]"; " "))
  ' "$payload"
}

command_path() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  printf '%s\n' "$OUT"
}

case "${1-}" in
  render) shift; command_render "$@" ;;
  '') command_render ;;
  open) shift; command_open "$@" ;;
  path) shift; command_path "$@" ;;
  groups) shift; command_groups "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
