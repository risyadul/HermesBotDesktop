# Roadmap

Planned work for Hermes Bot for macOS, compared against the Hermes desktop app's Bots, Bot Chat, Group Chat and
Kanban features, plus ideas that are specific to a native Mac app. Items are tracked here as a checklist; tick an
item when it ships and note it in [CHANGELOG.md](../CHANGELOG.md).

Last reviewed: 2026-11-05, against Hermes Agent `main` (`8a7a5a905fc`).

## Ground rules

- **Existing Hermes Agent APIs only.** Every item is built on what the backend already exposes (gateway JSON-RPC,
  hosted rooms `groups.*`, the built-in kanban plugin API, the `hermes` CLI). Items that would need backend changes
  stay in the backlog.
- **Group Chat stays on hosted rooms (`groups.*`).** It is the backend's official room API. The desktop app's own
  client-side room format is not used.
- **One local backend.** The app connects to a single loopback backend; multi-gateway features (cross-machine relay,
  per-gateway filters, bots on other machines) are out of scope.

## How items are ordered

Priorities, highest first. Within a priority, work top to bottom: earlier items unblock later ones.

1. **P0, replace the desktop app:** what stops someone using this app instead of the Hermes desktop app every day.
2. **P1, daily friction:** things used many times a day.
3. **P2, manage without the CLI:** bot and routine management that otherwise needs `hermes` commands.
4. **P3, everything else**, grouped by area. Small (S) items here can be picked up at any time.

