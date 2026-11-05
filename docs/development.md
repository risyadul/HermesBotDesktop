# Development notes

Contributor-facing notes: code layout, tests, harness CLIs, test-only environment variables, backend
lifecycle and the test-data cleanup rules. End-user setup lives in the [README](../README.md).

Protocol references:
- [gateway-contract.md](gateway-contract.md): connection (attach-first, spawn-if-absent), Bots, Bot Chat 1:1,
  streaming; Group Chat in §7.
- [groups-contract.md](groups-contract.md): the `groups.*` API, WS framing, error envelope.

Tags such as `[run]`, `[src]` and `[test]` in those docs say how a claim was established. `[run]` claims
point at local evidence logs (`evidence/`, git-ignored, never published because they hold raw wire traffic).

## History

The app was built in three steps; the contracts still use these names.
- **M0**: `spike-harness`, a `groups.*` round trip on a private, isolated Hermes home.
- **M1**: Bots + Bot Chat 1:1 with streaming (`profiles.list`, `session.create` → `session.title` →
  `prompt.submit` → pushed `message.start/delta/complete`).
- **M2**: Group Chat on hosted rooms (`groups.list/create/send/log/state/stop/retry/approve`, disband). Rooms
  are followed by polling `groups.log {since_seq}` + `groups.state`; there is no push for rooms.

## Layout

```
Sources/HermesGatewayKit/   reusable: HostRendezvous (attach discovery), Backend (attach-first /
                            spawn-if-absent + event routing), BotChat (Bot, BotChatSession),
                            ChatTranscript (submit gate, turn settling, tool lines, history seeding), Redaction (token-safe errors),
                            ServeProcess (owned backend), GatewayClient (JSON-RPC/WS),
                            GroupsAPI (raw groups.* calls), GroupChat (typed groups.* views + calls),
                            RoomTimeline (log reducer, phases, send gate, poll policy, RoomSync),
                            RoomPoller (one generation-guarded poll loop per room), JSONValue
  CanonicalBotChat.swift      the bot's one "Bot Chat": find -> resume, create only when absent, detach-only teardown
  ChatAttachments.swift       image/pdf/file attach RPCs, client-side checks, prompt text
  MediaTags.swift             MEDIA:<path> parsing + MediaSafety (deny rules for Open/Reveal)
  ServerRequests.swift        server->client requests (approval, clarify, sudo, secret): frames, answers, cancel
  SlashCommands.swift         commands.catalog (curated like Desktop) + invocation classification
  ToolActivity.swift          tool.start/progress/complete payloads
  PluginREST.swift            /api/plugins/<name>/ REST client (session token header, loopback, no redirects;
                              multipart upload + download with size caps)
  KanbanAPI.swift             kanban plugin calls (always ?board=); KanbanModels.swift: lenient models
  BotActivityAPI.swift        bot-activity plugin calls; install/enable/remove via plugins.manage (pinned ref,
                              provenance check); BotActivityProfileSwitch: per-profile `plugins enable/disable`;
                              BotActivityFeed.swift: paging merge, cursor, member phases
  BackgroundServe.swift       opt-in LaunchAgent keeping `hermes serve` running (plist, launchctl)
  GatewayStatus.swift         kanban dispatcher (`hermes gateway`) state + start; CommandRunner.swift: no-shell runner
Sources/BotChatHarness/     CLI: attach/spawn → profiles.list → one streamed 1:1 turn → cleanup
Sources/SpikeHarness/       CLI: the M0 groups.* round trip (isolated home): RoundTrip, GroupsAPI+Spike
                            (M0-only raw calls: profiles, create, disband, Member)
Sources/GroupChatHarness/   CLI: Group Chat scenarios (multi/stop/retry/approve/cleanup/audit)
Sources/HermesBotApp/       SwiftUI app:
  HermesBotApp.swift          @main App, AppDelegate (signals, quit cleanup with deadline), RootView, Settings
  AppModel.swift              connection (ConnectFlow), bots, rooms, backend loss, shutdown
  ChatModel.swift             one Bot Chat 1:1 (open/seed/send gate, wraps ChatTranscript)
  ChatModel+Slash.swift       slash command execution and directives
  ChatModel+Requests.swift    attachments staging and server request cards state
  ChatSessionLink.swift       protocol ChatModel needs from a chat (BotChatSession in prod, fake in tests)
  ChatComposer.swift          composer: paperclip, drop/paste, slash menu, Send/Stop
  SlashCommandMenu.swift      slash menu keyboard model
  AttachmentChips.swift       staged attachment chips, pasteboard file import
  ToolActivityRow.swift       compact tool-call row
  ServerRequestCards.swift    approval/clarify/secret cards; RequestCardModels.swift: their labels and answers
  MediaViews.swift            MEDIA files: inline images, file chips, click-time safety check
  SidebarView.swift           Group Chats + Bots + Boards sidebar, row style, connection footer
  KanbanHub.swift             board list for the sidebar, per-board models, dispatcher status (K8)
  KanbanBoardModel.swift      one board: polling, lanes, optimistic actions + rollback, details (KanbanService)
  KanbanBoardView.swift       board pane: header, lanes, cards, card menus, dispatcher chip
  KanbanTaskInspector.swift   card details inspector (attachments, message worker / requeue), New Task sheet;
                              KanbanSidebar.swift: Boards rows
  KanbanAttachments.swift     card attachments on disk: upload read + size cap, download name sanitising,
                              caches folder, open-or-reveal check (never runs files)
  BotChatView.swift           Bot Chat pane (transcript, composer, streaming text)
  BotInspector.swift          bot details inspector, DefaultTag
  RoomModel.swift             SidebarItem, RoomModel (polling, send gate, room actions)
  RoomView.swift              Group Chat pane; RoomRows.swift (ribbon, timeline rows),
                              RoomActionViews.swift (approval/retry cards, @mentions), CreateRoomView.swift
  RoomActivityModel.swift     per-room Activity inspector state: bot-activity polling, plugin enable/remove;
                              RoomActivityPresentation.swift (rows, chips, turn-state fallback),
                              RoomActivityPanel.swift (panel, enable sheet)
  RoomPresentation, Identity, Components, DesignSystem, MotionSheet, ConnectFlow: shared view logic
  EvidenceDriver.swift        scripted runs + window snapshots, #if DEBUG only (see below)
Tests/HermesGatewayKitTests/ ChatTranscript rules, token-leak regressions, GroupChat logic + groups.* wire
                            shapes, RoomPoller lifecycle + room availability
                            + parity suites: CanonicalBotChat, BotChatRebind (reclaim/session.info), ChatAttachment,
                            ChatTranscriptTool, MediaTags, ServerRequest, SlashCommand (ParityTestSupport: fakes)
Tests/HermesBotAppTests/    ChatModel (with FakeChatLink), BotChatUIModel, MediaViews; app regressions: Try Again reconnects after a failed load (ConnectFlow + real
                            AppModel.connect against a local fake backend, needs /usr/bin/python3),
                            approval ripple vs the motion gate, rendered monogram contrast ≥ 4.5:1,
                            create-room sheet vs the motion gate; real-window suites are opt-in
                            (WindowTestGate: HERMES_BOT_APP_WINDOW_TESTS=1)
scripts/run-app-evidence.sh  scripted app run with a watchdog
scripts/sigint-regression.sh Ctrl+C cleanup check against a fake backend (scripts/fixtures/)
```

