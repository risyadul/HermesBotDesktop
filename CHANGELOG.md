# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Highlights
- **Bot Chat is shared with Hermes Desktop:** the same chat, history kept, never deleted on quit.
- **Manage bots without the CLI:** New Bot, Edit (avatar, model, skills, MCP servers, SOUL), Duplicate, Delete.
- **Bot Chat tools:** steer or queue while a bot replies, regenerate/edit/restore, branch, find, export, voice.
- **Group Chat:** threads, rename, change members, attachments, templates and a live per-bot Activity panel.
- **Kanban:** boards, cards, workers, AI actions and board management from the sidebar.
- **Routines:** each bot's scheduled tasks, with Hermes Desktop's schedule picker.
- **Mac integration:** menu bar extra, Quick Ask (⌃⌥⌘Space), Services, Shortcuts, notifications, Dock badge.
- **Keep Hermes running in the background** after you quit (opt-in LaunchAgent).
- **Universal (Apple silicon + Intel) releases** and an update check.

### Added

#### Bot Chat
- **Shared chat:** Bot Chat is the chat Hermes Desktop uses for the bot; opening it continues the history. If the
  app can't confirm the chat exists it starts none; a chat running in another Hermes app is reported.
- **Markdown** in Bot Chat and Group Chat (headings, tables, lists, quotes, code blocks with Copy); http(s) links
  are clickable, also in your own messages.
- **Tool activity** reads like Hermes Desktop ("Ran git status", count, duration) and expands to command,
  arguments, diff and output; calls in a row fold into one line.
- **Reasoning** shows as "Thinking" while it streams and as a collapsed "Thought" afterwards, also for history.
- **Requests from bots** as cards: approvals (once, session, always, deny), clarifying questions and secret
  prompts. Requests the app can't show are left for other Hermes apps.
- **Slash commands** (`/`, including skills). `/new`, `/reset` and `/clear` compact instead of resetting;
  `/compress` and `/stop` work; Desktop- or terminal-only commands are not offered.
- **Attachments:** images (25 MB), PDFs (50 MB, 25 pages) and other files; **Attach Folder…** / **Attach URL…**
  send references; a paste over 3,000 characters becomes a file.
- **Files from bots** show inline or as chips and open only on click, after a safety check. Images in replies
  open in a zoom-and-pan window.
- **While the bot replies:** Return steers the reply, ⌘Return queues. The queue panel edits, sends now or deletes;
  Stop pauses it until Resume. A correction the bot refuses is queued, not lost.
