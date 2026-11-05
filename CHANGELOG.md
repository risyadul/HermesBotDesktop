# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Distribution (E3):
  - **Check for Updates…** in the app menu and a daily check (**Settings → Updates**, on by default): asks
    GitHub's Releases API for the latest release (unauthenticated, no token), compares it with the app's version
    and shows the release notes with **Download**, which opens the release page in the browser. Nothing is
    downloaded or installed by the app. A release is shown once by the daily check; its failures stay quiet.
  - Releases are **universal** (Apple silicon + Intel): `scripts/package-app.sh <version> --universal` builds both
    architectures and joins them with `lipo`; the release asset is now `HermesBot-<version>-macos-universal.zip`
    (was `-macos-arm64.zip`). The script also has `--dry-run` and `--help`.
  - Developer ID signing (hardened runtime, `scripts/HermesBot.entitlements`) and notarization (`notarytool`,
    stapled) when `DEVELOPER_ID_APPLICATION` / `NOTARY_PROFILE` are set; the release workflow uses them when the
    repository secrets exist (docs/development.md, "Release process") and stays ad-hoc signed otherwise. Not yet
    run for real: it needs the maintainer's Developer ID.
  - CI runs the build and the tests on an Intel runner (`macos-15-intel`) as well.
- Group Chat rooms can be pinned and reordered in the sidebar (C1.4): right-click a room for **Pin to Top** /
  **Unpin**, **Move Up** and **Move Down**, or drag it onto another room. Pinned rooms come first. Kept on this
  Mac only (UserDefaults), never sent to Hermes.
- Room availability and picture (C1.8): the room header reads "N of M available" (members whose bot still exists
  and whose last turn did not fail or wait on a retry; hover for who is out). Room menu → **Choose Picture…** /
  **Remove Picture** sets a local picture (256 px PNG in Application Support) shown instead of the members'
  avatars in the toolbar and sidebar; it is deleted when the room is disbanded.
- Group Chat attachments (C2.1): click a file or image for Quick Look; right-click for Quick Look, Open, Reveal in
  Finder and Copy Path. Chips show kind and size, and a copy that was deleted says the bots can no longer open
  it. Files that can run code are still only revealed in Finder, and only the app's own copies are checked
  before a click.
- C2.3 spike, documented in [docs/groups-contract.md §8](docs/groups-contract.md): room members' clarifying
  questions cannot be answered from the app. `groups.state` reports only approvals and retries, and no
  `groups.*` method answers a clarify; a member that needs the user should write `@user` (the "Needs you"
  badge). Answering them is in the backlog (C2.4, needs a backend change).
