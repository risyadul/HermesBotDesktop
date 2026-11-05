# Hermes Bot for macOS

A lightweight native macOS (SwiftUI) client for [Hermes Agent](https://github.com/NousResearch/hermes-agent),
focused on three things: **Bots**, **Bot Chat** (1:1, streaming) and **Group Chat** (2–6 bots in one room).

It is a thin client: all agent logic runs in the Hermes backend (`hermes serve`). The app talks to it over
the gateway WebSocket (JSON-RPC) and does not reimplement any agent behavior.

> **Independent project.** Not affiliated with or endorsed by Nous Research. "Hermes" refers to the
> Hermes Agent backend this app connects to.

**Status: early / pre-release.** Build from source, or download a universal (Apple silicon + Intel) zip from
[GitHub Releases](https://github.com/risyadul/HermesBotDesktop/releases); releases are ad-hoc signed (not
notarized) until the maintainer's Developer ID is set up. See [Download / packaging](#download--packaging).

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

The app works on your real Hermes install. Below is everything it can change or start. Unless a bullet says
otherwise, it happens only when you act.

**Backend and network**

- **Uses `~/.hermes`.** It attaches to a running Hermes backend (for example Hermes Desktop's), or starts its own
  `hermes serve` and stops it when you quit. A backend it attached to is never stopped. `HERMES_HOME` does
  **not** isolate the app today.
- **Loopback only:** it connects only to backends on `127.0.0.1`, `::1` or `localhost`; anything else is refused.
- **Background Hermes (opt-in):** **Keep Hermes running in the background** installs a per-user LaunchAgent that
  runs `hermes serve` at login ([Keeping Hermes running](#keeping-hermes-running)). Off by default.
- **Daily update check (on by default):** one unauthenticated request to the GitHub API
  (`api.github.com`). Turn it off in **Settings → Updates** ([Updates](#updates)).

**Bots (your Hermes profiles)**

- **Bot look and roster, in `profile.yaml` → `ui_meta` → `hermes-bots`:** `pinned`, `hidden`, `title`,
  `sectionId`, `sectionName`, `shape`, `color`, `imageKind`, `custom`, `created`. These are Hermes Desktop's
  keys, so both apps show the same roster. Each write also drops a stale `chat` key there, as Desktop does.
  Other `ui_meta` namespaces are never touched.
- **New Bot…** creates a profile (`profiles.create`), then saves its look and uploads its avatar.
- **Edit…** writes only the fields you changed (`profiles.configure`, the avatar with `profiles.set_asset`);
  **Inherit** model runs `hermes --profile <name> config unset model`.
- **Applied at once, without Save** (in Edit → Advanced): installing a skill from the skills hub; **Add
  Server…**, **API Key…** (written to the bot's `.env` and config) and **Sign In** (OAuth) for MCP servers.
- **Duplicate** creates a new profile cloned from the bot (`<name>-2`) and copies its look.
- **Delete…** runs `hermes profile delete <name> --yes`: the whole profile folder, permanently, after you
  confirm. `default` cannot be deleted. See [Managing bots](#managing-bots).
- **Approval mode** (⚡ menu in Bot Chat) writes `approvals.mode` in the bot's profile config, so it applies to
  every chat of that bot.

**Bot Chat**

- **It is the bot's shared chat with Hermes Desktop** (the session titled "Bot Chat"). Opening a bot continues
  it, or creates it if the bot has none yet. The app never deletes it; quitting only disconnects. If the app
  cannot confirm whether the chat exists, it does not create one. A chat running in another Hermes app
  (error 4090) is left to that app.
- **Model and reasoning effort picks are for this chat's session only;** the profile is not changed.
- **Regenerate, Edit Message and Restore from Here rewind the shared chat:** Hermes archives the later messages
  and they disappear in Hermes Desktop too. You are asked first whenever later messages would go.
- **Branch into New Chat** creates a new session of the bot and leaves the Bot Chat alone.

**Group Chat**

- **Rooms are the backend's hosted rooms (`groups.*`),** separate from Hermes Desktop's group chats. Creating,
  renaming and disbanding rooms, and **Change Members…** (which creates a new room), change those rooms.
- **Import from Hermes Desktop…** only reads; the archive is kept by this app alone
  ([Importing](#importing-hermes-desktop-group-chats)).
- **Summarize** sends a prompt quoting the room's new messages into the chosen bot's Bot Chat (a room member by
  default). It shows up there in Hermes Desktop too. Nothing is posted into the room.
- **Activity tracking:** **Enable Tracking…** installs the open-source
  [Bot Activity](https://github.com/risyadul/hermes-bot-activity) plugin (a pinned commit) and enables it in
  every bot profile; **Enable for N More Bots** does the same for bots added later. **Turn Off Activity
  Tracking…** disables it in every profile and removes it from Hermes (the bots' copies stay on disk, inactive).

**Routines and Kanban**

- **Routines** you create, pause, resume or delete are that bot's Hermes cron jobs. Routines that deliver to
  Bot Chat post each run's result into the bot's shared Bot Chat, and the bot answers it. When it lists a
  bot's routines, the app pauses any old-style delegated routine that Hermes Desktop marks unsafe.
- **Kanban edits are real:** cards (create, move, assign, comment, attach, archive), **Decompose** and
  **Specify** (rewrite cards with Hermes' auxiliary model; **Estimate** makes a model call), boards (create,
  rename, delete, import, export) and **Orchestration Settings** (Hermes config, every board). **Terminate Run**
  and **Reclaim Task** stop a worker process.
- **Start** (Kanban dispatcher) runs `hermes gateway start`. That brings up Hermes' whole messaging gateway,
  not only the dispatcher: chat platforms you configured in Hermes go live.

**Messages sent for you**

- The menu bar's quick send, **Quick Ask**, the **Send to Hermes Bot** service and the **Shortcuts** actions
  send real messages to a bot's Bot Chat (or, for the service and **Send to Group Chat**, to a room). They send
  only when you press Send or run the shortcut ([Mac integration](#mac-integration)).

## Requirements

| | |
|---|---|
| macOS | 14 or later. Apple silicon tested by hand; Intel (x86_64): the test suite passes as x86_64 under Rosetta and runs on an Intel CI runner; the app itself has not been tried on an Intel Mac |
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
   bots, and send the opening message. If something is missing on first run, the app shows a setup screen
   instead of an error: **Hermes not found** (install it, or set `HERMES_BOT_APP_HERMES_BIN`; Try Again),
   **no model configured** (`hermes setup` or `hermes model`, then Check Again; detected with the read-only
   `setup.runtime_check`), or **only one bot** (Bot Chat works; the commands to add a second bot, with Copy
   buttons). The app never runs those commands for you.
6. **Quit** with ⌘Q or with Ctrl+C in the terminal you launched it from. Both run the same cleanup (see the
   data section above). Closing the last window quits too, but only while the menu bar icon is off; with it on,
   the app keeps running ([Mac integration](#mac-integration)). Force-killing the app (`kill -9`) skips the
   cleanup.

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
  The paperclip also offers **Attach Folder…** and **Attach URL…**: a folder (also when dropped) or a web page
  is sent as an `@folder:` / `@url:` reference that the bot reads when your message runs; nothing is uploaded.
  Pasting more than 3,000 characters attaches the text as a file ("Pasted content") instead of filling the
  composer; the file is deleted once the reply finishes, like pasted images.
- **Images in replies:** click one to zoom (up to 8×, pinch or the buttons) and drag to pan; double-click
  resets. **Open** in that window opens it in its default app.
- **Files from bots:** images show inline and other files as chips (Bot Chat and Group Chat). A file opens
  only when you click it, after a safety check that refuses credentials and system locations.
- **Voice:** the **mic** button in the composer (Bot Chat and Group Chat) dictates into the message at the
  caret with macOS speech recognition, on this Mac when your language supports it. It stops after about two
  seconds of silence, when you click it again, or when you send. The first use asks for microphone and speech
  recognition access; if you said no, the composer explains and links to System Settings. Dictation needs the
  packaged `HermesBot.app`. **Read Aloud** (hover a finished reply, or right-click it) speaks it in the system
  voice; Shift-click reads the whole turn. Code blocks, tool activity and Thought rows are skipped; Esc or sending
  a message stops it. **Settings → Voice → Read replies aloud automatically** (off by default) speaks each new
  Bot Chat reply when it finishes. Hermes's own TTS/STT backends are not used.
- **Quick Look and drag out:** click an image to preview it in Quick Look, press Space while the pointer is over
  a file or image (not while typing), or choose **Quick Look** from its right-click menu; Space or Esc closes the
  preview. Drag a file or image out of the chat to copy it to Finder or another app. Both re-run the safety check
  first; web pages, SVG, archives and macro-enabled documents are not previewed (Open only reveals them).
- **Copy:** hover a message for Copy, or right-click it. A reply that came in several parts (text around tool
  calls) also offers Copy Full Response, which copies all of that reply's text.
- **Regenerate, edit, restore:** hover a reply for **Regenerate** (runs the prompt above it again); hover your
  message for **Edit Message** (change it and run it again), or right-click it for **Restore from Here** (run
  it again as it was). These rewind the Bot Chat to that message the way Hermes Desktop does: everything after
  it is removed from the conversation in Hermes (archived, also gone in Hermes Desktop). Restore always asks;
  Regenerate and Edit ask when later messages would be removed. They work only while the bot is idle. If Hermes
  cannot find the message in its stored history, the prompt is sent again as a new message and nothing is
  removed (the chat says so).
- **Branch into New Chat:** right-click a message to continue the conversation up to there in a new session of
  the bot, in a window over the Bot Chat (send, steer, approvals and the composer controls all work). The Bot
  Chat is not changed. Close the window to come back; the branch stays in Hermes and is the bot's
  **Open Recent Session** in the sidebar.
- **When a reply fails:** the error shows as a card with **Retry** (runs the prompt again), **Switch
  Provider** for provider, key and billing failures (opens the model list for this chat), **Copy Diagnostics**
  (error details for a bug report, with keys and tokens removed) and a close button.
- **Changed files:** when a reply edited files, a card under it lists them with the lines added and removed;
  click a file for its diff, or the folder button to reveal it in Finder (after the same safety check as files
  from bots; paths relative to the bot's folder cannot be revealed). Shown for replies the app watched;
  Hermes' stored history does not keep the diffs.
- **Times:** hovering a message also shows when it was sent ("3:27 PM", "Yesterday, 3:27 PM"; the full date
  in its tooltip). A reply you watched from its start shows how long the turn took under it ("12s").
- **@mention other bots:** type `@` for your other bots (never the one you are talking to); click one or press
  Tab for the first. When your message tags a bot, the app adds a short note for the model saying who that is,
  the same note Hermes Desktop adds, and the bot contacts it with its own `message_agent` tool. The app itself
  never sends your text to the other bot. Bots without that tool will say they cannot message other bots.
- **Scrolled up?** New output no longer pulls you down while you read older messages. A button above the
  composer counts the messages that arrived below ("3 new messages"); click it to jump back to the end.
- **Message history and drafts:** ↑ with the caret at the start of the composer brings back your earlier
  messages to this bot, newest first (like a shell); ↓ at the end goes forward again and finally back to what
  you were typing. An unsent draft is kept per bot, also across launches (stored in the app's preferences; a
  draft over 20,000 characters is not kept).
- **Find in chat (⌘F):** a find bar above the chat counts and highlights matches in the messages (not in
  Thought or tool rows) and rings the current one. Return or ⌘G goes to the next match, ⇧Return or ⇧⌘G to the
  previous one, Esc closes.
- **Export (⇧⌘E):** **Export Conversation** in the toolbar saves the chat as Markdown: the messages, a
  one-line summary of each tool call, times and turn durations. Tool arguments and results and the bot's
  reasoning are left out, and session tokens and auth headers are masked.
- **While the bot is replying:** Return *steers* the running reply: your message is added below what it has
  written so far and the bot continues from it. ⌘Return *queues* the message instead; queued messages wait
  in a panel above the composer and are sent one at a time when the reply finishes. Each can be edited, sent
  now (this stops the current reply) or deleted. Stop pauses the queue until you press Resume. A reply that
  another Hermes app started is never steered from here: Return queues instead. If the bot cannot take a
  correction, the message is queued, so nothing you typed is lost. Files and slash commands are never used
  to steer (files are queued; slash commands run at once).
- **Approval mode:** the ⚡ menu under the composer shows the bot's approval mode: **Manual** (ask before
  actions that need approval), **Smart** (Hermes assesses each action and asks when needed) or **Off** (no
  approval prompts). It is the bot's profile setting, so it applies to all of that bot's chats.
- **Model and reasoning effort:** the row under the composer shows the chat's model and reasoning effort;
  click either to change it. A change applies to this chat only (the same as `/model … --session`); it never
  changes the bot's profile or any other bot. A model that costs more asks for confirmation first, and a
  change made while the bot is replying takes effect when the reply finishes.
- **Context usage:** the small gauge shows how full the conversation's context window is (`~` when
  estimated). It appears as the chat opens, from Hermes' estimate until a reply reports the measured figure
  (it stays hidden if Hermes has not loaded the bot yet); click it for a breakdown by category and how often
  the chat has been compacted. While Hermes
  compacts the conversation the status reads "Compacting the conversation…".
- **Files in Group Chat:** the backend's group rooms accept only text, so a file you attach (paperclip, ⌘V or
  drag and drop, up to 10 files of 50 MB each) is copied to
  `~/Library/Application Support/HermesBotApp/Room Attachments/<room>/` and the message names the copies'
  paths; the room's bots open them with their file tools. This app shows them as attachments: images as a
  thumbnail, other files as a chip with their kind and size. Click one for Quick Look; right-click for Quick
  Look, Open, **Reveal in Finder** and Copy Path (web pages, SVG, archives and other files that can run code are
  only revealed in Finder). If a copy was deleted, its chip says the bots can no longer open it either. Hermes
  Desktop shows the paths as text. The copies are deleted when you disband the room.
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
- **Room menu** (right-click a group chat): Open, **Pin to Top** / **Unpin**, **Move Up**, **Move Down**. Pinned
  rooms sit at the top of Group Chats; drag a room onto another to put it in that place (pinned rooms among
  pinned ones, the others among the others). New rooms appear at the top of the unpinned ones. Pins and order
  are kept on this Mac only (app preferences), not in Hermes, and a disbanded room's pin is dropped.
- **Switching:** ⌘1 to ⌘9 select the first nine group chats and bots the sidebar shows (in its order; the filter
  applies, boards are skipped); they are listed in the **Go** menu. **⌘K** (Go → Quick Switch…) opens a switcher:
  type a few letters of a group chat, bot or board (fuzzy: `lnch` finds "Launch plan"), ↑/↓ to choose, Return to
  open, Esc to close. An exact title comes first, then titles starting with what you typed, then a word or
  @handle starting with it, then titles containing it, then fuzzy matches; a group chat found only through a
  member's name comes after all of those.
- **Search messages:** **⇧⌘F** (Go → Search Messages…), or Tab in the switcher, searches the messages the app
  already holds: the Bot Chats you opened since launch and, for every group chat, its loaded log or the latest
  200 events the sidebar's background check fetched. Results show the chat, the author and the text around the
  match; Return opens the chat and scrolls to the message. Older messages that are not loaded are not searched.
- **Own window:** right-click a bot or group chat → **Open in New Window** (also in the pane's toolbar menu),
  ⌘-double-click it, or Go → Open in New Window for the one on screen. The window shows the same chat as the
  main window (same connection, same polling, same drafts) and reopens at the next launch.
- **Mute:** right-click a bot or group chat → **Mute Notifications**, or use the pane's toolbar menu
  ([Notifications](#notifications-and-the-dock-badge)).

## Managing bots

**New Bot…** (the **+** beside the Bots heading, or **File → New Bot…**) creates a bot. Right-click a bot in the
sidebar, or use the Bot Chat's toolbar menu or the ••• menu in the Bot details panel (⌥⌘I), for **Edit…**,
**Duplicate** and **Delete…**. These
change the bot's Hermes profile exactly as Hermes Desktop's New Bot, Edit Profile, Duplicate and Delete do, so
both apps stay in step.

- **New Bot…:** a **name** (it becomes the profile name and @handle: lower-case letters, digits, `-` and `_`,
  up to 64; other characters are converted the way Hermes Desktop converts them, and a taken name is refused),
  **title**, **description** and **avatar**. **Advanced** adds **Clone from** (a profile to copy settings, keys
  and skills from, or a fresh profile with Hermes' bundled skills), the **model and provider**, your own
  **SOUL** (otherwise one is written from the title and description), **Share keys & accounts with the main
  profile** (on by default) and **Create empty (skip bundled skills)** (fresh profiles only). Create runs
  `profiles.create`, saves the title and look, uploads the avatar, then asks Hermes whether the bot has a usable
  model. If everything worked, its Bot Chat opens and, with **Say hello** on (the default), it is asked "Hey, tell
  me about yourself!". Otherwise the sheet says what did not work (the profile is never left behind silently),
  with **Set Up Model…** when no model is ready.
- **Edit…:** the bot's **title** (shown everywhere instead of the profile name), **description** and
  **avatar** (**Change Avatar…**: a **Shape** face in one of twelve colours or the name's own colour, with
  **Randomize**, or **Monogram**; **Upload** a PNG or JPEG up to 15 MB, cropped to a 256 px square; **Generate**
  one with Hermes' image generator when one is set up; or pick a **Pet** from the petdex gallery; or Remove).
  Shape faces are saved the way Hermes Desktop saves them (shape and colour in the profile's `ui_meta`, plus a
  160 px picture), so both apps show the same face. **Advanced** adds the **model and provider** (from Hermes'
  model list, typed in by hand, or **Inherit** to use the main profile's model), the bot's **skills** (on/off,
  and **Find Skills…** to search the skills hub and install one, after you confirm), **toolsets**, **MCP
  servers** (on/off, plus **Add Server…** with a command or a URL, **API Key…**, **Test** and **Sign In** for
  OAuth servers, which opens the sign-in page in your browser) and its **SOUL**. Only the fields you changed are
  saved. If one field cannot be saved, it says why under that field and the rest are kept; Save again retries
  just that one. Installing a skill and the MCP actions change the bot right away; the on/off switches are saved
  with Save. An API key goes to the bot's `.env` (the app never logs it). A model Hermes flags as expensive (or
  under a data policy) asks first and is only switched when you confirm. Saving a SOUL keeps the "Messaging other
  agents" section bots use to talk to each other (unless your Hermes adds it on its own), the same way Hermes
  Desktop does.
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
  it). Group Chats are checked in the background every 5 to 15 seconds even when they are not open (the same
  check that keeps their sidebar rows current).
- **Mute one bot or group chat:** right-click it in the sidebar → **Mute Notifications**, or use the pane's
  toolbar menu (Unmute to undo). A muted
  bot or room posts no notifications at all, approvals included, but its requests still count in the Dock badge
  and still show in the sidebar, because they still wait on you. Mutes are kept on this Mac.
- Turn notifications off in **Settings → Notifications → Show notifications** (on by default; it is the
  `notificationsEnabled` user default). Notifications need the packaged `HermesBot.app`; a bare `swift run`
  binary shows the Dock badge only.

## Updates

- **Hermes Bot → Check for Updates…** asks GitHub for the latest release and shows its notes. **Download** opens
  the release page in your browser; the app never downloads or installs anything itself. Replace the app with the
  new one from the zip (quit it first).
- Once a day the app checks by itself and shows a new release once (not again every day). Turn this off in
  **Settings → Updates → Check for updates automatically** (on by default). A failed daily check stays quiet and is
  retried an hour later; Check for Updates… and **Check Now** say what went wrong.
- The check is one unauthenticated request to `api.github.com` (no account, no token; the only thing sent besides
  the request itself is the app version in the User-Agent). A copy built with `swift build` has no version and
  never checks by itself.

## Mac integration

- **Menu bar:** the speech-bubble icon in the menu bar shows how many approvals and questions wait on you. Click
  it for every bot and group chat with its state (**Needs you**, **Working**, **Idle**; needs-you first) and a
  **Quick send** field: pick a bot, type, Return. The message goes to that bot's Bot Chat (refused while it is
  still replying) and the reply lands there. Click a row to open it in the main window. Turn the icon off in
  **Settings → Mac Integration → Show in menu bar** (on by default).
- **Closing the last window:** while the menu bar icon is on, the app keeps running (Quick Ask, notifications
  and a backend it started keep working). Reopen a window from the Dock or the menu bar; quit with ⌘Q. With the
  icon off, closing the last window quits the app.
- **Quick Ask (⌃⌥⌘Space):** from any app, the shortcut opens a floating panel: pick a bot, type, Return. The reply
  streams in below and stays in the bot's Bot Chat (**Open in Bot Chat**). Esc or the shortcut again hides it.
  The default avoids ⌃⌥Space, which macOS uses to switch input sources. Change or turn off the shortcut in
  **Settings → Mac Integration** (click the shortcut, then press the new keys; it needs ⌘, ⌃ or ⌥). It uses the
  system hot key API, so no Accessibility permission is asked for; if another app already holds the keys,
  Settings says so.
- **Services → Send to Hermes Bot:** select text in any app (or files in Finder), then the app menu → Services →
  **Send to Hermes Bot**. A small window opens with the text: pick a bot or a group chat, edit, then **Send**, or
  **Open in Composer** to put the text (and the files, as attachments) into that chat's composer and send from
  there. Nothing is sent until you press a button. Needs the packaged `HermesBot.app`; macOS may only list the
  service after the app was launched once (or after logging out and in).
- **Shortcuts:** the **Ask Bot** action sends a message to a bot's Bot Chat and returns its reply as text (it
  gives up after the timeout, 120 s by default; the reply then continues in the Bot Chat). **Send to Group Chat**
  posts a message to a room. Both run through the app: **Hermes Bot must be running and connected** (Shortcuts
  launches it if needed and the action waits up to 20 s for the connection). Needs the packaged `HermesBot.app`.
- **Summarize since I left:** in a group chat, the **Summarize** toolbar button collects the messages that came
  in since you last had the room open (up to the newest 80) and asks a bot of your choice (a room member by
  default) for a short summary, in that bot's Bot Chat. The summary streams into the sheet; **Open Bot Chat**
  shows it there. The prompt and summary stay in that Bot Chat (Hermes Desktop shows them too). Nothing is
  posted into the room.

## Using Group Chat

- **Rename a room:** room menu (⋯) → **Rename…**. The new name shows at once; if Hermes refuses it, the old name
  comes back and the note above the composer says why. Bots see the new name from their next turn.
- **Change members:** room menu (⋯) → **Change Members…** (available once the room has loaded). Hermes can't
  change who is in a room, so this starts a new group chat: pick 2 to 6 bots (the current ones are ticked, the
  name is kept and can be changed) and choose **Create New Room**. Its first message is a context note from you:
  where it continues from, who joined and left, and the previous room's last 12 messages (at most about 4,000
  characters), quoted one per line. Files are not copied; their names are mentioned. The note asks the bots to
  reply `(pass)`, so they wait for your next message. Then choose what happens to the previous room: **Keep it**
  (the default; tick **Rename it to "… (old)"** to rename it) or **Disband it** (the room id is retired and the
  file copies made for it are deleted). The new room opens after that. If Hermes refuses to create the room,
  nothing changes; if only the context note fails, the new room is still made and its note bar says so.
- **Threads:** hover a message (or right-click it) and choose **Reply in thread**. The thread opens in the right
  column with its own composer; the room composer below the timeline always writes to the whole room. Replying
  in thread to a room message starts a thread on it, and the first reply quotes that message, because bots only
  see the messages of their own thread. Thread messages also show in the room timeline with a "Thread · …"
  label; a message with a thread under it shows its reply count. Click either to open the thread.
- **Reply to @bot and Copy:** hover a bot's message for **Reply to @bot** (puts `@bot` in the composer of that
  message's thread; you still send) and **Copy** (the text as written). Your own messages offer Copy too.
- **Sidebar rows** show the last message and how long ago it was. An amber **@** badge means a bot wrote
  `@user` and you have not answered or opened the room since; an amber hand means a bot waits on your
  approval. Rooms you are not looking at are checked every 5–15 seconds. In messages, `@user` (a bot asking
  for you) is amber; mentions of bots are blue.
- **Drafts** are kept per room and per thread while the app runs, so switching rooms does not lose them.
- **Availability:** under the room name, "2 of 3 available" counts the members whose bot still exists and
  whose last turn did not fail or wait on a retry. Hover the room picture for who is out and why.
- **Room picture:** room menu (⋯) → **Choose Picture…** (PNG or JPEG, up to 15 MB, cropped to a 256 px square)
  shows it instead of the members' avatars in the toolbar and the sidebar; **Remove Picture** goes back to the
  avatars. The picture is kept on this Mac only, in
  `~/Library/Application Support/HermesBotApp/Room Pictures/`, and deleted when you disband the room.
- **Clarifying questions** from bots in a room cannot be answered here: Hermes does not pass them on to room
  clients (only approvals). A bot that needs you should write `@user`, which shows the **@** badge; answer it in
  the room.
- **Room actions in the toolbar:** the room menu (⋯) also has **Open in New Window**, **Save as Template…** and
  **Mute Notifications**, the same as the sidebar's right-click menu.
- **Templates:** right-click a group chat → **Save as Template…** (or File → Save Group Chat as Template…) keeps
  its bots and an opening prompt under a name. **File → New Group Chat from Template** opens New Group Chat with
  that name and those bots ticked (bots that no longer exist are left out); after you create it, the prompt is in
  the composer, not sent. File → New Group Chat from Template → Delete Template removes one. Templates are kept
  on this Mac.

## Importing Hermes Desktop group chats

Hermes Desktop runs its own group chats in the desktop app; they are not the backend's hosted rooms this app
uses. Desktop also saves a short copy of each one (the last 16 messages, up to 1200 characters each) into your
default profile, and **File → Import from Hermes Desktop…** reads that copy (`profiles.list`, read-only).

- Pick the rooms to import; they appear under **Desktop archive** at the bottom of the sidebar (collapsible,
  hidden while empty). Opening one shows its members and saved messages, read-only. Earlier messages Desktop did
  not save are counted, not shown.
- The archive is this app's own copy (`~/Library/Application Support/HermesBotApp/Desktop Archive/`). Importing
  never changes Hermes, your profiles or Hermes Desktop, and never creates rooms. Import again to refresh a room;
  **Remove from Archive** deletes only this app's copy.
- **Continue in a New Room…** opens New Group Chat with the archived name and its members that are bots on
  this Hermes (at least two are needed), and puts the last few messages, quoted, into the new room's composer
  for you to edit and send.

## Group Chat activity

Bots in a Group Chat work in hidden sessions, so the room itself only shows when each bot starts, replies or
passes. The **Activity** panel (toolbar button, ⌥⌘I) shows, per bot, what it is doing right now: the tool it
is running and for how long, its recent tool calls with arguments and results, its reasoning, and errors. The
bot's turn status (for example "needs approval") stays next to its live status. Several finished turns in a row
with nothing in between show as one line ("3 turns finished · 4.3–15s"). The panel stops polling while
its window is covered or the app is hidden, and picks up again when it is back.

The detailed view needs the [Bot Activity](https://github.com/risyadul/hermes-bot-activity) Hermes plugin,
because Hermes hands those events only to plugins. If it is not installed, the panel shows each bot's turn
status, a **This round** list of the latest round from the room log (queued, working, replied, passed, timed
out, failed, needs approval; newest first), and an **Enable Tracking…** button. Enable installs a pinned commit
of the plugin, turns it back on in any bot profile where it is disabled, and enables it for every bot. A copy
that is already installed but disabled is turned on only if Hermes's install record pins it to that same
commit; otherwise the panel says the installed copy isn't the reviewed version and offers **Reinstall Pinned
Version…**, which replaces it with the pinned commit. Bots added after tracking was enabled are listed with an
**Enable for N More Bots** button. Enabling and turning off run once for the whole app: a
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
- **AI actions:** a card's details (and its right-click menu) offer **Estimate** (a rough token and size
  guess, not a bill), and on a Triage card **Decompose…** (splits it into subtasks across your bots; the
  new subtasks are listed and open with a click) and **Specify…** (rewrites its title and description and
  moves it to Todo). Both change the card at once, so they ask first, and they can take a minute or more.
  **Model** pins the model and reasoning effort a card's worker uses (Profile default otherwise). Reassign
  is the **Assignee** menu (it releases a running worker first).
- **Boards:** the ••• **Board** menu in the board header creates, renames and deletes boards, exports a board
  to a `.tar.gz` archive and imports one as a new board. Deleting archives the board (it can be restored in
  Hermes); the `default` board can't be deleted, and deleting Hermes' current board warns first.
  **Orchestration Settings…** sets the orchestrator profile, the default assignee, automatic decomposition
  of triage cards and whether subtasks are queued right away (Hermes' config, shared by every board).
- **From chats to cards:** right-click a message in a Group Chat or a Bot Chat for **Create Task from
  Message…**: a New Task sheet with the message as the description, its first line as the title and its bot
  as the suggested assignee; pick the board there. A card's assignee opens its Bot Chat (**Open Bot Chat
  with @…** in the card menu, or the chat button next to the assignee).
- **Notifications for cards:** cards you create in the app, and cards you mark **Notify When Done or
  Blocked** (card menu), notify when they finish or get blocked while the app is in the background (checked
  every 15 seconds, also while the app's windows are hidden). Clicking the notification opens the card.
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
**Start** runs `hermes gateway start`; if it is not installed, run `hermes gateway install` once. That starts
Hermes' whole messaging gateway, so any chat platforms you configured in Hermes come online as well.

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
- **"Install Hermes Agent" screen / "hermes not found":** install Hermes Agent, or set
  `HERMES_BOT_APP_HERMES_BIN` to the full path of the binary and start the app from that terminal; the screen
  lists the places it checked.
- **"Choose a model for Hermes" screen:** Hermes runs but has no usable provider; run `hermes setup` or
  `hermes model`, then press Check Again.
- **Import from Hermes Desktop finds nothing:** Desktop saves its group chats into the default profile of the
  Hermes it is connected to; connect this app to the same Hermes.
- **Bots list is empty / Group Chat needs more bots:** see quick start step 2.
- **"Group Chat needs Hermes Agent v2026.9.14 or later":** the backend does not offer `groups.*`; update
  Hermes Agent. The "+" button stays disabled until then.
- **Connection lost:** the app shows a failure screen; press Try Again to reconnect.
- **My Bot Chat history looks short or empty:** Bot Chat is the bot's one chat titled "Bot Chat" and is never
  deleted by this app. `/new`, `/reset` and `/clear` compact it rather than reset it. If the app cannot find or
  confirm the chat it shows an error instead of starting a new one; press Try Again.
- **"Running in another Hermes app":** another backend process holds that bot's chat. Use it in that app.
- **PDF attachment fails:** PDFs are rendered with `pdftoppm` on the backend machine; install it (poppler).
- **"HermesBot.app can't be opened" / "Apple could not verify…" on first launch:** the release is ad-hoc signed,
  not notarized. Right-click the app → **Open** (macOS 15: System Settings → Privacy & Security → **Open
  Anyway**), or run `xattr -dr com.apple.quarantine HermesBot.app`. A notarized release will not need this.
- **"Couldn't check for updates":** the message says why. "limit for unauthenticated requests" means GitHub's
  hourly limit for your network address was used up (shared networks hit it sooner); try again later or open the
  [Releases page](https://github.com/risyadul/HermesBotDesktop/releases) yourself.
- **Is my copy Intel or Apple silicon?** `lipo -archs /Applications/HermesBot.app/Contents/MacOS/HermesBotApp`
  prints `x86_64 arm64` for the universal release.

## Download / packaging

Tagged releases attach `HermesBot-<version>-macos-universal.zip` (one app for Apple silicon and Intel) and
`SHA256SUMS.txt` on [GitHub Releases](https://github.com/risyadul/HermesBotDesktop/releases). To build the same
bundle yourself:

```sh
scripts/package-app.sh 0.2.0 --universal   # dist/HermesBot.app + dist/HermesBot-0.2.0-macos-universal.zip
scripts/package-app.sh 0.2.0               # this Mac's architecture only: ...-macos-arm64.zip or -x86_64.zip
scripts/package-app.sh 0.2.0 --universal --dry-run   # print the plan (architectures, signing) and stop
scripts/package-app.sh --help
```

Without a Developer ID the app is **ad-hoc signed, not notarized**. On first launch macOS will refuse it:
right-click the app and choose **Open**, or run `xattr -dr com.apple.quarantine HermesBot.app`. With
`DEVELOPER_ID_APPLICATION` (and `NOTARY_PROFILE` for notarization) set, the script signs with the hardened
runtime and notarizes and staples the app; see [docs/development.md](docs/development.md#release-process).
Packages have only been checked to build, sign and lint; launching them on a clean machine is untested.

## Known limitations

- macOS only; release builds are ad-hoc signed, not notarized, until a Developer ID is configured.
- Updates are not installed automatically: the app tells you about a new release and opens its page.
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
