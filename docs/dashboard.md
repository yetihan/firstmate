# Task dashboard

The task dashboard is this home's one-page, read-only view of every task the backlog and runtime records know about: what is running, what is waiting on the captain, what landed, and what each produced.
`bin/fm-task-dashboard.sh` builds it from the canonical fleet snapshot ([`fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh)), so the page never re-parses `data/backlog.md` or `state/` itself and never mutates anything.

```console
$ bin/fm-task-dashboard.sh open     # render, then open the page locally
$ bin/fm-task-dashboard.sh render   # render only; prints the page path
$ bin/fm-task-dashboard.sh path     # print where the page will land
$ bin/fm-task-dashboard.sh groups   # print the classification with reasons
```

The page lands at `data/dashboard.html` in this home: local, gitignored, mode 0600.
It is a single self-contained HTML file - inline CSS and JavaScript, system fonts, no external requests of any kind - so it opens standalone and no task content ever leaves the machine.
Regeneration is wholesale and deterministic: rendering twice over an unchanged home produces byte-identical output, and every render re-reads current state rather than editing the old page in place.

## Automatic grouping

Every task is classified along five dimensions, and the page switches between them with the tabs at the top:

- 仓库 (repo): the record's `(repo: ...)` field; unmarked rows group under 未标仓库.
- 类型 (kind): the record's `(kind: ...)` field.
- 状态 (status): done, in flight with a live endpoint, in flight without one, held for the captain, held otherwise, queued and blocked, queued and ready, or a free-form backlog line.
- 时段 (era): the month of the anchor date - the completion date for done rows, otherwise the since date.
- 主题 (theme): the first configured keyword (case-insensitive) found in the task's title or body text; see below.

Each card states the reason it was placed in its group (详情 / 归类理由), and `groups` prints the same classification with reasons for scripting or review.
Search, status chips, and the 已完成 toggle filter the page locally.

## Manual adjustments

Saved adjustments live in `config/dashboard-groups.json` and beat every automatic rule: an override replaces the task's group in all five dimensions, marks the card with a 手动 badge, and floats its group to the top of the page.
Overrides are keyed by task id, so regenerating the page, editing keywords, or changing rules never moves or drops a saved adjustment; ids that no longer match a current task are disclosed at the bottom of the page instead of disappearing.

The schema, validation behavior, and a starting example are owned by [`configuration.md`](configuration.md#task-dashboard-groups-configdashboard-groupsjson).

## What each card shows

Each card carries the task id, title, status badge, repo, kind, timeline (`since`, completion date), output tracking (PR URL, report path with a presence check, completion verb, extra links), and - for live work - the current run state and endpoint liveness.
Output values come from the snapshot's records: the PR link on a done row, the declared `data/<id>/report.md` path, and the recorded completion.
