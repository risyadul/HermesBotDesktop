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

Sizes are rough: **S** ≈ a day or less, **M** ≈ a few days, **L** ≈ a week or more, **XL** = needs its own plan.

## Phase 1: quick wins

- [ ] **A1** Bot row context menu: Open, Pin, Hide, Edit, Duplicate, Delete, Manage groups (S)
- [ ] **A2** Pin bots to the top; Hide/Unhide with a "Hidden (n)" section, stored in the profile's `ui_meta` (S–M)
- [ ] **A3** Search and filter bots and rooms (S)
- [ ] **A11** Duplicate a bot (`profiles.create {clone_from}`) (S)
- [ ] **A12** Delete a bot (never `default`), with confirmation (`hermes profile delete --yes`) (S)
- [ ] **A16** Bot Chat empty state with the bot's large avatar (S)
- [ ] **B2** Copy message and Copy full response (S)
- [ ] **B5** Timestamps on hover, turn duration (S)
- [ ] **B6** Scroll-to-bottom button with unread count (S)
- [ ] **B12** Composer prompt history (↑/↓) and per-bot drafts (S)
- [ ] **C1.1** Rename a room (`groups.rename`) (S)
- [ ] **C1.4** Pin and reorder rooms (local) (S)
- [ ] **C1.5** "Needs you" badge when a bot writes `@user` (S)
- [ ] **C1.6** Per-message actions in rooms: Reply to @bot, Copy (S)
- [ ] **C1.7** Last-message preview in room rows; per-room drafts (S)
- [ ] **D2** Dock badge for pending approvals and questions (S)
- [ ] **D5** ⌘1…9 to switch bots, ⌘K quick switcher (S)
- [ ] **D8** Quick Look for bot files and attachments; drag files out to Finder (S)

## Phase 2: daily driver (replace the desktop app)

- [ ] **E1** Keep the backend running after quit (login item / LaunchAgent for `hermes serve`), so rooms and
      routines keep running; the app attaches to it on launch (M–L)
- [ ] **A8** Edit a bot's title, description and avatar (`profiles.configure` with revision check,
      `profiles.set_asset`, `hermes profile describe`) (M)
- [ ] **A9** Advanced bot settings, model and provider first, then SOUL, skills, toolsets, MCP
      (`profiles.describe` / `profiles.configure`, `model.options`) (L, split per section)
- [ ] **A15** Routines (scheduled tasks) per bot: list, pause/resume, delete, details, create with a schedule
      picker, deliver results to Bot Chat (`cron.manage`) (L)
- [ ] **B1** @mention other bots from Bot Chat, with autocomplete (M)
- [ ] **B7** Model and reasoning effort per chat (`model.options`, `config.set`) (M)
- [ ] **B8** Queue messages while the bot is busy; steer the running turn (`session.redirect`); queue panel (M)
- [ ] **B9** Context usage gauge and "Compacting" indicator (`session.usage`, `session.context_breakdown`) (M)
- [ ] **C1.2** Threads in rooms: Reply in thread (`thread_id`) (M)
- [ ] **C1.3** Activity feed for the current room run (queued, working, replied, passed, timed out, …) (M)
- [ ] **D1** Native notifications for replies and approvals, with Approve/Deny actions (M)
- [ ] **K0** Spike: REST/WebSocket client for the kanban plugin (`/api/plugins/kanban/*`, `/events`) using the
      existing session token; detect when the plugin is disabled (S)
- [ ] **K1** Read-only board: columns, cards, live updates, switch board (M)
- [ ] **K2** Card details: description, latest summary, dependencies, comments, worker log, attachments (M)
- [ ] **K3** Card actions: create, move between columns, assign, priority, archive, comment, requeue with a note,
      message the running worker (M–L)
- [ ] **K8** Show whether the kanban dispatcher (`hermes gateway`) is running, with a way to start it (S–M)

## Phase 3: larger features