- Bot Chat (B1, B5, B6, B12, B13, B15):
  - **@mention other bots** with autocomplete (the roster, never the bot itself). A prompt that tags bots gets
    Hermes Desktop's identification note for the model, which contacts them with its `message_agent` tool; the
    app never forwards the text itself. The note is hidden again when the history loads.
  - **Times on hover** next to Copy, and the **turn duration** under a reply watched from its start.
  - **Scroll-to-bottom button** with a count of new messages while scrolled up; new output no longer pulls the
    view down while you read.
  - **Prompt history** with ↑/↓ at the start/end of the composer (per bot, from the chat's own messages) and
    **per-bot drafts** kept across launches (size-capped).
  - **Find in chat (⌘F)**: match count, previous/next (⇧⌘G/⌘G), highlights, Esc closes.
  - **Export Conversation (⇧⌘E)** to Markdown, with tool summaries; tool arguments, results and reasoning
    left out, tokens masked.
- macOS integration (D5, D8, D9, D10, D13, D15):
  - **⌘1…⌘9** select the first nine group chats and bots the sidebar shows (listed in a new **Go** menu), and
    **⌘K** opens a quick switcher with fuzzy search over group chats, bots and boards.
  - **Search Messages (⇧⌘F)**, also Tab in the switcher: searches the Bot Chats opened since launch and every
    group chat's loaded log or recent events, shows each hit with its context, and opens the chat scrolled to
    the message. Nothing extra is fetched for a search.
  - **Quick Look** for files bots send and Group Chat attachments (click an image, Space over a tile, or the
    context menu), and **drag them out** to Finder. Both re-run the file safety check first; reveal-only formats
    are not previewed.
  - **Open in New Window** for a Bot Chat or group chat (row menu, ⌘-double-click, or the Go menu). The window
    uses the same chat and room models as the main window, so there is no second connection or poller; a room
    shown in two windows keeps polling until both have closed it. These windows reopen at the next launch.
  - **Room templates:** Save as Template… on a group chat keeps its bots and an opening prompt; File → New Group
    Chat from Template prefills New Group Chat and puts the prompt in the new room's composer (not sent).
  - **Mute Notifications** per bot or group chat (row menu). Muted items post no notifications, approvals
    included, but still count in the Dock badge.
- First-run setup screens (E2) instead of a bare error: **Install Hermes Agent** when no `hermes` is found
  (docs link, the `HERMES_BOT_APP_HERMES_BIN` override with a Copy button, the places checked, Try Again);
  **Choose a model for Hermes** when the backend answers but `setup.runtime_check` (read-only) says no model can
  be served (`hermes setup` / `hermes model`, Check Again); and, with a single bot, Open Bot Chat plus the
  `hermes profile create <name>` / `hermes -p <name> setup` commands for a second bot, with Copy buttons. The app
  never runs them. Other connection failures keep the "Can't reach Hermes" screen.
- **File → Import from Hermes Desktop…** (E4 / D17): lists the group chats Hermes Desktop saved to the default
  profile (`ui_meta` → `hermes-bots-groups`, read with `profiles.list`; never written) and copies the chosen
  ones into a read-only **Desktop archive** sidebar section (collapsible, hidden when empty) kept by this app.
  An archived room shows its members and saved messages; **Continue in a New Room…** opens New Group Chat
  prefilled with its name and members and puts a quoted carry-over into the new room's composer (not sent).
- Kanban AI actions on a card: **Estimate** (rough tokens and size), and on Triage cards **Decompose…** (lists
  the subtasks it created) and **Specify…** (rewrites the card and moves it to Todo), both confirmed first.
  A **Model** field pins a card's model and reasoning effort (Profile default otherwise).
- Kanban board management from the board's ••• menu: New, Rename, Delete (archives; never `default`, a warning
  for Hermes' current board), Export to a `.tar.gz` and Import as a new board, and **Orchestration
  Settings…** (orchestrator profile, default assignee, auto-decompose, queue subtasks right away).
- Kanban integrations: **Create Task from Message…** in Group Chat and Bot Chat message menus (prefilled New
  Task sheet with a board picker), **Open Bot Chat with @…** for a card's assignee, and notifications when a
  card you created in the app, or marked **Notify When Done or Blocked**, finishes or gets blocked.
- Bot rows like Hermes Desktop's roster: newest activity first (pinned bots on top), the last message and its
  age, and a dot for activity you have not opened (routine runs, replies elsewhere, messages from other Hermes
  apps). Opening the Bot Chat clears it; what you have seen is remembered across launches. Read from one
  `profiles.list` every 10 seconds, never by opening chats.
- Sections (folders) for bots: create, rename, reorder, collapse and delete (with Undo) sections; file a bot
  with Move to Section or by dragging its row onto a section. Membership is saved in each bot's profile with
  Hermes Desktop's keys (`sectionId` / `sectionName`), so both apps show the same folders, and sections made in
  Hermes Desktop appear here.
- "Needs attention" badge on a bot whose last Bot Chat or Group Chat turn failed with something you must fix
  (sign in again, quota or balance, provider not configured, blocked), with the reason as its tooltip. Same
  rules as Hermes Desktop; temporary failures never show it and the next good reply clears it.
- Open Recent Session (right-click a bot): the bot's newest conversation other than its Bot Chat, such as a
  routine run or a side thread, read-only in a sheet. Nothing is resumed or written.
- An empty Bot Chat shows the bot's face large, its name and "Say something to get started."
- Manage bots without the CLI (right-click a bot, or the ••• menu in Bot details):
  - **Edit…** a bot's title, description and avatar (PNG/JPEG up to 15 MB, saved as a 256 px square), and under
    Advanced its model and provider (Hermes' model list, typed in, or Inherit), skills, toolsets, MCP servers
    and SOUL. Only changed fields are saved; a field that fails says why and the others are kept. Expensive
    models ask before switching. A saved SOUL keeps the bots' "Messaging other agents" section like Hermes
    Desktop. The title is the one Hermes Desktop shows (`ui_meta` → `hermes-bots` → `title`), and bot rows now
    show it.
  - **Duplicate** a bot as `<name>-2` (clone of its profile, plus its title "(copy)" and avatar), with progress
    and an Open button.
  - **Delete…** a bot after a confirmation that names its profile folder (`hermes profile delete --yes`); the
    default profile cannot be deleted.
- Routines per bot: **Routines** in a Bot Chat's toolbar lists the bot's scheduled tasks (Hermes cron jobs) with
  pause/resume, delete (asks first) and details (schedule, next and last run, last result, delivery, errors).
  New Routine has Hermes Desktop's schedule picker (once in N, hourly, daily, weekdays, weekly, monthly,
  interval, raw schedule), Stop after N runs, results to the run history or the bot's Bot Chat, and
  continuity; routines are stored exactly as Hermes Desktop stores them. A note says when routines stop with
  the app because it started Hermes.
- Kanban filters: one profile at a time, Show archived, and Group Running by profile.
- Kanban workers: the board's **Workers** list shows which bot runs which card, for how long and its last
  heartbeat; inspect a run (run record, worker process, log), terminate it or reclaim the task (both ask first).
- Sidebar filter: a field at the top of the sidebar narrows group chats, bots and boards by name, @handle,
  member, description or model. Return or ↓ jumps to the first match; Esc clears it. ⌘F stays free.
- Right-click a bot for Open Bot Chat, Pin to Top / Unpin, Hide Bot / Unhide Bot and Copy @handle. Pinned
  bots stay at the top; hidden bots move to a collapsible "Hidden (n)" section. Both are saved in the bot's
  profile (`ui_meta` → `hermes-bots`, with Hermes Desktop's keys and revision check), so Hermes Desktop shows
  the same pins and hidden bots; no other profile setting is touched.
- Notifications while the app is in the background: a finished Bot Chat reply, a bot asking for approval or
  an answer (Bot Chat and Group Chat), and a Group Chat round that ended with `@user`. Approvals can be
  answered from the notification (Approve Once, Deny). Permission is asked the first time. Turn them off in
  Settings → Notifications → Show notifications (the `notificationsEnabled` default).
- Dock badge with the number of approvals and questions waiting in Bot Chats and Group Chats.
- Group Chat: rename a room from the room menu (Rename…). The new name shows at once and goes back if Hermes
  refuses it, with the reason above the composer.
- Group Chat: change members from the room menu (Change Members…). Hermes has no way to change a room's members,
  so the app creates a new room with the chosen bots and the same name, posts a context note quoting the
  previous room's last 12 messages (capped, one safe line each, file names only), then keeps the previous room
  (optionally renamed "… (old)") or disbands it, and opens the new room.
- Group Chat threads: Reply in thread opens the thread beside the room with its own composer; the room
  composer keeps writing to the whole room. A thread started on a room message quotes it in its first reply,
  since bots only see their own thread. Thread messages are labelled in the room timeline, and a message with a
  thread shows its reply count.
- Group Chat message actions on hover or right-click: Reply to @bot (puts the mention in the right composer)
  and Copy.
- Group Chat rows in the sidebar show the last message and its age, and an amber badge when a bot wrote
  `@user` that you have not answered or seen, or waits on your approval. Composer drafts are kept per room
  and per thread while the app runs.
- Bot Chat: Copy message and Copy Full Response (hover or right-click a message).
- Bot Chat while the bot is replying: Return steers the running reply (`session.redirect`), ⌘Return queues
  the message. A queue panel above the composer lists waiting messages (Edit, Send now, Delete); they are
  sent one at a time when the reply finishes, and Stop pauses them until Resume. A correction the bot
  refuses is queued instead of lost.
- Bot Chat model and reasoning effort per chat, under the composer, from the backend's model list. Changes
  apply to that chat's session only (`--session`); no profile config is written.
- Bot Chat context gauge (click for the breakdown by category) and a "Compacting the conversation…" status
  while Hermes compacts it.
- Group Chat Activity panel (⌥⌘I): what each bot in the room is doing right now, its recent tool calls with
  arguments and results, its reasoning and errors, with its turn status kept beside the live status. The
  detailed view uses the open-source Bot Activity Hermes plugin; without it the panel shows each bot's turn
  status and a "This round" list from the room log, and offers to install the plugin (pinned commit, enabled for
  every bot, including bots where it was disabled). An installed copy that isn't pinned to the reviewed commit
  is never switched on; the panel offers to reinstall the pinned version instead. Turning it off disables it in
  every bot profile and removes it from Hermes (the bots' copies stay on disk, inactive, until Enable turns them
  back on). Enable and Turn Off run once for the whole app, and polling pauses while the window is covered or
  the app is hidden.
- Kanban boards in the sidebar (Boards section, with running and blocked counts). A board shows its lanes and
  cards, refreshes every few seconds while open, and switches between boards. Cards open into a details
  panel (description, latest summary, dependencies, attachments, comments, runs, worker log); drag a card to
  another lane, or use its menu to assign it, set its priority, archive it, or copy its id. Attach files with
  the paperclip or by dropping them (up to 25 MB), open or delete them; scripts and apps are only shown in
  Finder. On a running card the comment box messages the worker, and Requeue with note restarts the task
  with your note. New Task creates a card. The
  board header says whether the kanban dispatcher (`hermes gateway`) is running, starts it when it is
  installed, and shows the install command when it is not.
- Settings → Keep Hermes running in the background: an opt-in LaunchAgent keeps `hermes serve` running after you
  quit, so Group Chat rounds and routines continue; the app attaches to it on launch.
- Bot Chat is now the same chat Hermes Desktop uses for that bot: opening it continues the existing history
  instead of starting a new conversation, and bots can message other bots from it. If the app cannot confirm
  whether the chat exists, it does not start a new one. If the chat is running in another Hermes app, the app
  says so.
- Slash commands in Bot Chat: type `/` to see the commands your bot offers, including skills. `/new`, `/reset`
  and `/clear` compact the conversation instead of resetting it; `/compress` and `/stop` work; commands that
  only make sense in Hermes Desktop or the terminal are not offered.
- Tool activity in Bot Chat, as in Hermes Desktop: each call reads as what it did ("Ran git status",
  "Atlassian · getjiraissue") with a count and duration, and expands to its command, arguments, diff and
  output. Two or more calls in a row fold into one collapsible line such as "Ran 2 commands, used 1 tool".
- The bot's reasoning shows as "Thinking" while it streams and as a collapsed "Thought" afterwards,
  including for past messages.
- Messages render as markdown in Bot Chat and Group Chat: headings, tables, numbered and nested lists,
  quotes, rules, and code blocks with a Copy button.
- Bots can ask you questions in Bot Chat: approval requests (once, for the session, always, or deny),
  clarifying questions, and password or secret prompts. Requests the app cannot show are left for other
  Hermes apps to answer.
- Attachments in Bot Chat: images, PDFs (up to 25 pages) and other files. Images and PDFs larger than the
  limits (25 MB and 50 MB) are refused with a message.
- Files that bots send (`MEDIA:` references) show in Bot Chat and Group Chat: images inline, other files as
  chips. A file opens only when you click it, after a safety check that refuses credentials and system
  locations.
- The app finds `hermes` automatically: `~/.local/bin`, every directory on the `$PATH` of the process that
  launched the app, then Homebrew locations (`/opt/homebrew/bin`, `/usr/local/bin`). An app opened from
  Finder gets launchd's minimal `$PATH`, so the fixed locations are what find it there.
  `HERMES_BOT_APP_HERMES_BIN` (an absolute path) replaces the search instead of being its first step. The
  error shown when it is missing names the override variable; a relative override or a directory gets its
  own clear error. A binary in a group/world-writable directory without the sticky bit is refused.
- Group Chat availability check: when the backend lacks `groups.*`, "+" is disabled and the app shows
  "Group Chat needs Hermes Agent v2026.9.14 or later".
- Clickable links in messages (http and https only), blue and underlined, also in your own messages. In Group
  Chat, @mentions of the room's bots are blue.
- `scripts/package-app.sh` builds an ad-hoc signed `HermesBot.app` and zip; a release workflow attaches it to
  GitHub Releases for `v*` tags.
- GitHub Actions CI (build and test on macOS), pull request template, Code of Conduct and this changelog.

### Changed
- Group Chat: `@user` in messages is amber and semibold (bot mentions stay blue), so a bot asking for you stands
  out.
- Group Chat notifications and the sidebar rows share one background check of the rooms (5–15 s) instead of two;
  notifications behave as before.
- Hidden bots in "Hidden (n)" follow the same order as the rest of the list (pinned, then newest activity)
  instead of server order.
- Settings → Keep Hermes running in the background asks before turning on and names the `hermes` it will run
  (with a warning when `HERMES_BOT_APP_HERMES_BIN` chose it). While the app runs its own backend it offers
  **Switch Now** (stop it, start the background Hermes, reconnect) or **At Next Launch** (install only; the next
  launch starts it), so two backends never run at once. Turning it off while connected to it asks first and
  reconnects afterwards. A job launchd has loaded but that is not running now shows **Loaded but not
  running** with **Start**, instead of "Running".
- The board header's dispatcher chip and Settings → Kanban dispatcher share one status, so they always agree.
- Kanban refreshing (open board, board list, dispatcher status) pauses while no main app window is on screen
  (the Settings window does not count) and resumes when one is.
- A board deleted or archived while open says so, stops refreshing, refuses changes and offers **Go to Another
  Board**; it leaves the sidebar (and the selection) at the next board list refresh.
- The sidebar says **Boards unavailable on this connection** instead of "Not loaded yet" when the backend
  gives no REST access.
- When the backend connection drops, the app shows a failure with Try Again instead of staying in a dead
  state; Try Again reconnects.
- Quit cleanup finishes within about 5 seconds, then the app exits. Bot Chat sessions opened during quit are
  no longer left behind.
- Bot Chats are no longer deleted when you quit: the chat is the bot's one continuous conversation, and quitting
  only disconnects. This replaces the earlier behavior of deleting 1:1 chats on quit.
- Attachments in Group Chat: the backend's rooms take text only, so attached files (paperclip, ⌘V, drag and
  drop; up to 10 files of 50 MB) are copied to the app's Application Support folder and the message names the
  copies, which the room's bots open with their file tools. The app shows them as attachments; the copies are
  deleted when the room is disbanded.
- Bot monograms are unique among visible bots (for example "reviewer" and "researcher" no longer both show
  "RE").
- Avatars that failed to load are retried after reconnecting.
- A Group Chat room is disbanded after a sync failure only for the backend's explicit "room gone" error, not
  for any message that happens to contain "not found".
- Documentation no longer contains internal project-management references; examples use neutral profile
  names.

### Security
- Plugin REST answers (Kanban, Bot Activity) are read as a stream and refused once larger than 8 MB (downloads:
  their own cap), so a misbehaving route cannot make the app buffer without bound. Card texts longer than
  64,000 characters are truncated before markdown rendering.
- `+` in plugin REST query values is sent as `%2B`, so the server does not read it as a space.
- The background Hermes log folder is set to 0700 and its log file created 0600.
- The background Hermes install refuses when the `hermes` found differs from the one you confirmed.
- The app only connects to backends on loopback (127.0.0.0/8, ::1, localhost); other hosts are rejected.
- Refuses a `hermes` binary that is group/world-writable or owned by someone other than you or root.
- Rendezvous lock directory must not be group/world-writable and is read without following symlinks; the
  identity probe refuses HTTP redirects.
- `serve.log` is created with mode 0600 in a 0700 directory; start-up errors point to its path.
- File references from bots are checked on a case- and width-folded path (so `/Volumeſ` or
  `/System/Volumes/Data/…` spellings cannot dodge the checks), `/.nofollow`-style paths are refused, and
  symlinks are followed one hop at a time with every target checked before it is touched.
- Approval commands show more invisible characters by code point, stacked combining marks, long runs of
  blank lines, are always laid out left to right, and are flagged when they contain non-ASCII characters.
- Archives, OpenDocument and KML/KMZ files sent by bots are revealed in Finder instead of opened.

### Fixed
- Bot Chat: the Routines toolbar button opens its sheet again (it was presented from inside the toolbar item and
  never appeared).
- Edit bot sheet: with Advanced open the sheet uses the window's height (less 80 pt), its fields scroll and
  Cancel / Save stay pinned at the bottom; skills, toolsets, MCP servers and SOUL were cut off before. The Title
  field shows the bot's current name as its placeholder when no title is set.
- Bot Chat context gauge shows as soon as the chat opens (Hermes' read-only context estimate, as Hermes Desktop
  does) instead of after the first reply.
- Group Chat Activity panel: a run of "Turn finished" separators with nothing between them reads as one
  ("3 turns finished · 4.3–15s").
- Running `launchctl` or `hermes gateway start` no longer hangs when a process they start keeps the output
  pipe open, and stops the command when the caller gives up.
- A card action no longer fetches the board again after the board view has closed.
- A dispatcher Start or status check still in flight across a reconnect no longer overwrites the new state, and
  Start stays disabled until that start has finished.
- Turning off activity tracking from one Group Chat while another is enabling it is refused instead of silently
  joining the enable.
- A failing Bot Activity setup check is retried after a minute instead of on every poll; Try Again restarts
  polling with the backoff reset.
- Toggling Background Hermes off twice quickly removes it once.
- A Kanban comment draft stays with its card; a send finishing after switching cards no longer clears the
  other card's draft.
- Crash when stopping a backend the app started while it was still logging.
- A malformed `session.create` response can no longer produce an empty session id.
- A Bot Chat that fails while opening closes and deletes the half-created session.
- Group room listing stops if the backend does not advance its paging offset.
- Calls made after the connection closed fail cleanly; the WebSocket session is released on close.
- Missing `profiles` / `rooms` keys in backend responses are logged as schema warnings.
- Bot Chat no longer misses a reply, question or approval that arrives while the chat is still opening.
- A reply that was already running when the Bot Chat opened can no longer show twice or keep the chat
  blocked; Stop always unblocks it.
- A message that failed to send is no longer shown twice when you send it again.
- Hermes' "waiting for the provider" notices no longer show up as bot reasoning.
- Opening a bot with a long Bot Chat history no longer drops the connection with "Message too long": the app
  accepts backend messages up to 128 MB instead of 1 MB.
- Opening a Group Chat with long messages no longer shows an empty timeline until you scroll, and opens
  without a noticeable pause; Bot Chat transcripts use the same layout.
