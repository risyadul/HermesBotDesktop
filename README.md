# Hermes Bot for macOS

A lightweight native macOS (SwiftUI) client for [Hermes Agent](https://github.com/NousResearch/hermes-agent),
focused on three things: **Bots**, **Bot Chat** (1:1, streaming) and **Group Chat** (2–6 bots in one room).

It is a thin client: all agent logic runs in the Hermes backend (`hermes serve`). The app talks to it over
the gateway WebSocket (JSON-RPC) and does not reimplement any agent behavior.

> **Independent project.** Not affiliated with or endorsed by Nous Research. "Hermes" refers to the
> Hermes Agent backend this app connects to.

**Status: early / pre-release.** Build from source only; no signed release binary yet.

<!-- TODO before publishing: screenshot (light + dark). -->

## Before you start: what this app does to your Hermes data

- **It uses your real Hermes install (`~/.hermes`).** If a Hermes backend is already running (for example the
  Hermes desktop app), this app attaches to it. Otherwise it starts its own `hermes serve` on `~/.hermes` and
  stops it when you quit. A backend it attached to is never stopped.
- **1:1 chats are deleted when you quit (default).** Bot Chat sessions created by this app are closed and
  deleted on Quit. To keep them, launch with `HERMES_BOT_APP_KEEP_SESSIONS=1`.
- **Group Chat rooms are separate from the Hermes desktop app's group chats.** Rooms here are the backend's
  hosted rooms (`groups.*`); group chats you made in the Electron app will not show up, and vice versa.
- **It does not change your profiles or bot config.** Bots are your existing Hermes profiles.
- Setting `HERMES_HOME` does **not** isolate the app today; it always uses `~/.hermes`.

## Requirements

| | |
|---|---|
| macOS | 14 or later (Apple Silicon tested; Intel untested) |
| Toolchain | Xcode 26 / Swift 6.3 (tested). Command Line Tools only: **untested** |
| Hermes Agent | installed and configured with a model provider (see below) |
| `hermes` binary | at `~/.local/bin/hermes`, **or** set `HERMES_BOT_APP_HERMES_BIN` (the app does not search `$PATH`) |

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
3. **Make the `hermes` binary findable.** If `which hermes` is not `~/.local/bin/hermes` (Homebrew, pipx,
   venv, …):
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
| `HERMES_BOT_APP_HERMES_BIN=<path>` | `hermes` executable used when the app has to start a backend |
| `HERMES_BOT_APP_KEEP_SESSIONS=1` | keep 1:1 chat sessions on quit |
| `HERMES_BOT_APP_NO_SPAWN=1` | only attach to a running backend; never start one |
| `HERMES_BOT_APP_APPEARANCE=light\|dark` | force appearance |

Developer/test variables are listed in [docs/development.md](docs/development.md).

## Troubleshooting

> ⚠️ Failure messages below are not yet verified on a clean machine.

- **Backend does not start:** check `~/Library/Logs/HermesBotApp/serve.log`; usually the `hermes` path
  (quick start step 3) or a missing provider config (step 1).
- **Bots list is empty / Group Chat needs more bots:** see quick start step 2.
- **Group Chat unavailable:** your Hermes Agent version may lack `groups.*`; update Hermes.

## Known limitations

- macOS only; build from source (no signed/notarized `.app`).
- Group Chat follows rooms by polling (the backend has no push for rooms yet).
- No isolated mode for end users; always uses `~/.hermes`.

## Contributing

See [docs/development.md](docs/development.md) for layout, tests (`swift test`, no live backend needed),
harness CLIs and protocol notes ([gateway contract](docs/gateway-contract.md),
[groups contract](docs/groups-contract.md)). <!-- TODO: CONTRIBUTING.md, SECURITY.md, issue templates -->

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

Unless you explicitly state otherwise, any contribution you intentionally submit for inclusion in this
project is licensed under the same terms, without any additional terms or conditions.