Look, tokens and motion: [DESIGN.md](../DESIGN.md), mirrored in `Sources/HermesBotApp/DesignSystem.swift`.

## Build and test

`Package.swift` declares swift-tools 6.0 and macOS 14. Tested with Xcode 26 / Swift 6.3.

```
swift build
swift test                                                         # headless, no live backend needed
HERMES_BOT_APP_WINDOW_TESTS=1 swift test                           # also the real-window suites (before UI changes)
.build/debug/HermesBotApp                                          # attach-first, else spawn
.build/debug/bot-chat-harness evidence/<name> [profile] [prompt]   # exit 0 = ≥2 deltas + complete
.build/debug/bot-chat-harness --delete <profile> <stored_session_id>   # remove a leftover test session
.build/debug/spike-harness evidence/<name>                         # M0 groups.* round trip
.build/debug/group-chat-harness <scenario> evidence/<name> [args]  # scenarios in its header comment
```

## Test-only environment variables

User-facing variables are in the README. These exist for scripted runs and tests. The scripted-run ones
(`AUTOCHAT`, `EVIDENCE`, `AUTOQUIT`, Group Chat scripting, `ROOM_MANIFEST`) live in
`EvidenceDriver.swift` and exist only in debug builds (`swift build`; the scripts use `.build/debug`);
a release build ignores them. `LOCK_DIR` and `FORCE_SPAWN` work in every build.
- `HERMES_BOT_APP_LOCK_DIR=<dir>`: discover in this lock dir and give it to a spawned backend. An empty dir
  means "no backend running" for tests. It does **not** change the Hermes home (still `~/.hermes`).
- `HERMES_BOT_APP_FORCE_SPAWN=1`: skip discovery and always spawn.
- `HERMES_BOT_APP_AUTOCHAT="<profile>|<prompt>"`, `HERMES_BOT_APP_EVIDENCE=<dir>`,
  `HERMES_BOT_APP_AUTOQUIT=1`: scripted app run with window renders.