- **Model and reasoning effort per chat** (this chat's session only), a **context gauge** with a breakdown, and a
  "Compacting the conversation…" status.
- **Approval mode** menu (Manual, Smart, Off): the bot profile's setting, as in Hermes Desktop.
- **Regenerate, Edit Message, Restore from Here** rewind the chat as Hermes Desktop does (later messages are
  archived in both apps; asks first). **Branch into New Chat** opens a new session in a sheet.
- **Error cards** (Retry, Switch Provider, Copy Diagnostics, Dismiss) and a **Changed files** card with per-file
  diffs and Reveal in Finder.
- **@mention other bots** with autocomplete; the bot reaches them with its own `message_agent` tool. The app never
  forwards your text.
- **Copy** and **Copy Full Response**, **times on hover**, **turn duration**, and a **scroll-to-bottom** button with
  a new-message count; new output no longer pulls you down while you read.
- **Prompt history** (↑/↓), **per-bot drafts** kept across launches, **Find in chat** (⌘F) and **Export
  Conversation** (⇧⌘E) to Markdown (no tool arguments, results or reasoning; tokens masked).
- **Voice:** dictation (mic button, also in Group Chat) and **Read Aloud**, optionally automatic, with the macOS
  engines. See [Using Bot Chat](README.md#using-bot-chat).
- An empty Bot Chat shows the bot's face large, its name and "Say something to get started."

#### Group Chat
- **Threads:** Reply in thread opens the thread beside the room with its own composer; the first reply quotes the
  message. Thread messages are labelled in the room, with reply counts.
- **Rename…** and **Change Members…** (a new room with the chosen bots and a note quoting the last 12 messages;
  the old one is kept, optionally renamed, or disbanded). See [Using Group Chat](README.md#using-group-chat).
- **Message actions:** Reply to @bot and Copy. `@user` is amber, mentions of bots are blue.
- **Sidebar rows** show the last message and its age, with an amber badge when a bot wrote `@user` or waits on
  your approval. Drafts are kept per room and thread while the app runs.
- **Pin and reorder rooms** (kept on this Mac), **"N of M available"** in the header, and a local **room picture**.
- **Attachments** (up to 10 files of 50 MB): copied to Application Support and named in the message, since rooms
  take text only. Quick Look, Open, Reveal in Finder, Copy Path; deleted with the room.
- **Templates:** Save as Template… keeps the bots and an opening prompt; New Group Chat from Template prefills a
  room and puts the prompt in the composer, unsent.
- **File → Import from Hermes Desktop…** copies Desktop's saved group chats into a read-only **Desktop archive**;
  **Continue in a New Room…** carries members and recent messages over.
- Without Group Chat support in the backend, "+" is disabled and the app asks for Hermes Agent v2026.9.14 or later.
- Clarifying questions from room members can't be answered in the app (Hermes doesn't pass them on); a bot that
  needs you should write `@user`. Details: [groups contract §8](docs/groups-contract.md).

#### Bots
- **New Bot…** (+ or File menu): name, title, description, avatar; Advanced adds clone from, model, SOUL, shared
  keys, skip bundled skills. Ends with a readiness check and "Say hello". See [Managing bots](README.md#managing-bots).
- **Edit…** title, description and avatar; Advanced: model and provider (or Inherit), skills, toolsets, MCP servers,
  SOUL. Only changed fields are saved; expensive models ask first.
- **Avatar picker:** Shape faces (Hermes Desktop's shapes and twelve colours, Randomize, Monogram), Upload (PNG/JPEG
  up to 15 MB), Generate (when an image generator is set up) and the Pet gallery. Faces match Desktop.
- **Find Skills…** searches the skills hub and installs a skill after you confirm.
- **MCP servers:** on/off, **Add Server…** (command or URL), **API Key…** (in the bot's `.env`, never logged),
  **Test**, and **Sign In** for OAuth servers.
- **Duplicate** (`<name>-2`, title "(copy)", same avatar) and **Delete…** (names the profile folder first; never
  `default`).
- **Roster like Hermes Desktop's:** newest activity first, last message and age, an unread dot remembered across
  launches; a file in the preview shows its name.
- **Bot menu:** Pin to Top, Hide Bot (a "Hidden (n)" section), Move to Section, Copy @handle. **Sections** support
  drag and drop and Undo on delete. Pins, hides and sections are shared with Hermes Desktop.
- **Needs attention** badge when a bot's last turn failed with something you must fix (sign-in, quota, provider,
  blocked); temporary failures never show it.
- **Open Recent Session:** the bot's newest conversation other than Bot Chat (a routine run, a side thread),
  read-only.
- **Routines:** list, pause, resume, delete and inspect a bot's scheduled tasks; New Routine with Hermes Desktop's
  schedule picker, Stop after N runs, delivery to Bot Chat and continuity.

#### Kanban
- **Boards** in the sidebar with running and blocked counts. Card details: description, summary, dependencies,
  attachments, comments, runs and worker log. See [Kanban](README.md#kanban).
- **Card actions:** New Task, drag between lanes, assign, priority, archive, copy id, attachments (25 MB),
  comments, messages to the running worker, Requeue with note.
- **Filters** (one profile, Show archived, group Running by profile) and **Workers** (who runs which card,
  heartbeats, Inspect Run, Terminate Run, Reclaim Task).
- **AI actions:** Estimate, Decompose… and Specify… (both confirm first); a **Model** field pins a card's model and
  effort.
- **Board menu:** New, Rename, Delete (archives; never `default`), Export to `.tar.gz`, Import, and
  **Orchestration Settings…**.
- **From chats:** Create Task from Message… in Bot Chat and Group Chat, Open Bot Chat with @… for the assignee,
  and notifications when your cards finish or get blocked.
- **Dispatcher status** in the board header and Settings, with **Start** (`hermes gateway start`, which starts the
  whole messaging gateway) or the install command.

#### Mac integration
- **Notifications** while the app is in the background (finished replies, approvals, questions, `@user` rounds),
  with Approve Once / Deny; Settings switch. See [Notifications](README.md#notifications-and-the-dock-badge).
- **Dock badge** counting the approvals and questions waiting; **Mute Notifications** per bot or group chat.
- **Menu bar extra:** every bot and group chat with its state, the waiting count and a quick send. While it is on,
  closing the last window keeps the app running. See [Mac integration](README.md#mac-integration).
- **Quick Ask (⌃⌥⌘Space):** a floating panel from any app; configurable, no Accessibility permission needed.
- **Services → Send to Hermes Bot** for selected text and Finder files: sends only on Send, or fills a composer.
- **Shortcuts:** Ask Bot (returns the reply) and Send to Group Chat; the app must be running and connected.
- **Summarize since I left** in group chats: a chosen bot summarizes what's new, in its Bot Chat. Nothing is
  posted into the room.
- **Navigation:** a sidebar filter, ⌘1…⌘9 and a Go menu, a ⌘K quick switcher, and **Search Messages** (⇧⌘F)
  over the chats the app has loaded.
- **Open in New Window** for a Bot Chat or group chat; windows reopen at the next launch. Room and bot actions
  are also in the pane's toolbar menu.
- **Quick Look** and **drag out** to Finder for bot files and room attachments, after the file safety check.

#### Background & distribution
- **Keep Hermes running in the background** (opt-in LaunchAgent): rounds and routines go on after you quit. See
  [Keeping Hermes running](README.md#keeping-hermes-running).
- **First-run screens** for Hermes not found, no model configured and only one bot, with commands to copy (the app
  never runs them).
- **Finds `hermes`** in `~/.local/bin`, the launching `$PATH`, then Homebrew; `HERMES_BOT_APP_HERMES_BIN` replaces
  the search.
- **Check for Updates…** and a daily check (on by default) against GitHub Releases. Download opens the release
  page; nothing is installed. See [Updates](README.md#updates).
- **Universal releases:** `HermesBot-<version>-macos-universal.zip` (was `-macos-arm64.zip`);
  `scripts/package-app.sh` gains `--universal`, `--dry-run` and `--help`.
- Developer ID signing and notarization when configured; ad-hoc signed otherwise (no Developer ID yet).
- Release workflow for `v*` tags, CI on macOS (Apple silicon and Intel), PR template, Code of Conduct, this changelog.

#### Activity
- **Activity panel** (⌥⌘I) in Group Chat: what each bot is doing now, tool calls with arguments and results,
  reasoning and errors, next to its turn status. See [Group Chat activity](README.md#group-chat-activity).
- Without the Bot Activity plugin the panel shows each bot's turn status and a **This round** list from the room
  log, with **Enable Tracking…**.
- **Enable Tracking…** installs the plugin at a pinned commit for every bot; **Enable for N More Bots** covers bots
  added later. A copy not at the reviewed commit stays off (**Reinstall Pinned Version…**).
- **Turn Off Activity Tracking…** disables it in every profile and removes it from Hermes. Enable and Turn Off run
  once for the whole app; polling pauses while the panel is hidden.

### Changes to your Hermes data
Full list: [README](README.md#before-you-start-what-this-app-does-to-your-hermes-data).
- Pins, hides, titles, sections and looks go into each profile's `ui_meta["hermes-bots"]` (Hermes Desktop's
  keys); other `ui_meta` entries are untouched.
- New Bot, Edit, Duplicate and Delete change profiles; Delete removes the profile folder.
- Skill installs and MCP Add Server, API Key and Sign In apply at once, without Save.
- Approval mode writes the profile's `approvals.mode`; model and effort picks stay in the chat's session.
- Regenerate, Edit Message and Restore archive later messages of the shared Bot Chat; Branch creates a session.
- Routines are the bot's cron jobs; Bot Chat delivery and Summarize post into a bot's shared Bot Chat.
- Kanban edits change your boards and orchestration config; **Start** brings up the whole messaging gateway.
- Activity tracking installs or disables a plugin in every profile; the background LaunchAgent is opt-in.
- Quick sends (menu bar, Quick Ask, Services, Shortcuts) are real messages; the update check calls the GitHub API.

### Changed
- Bot Chats are no longer deleted when you quit; quitting only disconnects. Quit cleanup ends within about 5 s.
- Background Hermes asks first, names the `hermes` it will run, and offers **Switch Now** or **At Next Launch**;
  two backends never run at once. A stopped job shows **Loaded but not running** with Start.
- Group Chat: `@user` is amber and semibold; bot mentions stay blue.
- Group Chat notifications and sidebar rows share one background room check (5–15 s).
- Hidden bots follow the list's order (pinned, then newest activity).
- The dispatcher chip and Settings → Kanban dispatcher share one status.
- Kanban refreshing pauses while no main window is on screen; the first board list still loads.
- A board deleted or archived while open says so, stops refreshing and offers **Go to Another Board**.
- The sidebar says **Boards unavailable on this connection** when the backend gives no REST access.
- A dropped backend connection shows a failure screen with Try Again.
- Bot monograms are unique among visible bots ("reviewer" and "researcher" no longer both show "RE").
- Avatars that failed to load are retried after reconnecting.
- A room is disbanded after a sync failure only for the backend's explicit "room gone" error.
- Documentation drops internal project-management references and uses neutral example names.

### Security
- Only loopback backends (127.0.0.0/8, `::1`, `localhost`) are accepted.
- A `hermes` binary is refused if it or its directory is group/world-writable (unless sticky), or it is owned by
  someone other than you or root. Background install refuses a `hermes` other than the one you confirmed.
- Plugin REST answers over 8 MB are refused (downloads have their own cap); card texts over 64,000 characters are
  truncated before rendering. `+` in query values is sent as `%2B`.
- `serve.log` and the background log are created 0600 in 0700 folders.
- The rendezvous lock directory must not be group/world-writable and is read without following symlinks; the
  identity probe refuses redirects.
- Bot file paths are checked case- and width-folded, `/.nofollow` paths are refused, and symlinks are followed one
  hop at a time.
- Approval commands show invisible characters by code point, flag stacked marks, blank-line runs and non-ASCII
  text, and always lay out left to right.
- Archives, OpenDocument and KML/KMZ files from bots are revealed in Finder, not opened.
- MCP API keys, avatar uploads and approval answers are left out of the app's logs.
- Attached URLs and folders containing line breaks or control characters are refused, so they cannot add extra
  references to a prompt.
- Avatars and room pictures over 16,384 pixels on a side are refused before decoding; other images are decoded at
  most 4,096 px.
- MCP API keys cannot contain line breaks and their variable names must be identifiers; skill names allow at most
  one `/` and no `..`; MCP sign-in needs an https authorization page (http only on this Mac).
- Composer drafts that contain token-shaped text are not saved across launches.

### Fixed
- The app no longer hangs on "Connecting" at 100% CPU when the menu bar icon is on.
- The Boards list loads even when the app starts behind other windows.
- A bot's last message in the sidebar shows a sent file's name, not its local path.
- At the narrowest window with the inspector open the Bot Chat composer stays usable: the mic button (and Stop,
  if needed) moves to the row below the field.
- Settings scrolls when it is taller than the screen.
- Seen marks and "needs you" are not cleared while the window is hidden, minimised or covered; room polling and the
  Routines and Workers sheets pause meanwhile (notifications keep working).
- Space previews room attachments in Quick Look too; "Reveal in Finder" no longer appears twice.
- Bots created or deleted in Hermes Desktop or the CLI appear in or leave the sidebar within seconds.
- A legacy routine whose pause keeps failing is retried with a backoff, not on every refresh.
- The Routines toolbar button opens its sheet again.
- VoiceOver reads every Settings switch by its title (they were unlabeled "checkbox"es), and every other toggle
  and picker in sheets (New Bot, Routines, Kanban, Change Members, Quick Ask) names itself too.
- Kanban: the board actions menu reads "Board" next to its ••• symbol (the bare symbol looked like a remove
  button) and sits at the right end of the board header.
- New Bot and Edit bot sheets are as tall as their content (no empty gap above Cancel / Create with Advanced
  collapsed); only content taller than the window scrolls.
- Bot Chat: the approval pill reads "Approvals: Off" (Manual, Smart) instead of a bare "⚡ Off"; a narrow composer
  shows the short form.
- Search Messages: "No messages found" explains what is searched and suggests opening the chat; results update
  when a chat's messages load while the palette is open.
- Quick Switch (⌘K) ranks an exact title first, then title prefix, word or @handle start, substring and fuzzy
  matches; group chats matching only a member's name come last ("gen" no longer lists group chats above the
  bot generalist).
- Group Chat: the **Summarize** toolbar button opens its sheet (it did nothing); no other toolbar control presents
  a sheet, popover or alert from inside the toolbar.
- Edit bot: with Advanced open the sheet fits the window, scrolls, and keeps Cancel / Save visible; an empty
  Title shows the bot's name as placeholder.
- The context gauge shows as soon as a Bot Chat opens.
- Activity panel: consecutive "Turn finished" separators read as one ("3 turns finished · 4.3–15s").
- `launchctl` and `hermes gateway start` no longer hang on a child that keeps the output open.
- Kanban: no board refetch after the board closed; a comment draft stays with its card.
- A dispatcher Start or status check across a reconnect no longer overwrites the new state.
- Turning off activity tracking while another room enables it is refused instead of joining the enable; a failing
  setup check is retried after a minute.
- Toggling Background Hermes off twice quickly removes it once.
- Crash when stopping the app's backend while it was still logging.
- Bot Chat: no empty session id from a malformed reply; a chat that fails while opening is cleaned up.
- Bot Chat no longer misses a reply, question or approval that arrives while it opens, nor shows a reply already
  running twice; Stop always unblocks it.
- A message that failed to send is no longer shown twice when sent again.
- "Waiting for the provider" notices no longer show as bot reasoning.
- Long Bot Chat histories no longer drop the connection ("Message too long"): backend messages up to 128 MB.
- Group Chats with long messages open at once with their timeline (Bot Chat uses the same layout).
- Room listing stops if the backend does not advance its paging offset.
- Calls after the connection closed fail cleanly and release the WebSocket; missing `profiles` / `rooms` keys
  are logged.
