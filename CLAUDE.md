# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Herald (formerly Hermes Bot; repo and Swift target names still say HermesBot) is a native macOS SwiftUI client
for [Hermes Agent](https://github.com/NousResearch/hermes-agent): Bots + Bot Chat, Group Chat, Kanban and Mac
integration, at parity with Hermes Desktop. It is a thin client: agent behaviour belongs upstream, and this
repo never sends PRs to hermes-agent. Contributor detail lives in `docs/development.md` (code layout per file,
env vars, cleanup rules); protocol facts in `docs/gateway-contract.md` and `docs/groups-contract.md`; UI tokens
in `DESIGN.md`, mirrored in `Sources/HermesBotApp/DesignSystem.swift`.

## Commands

```sh
swift build
swift test                                      # headless: no backend, no windows
swift test --filter ChatModelQueueTests         # one XCTest class (or Class/testMethod)
swift test --filter MediaTagsTests              # Swift Testing (@Test) suites filter the same way
HERMES_BOT_APP_WINDOW_TESTS=1 swift test        # + real-window suites; run before UI changes (windows appear)
.build/debug/HermesBotApp                       # bare executable: attach to a running backend, else spawn one
scripts/package-app.sh --debug                  # debug build as dist/Herald.app (ad-hoc, no zip)
scripts/package-app.sh [X.Y.Z] [--universal]    # release dist/Herald.app + zip; --dry-run prints the plan
scripts/make-icon.sh                            # regenerate Resources/AppIcon.icns from scripts/app-icon.swift
```

There is no linter. Services, App Intents (Shortcuts), notifications, dictation and the app icon only work from
the packaged `dist/Herald.app`, not from `swift run`.

## Architecture

- **`HermesGatewayKit`** (library): everything reusable and most testable logic. `GatewayClient` speaks
  JSON-RPC over WebSocket (`/api/ws`) to `hermes serve`; `Backend` + `HostRendezvous` + `ServeProcess` do
  attach-first, spawn-if-absent (loopback only; an attached backend is never stopped, a spawned one is stopped
  on quit). Bot Chat streams via pushed `message.start/delta/complete` events reduced by `ChatTranscript`.
  Group Chat has no push: rooms are followed by polling `groups.log {since_seq}` + `groups.state`
  (`RoomTimeline`, `RoomPoller`). Kanban, bot activity and session transcripts use plugin REST
  (`PluginREST`, `X-Hermes-Session-Token`). Profile/CLI writes go through `CommandRunner` (no shell).
- **`HermesBotApp`** (executable, the app): `AppModel` owns connection, bots, rooms and shutdown, split into
  `AppModel+*.swift` extensions. `ChatModel` (+ `ChatModel+*.swift`) is one Bot Chat and talks to a
  `ChatSessionLink` protocol; `RoomModel` talks to `any RoomActions`; bot management goes through
  `BotProfileService`; Kanban through `KanbanService`. These protocols exist so tests use fakes
  (`FakeChatLink`, `FakeRoomActions`, `FakeKanbanService`, `FakeGateway`, `FakeCommandRunner`).
- **Hermes Desktop compatibility**: the app shares `~/.hermes` and Desktop's data. Each bot has one canonical
  "Bot Chat" session (find → resume, create only when absent, detach-only teardown, never deleted on quit).
  Roster/look state is `ui_meta["hermes-bots"]` in the profile, written read-patch-write with CAS like
  Desktop. Many types port Desktop rules by name (mentions, SOUL, slugify, model picker); keep them faithful.
- `EvidenceDriver.swift` and the scripted-run env vars exist only under `#if DEBUG`; release binaries must not
  contain them.
- Harness CLIs (`spike-harness`, `bot-chat-harness`, `group-chat-harness`) drive a live backend; their output
  goes to the git-ignored `evidence/` (raw wire traffic, never commit it).

## Rules that are easy to break

- **Tests never touch real Hermes data.** No real profile create/edit/delete, no prompts to real bots, no
  `cron.manage` mutations, Kanban writes, rewinds/branches, `approvals.mode` changes, notifications, global hot
  keys, Services registration, LaunchAgent install or GitHub API calls. Use the fakes, throwaway
  `UserDefaults` suites and temp folders (see "Test data and cleanup" in `docs/development.md`). Live harness
  sessions/rooms are named `hba-…` and must be cleaned up.
- **CI is Xcode 16.4 / Swift 6.1** (`macos-15`) plus a GPU-less **Intel VM** (`macos-15-intel`); local is
  Swift 6.3, which accepts code 6.1 rejects. Known traps: main-actor default args in stored-property
  initializers (crash 6.1 SILGen; build them in `init`), statics on a SwiftUI `Scene` (mark constants
  `nonisolated`), non-Sendable values crossing off the main actor, `@MainActor` XCTestCase must use
  `setUp() async throws` without `await super.setUp()`.
- **Window tests run on CI** (`CI=true`) unless gated: `WindowTestGate.requireWindows()` (CI or opt-in),
  `requirePixelExactWindows()` (local opt-in only), `requireMetalRendering()` (`ImageRenderer` aborts xctest
  on the Intel runner). Never assert after a fixed wait: poll until the state holds; the Intel runner is slow.
- Security posture to preserve: loopback-only backends, refuse a writable or foreign-owned `hermes` binary,
  lock dirs checked without following symlinks, logs 0600/0700, tokens never logged (`Redaction`), model
  links open only for http/https, `MediaSafety` checks before Open/Reveal.
- If you change how the app talks to the backend, update the contract docs. User-visible changes go in
  `CHANGELOG.md` under Unreleased; the README lists everything the app can change in Hermes data, so keep it
  in sync.

## Releases

Bundle id stays `io.github.risyadul.hermesbot`; the executable is `HermesBotApp` inside `Herald.app`. To
release: move CHANGELOG "Unreleased" under the new version, merge to `main`, push a numeric tag `vX.Y.Z`;
`.github/workflows/release.yml` publishes `Herald-X.Y.Z-macos-universal.zip` + `SHA256SUMS.txt`. Without the
Developer ID secrets the release is ad-hoc signed and not notarized. App Intents metadata needs Xcode's
`appintentsmetadataprocessor`; `package-app.sh` handles both the release (one `.swiftconstvalues` per module)
and debug (one per file) layouts.
