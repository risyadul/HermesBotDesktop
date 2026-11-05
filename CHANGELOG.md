# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
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
- Clickable links in messages (http and https only).
- `scripts/package-app.sh` builds an ad-hoc signed `HermesBot.app` and zip; a release workflow attaches it to
  GitHub Releases for `v*` tags.
- GitHub Actions CI (build and test on macOS), pull request template, Code of Conduct and this changelog.

### Changed
- When the backend connection drops, the app shows a failure with Try Again instead of staying in a dead
  state; Try Again reconnects.
- Quit cleanup finishes within about 5 seconds, then the app exits. Bot Chat sessions opened during quit are
  no longer left behind.
- Bot Chats are no longer deleted when you quit: the chat is the bot's one continuous conversation, and quitting
  only disconnects. This replaces the earlier behavior of deleting 1:1 chats on quit.
- Group Chat stays text-only for your own messages: the Hermes backend's group rooms accept only text, so you
  cannot attach files there (bots can still send you files).
- Bot monograms are unique among visible bots (for example "reviewer" and "researcher" no longer both show
  "RE").
- Avatars that failed to load are retried after reconnecting.
- A Group Chat room is disbanded after a sync failure only for the backend's explicit "room gone" error, not
  for any message that happens to contain "not found".
- Documentation no longer contains internal project-management references; examples use neutral profile
  names.

### Security
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
