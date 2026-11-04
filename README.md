# HermesBotApp

This is a native macOS (SwiftUI) thin client for Hermes Bot. It talks to a `hermes serve` backend
over the gateway WebSocket and does not port the Electron renderer.

- **M2 (current app)**: Group Chat. The sidebar lists hosted rooms (`groups.list`), and "+" creates
  one with 2–6 bots (`groups.create`). The room view sends with `groups.send` and follows the room by
  polling `groups.log {since_seq}` + `groups.state` (no push exists). It also has Stop
  (`groups.stop`), Retry (`groups.retry`), Approve once/Deny (`groups.approve`) and Disband.
- **M1**: Bots + Bot Chat 1:1 with streaming.
  - The app attaches to the backend that is already running: the rendezvous record `host-serve`, else
    `host-desktop-serve`, which is the Electron app's backend.
  - When no backend runs, it spawns `hermes serve --port 0 --isolated` on `~/.hermes` and stops that
    process on quit.
  - It lists the user's profiles as bots (`profiles.list`) and chats 1:1: `session.create` →
    `session.title` → `prompt.submit` → pushed `message.start/delta/complete` events.
- **M0 (spike-harness)**: a `groups.*` round trip on a private, isolated home.

Docs:
- M1 + M2 contract (connection, bots, 1:1 chat, streaming; Group Chat in §7): [docs/gateway-contract.md](docs/gateway-contract.md)
- M0 contract (`groups.*`, WS framing, error envelope): [docs/groups-contract.md](docs/groups-contract.md)

