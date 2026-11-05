# Contributing

Thanks for helping. This is a small, independent project; keep changes focused.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Scope is deliberately narrow: **Bots, Bot Chat and Group Chat** on macOS. Features outside that scope
  (settings editors, other Hermes surfaces, other platforms) are unlikely to be merged.
- The app is a thin client. Agent behavior belongs in [Hermes Agent](https://github.com/NousResearch/hermes-agent),
  not here.

## Setup

Follow the [README](README.md) quick start, then read [docs/development.md](docs/development.md) for the code
layout, harness CLIs and test-only environment variables. Protocol details are in
[docs/gateway-contract.md](docs/gateway-contract.md) and [docs/groups-contract.md](docs/groups-contract.md).

## Making a change

1. Branch from `main`.
2. `swift build` and `swift test` must pass. The test suite does not need a live backend and, by default,
   opens no windows. The suites that open real windows (`BotChatLayoutTests`, `InspectorLayoutTests`,
   `SidebarLayoutTests`, `MotionSheetTests`) are opt-in locally: run `HERMES_BOT_APP_WINDOW_TESTS=1 swift test`
   before any UI change (windows appear on screen while it runs). CI runs `BotChatLayoutTests`; the
   pixel-exact suites skip there because hosted runners have a smaller screen and an older macOS.
3. Add a regression test for bug fixes where the logic is testable (most logic lives in `HermesGatewayKit`).
4. UI changes follow [DESIGN.md](DESIGN.md) (tokens mirrored in `Sources/HermesBotApp/DesignSystem.swift`).
   Include light and dark screenshots in the pull request.
5. If you change how the app talks to the backend, update the contract docs and say which Hermes Agent version
   you tested against.

## Testing against a real backend

Live runs use your real `~/.hermes`. Do not commit anything from it, and clean up what you create; the rules
and cleanup commands are in [docs/development.md](docs/development.md#test-data-and-cleanup). The `evidence/`
directory is git-ignored because it holds raw chat traffic: keep it that way.

**Never paste tokens, API keys or session tokens** into issues, pull requests, logs or test fixtures.

## Pull requests

- One topic per pull request, with a clear description of what changed and how you verified it.
- Say what you could not verify (for example: tested only on Apple Silicon, only with one Hermes version).

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
