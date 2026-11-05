# Hermes Bot for macOS

A lightweight native macOS (SwiftUI) client for [Hermes Agent](https://github.com/NousResearch/hermes-agent),
focused on three things: **Bots**, **Bot Chat** (1:1, streaming) and **Group Chat** (2–6 bots in one room).

It is a thin client: all agent logic runs in the Hermes backend (`hermes serve`). The app talks to it over
the gateway WebSocket (JSON-RPC) and does not reimplement any agent behavior.

> **Independent project.** Not affiliated with or endorsed by Nous Research. "Hermes" refers to the
> Hermes Agent backend this app connects to.

**Status: early / pre-release.** Build from source, or download an ad-hoc signed (not notarized) zip from
[GitHub Releases](https://github.com/risyadul/HermesBotDesktop/releases); see [Download / packaging](#download--packaging).

<p align="center">
  <img src="docs/screenshots/screenshot-dark.png" alt="Hermes Bot macOS Group Chat (Dark Mode)" width="700">
  <br>
  <em>Native app with demo/mock data (Group Chat in Dark Mode)</em>
</p>
<details>
<summary>View Light Mode screenshot</summary>
<p align="center">
  <img src="docs/screenshots/screenshot-light.png" alt="Hermes Bot macOS Group Chat (Light Mode)" width="700">
  <br>
  <em>Native app with demo/mock data (Group Chat in Light Mode)</em>
</p>
</details>

## Before you start: what this app does to your Hermes data

- **It uses your real Hermes install (`~/.hermes`).** If a Hermes backend is already running (for example the
  Hermes desktop app), this app attaches to it. Otherwise it starts its own `hermes serve` on `~/.hermes` and
  stops it when you quit. A backend it attached to is never stopped. To keep rooms and routines running after
  you quit, turn on **Keep Hermes running in the background** in Settings (see
  [Keeping Hermes running](#keeping-hermes-running)).
- **Bot Chat is the same chat Hermes Desktop uses for that bot.** Opening a bot continues its existing
  history; the app never deletes it. Quitting only disconnects. If the app cannot confirm whether the chat
  exists, it does not start a new one. If the chat is running in another Hermes app (error 4090), the app
  says so; open it in that app.
- **Group Chat rooms are separate from the Hermes desktop app's group chats.** Rooms here are the backend's
  hosted rooms (`groups.*`); group chats you made in the Electron app will not show up, and vice versa.
- **It changes your profiles and bot config only when you ask it to.** Bots are your existing Hermes
  profiles. **Pin to Top**, **Hide Bot** and a bot's **title** are saved in that profile's `profile.yaml` under
  `ui_meta` → `hermes-bots` (`pinned`, `hidden`, `title`), the same place and keys Hermes Desktop uses, so both
  apps show the same roster; every other `ui_meta` entry is left alone. **Edit…** writes only the fields you
  changed (description, avatar, model, skills, toolsets, MCP servers, SOUL) into that profile.
  **Duplicate** creates a new profile cloned from the bot, and **Delete…** permanently removes a bot's whole
  profile folder after you confirm (never `default`); see [Managing bots](#managing-bots). And if you turn on
  activity tracking in a Group Chat, the app installs the open-source
  [Bot Activity](https://github.com/risyadul/hermes-bot-activity) plugin (a pinned commit) into Hermes and
  enables it for every bot. Turning it off from the same panel disables it in every bot profile and removes it
  from Hermes; the bots' copies stay on disk, inactive.
- **Kanban edits are real.** Cards you create, move, assign or archive in the Kanban view change your Hermes
  Kanban board, the same one Hermes Desktop and the `hermes kanban` CLI use. **Terminate Run** and **Reclaim
  Task** (Workers) stop a running worker process.
- **Routines are real.** Routines you create, pause, resume or delete change that bot's Hermes cron jobs, the
  same ones Hermes Desktop's Routines and `hermes cron` show. When it lists a bot's routines, the app pauses
  any old-style delegated routine Hermes Desktop marks unsafe, as Hermes Desktop does.
- **It only connects to backends on loopback** (`127.0.0.1`, `::1`, `localhost`); a backend record pointing
  elsewhere is rejected.
- Setting `HERMES_HOME` does **not** isolate the app today; it always uses `~/.hermes`.

## Requirements

| | |
|---|---|
| macOS | 14 or later (Apple Silicon tested; Intel untested) |
| Toolchain | Xcode 26 / Swift 6.3 (tested). Command Line Tools only: **untested** |
| Hermes Agent | installed and configured with a model provider (see below) |
| `hermes` binary | found automatically: `~/.local/bin/hermes`, the `$PATH` of the process that launched the app, then `/opt/homebrew/bin` and `/usr/local/bin`. `HERMES_BOT_APP_HERMES_BIN` (an absolute path) replaces that search. It must be a regular executable file, not group/world-writable, in a directory that is not group/world-writable (unless sticky) |

Hermes Agent compatibility: tested only against a Hermes Agent `main` build (`v0.21.6+783.g8a7a5a9`).
The `groups.*` API this app needs is present in stable `v2026.9.14` and later, but stable releases
have **not been tested** with this app yet.

## Quick start

> ⚠️ Verified: clean-clone build (`swift build`). **Not yet verified end to end** (fresh Hermes install →
> first reply in Bot Chat and Group Chat) on a clean machine. Report anything that does not work.

1. **Install and set up Hermes Agent** by following the
   [Hermes Agent docs](https://hermes-agent.nousresearch.com/docs), then configure a model provider
   (`hermes setup` or `hermes model`). Check that a plain chat works in Hermes itself first.
2. **Have at least two bots (for Group Chat).** Each Hermes profile is a bot; `default` counts as one. Create
   another and give it its own provider config:
   ```sh
   hermes profile create reviewer
   hermes -p reviewer setup        # or: hermes -p reviewer model
   ```
   `hermes profile create reviewer --clone` also works but copies the active profile's `config.yaml` **and `.env`
   (credentials)** into the new profile; only use it if that is what you want.
   Bot Chat alone works with a single profile.
3. **(Optional) Point the app at a specific `hermes` binary.** The app looks in `~/.local/bin`, on the
   `$PATH` of the process that launched it, and in the Homebrew locations. A terminal launch inherits your
   shell's `$PATH`; an app opened from Finder gets launchd's minimal `$PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
   so there only the fixed locations (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) find it. If yours
   lives elsewhere (pipx, venv, …), set an absolute path; it replaces the search (nothing else is tried):
   ```sh
   export HERMES_BOT_APP_HERMES_BIN="$(which hermes)"
   ```
4. **Build and run:**
   ```sh
   git clone https://github.com/risyadul/HermesBotDesktop.git
   cd HermesBotDesktop
   swift build
   .build/debug/HermesBotApp        # or: swift run HermesBotApp (the package has several executables)
   ```
5. **First chat:** pick a bot in the sidebar and send a message. For Group Chat, press **+**, choose 2–6
   bots, and send the opening message.
6. **Quit** with ⌘Q, by closing the window, or with Ctrl+C in the terminal you launched it from. All three
   run the same cleanup (see the data section above). Force-killing the app (`kill -9`) skips it.

## Using Bot Chat

- **Slash commands:** type `/` for the commands your bot offers (including skills); ↑/↓ move, Tab or Return
  accepts, Esc closes. `/new`, `/reset` and `/clear` compact the conversation instead of resetting it;
  `/compress` and `/stop` work. Commands that only make sense in Hermes Desktop or the terminal are not offered.
- **Tool activity:** each tool a bot uses shows as a line that ends with its duration and result summary, or
  is marked failed.
- **Bots asking you things:** approval requests (once, for the session, always, or deny), clarifying questions
  and password/secret prompts appear as cards above the composer. Requests the app cannot show are left for
  other Hermes apps to answer.
- **Attachments:** paperclip, drag and drop, or paste. Images (up to 25 MB), PDFs (up to 50 MB and 25 pages;
  needs `pdftoppm` on the backend machine) and other files. Files over a limit are refused with a message.
- **Files from bots:** images show inline and other files as chips (Bot Chat and Group Chat). A file opens
  only when you click it, after a safety check that refuses credentials and system locations.
- **Copy:** hover a message for Copy, or right-click it. A reply that came in several parts (text around tool
  calls) also offers Copy Full Response, which copies all of that reply's text.
- **While the bot is replying:** Return *steers* the running reply: your message is added below what it has
  written so far and the bot continues from it. ⌘Return *queues* the message instead; queued messages wait
  in a panel above the composer and are sent one at a time when the reply finishes. Each can be edited, sent
  now (this stops the current reply) or deleted. Stop pauses the queue until you press Resume. A reply that
  another Hermes app started is never steered from here: Return queues instead. If the bot cannot take a
  correction, the message is queued, so nothing you typed is lost. Files and slash commands are never used
  to steer (files are queued; slash commands run at once).
- **Model and reasoning effort:** the row under the composer shows the chat's model and reasoning effort;
  click either to change it. A change applies to this chat only (the same as `/model … --session`); it never
  changes the bot's profile or any other bot. A model that costs more asks for confirmation first, and a
  change made while the bot is replying takes effect when the reply finishes.
- **Context usage:** the small gauge shows how full the conversation's context window is (`~` when
  estimated); click it for a breakdown by category and how often the chat has been compacted. While Hermes
  compacts the conversation the status reads "Compacting the conversation…".
- **Files in Group Chat:** the backend's group rooms accept only text, so a file you attach (paperclip, ⌘V or
  drag and drop, up to 10 files of 50 MB each) is copied to
  `~/Library/Application Support/HermesBotApp/Room Attachments/<room>/` and the message names the copies'
  paths; the room's bots open them with their file tools. This app shows them as attachments; Hermes Desktop
  shows the paths as text. The copies are deleted when you disband the room.
- **Routines:** **Routines** in a Bot Chat's toolbar lists the bot's scheduled tasks (Hermes cron jobs). Switch
  one off to pause it, on to resume it, delete it (asks first), or click it for its schedule, next and last
  run, last result, where results go and any error. **New Routine** asks for a name, the instruction and when
  to run it: once in N minutes/hours/days, every hour, every day at a time, weekdays, a weekday, a day of the
  month, every N minutes/hours/days, or a raw schedule (`every 2h`, `0 9 * * *`); repeating schedules can stop
  after N runs. Results stay in the run history or go to the bot's Bot Chat, where the bot answers them;
  **Continuity** lets each run see the previous run's output. Routines are stored like Hermes Desktop's (named
  `[bot:<name>] …` in the bot's own cron store), so both apps show the same ones. They fire only while Hermes
  runs: if this app started Hermes, quitting stops them (see [Keeping Hermes running](#keeping-hermes-running)).

## Sidebar

- **Filter:** the field at the top of the sidebar narrows group chats, bots and boards as you type (name,
  @handle, member, description or model; a leading `@` is optional). Return or ↓ selects the first match and
  moves to the list; Esc clears it. It does not take ⌘F.
- **Bot rows:** bots with the newest activity come first (pinned bots stay on top). Each row shows the last
  message and its age; a message one bot sent another reads "@sender: …". A dot marks a bot with activity you
  have not opened yet (a routine run, a reply that finished while you were elsewhere, a message from Hermes
  Desktop or the CLI); opening its Bot Chat clears it. What you have seen is remembered across launches. The
  app reads all of this from one `profiles.list` every 10 seconds, without opening any chat.
- **Needs attention:** an amber warning on a bot whose last turn failed in a way you have to fix: sign in
  again, quota or balance exhausted, provider not configured, or blocked. The tooltip says which. Temporary
  failures (rate limits, timeouts, server errors) never show it, and the bot's next good reply clears it.
- **Bot menu** (right-click a bot): Open Bot Chat, Open Recent Session, Pin to Top / Unpin, Hide Bot / Unhide
  Bot, Move to Section, Copy @handle, then Edit…, Duplicate and Delete… ([Managing bots](#managing-bots)).
  Hidden bots move to a collapsed **Hidden (n)** section at the bottom; a hidden bot keeps working, stays
  mentionable and keeps its chats. A filter shows matching hidden bots without expanding the section. If
  Hermes does not save a pin, hide or move (another app changed the bot at the same time, or an older Hermes
  Agent), the row goes back and the sidebar says why.
- **Open Recent Session** shows the bot's newest conversation other than its Bot Chat (a routine run, or a
  side thread started in Hermes Desktop or the CLI) in a read-only sheet. Nothing is resumed or written; to
  continue it, use Hermes Desktop or the CLI.
- **Sections:** the folder button next to **Bots** (or Move to Section → New Section…) makes a section. File a
  bot with Move to Section or by dragging its row onto a section; bots in no section are under
  **Unassigned**. Click a section's header to collapse it; right-click it to rename, move or delete it. Deleting
  a section only moves its bots to Unassigned, and **Undo** puts it back. Each bot keeps its section in its
  profile (`ui_meta` → `hermes-bots` → `sectionId` / `sectionName`, Hermes Desktop's keys), so Hermes Desktop
  shows the same folders; the list of sections and which are collapsed stay on this Mac.

## Managing bots

Right-click a bot in the sidebar, or use the ••• menu in the Bot details panel (⌥⌘I), for **Edit…**,
**Duplicate** and **Delete…**. These change the bot's Hermes profile, exactly as Hermes Desktop's Edit
Profile, Duplicate and Delete do, so both apps stay in step.

- **Edit…:** the bot's **title** (shown everywhere instead of the profile name), **description** and
  **avatar** (a PNG or JPEG up to 15 MB, cropped to a 256 px square; or Remove). **Advanced** adds the
  **model and provider** (from Hermes' model list, typed in by hand, or **Inherit** to use the main profile's
  model), the bot's **skills**, **toolsets** and **MCP servers** (on/off), and its **SOUL**. Only the fields you
  changed are saved. If one field cannot be saved, it says why under that field and the rest are kept; Save
  again retries just that one. A model Hermes flags as expensive (or under a data policy) asks first and is
  only switched when you confirm. Saving a SOUL keeps the "Messaging other agents" section bots use to talk to
  each other (unless your Hermes adds it on its own), the same way Hermes Desktop does.
- **Duplicate:** creates `<name>-2` (or the next free number) as a clone of the bot (settings, skills, SOUL,
  memory), then copies its look: title with "(copy)" and avatar. The sheet shows each step and ends with
  **Open** for the new bot.
- **Delete…:** asks first and names the profile folder that will be removed. Deleting runs
  `hermes profile delete <name> --yes` and cannot be undone. The default profile cannot be deleted. The bot's
  Bot Chat is closed and the bot leaves the sidebar.

"Inherit" and Delete use the `hermes` command (found the same way as for `hermes serve`); everything else goes
through the running Hermes backend.

## Notifications and the Dock badge

- When the app is **not frontmost**, it posts a macOS notification when a bot's reply finishes in Bot Chat,
  when a bot asks for approval or an answer (Bot Chat and Group Chat), and when a Group Chat round ends after a
  bot wrote `@user`. macOS asks for permission the first time the app has something to show.
- Approval notifications have **Approve Once** (needs an unlocked Mac) and **Deny**, answered with the same
  calls as the cards in the app. Clicking a notification opens its bot or room. A notification is withdrawn
  once its request is answered anywhere.
- A hidden bot's replies do not notify; its approvals and questions still do.
- The **Dock badge** counts what is waiting on you: open request cards in Bot Chats and pending approvals in
  Group Chats.
- Bot Chat notifications cover the bots you opened since launch (the app follows a bot's chat once you open
  it). Group Chats are checked every 8 seconds even when they are not open.
- Turn notifications off with `defaults write io.github.risyadul.hermesbot notificationsEnabled -bool false`
  (a Settings switch for this key is planned). Notifications need the packaged `HermesBot.app`; a bare
  `swift run` binary shows the Dock badge only.

## Using Group Chat

- **Rename a room:** room menu (⋯) → **Rename…**. The new name shows at once; if Hermes refuses it, the old name
  comes back and the note above the composer says why. Bots see the new name from their next turn.
- **Threads:** hover a message (or right-click it) and choose **Reply in thread**. The thread opens in the right
  column with its own composer; the room composer below the timeline always writes to the whole room. Replying
  in thread to a room message starts a thread on it, and the first reply quotes that message, because bots only
  see the messages of their own thread. Thread messages also show in the room timeline with a "Thread · …"
  label; a message with a thread under it shows its reply count. Click either to open the thread.
- **Reply to @bot and Copy:** hover a bot's message for **Reply to @bot** (puts `@bot` in the composer of that
  message's thread; you still send) and **Copy** (the text as written). Your own messages offer Copy too.
- **Sidebar rows** show the last message and how long ago it was. An amber **@** badge means a bot wrote
  `@user` and you have not answered or opened the room since; an amber hand means a bot waits on your
  approval. Rooms you are not looking at are checked every 5–15 seconds.
- **Drafts** are kept per room and per thread while the app runs, so switching rooms does not lose them.

## Group Chat activity

Bots in a Group Chat work in hidden sessions, so the room itself only shows when each bot starts, replies or
passes. The **Activity** panel (toolbar button, ⌥⌘I) shows, per bot, what it is doing right now: the tool it
is running and for how long, its recent tool calls with arguments and results, its reasoning, and errors. The
bot's turn status (for example "needs approval") stays next to its live status. The panel stops polling while
its window is covered or the app is hidden, and picks up again when it is back.

The detailed view needs the [Bot Activity](https://github.com/risyadul/hermes-bot-activity) Hermes plugin,
because Hermes hands those events only to plugins. If it is not installed, the panel shows each bot's turn
status, a **This round** list of the latest round from the room log (queued, working, replied, passed, timed
out, failed, needs approval; newest first), and an **Enable Tracking…** button. Enable installs a pinned commit
of the plugin, turns it back on in any bot profile where it is disabled, and enables it for every bot. A copy
that is already installed but disabled is turned on only if Hermes's install record pins it to that same
commit; otherwise the panel says the installed copy isn't the reviewed version and offers **Reinstall Pinned
Version…**, which replaces it with the pinned commit. Enabling and turning off run once for the whole app: a
second Group Chat that asks for the same thing while it runs waits for it and shows the same progress; a
different action is refused until the running one finishes (its buttons are disabled meanwhile).

**Turn Off Activity Tracking…** in the panel's … menu disables the plugin in every bot profile
(`hermes -p <bot> plugins disable bot-activity`), then removes the copy in Hermes's own plugins folder. The bots'
copies stay on disk but inactive; **Enable Tracking…** turns them back on. If some bots can't be switched off,
the panel names them.

## Kanban

The **Boards** section in the sidebar shows your Hermes Kanban boards (the built-in `kanban` plugin). You can
see the columns and cards, open a card for its description, summary, dependencies, attachments, comments and
worker log, and create, move, assign, prioritize, comment on and archive cards.

- **Attachments:** attach files to a card with the paperclip or by dropping them on its Attachments list (up to
  25 MB each, the server's limit), open them, or delete them. Opening downloads a copy into the app's caches
  folder; documents open in their usual app, while apps, scripts, installers, web pages and archives are only
  shown in Finder, never run.
- **Message the running worker:** on a running card the comment box sends your note to the worker, which picks
  it up in its current turn within a few seconds. **Requeue with note** posts the note and restarts the task
  from scratch with it.

- **Filters:** the filter button next to the search field shows one profile's cards at a time, shows archived
  cards (an Archived lane), and groups the Running lane by profile (remembered).
- **Workers:** **Workers** in the board header lists the cards being worked on right now: which bot runs which
  card, for how long and its last heartbeat (amber after two minutes without one). **Inspect Run** shows the
  run, the worker process and its log. **Terminate Run** and **Reclaim Task** stop the worker and put the card
  back to Ready for the dispatcher; both ask first.
- **Boards that go away:** if a board is deleted or archived while you have it open, it says so, stops
  refreshing and refuses changes; **Go to Another Board** opens one that still exists. It also leaves the
  sidebar at the next board list refresh.
- **Long texts:** descriptions, summaries, results and comments longer than 64,000 characters show their
  first 64,000 characters with a note.
- **Refreshing:** the open board, the board list and the dispatcher status refresh only while an app window is
  on screen; they pause while the app is hidden or its windows are minimised or covered, and catch up when
  you come back.
- If the sidebar says **Boards unavailable on this connection**, the connected Hermes gave the app no REST
  access, which Kanban needs.

Cards are worked on by the Kanban dispatcher, which runs inside `hermes gateway`, not inside this app. The
board header and **Settings → Kanban dispatcher** show the same status. If it is installed but stopped,
**Start** runs `hermes gateway start`; if it is not installed, run `hermes gateway install` once.

## Keeping Hermes running

When this app starts its own backend, quitting the app stops it, and with it any Group Chat round in progress
and the scheduler for routines. **Settings → Keep Hermes running in the background** installs a per-user
LaunchAgent (`~/Library/LaunchAgents/io.github.risyadul.hermesbot.serve.plist`) that starts `hermes serve` at
login and restarts it if it crashes; the app then attaches to it. It is off by default. Its log is
`~/Library/Logs/HermesBotApp/background-serve.log`.

- Turning it on asks first and shows the `hermes` executable launchd will run. If that path comes from
  `HERMES_BOT_APP_HERMES_BIN` rather than the usual search, the question says so; it keeps running after the
  app quits, so make sure you trust it.
- If the app is running its own backend at that moment, you choose: **Switch Now** stops the app's backend
  (a Group Chat round in progress stops), starts the background Hermes and reconnects to it; **At Next
  Launch** only installs the LaunchAgent, and the background Hermes starts the next time you open the app (or
  at login). Two backends never run side by side.
- Turning it off unloads and deletes the LaunchAgent, which stops that Hermes. If the app is connected to it,
  it asks first (the connection drops and a Group Chat round in progress stops), then reconnects, starting its
  own backend if no other Hermes is running.
- **Installed but not running** (launchd does not have it) and **Loaded but not running** (launchd has it, but
  Hermes exited or is waiting after a crash; see the log): **Start** starts the installed agent as it is. If
  it shows **Hermes not found** (for example after moving or reinstalling Hermes), **Reinstall** rewrites it
  with the current `hermes` path, after the same question as turning it on.
- The log folder is readable by you only (0700) and the log file is created 0600.

## Configuration

| Variable | Effect |
|---|---|
| `HERMES_BOT_APP_HERMES_BIN=<path>` | `hermes` executable used when the app has to start a backend. Absolute path (or `~/…`); replaces the automatic search |
| `HERMES_BOT_APP_NO_SPAWN=1` | only attach to a running backend; never start one |
| `HERMES_BOT_APP_APPEARANCE=light\|dark` | force appearance |

Developer/test variables are listed in [docs/development.md](docs/development.md).

## Troubleshooting

> ⚠️ Failure messages below are not yet verified on a clean machine.

- **Backend does not start:** check `~/Library/Logs/HermesBotApp/serve.log` (the error message names it);
  usually the `hermes` path (quick start step 3) or a missing provider config (step 1).
- **"hermes not found":** set `HERMES_BOT_APP_HERMES_BIN` to the full path of the binary.
- **Bots list is empty / Group Chat needs more bots:** see quick start step 2.
- **"Group Chat needs Hermes Agent v2026.9.14 or later":** the backend does not offer `groups.*`; update
  Hermes Agent. The "+" button stays disabled until then.
- **Connection lost:** the app shows a failure screen; press Try Again to reconnect.
- **My Bot Chat history looks short or empty:** Bot Chat is the bot's one chat titled "Bot Chat" and is never
  deleted by this app. `/new`, `/reset` and `/clear` compact it rather than reset it. If the app cannot find or
  confirm the chat it shows an error instead of starting a new one; press Try Again.
- **"Running in another Hermes app":** another backend process holds that bot's chat. Use it in that app.
- **PDF attachment fails:** PDFs are rendered with `pdftoppm` on the backend machine; install it (poppler).

## Download / packaging

Tagged releases attach `HermesBot-<version>-macos-arm64.zip` on
[GitHub Releases](https://github.com/risyadul/HermesBotDesktop/releases). To build the same bundle yourself:

```sh
scripts/package-app.sh [version]    # writes dist/HermesBot.app and dist/HermesBot-<version>-macos-arm64.zip
```

The app is **ad-hoc signed, not notarized** (no Developer ID). On first launch macOS will refuse it:
right-click the app and choose **Open**, or run `xattr -dr com.apple.quarantine HermesBot.app`. These
packages have only been checked to build, sign and lint; launching them on a clean machine is untested.

## Known limitations

- macOS only; release builds are ad-hoc signed, not notarized.
- Group Chat follows rooms by polling (the backend has no push for rooms yet).
- No isolated mode for end users; always uses `~/.hermes`.

## Roadmap

Planned work, phased and tracked as a checklist: [docs/roadmap.md](docs/roadmap.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/development.md](docs/development.md) for layout, tests (`swift test`, no live backend needed),
harness CLIs and protocol notes ([gateway contract](docs/gateway-contract.md),
[groups contract](docs/groups-contract.md)).

Security issues: please report privately, see [SECURITY.md](SECURITY.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Changes are listed in the [CHANGELOG](CHANGELOG.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

Unless you explicitly state otherwise, any contribution you intentionally submit for inclusion in this
project is licensed under the same terms, without any additional terms or conditions.
