# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
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
- The UI states plainly that 1:1 chats are deleted on quit (unless `HERMES_BOT_APP_KEEP_SESSIONS=1`). They
  are deleted on a normal quit; they may be kept if the connection was lost or quit hit the 5-second deadline.
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

### Fixed
- Crash when stopping a backend the app started while it was still logging.
- A malformed `session.create` response can no longer produce an empty session id.
- A Bot Chat that fails while opening closes and deletes the half-created session.
- Group room listing stops if the backend does not advance its paging offset.
- Calls made after the connection closed fail cleanly; the WebSocket session is released on close.
- Missing `profiles` / `rooms` keys in backend responses are logged as schema warnings.
- Opening a Group Chat with long messages no longer shows an empty timeline until you scroll; Bot Chat
  transcripts use the same layout.