- Group Chat scripting: `HERMES_BOT_APP_AUTOROOM="<botA,botB>|<prompt>"`, `HERMES_BOT_APP_OPEN_ROOM`,
  `HERMES_BOT_APP_AUTOROOM_STOP_AFTER`, `HERMES_BOT_APP_AUTOROOM_APPROVE`,
  `HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER=<s>` (leave the approval card on screen `<s>` seconds before
  answering), `HERMES_BOT_APP_AUTOROOM_RETRY`, `HERMES_BOT_APP_DISBAND_ROOMS=1`,
  `HERMES_BOT_APP_ROOM_MANIFEST=<path>` (gateway-contract §7.9).
- Harness: `HBA_ROOM_MANIFEST`, `HBA_SESSION_LEDGER`, `HBA_CLEANUP_QUIET` (see below).

## Backend lifecycle

- An attached backend is never stopped by the app.
- A spawned backend (`hermes serve --host 127.0.0.1 --port 0 --isolated` on `~/.hermes`, log at
  `~/Library/Logs/HermesBotApp/serve.log`) gets `HERMES_PARENT_PID`. It is stopped with SIGTERM on quit. If
  the app crashes, the backend exits through its parent-death watchdog.
- Quit (⌘Q, last window closed), SIGTERM and SIGINT (Ctrl+C in the launching terminal) all run the same
  graceful cleanup, once; a repeated signal during cleanup is ignored. The spawned backend runs in its own
  process group (Foundation `Process`), so the terminal's Ctrl+C reaches only the app, which then uses the
  backend for cleanup and stops it with SIGTERM. SIGKILL skips cleanup.
  Regression check: `scripts/sigint-regression.sh` (needs tmux and a GUI session; exit 0 = pass). It runs the
  canonical Bot Chat flow against a fake backend and asserts that Ctrl+C sends no `session.close` /
  `session.delete` (the Bot Chat is only detached) and that the quit completes.
- Session tokens are read from the 0600 rendezvous file (attach) or minted per start (spawn). They are never
  logged or written to repo/evidence files.

## M0 spike home

The M0 spike harness uses its own isolated home at `~/.hermes-bot-app-spike/home` (groups-contract §1): a
minimal `config.yaml` plus `.env` with the provider key, and a second profile at `profiles/bravo`. Its backend
binds `127.0.0.1` on an OS-assigned port, printed as `READY port=N`. The per-start session token lands in
`~/.hermes-bot-app-spike/locks/host-serve.token` (0600) while that backend runs and is removed on a graceful
exit. The app itself does not use this home.

## Test data and cleanup

Live tests run against a real `~/.hermes`, so they must clean up after themselves.

- Bot Chat test sessions made by the harness are titled `hba-…` and deleted after each run (the app's own
  canonical "Bot Chat" is never deleted). The app never changes profile or bot config.
- Group Chat test rooms are `hba-…` and get disbanded after each run. Disband leaves a tombstone until backend
  pruning. The hidden member sessions are cleaned without restarting anything:
  `group-chat-harness cleanup <evidence-dir> @<room-manifest.jsonl>` disbands, then re-discovers the rooms'
  member sessions by provenance (exact `Group: <id>` title or the driver's opening prompt in the
  preview/derived title; the title is not reliable during a first turn), closes owned runtimes once `idle`,
  deletes the stored rows (4023 → next round) and succeeds only after a quiet window of consecutive empty
  discoveries (`HBA_CLEANUP_QUIET`, default 90 s). It exits 1 if anything owned or unprovable is left
  (gateway-contract §7.8).
- A runtime is closed only when an exact-id lookup (`GET /api/sessions/{id}?profile=` in every profile, not the
  filtered `session.list`) proves its session key is stored in the owning profile only, one runtime holds it,
  and its live title agrees. A member profile's `bot_room` row from the test window that names no room is
  unresolved, never ignored.
- Every proven key goes into a session ledger (`evidence/m2/session-ledger.jsonl`, `HBA_SESSION_LEDGER`) before
  it is touched and is read back by exact id afterwards: the backend's late title-generation usage write can
  re-create a deleted id as `source=unknown` (§7.8), which is deleted again. `audit`, `ledger-audit` and
  `ledger-cleanup` use the same readback.
- The harness writes the room manifest at `groups.create` (`evidence/m2/room-manifest.jsonl`,
  `HBA_ROOM_MANIFEST`); the app does so with `HERMES_BOT_APP_ROOM_MANIFEST=<path>`.
- Approvals are tested only in an isolated home (`~/.hermes-bot-app-spike/m2`), because approvals may be off in a
  real install.