- [ ] **A4** Sort rows by last activity; last-message preview, age and unread dot (M)
- [ ] **A5** Sections (folders) for bots, with drag and drop (M)
- [ ] **A6** "Needs attention" badge: re-sign-in, quota, provider not configured (M)
- [ ] **A7** Create a bot: name, title, description, avatar, clone from, share keys, skip bundled skills, model;
      readiness check (`profiles.create`, `setup.runtime_check`) (L)
- [ ] **A10** Avatar picker: shapes and faces, upload, generate (`image.generate`), pet gallery (L)
- [ ] **A13** Skills: search and install (`skills.manage`) (M)
- [ ] **A14** MCP servers: add, API key, test, OAuth sign-in (`mcp.servers.*`) (L)
- [ ] **A17** Open a bot's recent session (routine runs, side threads) (M)
- [ ] **B3** Regenerate, edit a sent message, restore from a message (backing RPC to be confirmed) (M–L)
- [ ] **B4** Branch into a new chat (`session.branch`) (M)
- [ ] **B10** Actionable error cards: Retry, Switch provider, Copy diagnostics (M)
- [ ] **B11** More attachment types: URL, folder, long paste as a file, image zoom (S–M)
- [ ] **B13** Find in chat (⌘F) (M)
- [ ] **B14** Approval mode menu (S–M)
- [ ] **B15** Export a conversation (S)
- [ ] **B16** Changed-files card (M)
- [ ] **B17** Voice: dictation and read aloud (L)
- [ ] **C1.8** Room availability ("N of M available"), local room picture (S)
- [ ] **C2.1** Polish Group Chat attachments (already sent as file references) (S)
- [ ] **C2.2** Change room members: create a new room with the new members and carry a summary over (M)
- [ ] **C2.3** Spike: can room members' clarifying questions be answered from the app? (S)
- [ ] **D3** Menu bar extra: bot status and quick send (M)
- [ ] **D4** Global hotkey "quick ask" panel (M)
- [ ] **D6** macOS Services / Share: "Send to Hermes bot" (M)
- [ ] **D7** Shortcuts actions: "Ask <bot>", "Send to group" (M)
- [ ] **D9** Open a Bot Chat or room in its own window (M)
- [ ] **D10** Search across Bot Chats and rooms (M)
- [ ] **D12** "Summarize since I left" for rooms (M)
- [ ] **D13** Room templates: saved member sets and an opening prompt (S)
- [ ] **D15** Mute notifications per bot or room (S)
- [ ] **E2** First-run onboarding: Hermes missing, no model configured, only one bot (M)
- [ ] **E3** Distribution: Developer ID notarization, auto-update, Intel testing (M)
- [ ] **E4 / D17** One-time, read-only import of the desktop app's group chats (M)
- [ ] **K4** Kanban filters and search: by profile, archived, group Running by profile (S)
- [ ] **K5** Kanban workers: active workers, inspect run, terminate, reclaim (M)
- [ ] **K6** Kanban AI actions: estimate, decompose, specify, reassign (M)
- [ ] **K7** Kanban boards and orchestration settings: create/rename/delete, export/import, orchestrator profile,
      default assignee, model override (M)
- [ ] **K9** Kanban integrations: open the assignee's Bot Chat from a card, "Create task from message" in rooms,
      notifications when a card finishes or is blocked, Boards section in the sidebar (M)

## Backlog

Kept for reference; not planned.

- **A18** Screen: live view of a bot's virtual desktop (`display.*`) (XL)
- **B18** Emoji reactions (S)
- **C1.9** Show disbanded rooms (`include_disbanded`) (S)
- **D11** Spotlight indexing of conversations (M)
- **D14** Token and cost usage per bot (M)
- **D16** Undo send in rooms (S)
- **Group Chat features hosted rooms do not support:** holding/pausing individual bots (`@all stop` / resume),
  "this session" / "always" approvals, compressing a member's history. These would need either backend support or a
  second, client-orchestrated room mode (XL).

## Open questions

- **B3**: which gateway RPC backs regenerate / edit / restore.
- **C2.3**: whether room members' clarifying questions reach the app at all.
- **K0**: whether the kanban plugin API accepts the session token the app already holds.
- **K8 / E1**: whether `hermes serve` also runs the kanban dispatcher, or only `hermes gateway` does.
