# nio-chat-agent worker runtime

nio-chat-agent is a harness-axis runtime in which the worker is not a terminal agent but an agent thread on the NIO Chat desktop app's Local Agent Protocol Server.
The app runs a verified HTTP+SSE protocol server on `127.0.0.1:8765`; firstmate creates a thread, sends the task brief as the run's user message, and supervises the run through the same lifecycle contracts as any crewmate.
`bin/fm-niochat-lib.sh` is the single owner of the protocol surface, the run record, and every lifecycle verb; `bin/backends/nio-chat.sh` is the thin backend adapter; `bin/fm-niochat.sh` is the operator CLI.

## Opt-in and selection

The channel ships default off and changes nothing until the operating home opts in.

- Local gitignored `config/nio-chat-worker` containing exactly `on` opts in.
- An absent file means off; any other value is an invalid configuration error, never silently treated as off or on.
- Selection is explicit per task only: `fm-spawn.sh <id> ... --scout --harness nio-chat-agent`.
- The runtime is scout-only: its deliverable is the agent's answer, captured into `data/<id>/report.md`.
- Firstmate never launches the NIO Chat app; when the app is not running the server is unreachable and dispatch refuses.

## Data boundary (captain-decided)

The agent acts with the captain's NIO Chat identity and can reach company systems, so firstmate gates every task BEFORE dispatch.

Allowed task categories:

- 飞书相关 (Feishu/Lark-related work)
- 查 wiki (wiki lookup)
- 写文档 (writing Feishu documents)
- 查飞书聊天记录 (searching Feishu chat history)

Forbidden task categories:

- 未公开代码 (unreleased code)
- 密钥凭证 (secrets and credentials)
- 人事内容 (HR/personnel matters)

The category judgment happens in firstmate itself, by reading the task's actual content, before any dispatch; it is never a keyword regex and never delegated to the worker's self-restraint.
A task outside the allowed categories is not dispatched on this channel.
Accepted consequences of using the channel: ModelSight quota and audit see the runs, the captain's Feishu identity is attributable for actions, the observability system may retain residuals, and every run carries the timeout-plus-cancel fallback below.

## Setup

Prerequisites:

- The NIO Chat desktop app installed, running, and logged in.
- `jq` and `curl` on `PATH`.

The handshake file `~/.nio-chat-desktop/agent-protocol.json` carries `base_url` and `token`.
The token rotates per app launch, so the library re-reads the handshake before every HTTP call and retries exactly once on a 401.
`base_url` must be a loopback address; anything else is treated as a corrupt handshake and refused without dialing.

`bin/fm-niochat.sh doctor` checks the gate, the handshake, server readiness (a capabilities read answering `protocol_version` 0.2), and whether the channel is currently held.

## Task shape and metadata

A nio-chat task has no worktree and no project; its meta deliberately omits `worktree=` and `project=` entirely.

```text
backend=nio-chat
window=fm-<id>
external_ref=<agent thread id>
endpoint_task_id=<id>
```

`window=fm-<id>` is the shared firstmate alias (Orca's `terminal=` precedent); the thread id in `external_ref=` is the endpoint authority.
`bin/fm-backend.sh`'s nio endpoint validation is a dedicated contract: it requires exactly one `backend=`, `window=fm-<id>`, `endpoint_task_id=`, and `external_ref=`, forbids `worktree=` and `project=` keys outright, and refuses anything malformed rather than guessing.

## Lifecycle

Dispatch (`fm-spawn.sh`): the library gates the opt-in, takes the single-concurrency channel lock, verifies readiness, creates a fresh thread (or adopts the recorded one on a relaunch), sends the brief text as the run's user message, writes the run record and a generated per-task check, and the spawn continues through the ordinary record-publication and backlog-In-flight ordering.
The brief IS the run's user message: the agent cannot read files, so everything it needs travels in the brief.

Busy/idle: the server's own status read stays `idle` during streaming runs (verified), so busy truth is the local run record alone - `bin/fm-busy-lib.sh` classifies from it, and `bin/fm-crew-state.sh` reads it directly.
No network call is made to classify a task.

Wake path: the generated `state/<id>.check.sh` (registered through `bin/fm-check-register.sh`) does local reads only and prints `niochat <id> <event>` when the run record holds a state firstmate must act on - a settled run, or a streaming run past its deadline.
Reconcile (`bin/fm-niochat.sh reconcile`) then finalizes it: a completed run's captured reply is written to `data/<id>/report.md` with a `done:` status line; an interrupted run's ask_user question is read from the thread history and surfaced as a `blocked:` status line with the answer command; a streaming run past its deadline is cancelled and failed.
An unreachable server at finish time bumps the deadline by a bounded retry window instead of refiring the wake every poll.

Steering: `fm-send.sh` writes the ordinary durable inbox record; for a nio target the ring IS the delivery - `fm-task-inbox-lib.sh`'s nio branch hands the record to the runtime library, which steers its text as a new run on the same thread (queued durably when the channel is mid-run) and moves the record to `handled/`, the same acknowledgement every harness uses.

Interrupt/exit: `fm-control.sh <id> interrupt` cancels this task's own active run (never another task's); `exit` settles the channel and keeps the thread; `relaunch` re-dispatches on the recorded thread through the spawn plane.

