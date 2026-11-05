# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Group Chat: rename a room from the room menu (Rename…). The new name shows at once and goes back if Hermes
  refuses it, with the reason above the composer.
- Group Chat threads: Reply in thread opens the thread beside the room with its own composer; the room
  composer keeps writing to the whole room. A thread started on a room message quotes it in its first reply,
  since bots only see their own thread. Thread messages are labelled in the room timeline, and a message with a
  thread shows its reply count.
- Group Chat message actions on hover or right-click: Reply to @bot (puts the mention in the right composer)
  and Copy.
- Group Chat rows in the sidebar show the last message and its age, and an amber badge when a bot wrote
  `@user` that you have not answered or seen, or waits on your approval. Composer drafts are kept per room
  and per thread while the app runs.
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