Evidence (local-only: `evidence/` is git-ignored and not in this repo; it holds raw wire logs of real chat
traffic. The layout below is kept so the `[run]` tags in the docs can be traced on the author's machine):
- `evidence/m1/`: `attach-run*`/`spawn-run1` are `bot-chat-harness` runs (`chat.json` + `wire.log`).
  `app-attach*`/`app-spawn-*` are SwiftUI runs (window renders + console). `baseline.txt` and
  `*-post.txt` are process, lock and DB checks.
- `evidence/m1-r2/`: round-2 re-runs after review run300 (token-safe errors, submit gate, turn
  settling). `kb-probe/` drives the real chat view with keyboard Return against the attached backend.
- `evidence/m2/`: `group-chat-harness` runs (`list`, `multi`, `stop`, `retry-attach` on the user install;
  `approve-iso`, `retry-iso` on the isolated home `~/.hermes-bot-app-spike/m2`; `cleanup`). `app-*` are
  SwiftUI runs (snapshots `r*.png` + `ui-log.json`). `retry-iso-run1` is a failed first run that is
  kept on purpose: the harness had wrongly required `turn.deferred`. `run306/` is the round-2 rework
  (review run305): app reruns from the final candidate, both `retry-attach` outcomes, `audit`/`cleanup`
  of the hidden member sessions, and `probe/` (lifecycle + keyboard Return regressions on a fake WS).
- `evidence/` top level: M0. `run3` is the latest harness run, `app-*` the M0 SwiftUI runs.

## Layout

```
Sources/HermesGatewayKit/   reusable: HostRendezvous (attach discovery), Backend (attach-first /
                            spawn-if-absent + event routing), BotChat (Bot, BotChatSession),
                            ChatTranscript (submit gate + turn settling), Redaction (token-safe errors),
                            ServeProcess (owned backend), GatewayClient (JSON-RPC/WS),
                            GroupsAPI + RoundTrip (M0), GroupChat (typed groups.* views),
                            RoomTimeline (log reducer, phases, send gate, poll policy, RoomSync),
                            RoomPoller (one generation-guarded poll loop per room), JSONValue
Sources/BotChatHarness/     CLI: attach/spawn → profiles.list → one streamed 1:1 turn → cleanup
Sources/SpikeHarness/       CLI: the M0 groups.* round trip (isolated home)
Sources/GroupChatHarness/   CLI: M2 Group Chat scenarios (multi/stop/retry/approve/cleanup/audit)
Sources/HermesBotApp/       SwiftUI app: Bots + Group Chats sidebar, Bot Chat, RoomView (GroupChatViews)
Tests/HermesGatewayKitTests/ ChatTranscript rules, token-leak regressions, GroupChat logic + groups.* wire shapes,
                            RoomPoller lifecycle + room availability
Tests/HermesBotAppTests/    app regressions: Try Again reconnects after a failed load (ConnectFlow + real
                            AppModel.connect against a local fake backend, needs /usr/bin/python3),
                            approval ripple vs the motion gate, rendered monogram contrast ≥ 4.5:1,
                            create-room sheet vs the motion gate (real window, needs a GUI session)
scripts/run-app-evidence.sh  scripted app run with a watchdog
```

## Run

You need Xcode 26 / Swift 6.3 and `hermes` at `~/.local/bin/hermes`. To use a different binary, set
`HERMES_BOT_APP_HERMES_BIN`.

```
swift build
swift test                                                         # no live backend needed
.build/debug/HermesBotApp                                          # attach-first, else spawn
.build/debug/bot-chat-harness evidence/<name> [profile] [prompt]   # exit 0 = ≥2 deltas + complete
.build/debug/bot-chat-harness --delete <profile> <stored_session_id>   # remove a leftover test session
.build/debug/spike-harness evidence/<name>                         # M0 groups.* round trip
.build/debug/group-chat-harness <scenario> evidence/<name> [args]  # M2; scenarios in its header comment
```

App/harness env:
- `HERMES_BOT_APP_LOCK_DIR=<dir>`: discover in this lock dir and give it to a spawned backend. An empty
  dir means "no backend running" for tests.
- `HERMES_BOT_APP_FORCE_SPAWN=1`, `HERMES_BOT_APP_NO_SPAWN=1`.
- `HERMES_BOT_APP_AUTOCHAT="<profile>|<prompt>"`, `HERMES_BOT_APP_EVIDENCE=<dir>`,
  `HERMES_BOT_APP_AUTOQUIT=1`: scripted app run with window renders.
- `HERMES_BOT_APP_KEEP_SESSIONS=1`: keep chat sessions on quit. By default they are closed and deleted.
- Group Chat scripting: `HERMES_BOT_APP_AUTOROOM="<botA,botB>|<prompt>"`, `HERMES_BOT_APP_OPEN_ROOM`,
  `HERMES_BOT_APP_AUTOROOM_STOP_AFTER`, `HERMES_BOT_APP_AUTOROOM_APPROVE`, `HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER=<s>`
  (leave the approval card on screen `<s>` seconds before answering, for evidence), `HERMES_BOT_APP_AUTOROOM_RETRY`,
  `HERMES_BOT_APP_DISBAND_ROOMS=1`, `HERMES_BOT_APP_ROOM_MANIFEST=<path>` (gateway-contract §7.9).
- `HERMES_BOT_APP_APPEARANCE=light|dark`: force the appearance (evidence of both designed modes).
- Look, tokens and motion: `DESIGN.md` (mirrored in `Sources/HermesBotApp/DesignSystem.swift`).

Lifecycle:
- An attached backend is never stopped by the app.
- A spawned backend gets `HERMES_PARENT_PID`. It is stopped with SIGTERM on quit. If the app crashes,
  the backend exits through its parent-death watchdog.
- Session tokens are read from the 0600 rendezvous file (attach) or minted per start (spawn). They are
  never logged or written to repo/evidence files.

The M0 spike harness still uses its isolated home at `~/.hermes-bot-app-spike/home`. See
groups-contract §1. It holds a minimal `config.yaml` plus `.env` with the provider key, and a second
profile at `profiles/bravo`. Its backend binds `127.0.0.1` on an OS-assigned port, printed as
`READY port=N`. The per-start session token also lands in `~/.hermes-bot-app-spike/locks/host-serve.token`
(0600) while that backend runs, and is removed on a graceful exit.

## Constraints

- M1 runs on the user's real `~/.hermes`. Test sessions are titled `hba-…` and are deleted after each
  run. The app never changes profile or bot config.
- M2 test rooms are `hba-…` and get disbanded after each run. Disband leaves a tombstone until backend
  pruning. The hidden member sessions are cleaned without restarting anything:
  `group-chat-harness cleanup <evidence-dir> @<room-manifest.jsonl>` disbands, then re-discovers the
  rooms' member sessions by provenance (exact `Group: <id>` title or the driver's opening prompt in the
  preview/derived title — the title is not reliable during a first turn), closes owned runtimes once
  `idle`, deletes the stored rows (4023 → next round) and succeeds only after a quiet window of
  consecutive empty discoveries (`HBA_CLEANUP_QUIET`, default 90 s); it exits 1 if anything owned or
  unprovable is left (gateway-contract §7.8). A runtime is
  closed only when an exact-id lookup (`GET /api/sessions/{id}?profile=` in every profile, not the
  filtered `session.list`) proves its session key stored in the owning profile only, one runtime holds it,
  and its live title agrees; a member profile's `bot_room` row from the test window that names no room is unresolved, never
  ignored. Every proven key goes into a session ledger (`evidence/m2/session-ledger.jsonl`,
  `HBA_SESSION_LEDGER`) before it is touched and is read back by exact id afterwards: the backend's late
  title-generation usage write can re-create a deleted id as `source=unknown` (§7.8), which is deleted
  again; `audit`, `ledger-audit` and `ledger-cleanup` use the same readback. The harness
  writes the manifest at `groups.create` (`evidence/m2/room-manifest.jsonl`, `HBA_ROOM_MANIFEST`); the app
  does so with `HERMES_BOT_APP_ROOM_MANIFEST=<path>`. Approvals are tested only in the isolated home `~/.hermes-bot-app-spike/m2`, because the
  user's profiles have approvals off.
- The M0 spike uses a private `HERMES_HOME` and a private lock dir (groups-contract §1).
- Not committed. This is working tree only.