Teardown: the ordinary scout gates hold - the report and the captain-call inventory are required before any cleanup.
Cleanup cancels any active run, deletes the thread only when firstmate created it (an adopted thread is the captain's conversation and is never destroyed), and removes the run record, stream capture, steer queue, wake marker, and channel lock.

## Safety properties

- Default off; explicit per-task selection only; config-resolved harness defaults can never reach this runtime.
- Scout-only, enforced structurally at spawn.
- The app is never launched, updated, or restarted by firstmate.
- Loopback-only dialing; a non-loopback handshake is refused without a request.
- Single concurrency: one channel lock per home; a second task queues or refuses rather than interleaving runs.
- Every run has a deadline (`FM_NIOCHAT_RUN_TIMEOUT`, default 1800s); a streaming run past it is cancelled and failed - the cancel is the fallback, not the primary control.
- Cancel addresses only the task's own recorded run.
- Interrupted ask_user runs park as a captain decision; a steer refuses until answered.

## Environment tunables

- `FM_NIOCHAT_HANDSHAKE` - override the handshake file path (tests).
- `FM_NIOCHAT_HTTP_TIMEOUT` - per-call curl cap in seconds (default 20).
- `FM_NIOCHAT_RUN_TIMEOUT` - run deadline in seconds (default 1800).
- `FM_NIOCHAT_DISPATCH_GRACE` - seconds to wait for the run's metadata event before declaring dispatch failed (default 30).
- `FM_NIOCHAT_RETRY_WINDOW` - seconds added to the deadline when the server is unreachable at finish (default 60).

## Verified protocol surface

Recorded from five access-verification experiments against the real server; the PR description carries the evidence.

- Input shape: `{"input":{"messages":[{"role":"user","content":"..."}]},"stream_mode":["messages"]}`.
  The server applies no HTTP input validation - malformed payloads are coerced to empty and still run - so the canonical shape is always sent exactly.
- SSE envelope: `data: {"type":"event","seq":N,"method":...,"params":{"data":...}}`.
  `metadata` carries `run_id`; `messages` carries a list of blocks whose visible text is `content-block-delta`/`text-delta`; `lifecycle` ends `started|interrupted|completed`; `done` terminates the stream.
- ask_user works headless: the run ends `lifecycle=interrupted` plus `done`, and the question exists only in `GET threads/{id}/history` at `.messages[-1].checkpoint.channel_values.__interrupt__[0].value` with `options[{id,label}]`.
  Answering is `POST threads/{id}/resume/stream` with `{"command":{"resume":"<option-id>"}}`.
- The server does not serialize concurrent runs and its thread status read stays `idle` during streaming - local truth it is.
- `GET /threads/{id}` with an unknown id creates an empty thread, so liveness is always the capabilities read, never a thread probe.
- `POST runs/{run_id}/cancel` cancels; thread deletion is `DELETE /threads/{id}`.

## Active limits

- macOS-only in practice (the desktop app), and only as available inside the company network identity.
- One run at a time per home; a queued steer waits for the current run to settle.
- The final answer is captured from the SSE stream only; the history endpoint serializes message objects unreliably (constructor/null shapes), so it is never used to recover final text.
- No `--secondmate` launch, no typed-plane keys, no composer model - there is no terminal.
- The runtime speaks protocol 0.2 only; a different `protocol_version` refuses loudly.

## Regression entry points

```sh
tests/fm-niochat.test.sh
tests/fm-backend.test.sh
```