**Before a public release**, the two items under [Release gate](#release-gate) must be done as well.

Sizes are rough: **S** ≈ a day or less, **M** ≈ a few days, **L** ≈ a week or more, **XL** = needs its own plan.

## P0: replace the desktop app

- [x] **K0** Spike: REST/WebSocket client for backend plugin APIs (`/api/plugins/kanban/*`, `/events`, and
      `/api/plugins/bot-activity/*`) using the existing session token; detect when a plugin is disabled. Unblocks
      C1.10 and K1–K3 (S)
- [x] **E1** Keep the backend running after quit (login item / LaunchAgent for `hermes serve`), so rooms and
      routines keep running; the app attaches to it on launch (M–L)
- [x] **K8** Show whether the kanban dispatcher (`hermes gateway`) is running, with a way to start it (S–M)
- [x] **C1.3** Activity feed for the current room run (queued, working, replied, passed, timed out, …) (M)
- [x] **C1.10** Per-bot activity panel in each room: what every member is doing live (status, tool calls with
      arguments/result/duration, reasoning). Room members run in hidden sessions whose events never reach
      `groups.log`, so this reads the [Bot Activity](https://github.com/risyadul/hermes-bot-activity) plugin
      (`/api/plugins/bot-activity/activity?room=…&since=…`, `/bots`). The app installs it on request: an opt-in
      "Enable activity tracking" button installs a pinned commit with `plugins.install {repo, ref, enable}` and rolls
      it out to every bot profile with the plugin's `POST /setup`; it can also be removed from the app. Until it is
      enabled the panel falls back to C1.3. Needs a README update, since the app then changes profile plugin config
      (M–L)
- [x] **K1** Kanban, read-only board: columns, cards, live updates, switch board (M)
- [x] **K2** Kanban card details: description, latest summary, dependencies, comments, worker log, attachments (M)
- [x] **K3** Kanban card actions: create, move between columns, assign, priority, archive, comment, requeue with a
      note, message the running worker (M–L)

## P1: daily friction

- [x] **D1** Native notifications for replies and approvals, with Approve/Deny actions (M)
- [x] **D2** Dock badge for pending approvals and questions (S)
- [x] **B2** Copy message and Copy full response (S)
- [x] **B8** Queue messages while the bot is busy; steer the running turn (`session.redirect`); queue panel (M)
- [x] **B7** Model and reasoning effort per chat (`model.options`, `config.set`) (M)
- [x] **B9** Context usage gauge and "Compacting" indicator (`session.usage`, `session.context_breakdown`) (M)
- [x] **C1.2** Threads in rooms: Reply in thread (`thread_id`) (M)
- [x] **C1.1** Rename a room (`groups.rename`) (S)
- [x] **C1.5** "Needs you" badge when a bot writes `@user` (S)
- [x] **C1.6** Per-message actions in rooms: Reply to @bot, Copy (S)
- [x] **C1.7** Last-message preview in room rows; per-room drafts (S)
- [x] **A1** Bot row context menu: Open, Pin, Hide, Copy @handle; Edit, Duplicate, Delete and Manage groups join
      it with A8, A11, A12 and A5 (S)
- [x] **A2** Pin bots to the top; Hide/Unhide with a "Hidden (n)" section, stored in the profile's `ui_meta` (S–M)
- [x] **A3** Search and filter bots and rooms (S)

## P2: manage without the CLI

- [x] **A8** Edit a bot's title, description and avatar (`profiles.configure` with revision check,
      `profiles.set_asset`, `hermes profile describe`) (M)
- [x] **A9** Advanced bot settings, model and provider first, then SOUL, skills, toolsets, MCP
      (`profiles.describe` / `profiles.configure`, `model.options`) (L, split per section)
- [x] **A15** Routines (scheduled tasks) per bot: list, pause/resume, delete, details, create with a schedule
      picker, deliver results to Bot Chat (`cron.manage`) (L)
- [x] **A11** Duplicate a bot (`profiles.create {clone_from}`) (S)
- [x] **A12** Delete a bot (never `default`), with confirmation (`hermes profile delete --yes`) (S)
- [x] **C2.2** Change room members: create a new room with the new members and carry a summary over (M)
- [x] **K4** Kanban filters and search: by profile, archived, group Running by profile (S)
- [x] **K5** Kanban workers: active workers, inspect run, terminate, reclaim (M)

## P3: everything else

### Bots
- [x] **A16** Bot Chat empty state with the bot's large avatar (S)
- [x] **A4** Sort rows by last activity; last-message preview, age and unread dot (M)
- [x] **A5** Sections (folders) for bots, with drag and drop (M)
- [x] **A6** "Needs attention" badge: re-sign-in, quota, provider not configured (M)
- [ ] **A7** Create a bot: name, title, description, avatar, clone from, share keys, skip bundled skills, model;
      readiness check (`profiles.create`, `setup.runtime_check`) (L)
- [ ] **A10** Avatar picker: shapes and faces, upload, generate (`image.generate`), pet gallery (L)
- [ ] **A13** Skills: search and install (`skills.manage`) (M)
- [ ] **A14** MCP servers: add, API key, test, OAuth sign-in (`mcp.servers.*`) (L)
- [x] **A17** Open a bot's recent session (routine runs, side threads) (M)

### Bot Chat
- [x] **B5** Timestamps on hover, turn duration (S)
- [x] **B6** Scroll-to-bottom button with unread count (S)
- [x] **B12** Composer prompt history (↑/↓) and per-bot drafts (S)
- [x] **B15** Export a conversation (S)
- [x] **B1** @mention other bots from Bot Chat, with autocomplete (M)
- [ ] **B10** Actionable error cards: Retry, Switch provider, Copy diagnostics (M)
- [ ] **B11** More attachment types: URL, folder, long paste as a file, image zoom (S–M)
- [x] **B13** Find in chat (⌘F) (M)
- [ ] **B14** Approval mode menu (S–M)
- [ ] **B3** Regenerate, edit a sent message, restore from a message (backing RPC to be confirmed) (M–L)
- [ ] **B4** Branch into a new chat (`session.branch`) (M)
- [ ] **B16** Changed-files card (M)
- [ ] **B17** Voice: dictation and read aloud (L)

### Group Chat
- [x] **C1.4** Pin and reorder rooms (local) (S)
- [x] **C1.8** Room availability ("N of M available"), local room picture (S)
- [x] **C2.1** Polish Group Chat attachments (already sent as file references) (S)
- [x] **C2.3** Spike: can room members' clarifying questions be answered from the app? (S). Answer: no; no
      `groups.*` event or method carries them ([groups-contract.md §8](groups-contract.md#8-clarifying-questions-from-room-members-c23-spike)).
      Answering them needs a backend change (backlog).

### Kanban
- [x] **K6** Kanban AI actions: estimate, decompose, specify, reassign (M)
- [x] **K7** Kanban boards and orchestration settings: create/rename/delete, export/import, orchestrator profile,
      default assignee, model override (M)
- [x] **K9** Kanban integrations: open the assignee's Bot Chat from a card, "Create task from message" in rooms,
      notifications when a card finishes or is blocked, Boards section in the sidebar (M)

### macOS integration
- [ ] **D5** ⌘1…9 to switch bots, ⌘K quick switcher (S)
- [ ] **D8** Quick Look for bot files and attachments; drag files out to Finder (S)
- [ ] **D13** Room templates: saved member sets and an opening prompt (S)
- [ ] **D15** Mute notifications per bot or room (S). Done: the Settings switch for `notificationsEnabled`
      (Settings → Notifications → Show notifications).
- [x] **D3** Menu bar extra: bot status and quick send (M)
- [x] **D4** Global hotkey "quick ask" panel (M)
- [x] **D6** macOS Services / Share: "Send to Hermes bot" (M)
- [x] **D7** Shortcuts actions: "Ask <bot>", "Send to group" (M)
- [ ] **D9** Open a Bot Chat or room in its own window (M)
- [ ] **D10** Search across Bot Chats and rooms (M)
- [x] **D12** "Summarize since I left" for rooms (M)

### Migration
- [x] **E4 / D17** One-time, read-only import of the desktop app's group chats (M)

## Release gate

Not needed to use the app yourself, but required before announcing a public release.

- [x] **E2** First-run onboarding: Hermes missing, no model configured, only one bot (M)
- [ ] **E3** Distribution: Developer ID notarization, auto-update, Intel testing (M)

## Backlog

Kept for reference; not planned.

- **A18** Screen: live view of a bot's virtual desktop (`display.*`) (XL)
- **B18** Emoji reactions (S)
- **C1.9** Show disbanded rooms (`include_disbanded`) (S)
- **D11** Spotlight indexing of conversations (M)
- **D14** Token and cost usage per bot (M)
- **D16** Undo send in rooms (S)
- **C2.4** Answer room members' clarifying questions in the room (needs a backend pending action and answer
  method, see C2.3) (M)
- **Group Chat features hosted rooms do not support:** holding/pausing individual bots (`@all stop` / resume),
  "this session" / "always" approvals, compressing a member's history. These would need either backend support or a
  second, client-orchestrated room mode (XL).

## Open questions

- **B3**: which gateway RPC backs regenerate / edit / restore.
- **K0 / C1.10**: whether plugin APIs (`/api/plugins/kanban/*`, `/api/plugins/bot-activity/*`) accept the session
  token the app already holds.
- **C1.10**: bots created after the plugin is enabled need it too (hook into A7, or re-run `/setup`).
- **C1.10**: whether the `plugin.bot-activity.changed` event reaches the app's gateway WebSocket, or polling with
  `since` is needed.
- **K8 / E1**: whether `hermes serve` also runs the kanban dispatcher, or only `hermes gateway` does, and whether
  `hermes gateway` was being started by the desktop app.
