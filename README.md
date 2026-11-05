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
  stops it when you quit. A backend it attached to is never stopped.
- **Bot Chat sessions are deleted on quit (default).** 1:1 chats created by this app are closed and
  deleted on a normal Quit. They may be kept if the connection to the backend was lost, or if quit cleanup
  hit its 5-second deadline. To always keep them, launch with `HERMES_BOT_APP_KEEP_SESSIONS=1`.
- **Group Chat rooms are separate from the Hermes desktop app's group chats.** Rooms here are the backend's
  hosted rooms (`groups.*`); group chats you made in the Electron app will not show up, and vice versa.
- **It does not change your profiles or bot config.** Bots are your existing Hermes profiles.
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

## Configuration

| Variable | Effect |
|---|---|
| `HERMES_BOT_APP_HERMES_BIN=<path>` | `hermes` executable used when the app has to start a backend. Absolute path (or `~/…`); replaces the automatic search |
| `HERMES_BOT_APP_KEEP_SESSIONS=1` | keep 1:1 chat sessions on quit |
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
- **My Bot Chat history is gone:** by design, 1:1 sessions are deleted on a normal quit unless
  `HERMES_BOT_APP_KEEP_SESSIONS=1`. (After a lost connection or a quit that hit the 5-second deadline,
  some may be left behind.)

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
