# Gateway contract: attach-first connection + Bots + Bot Chat 1:1 (M1) + Group Chat (M2)

Status: M1, 2026-11-03, round 2 (review fixes: §1.6 token-safe errors, §3.3 submit gate,
§4.5 turn settling, §4.6 disconnect). Builds on `docs/groups-contract.md` (M0, `groups.*`,
WS framing, error envelope), which stays valid; this file adds the connection procedure and the 1:1
chat methods the app now uses.
M2 (2026-11-03): §7 is the final `groups.*` contract the Group Chat uses (room
update model, approve/stop/retry). Where §7 and groups-contract.md differ, §7 wins.
M3 (2026-11-05, desktop parity): §8-§13 document what the app now does beyond the M1 flow:
canonical Bot Chat (§8), server→client requests (§9), tool activity (§10), slash commands (§11),
attachments (§12), `MEDIA:` files (§13). §8-§13 replace the ephemeral `hba-` 1:1 flow of §3.1/§3.2/§3.4
for the app's Bot Chat; those sections stay as the record of what was run in M1. Wire facts in §8-§13
come from backend source (citations below) and the kit's fake-gateway unit tests. **No live run was done
for any of §8-§13**; see §14.
Reference source (read-only): [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) @ `8a7a5a905fc6` (local checkout `~/.hermes/hermes-agent`).
Paths below are relative to that checkout.

Tags:
- **[run]**: observed on the wire in `evidence/m1/*` (`chat.json` = decoded summary + events with
  timestamps, `wire.log` = raw frames minus pings; `*-console.log` = harness/app log).
- **[src]**: read from source only.
- **[test]**: covered by `swift test` (`Tests/HermesGatewayKitTests`, no live backend).
- M2 evidence is in `evidence/m2/` (harness: `scenario.json` + `wire.log` + `*-console.log`;
  app: `app-*/` = window snapshots `r*.png` + `ui-log.json` + `console.log`).
- Round-2 runtime evidence is in `evidence/m1-r2/` (`kb-probe/` = the real `BotChatView` in an
  `NSHostingView` driven by NSEvent Return against the attached Electron backend).

---

## 1. Connection: attach-first, spawn-if-absent

Implemented in `Sources/HermesGatewayKit/HostRendezvous.swift` (discovery) and `Backend.swift`
(connect/spawn/shutdown).

### 1.1 Where running backends announce themselves [src + run]

- Lock dir: `$HERMES_GATEWAY_LOCK_DIR`, else `$XDG_STATE_HOME/hermes/gateway-locks` (absolute only),
  else `~/.local/state/hermes/gateway-locks` (`gateway/status.py:319-335`). Per OS user, shared by all
  profiles.
- Per role R a winner writes `host-R.lock` (flock, held for its lifetime), `host-R.json` (record, 0600)
  and, for serve roles, `host-R.token` (live session token, 0600; tmp file + atomic replace)
  (`gateway/host_rendezvous.py:208-218`, `373-399`, `465-507`).
- Record JSON (`HostRecord.to_json`, `:107-120`):
  `{role, home, pid, createTime, startTime, host, port, protocolVersion, tokenFingerprint, profiles, updatedAt}`.
  `tokenFingerprint` = first 16 hex of sha256(token) (`:220-222`). The token itself is never in the record.
- Roles (`:64-72`):
  - `serve`: the machine-level owner, a standalone `hermes serve`/`dashboard`.
  - `desktop-serve`: the Electron app's own backend (`HERMES_DESKTOP=1` + per-spawn token,
    `hermes_cli/process_identity.py:243-259`). It publishes under this role, never `serve`
    (`hermes_cli/web_server.py:1320-1371`).
  - `gateway`: the messaging gateway; no token, no WS. Not used by the app.
- The CLI's own attach ladder reads only `serve` (`hermes_cli/main_dashboard.py:818-835`). The app reads
  `serve` first, then `desktop-serve`.
- [run] On this machine during M1: `host-desktop-serve.json` = pid 29903, port 51410, protocolVersion 1,
  served profiles `[default, builder, reviewer, assistant, planner, researcher]`;
  no `host-serve.json` (only the bare `host-serve.lock`). `evidence/m1/baseline.txt`.

### 1.2 Accepting a record (all must pass; mirrors the Python checks)

| # | Check | Source | Tag |
|---|---|---|---|
| 1 | Record file, token file and lock dir owned by this uid | `_record_is_own` `host_rendezvous.py:178-199` | src |
| 2 | `protocolVersion == 1` | `HOST_PROTOCOL_VERSION` `:54`, `record_is_stale` `:257-271` | src |
| 3 | PID alive, and its start fingerprint matches `startTime` within 200. On macOS the fingerprint is `round(psutil.create_time()*100)` (centiseconds since epoch); the app reads `kinfo_proc.p_starttime` via sysctl. Legacy records without `startTime` fall back to `createTime`. Dead → reject; unprovable → defer to the probe (#5) | `_record_incarnation_matches` `:239-254`, `gateway/status.py:452`, `470-507` | src + run (29903 accepted) |
| 4 | Token file non-empty, owner-only mode, sha256(token)[:16] == `tokenFingerprint` (a mismatch = torn restart) | `record_token_is_consistent` `:361-370` | src + run |
| 5 | TCP connect to `dial_host:port` (wildcard host → 127.0.0.1), then `GET /api/host/identity` with headers `X-Hermes-Token: <token>` and `Authorization: Bearer <token>` returns 200 `{ok, protocolVersion:1, pid, role, servesSpa}` with `pid`/`role` equal to the record | `probe_owner` `:285-325`, route `hermes_cli/web_routers/status.py:130-145` | src + run |

[run] `attach-run1-console.log`: `serve: reject (no record)` → `desktop-serve: ACCEPT (pid=29903 port=51410)`.
`spawn-run1-console.log`: the app's own spawned serve passes the same checks under role `serve`
(`re-discovery against own spawn: serve: ACCEPT (pid=73346 port=65325)`).

Then connect `ws://<dial_host>:<port>/api/ws?token=<token>` exactly as in groups-contract §2 (loopback
`?token=` auth, no subprotocol negotiated). [run] `gateway.ready` arrived on the Electron backend.

The token is read into memory only. It is never logged, and it is never written to repo or evidence
files (the wire log holds frames only; the WS URL is not logged). Error text is the other channel, see
§1.6.

### 1.3 Spawn-if-absent [src + run]

When no record is accepted, the app spawns (`ServeProcess.Configuration.sameHomeDefault()`):

```
hermes serve --host 127.0.0.1 --port 0 --isolated
env: clean, HERMES_HOME=~/.hermes, HERMES_DASHBOARD_SESSION_TOKEN=<32 random bytes, b64url>,
     HERMES_PARENT_PID=<app pid>, no HERMES_DESKTOP, HERMES_GATEWAY_LOCK_DIR unset (= real dir)
```

- READY = first stdout line `HERMES_BACKEND_READY port=N` (groups-contract §1). The app drains stdout and
  stderr into `~/Library/Logs/HermesBotApp/serve.log`.
- `--isolated` only skips the child's own attach-first ladder (`main_dashboard.py:895`): without it, a
  `host-serve` owner appearing between our discovery and the child's start would make the child print
  "already running" and exit 0 without READY.
- **Correction to an earlier probe, §1 requirement 2 / §5.2**: `--isolated` does NOT keep the child out of the
  rendezvous. After bind every non-desktop serve claims `ROLE_SERVE` and publishes `host-serve.json` +
  `.token` when the lock is free (`web_server.py:1320-1371`, called unconditionally at `:1465`). A later
  CLI `hermes serve` would therefore attach to the app's backend. [run] `spawn-run1-console.log`:
  `host-serve.json 600, host-serve.lock 644, host-serve.token 600` in the lock dir while the child ran.
- Same home is deliberate. The probe showed that two serves on `~/.hermes` coexist (desktop-serve and
  serve are different roles), and that the per-room durable lease fences double execution of room turns.
  1:1 sessions do not touch rooms. [run] `hosted_room_driver_leases` held 0 rows before and after every
  M1 run.

### 1.4 Lifecycle and cleanup

- Attached backend: the app only closes its socket. It never signals that process. [run] after every
  attach run: `attached backend left running (not ours)`, `/api/health` on 51410 = 200, Electron
  29443/29903 start time unchanged (`Tue Nov 3 12:25:10/12:25:14`).
- Owned backend: `ServeProcess.stop()` = SIGTERM, then SIGKILL after 10 s. The serve's prepended SIGTERM
  handler removes its record + token and releases the host lock (`host_rendezvous.py:538-611`).
  [run] `spawn-run1`: after shutdown, pid 73346 `kill0_alive=false` and the lock dir held only
  `host-serve.lock`. `app-spawn-sigterm`: app SIGTERM → graceful quit → `owned backend pid 73931 stopped`.
- App crash: `HERMES_PARENT_PID` arms the serve's parent-death watchdog (poll 2 s,
  `hermes_cli/web_server_lifecycle.py:326-375`). It shuts down by raising SIGTERM in-process
  (`_request_orphan_shutdown`, `:303-323`; a 10 s `os._exit` ceiling backstops a stalled unwind),
  so the rendezvous SIGTERM handler still clears the record.
  [run] `app-spawn-sigkill-post.txt`: app SIGKILLed → serve 74214 gone within 1 s, lock dir clean, no
  `--isolated` serve left.
- App-side SIGTERM is mapped to the same graceful quit (DispatchSource → `NSApp.terminate`).
  Termination uses cancel → async cleanup → terminate again, not `.terminateLater`. With
  `.terminateLater` the MainActor continuations never ran, and the quit hung until SIGKILL
  (`evidence/m1/app-attach-run1-quit-hang-console.log`).

### 1.5 Test-only overrides (app + harness)

- `HERMES_BOT_APP_LOCK_DIR=<dir>`: discover in, and hand the spawned child, that lock dir. An empty dir
  simulates "no backend running" without stopping Electron. All M1 fallback evidence used a private empty
  dir. The production default (real lock dir) differs only in this env var, and was not exercised with a
  spawn (Electron was alive and must not be stopped).
- `HERMES_BOT_APP_FORCE_SPAWN=1`, `HERMES_BOT_APP_NO_SPAWN=1`.

### 1.6 Token-safe error text [test + run]

Foundation transport errors from `URLSessionWebSocketTask` carry the request URL in `userInfo`
(`NSErrorFailingURLKey` / `NSErrorFailingURLStringKey`), i.e. `ws://…/api/ws?token=<live token>`.
Interpolating one (`"\(error)"`) printed the token (an earlier review finding: `session.close`/`session.delete`
notes after a client-side socket close). Rules now:

- `GatewayClient.sanitize` converts every Foundation error into
  `ClientError.transport(domain, code, message)` before any continuation resumes or `onDisconnect`
  fires. `message` is `localizedDescription`, scrubbed; `userInfo` is dropped.
- `GatewayClient.close()` clears its task, so later calls fail fast with `notConnected` instead of
  sending on a cancelled task.
- Every consumer turns errors into text only through `Redaction.describe(_:)`: known kit error types
  keep their description; anything else becomes `domain code: localizedDescription`. The result is
  scrubbed for `?token=`/`&token=` values, `Bearer …`, `X-Hermes-Token …` and
  `hermes-gateway-ticket.…` (`Sources/HermesGatewayKit/Redaction.swift`). Users: app connect/send
  failures, `BotChatSession.close` notes, both harnesses, `RoundTrip`.
- [test] `TokenLeakTests`: connect refused on a closed loopback port, and `session.close`/
  `session.delete`/`prompt.submit` after a client close and after a server drop. They run against an
  in-process fake `/api/ws`. Each checks interpolation, `String(reflecting:)`, `localizedDescription`,
  `userInfo` and `describe`. Mutation check: with `sanitize` disabled and the old `close()`, 3 of the 4
  tests fail on the token.
- [run] `evidence/m1-r2/kb-probe/kb-probe.json` case `E-drop-mid-turn`, attached to desktop-serve 29903:
  `notes_contain_live_token=false`, `notes_contain_token_query=false`, `ui_error_lines_contain_token=false`.
  `final-checks.txt`: live desktop-serve token found in 0 of 119 repo/log/scratch files.

## 2. Bots: `profiles.list` [run]

- Params: `{include_sessions: false}`. Result and fields as in groups-contract §3.2
  (`tui_gateway/methods_profiles.py:281-303`).
- The app maps each profile to a bot: `name`, `display_name`, `description`, `model`, `provider`,
  `is_default`, `skill_count`.
- [run] attached to desktop-serve 29903: 6 bots = the user's real profiles
  (`default` [is_default, claude-opus-5-5[1m]], `builder`, `reviewer`, `assistant`,
  `planner`, `researcher` [example-model-flash]). The spawned same-home serve returned the same 6.

## 3. Bot Chat 1:1

Implemented in `Sources/HermesGatewayKit/BotChat.swift` (`BotChatSession`).

> **Replaced (M3).** §3.1, §3.2 and §3.4 describe the M1 flow: a throwaway `hba-` session
> (`close_on_disconnect: true`, `session.title hba-…`, `session.close` + `session.delete` on quit). The app's
> Bot Chat now opens the bot's canonical chat instead (§8): `close_on_disconnect: false`, title `"Bot Chat"`,
> teardown = detach only. The M1 flow is kept in the kit as `BotChatSession.open` (non-canonical sessions) and
> is the evidence base for §3.2's title-race findings. The M1 text below is history, not current behavior.

### 3.1 `session.create` [run] — M1 flow, replaced by §8

- Params used: `{profile: <bot name>, close_on_disconnect: true, cols: 100}`
  (`SessionCreateParams`, `tui_gateway/contracts/sessions.py:119-148`; handler
  `methods_session.py:337-489`).
  - `profile` re-binds `HERMES_HOME` for the agent build and every turn (`:340-342`, `server.py:575-595`).
  - `close_on_disconnect` makes a dropped socket reap the live session immediately
    (`session_lifecycle.py:1000-1032`).
- Result: `{session_id: <8-hex runtime id>, stored_session_id: "<YYYYMMDD_HHMMSS_xxxxxx>",
  message_count: 0, messages: [], info: {model, provider?, cwd, lazy: true, profile_name, …}}`.
  - The agent builds after the reply.
  - No DB row exists yet: the row is created lazily on the first prompt (`:453-476`).
- The creating socket becomes the session's transport (`"transport": current_transport()`, `:442`).
  That binding is what routes the turn's events to this client (§4).

### 3.2 `session.title` (set before the first prompt) [run] — M1 flow, see §8 for the canonical title

- Params: `{session_id, title}`. Result `{pending: false, title}`.
- With no row yet, the handler persists the row now and writes the title with `user` provenance
  (`methods_session.py:1226-1254`, `hermes_state_titles.py:156-159`). Test titles use `hba-`.
- Why not `session.create {title}`? That only queues `pending_title`, applied after the turn
  (`prompt_turn.py:397-409`).
  - The turn-start auto-titler first writes a `derived` title. Its LLM upgrade thread then writes an
    `llm` title, and it accounts usage against the session id (`agent/title_generator.py:642-700`,
    `736-800`).
  - [run] `evidence/m1/attach-run1`: with `title` on create, the final title became the auto title
    "Count 1 to 20 in words", not `hba-…`.
  - The row was **re-created ~2 s after `session.delete`** (`started_at` 10:51:28 > delete at 10:51:26,
    `source='unknown'`, 0 messages). This is a backend race between delete and the upgrade thread.
    `attach-run1-leftover-cleanup.log` records the cleanup.
  - A `user` title makes `auto_title_session` return before any write (`_has_upgraded_title`,
    `title_generator.py:563-571`). [run] attach-run2: 15 s after delete, 0 rows and 0 messages.

### 3.3 `prompt.submit` [run]

- Params used: `{session_id, text}` (`PromptSubmitParams`, `contracts/prompt_voice.py:26-53`; handler
  `methods_prompt.py:735-886`).
- Result (idle session): `{status: "streaming", user_row_id: N}`. The reply itself only arrives as events.
- When a turn is already running, the busy path answers `queued`/`steered`/`redirected` instead
  (`PromptSubmitStatus` `:56-60`, `session_auto_continue.py:404`) [src]. The app never sends while its
  turn runs (submit gate below), so it does not exercise these statuses.
- Multi-turn [run]: `kb-probe` sent 3 turns on one session (`prompt.submit` → `user_row_id` 1131, 1133,
  1135), each settled with `message.complete`.

#### Submit gate (app) [test + run]

- `ChatTranscript.beginTurn` is the only way a user line enters. It refuses blank input and any input
  while a turn runs, and it changes nothing when it refuses.
- `ChatModel.submit` calls it synchronously on the main actor before starting the network task. The
  view clears its draft only when `submit` returns true. Return (`TextField.onSubmit`) and the Send
  button share that path; `.disabled` on the button alone did not stop Return (found in review).
- [test] `testBusyRefusesSubmitAndKeepsState`, `testDoubleSubmitBeforeAnyEventPassesOnce`.
- [run] `kb-probe` (NSEvent Return keyCode 36 into the real NSTextField, first responder
  `_SystemTextFieldFieldEditor`):
  - A, idle Return: draft cleared, 1 user line.
  - B, Return while streaming: draft `"Please retain the follow-up"` kept, still 1 user line, still 1
    `prompt.submit` frame (`B-busy-return.png`).
  - C, idle Return after completion: the kept draft is sent.
  - D, two synchronous `submit`s: `[true, false]`, exactly one more `prompt.submit` frame.
- A client-supplied `_turn_author` is refused with 4124 (`methods_prompt.py:761-764`) [src].

### 3.4 Teardown [run] — M1 flow, replaced by §8.5

- `session.close {session_id}` → `{closed: true, messages: []}` (`methods_session.py:2202-2206`).
  The stored row stays resumable.
- `session.delete {session_id: <stored_session_id>, profile}` → `{deleted: <id>}`.
  - It takes the STORED id.
  - It refuses with 4023 while the session is live in this process, hence close first
    (`methods_session.py:1181-1205`).
- App policy (M1, **replaced by §8.5**): app chats were ephemeral. On quit the app closed and deleted them;
  `HERMES_BOT_APP_KEEP_SESSIONS=1` kept them. The canonical Bot Chat is never closed or deleted. The
  close + delete path remains in the kit only for non-canonical sessions.
- Crash path [run]: an app SIGKILL leaves the stored row. `close_on_disconnect` reaps only the live
  session. The leftover in `app-spawn-sigkill` was deleted afterwards with
  `bot-chat-harness --delete researcher <id>`.
- Other methods [src, not called]: `session.interrupt {session_id, expected_hosted_task_id?}`
  (`contracts/sessions.py:604-619`) is wired in `BotChatSession.interrupt()`, but no UI calls it in M1.

## 4. Streaming: how a 1:1 turn reaches the client

### 4.1 Routing [src + run]

- Turn events are JSON-RPC notifications:
  `{"jsonrpc":"2.0","method":"event","params":{"type":T,"session_id":<runtime id>,"payload":P?,"seq":N}}`
  (`_event_frame`, `tui_gateway/server.py:701-711`). `seq` is a per-session monotonic stamp for replay
  (`write_json` `:681-698`, `session.events.since` `methods_session.py:2334`).
- `write_json` sends any event frame carrying a `session_id` to THAT session's transport, which is the
  creating WS. So 1:1 streaming is pushed over the socket and needs no polling.
- This is unlike room member sessions: they have no transport, so their frames fall to stdout
  (groups-contract §5).
- Session-less broadcasts arrive with `session_id: ""`: `sessions.changed`, `platforms.changed`,
  `plugin.bot-activity.changed`.
- The app routes by `params.session_id` (`EventRouter` in `Backend.swift`).

### 4.2 Coalescing [src + run]

- `message.delta`, `reasoning.delta` and `thinking.delta` are buffered per connection and flushed every
  ≤33 ms (`tui_gateway/ws.py:77-83`, `123-150`). Any other frame flushes the buffer ahead of itself, so
  order holds.
- Each frame is still its own WS text message (`_safe_send_many` `:195-215`).
- One `message.delta` = one model chunk, not one token.

### 4.3 Event sequence of one turn [run]

Taken from `evidence/m1/attach-run1/wire.log`, attached to Electron desktop-serve, profile `researcher`.

| t (s) | type | payload (shape) |
|---|---|---|
| 0.379 | `session.info` | `{model, provider, reasoning_effort, …}` (live settings) |
| 0.379 | `message.start` | none |
| 1.576 | `session.title` | `{session_id: <stored id>, title}` (auto-title; absent once a `user` title is set) |
| 1.614 → 8.859 | `thinking.delta` | `{text}` (spinner text, then `""`) |
| 8.859 → 9.078 | `reasoning.delta` | `{text}` |
| 9.188, 9.346, 9.347 | `message.delta` | `{text}` (three chunks of the reply) |
| 9.352 | `reasoning.available` | `{text}` |
| 9.425 | `session.usage` | `{usage{…}}` |
| 9.437 | `message.complete` | `{text: <full reply>, usage, status: "complete", …}` |

- Payload models: `contracts/events.py:113-213` (`StreamDeltaPayload {text, rendered?, verbose?}`,
  `MessageCompletePayload {text, usage?, status? ∈ complete|error|interrupted, reasoning?, error?,
  failure_reason?, partial?, persisted_turn?, response_previewed?, response_reused?,
  response_transformed?, rendered?, …}`). The flags are set in `_complete_turn_payload`
  (`prompt_turn.py:952-965`). §4.5 covers how the app uses them.
- `message.interim {text, already_streamed}` carries commentary beside tool calls (`:131-140`) [src].
- `error {message}` is a session-level failure outside a turn (`:98`) [src].
- Bot Chat silence: for the canonical Bot Chat (title exactly `"Bot Chat"`, `tools/bot_mode_probe.py:31`)
  deltas are withheld while the buffer could still be a silence marker (`prompt_turn.py:31-42`, `744-767`).
  A client must keep the streamed text when `message.complete.text` is `""`. The M1 `hba-` sessions never hit
  this path. The canonical chat (§8) does; the transcript keeps the streamed text when the final is empty
  (§4.5), not run live.
- Observed chunking [run]: with example-model-flash via antigravity, the reply text arrives as 2–7
  `message.delta` frames in a 0.2–0.7 s burst, after 8–22 s of `thinking`/`reasoning` events.
  - App attach run: `ui message.delta` at 23.575 → 24.300 s, the bubble growing 109 → 870 chars over
    7 frames (`app-attach-console.log`).
  - App spawn run: 6 frames, 10 → 698 chars.

### 4.4 UI evidence [run]

`evidence/m1/app-attach/` holds in-app window renders (`cacheDisplay`; screen capture is not permitted
for this session):

- `1-selected.png`: bot list and empty chat.
- `2-streaming.png`, rendered at the first delta: sidebar with the 6 real bots, footer
  `attached role=desktop-serve pid=29903 port=51410`, header `streaming…`, and the partial bot bubble
  with a `streaming…` label.
- `3-complete.png`: the full reply.

`evidence/m1/app-spawn-sigterm/3-complete.png` shows the fallback: footer
`spawned pid=73931 port=49188 (--isolated)`.

Round 2 re-runs (`evidence/m1-r2/`):
- `attach-harness` exit 0: desktop-serve 29903:51410, 6 bots, 3 deltas + complete.
- `app-attach` (renders 1–3): 3 deltas, 28 → 131 chars.
- `spawn-harness` exit 0: private empty lock dir, serve 96330:56798 `--isolated`. Afterwards
  `kill0_alive=false` and only `host-serve.lock` is left.
- `app-spawn-sigterm`: app 96739 → serve 96743. After SIGTERM both are gone and only `host-serve.lock`
  is left (`app-spawn-sigterm-post.txt`).
- `m0-regression`: `spike-harness` exit 0, pong + `turn.settled`.


### 4.5 Settling a turn: the final text is authoritative [src + test + run]

Review finding: the app kept the streamed text whenever any delta had arrived. It therefore dropped
a final that extended or replaced the stream. The producer marks a post-stream rewrite
(`transform_llm_output`) with `response_transformed: true`: "the renderer must treat this payload as
the authoritative replacement even without a prefix relationship" (`prompt_turn.py:962-965`).

`ChatTranscript` (`Sources/HermesGatewayKit/ChatTranscript.swift`) now follows the TUI reference
`recordInterimMessage` / `recordMessageComplete` (`ui-tui/src/app/turnController.ts:629-760`,
`772-796`, `finalTail` `:112-124`), reduced to bubbles:

| Event | Effect |
|---|---|
| `message.start` | opens the live bubble (`streaming`) |
| `message.delta {text}` | appended to the live bubble |
| `message.interim {text}` | non-empty text: the live bubble is sealed as its own segment with the interim text as content, or a sealed bubble is appended when nothing streamed. The interim boundary moves past it |
| `message.complete`, no string `text`/`rendered` | the streamed bubble is the answer |
| `message.complete`, `response_transformed` + non-empty `text` | `text` REPLACES the live bubble |
| `message.complete`, streamed text not contained in `text` (e.g. `text: ""` from the Bot Chat silence guard) | the streamed bubble is kept as a segment |
| `message.complete` (all cases) | shown = `text` minus leading segments it repeats. It dedupes against segments after the interim boundary, or all segments when `response_previewed`/`response_reused`. Shown text takes the live bubble's place; an empty live bubble is dropped. A `status` other than `complete` adds an error line |

Decoding: `ChatCompletion` keeps `text` (string, else `rendered`, else nil), `status`, `error` and the
three flags (`BotChat.swift`).

App choices vs the TUI, stated rather than hidden:
- With `response_transformed` and a non-empty final, the streamed tail is dropped. The TUI would still
  flush it as a segment; the app follows the producer comment.
- `response_reused` dedupes like `response_previewed`. Per `events.py:200-201`, the text "adds no text".
- A final that neither contains the stream nor is flagged transformed shows both bubbles, as in the TUI.

Coverage:
- [test] `ChatTranscriptTests`: ordinary, no-delta, extending final (`Partial` → `Partial plus final
  suffix`), transformed (`TOKEN_1` → `example-service.internal`), empty final keeps the stream (also with
  the transformed flag), missing text, empty turn, unrelated final, interim sealing (streamed and not),
  previewed dedupe, identical interim + final without preview, non-complete status.
- [run] Live turns had no transform/preview/reuse flags (`attach-harness/chat.json`: all three false).
  In `kb-probe` the settled bubble equals `message.complete.text` (`bubble_equals_complete_text=true`,
  `last_bubble_equals_complete_text=true`).
- Not run live: a transform plugin, interim commentary from tool calls.

### 4.6 Errors and disconnects end the turn in the UI [test + run]

- `GatewayClient.onDisconnect` fires once, with a token-free reason, when the socket goes after
  `gateway.ready`. `Backend` fans it out, and each `BotChatSession` emits `ChatEvent.disconnected`.
- A running turn then ends: the live bubble is sealed (dropped when empty), an error line
  `disconnected: …` is added, and `busy` clears. An `error` event does the same. Before this,
  `busy` stayed true after a drop (review WARN-001). No reconnect/replay in M1.
- Events reach `ChatModel` FIFO through `DispatchQueue.main`, not one `Task` per event, so delta
  order is preserved.
- [run] `kb-probe` `E-drop-mid-turn` (`E-disconnected.png`): socket closed right after `message.start`
  → `busy_after=false`, 0 streaming bubbles, error `disconnected: socket closed: client close`.
- [run] After a mid-turn drop, `session.delete` kept answering 4023 "cannot delete an active session"
  for ≥7 s (10 retries). It succeeded ~30 s later (`kb-probe/cleanup-retry.log`). Source:
  `close_on_disconnect` pops the live session (`session_lifecycle.py:1000-1032`), but
  `db.delete_session` raises `SessionActiveWriteGuardError` while the interrupted turn still holds its
  write guard (`methods_session.py:1193-1201`). Deleting right after a crash or drop needs a delayed
  retry.

## 5. Not proven / open

- Spawn with the REAL lock dir, i.e. the true production "no Electron" case. Only a private empty lock
  dir was used, because Electron could not be stopped. The code path differs only by the env var.
- `session.interrupt`, busy-path statuses (`queued`/`steered`/`redirected`), live `message.interim`, a live
  `response_transformed`/`response_previewed` turn. Multi-turn on one session is proven (§3.3).
- Everything in §8-§13 (canonical chat, server→client requests, tool activity, slash commands, attachments,
  `MEDIA:` files): implemented and unit-tested against a fake gateway, **not run against a live backend**.
  The M1 statement that the app never sends `client.capabilities` is obsolete: it now sends it after
  `gateway.ready` (§9.1). Details of what is unproven: §14.
- Reconnect/replay (`session.events.since`) after a socket drop. (`session.resume` is used to open the
  canonical chat, §8.3, but not as a reconnect after a drop.)
- One `session.info` frame for the 1:1 session also appeared on the spawned backend's stdout
  (`~/Library/Logs/HermesBotApp/serve.log`), besides the one on the WS. The emitting path was not
  traced. Draining stdout already covers it.
- Gated/remote auth (ticket subprotocol) and Windows.

## 6. Risks for M2 (Group Chat) — status after M2 in §7.8

- Same-home room worker: an app-spawned serve on `~/.hermes` runs a room worker on the root
  `shared-state.db` next to Electron and the messaging gateway. Leases fence double execution
  (earlier probe). Which process runs a room's turn depends on who holds that room's lease.
- `groups.*` rooms still have no WS push (groups-contract §5). Group Chat must poll
  `groups.log`/`groups.state`.
  - Member token streams stay invisible: hidden sessions have no transport.
  - Live typing for members needs either a backend change or polling `room.activity` only.
- `--isolated` publishes `host-serve`. While the app's spawned backend lives, a terminal `hermes serve`
  attaches to it, and quitting the app takes that backend away from such a CLI client.
- Leftover rows after a crash (§3.4). Moot for Bot Chat since M3 (the chat is canonical and kept, §8.5).
- Group Chat transcripts need the same settling rules as §4.5 (authoritative final, interim
  segments, the transform flag) once member replies are rendered; `ChatTranscript` is per-session
  today and does not model several authors per turn.
- Token-safe errors (§1.6) cover `GatewayClient`; any new transport (e.g. HTTP polling for
  `groups.log`) needs the same `sanitize`/`Redaction.describe` path.
- Delete after a drop needs a delayed retry (§4.6, 4023 while the write guard is held).
- The auto-title thread race (§3.2) also applies to rooms' hidden sessions created through
  `hosted_room_server_rpc.py` if the app ever deletes them. Prefer `groups.disband` over row deletes.


## 7. Group Chat (M2)

Code: `Sources/HermesGatewayKit/GroupChat.swift` (typed wire views + typed `GroupsAPI` calls),
`RoomTimeline.swift` (log reducer, discussion phase, send gate, poll policy, `RoomSync`),
`Sources/HermesBotApp/RoomModel.swift`, `RoomView.swift`, `CreateRoomView.swift`,
`Sources/GroupChatHarness/main.swift` (`group-chat-harness`, live evidence). Tests:
`Tests/HermesGatewayKitTests/GroupChatTests.swift`.

All methods below go over the same `/api/ws` JSON-RPC socket as M1 (`GatewayClient`), registered in
`tui_gateway/methods_groups.py:19-21` (`groups.capabilities` reports the same list [run, `list/`]).
Errors use the M0 envelope; app/harness render them only through `Redaction.describe` (§1.6).

### 7.1 Methods the app uses [src + run]

| Method | Params (app) | Result (fields used) | Source |
|---|---|---|---|
| `groups.list` | `{limit: 500, offset}` | `{rooms: [room], next_offset: int\|null}`; follow `next_offset` until null | `methods_groups.py:344` |
| `groups.create` | `{room_id, name, members: [{member_id, profile, handle, display_name?}]}` | `{room}` (no `latest_seq`; `idempotent: true` on an identical repeat) | `:358` |
| `groups.send` | `{room_id, event_id, payload: {text, thread_id: "main"}}` | `{event}` = the stored `message.user` (`event_id` becomes `user:<sha256>`). ACK only | `:382` |
| `groups.log` | `{room_id, since_seq, limit: 200}` | `{events, cursor, latest_seq, has_more}` | `:488` → `hosted_rooms.read_events` |
| `groups.state` | `{room_id}` | `{room, driver_status?}` (§7.3) | `:367` |
| `groups.stop` | `{room_id, cancel_id}` (fresh per press) | `{cancelled: n}` | `:429` |
| `groups.approve` | `{room_id, member_id, task_id, execution_generation, choice: once\|deny, request_id}` | `{approved: true, result: {resolved: 1}}` | `:437` |
| `groups.retry` | `{room_id, task_id}` | `{retried: true, task: {room_id, task_id, thread_id, turn_id, status: "queued", execution_generation, cancel_generation}}` | `:448` |
| `groups.disband` | `{room_id, cancel_id}` | `{tombstone: {disbanded_at, event: room.disbanded}}` | `:397` |

App rules on top of the wire:
- Room ids are minted by the app: `hba-` + 12 hex (`AppModel.createRoom`). Members are the user's bots
  with `member_id = handle = profile = profile name` and `display_name` from `profiles.list`; names that
  fail the identifier rule (`^[A-Za-z0-9][A-Za-z0-9._:-]*$`, ≤128) or are `all`/`everyone` are not
  offered (`RoomMember.forBot`) [src + test]. Create needs 2–6 bots in the UI.
- `groups.send` `text` ≤ 64 KiB (`hosted_room_discussion.py:198-203`). `RoomComposer` blocks a
  second submit while one send is in flight; a user may post while bots work (the newer message
  supersedes the older one in the same thread) [src + test].
- Room availability (`RoomComposer.availability`: `open` → `closing` while `groups.disband` is in
  flight → `closed` once disbanded or found retired, 4114). Only `open` accepts send, stop, retry,
  approve or another disband; a failed disband goes back to `open`. The gate is in the model
  (`RoomModel.send` → `RoomComposer.beginSend`), so Return (`TextField.onSubmit`, which ignores the
  Button's disabled state), the Send button and scripts all hit it; a refused submit keeps the draft.
  A disbanded room leaves the sidebar, the selection and the model cache (`AppModel.roomDisbanded`)
  [test + probe + run, §7.11].
- `cancel_id` must be unique per Stop: the fence event id is `room-stop:<sha256(cancel_id)[:32]>`
  (`hosted_rooms.py:1029-1036`), so a reused id returns the old fence and does not cover newer
  messages. The app sends `hba-stop-<uuid>` [src + test]. The server default when absent is
  `"desktop-stop"` (`methods_groups.py:433`) — i.e. reused.

### 7.2 Room update model: polling, no push [src + run]

There is no WS push for rooms: no `groups.*`/room notification is emitted on `/api/ws` (M0 §5 still
holds), and member token streams stay in hidden `bot_room` sessions with no client transport. The app
therefore polls (`RoomModel.start` → `RoomSync.refresh`):

1. `groups.log {since_seq: cursor}` repeatedly while `has_more` (≤20 pages per pass), then
   `groups.state`. Events are append-only with a contiguous per-room `seq`; applying a page skips
   `seq ≤ cursor`, so re-delivery is harmless. A seq gap reloads from 0 once [test].
   One owner per room: `RoomPoller` (HermesGatewayKit). `start()` opens a new generation, `stop()`
   (view disappear, disband, app quit) ends it. `GatewayClient.call` does not observe task
   cancellation, so a stopped loop can still get its response later, after a newer loop applied a
   newer snapshot. Each result is checked against the generation it was requested under after the
   await: a stale one is dropped before it is applied, published (`onSync`) or followed by a sleep, and
   a result behind the applied cursor is dropped too. Run 1 lacked this: delayed poll 1 overwrote
   poll 2 after disappear/appear (found in review, cursors `[2, 1]`) [test + probe, §7.11].
2. Cadence (`RoomPollPolicy`): 0 s while the log is behind, 1 s while *busy*, 5 s idle. The server's
   own worker polls at 0.25 s active (`hosted_room_service.py:31`). *Busy* =
   `driver_status.working` (any task `queued|running|stopping`) or `blocked`, or the latest user message
   per thread still `pending` (§7.4: between member turns `working` is briefly false), or more terminal
   tasks in `counts` than `turn.*` events in the log (a finished task's event not yet appended). The
   last rule came from a real UI run: right after Stop, the task was `cancelled` one poll before
   `turn.cancelled` landed (`evidence/m2/app-stop/console.log` 4.765 s vs 5.790 s) [run + test].
3. After every action (send, stop, retry, approve) the model cancels the pending sleep and syncs at once.

UI proof that it does not freeze after send (`evidence/m2/app-multi/console.log`, attached Electron
backend, room `hba-e380e47310ee`, researcher + reviewer): `ui room.sync cursor=1 [message.user]
working=true queued:1` (2.3 s) → `cursor=3 [message.member, turn.settled] running:1 settled:1` (13.0 s) →
`cursor=6 [message.member, turn.settled, room.activity] working=false settled:2` (21.3 s); snapshots
`r2-working.png`, `r3-first-reply.png`, `r5-settled.png` show the rows appear without user input [run].

### 7.3 `groups.state.driver_status` [src + run]

Present only when this process runs a room worker (`methods_groups.py:367-378`). Built by
`HostedRoomService.status` (`hosted_room_service.py:536-556`):

- `counts`: task rows by status, from the shared `hosted_room_driver_tasks` table, so the same from any
  process.
- `working`: any `queued|running|stopping`; `blocked`: room in the runtime blocked set or any
  `indeterminate|stopping`.
- `pending_actions`: `{kind: "retry", task_id}` for each `indeterminate|deferred` task (DB, any process),
  plus `{kind: "approval", member_id, task_id, execution_generation, request_id, session_id, run_id,
  approval: {command, description, choices, request_id}}` from `self._pending_actions` — **in memory
  of the process whose room worker runs that turn** (`_report_pending_action`,
  `tui_gateway/hosted_room_driver.py:392-405`; choices are filtered to `once|deny`).

### 7.4 Log events and discussion phase [src + run + test]

Kinds seen in M2 runs: `message.user`, `message.member` (`payload.text`, `member_id`,
`discussion_event_id`), `turn.settled` (`passed: true` = no reply), `turn.cancelled`, `room.activity`
(`status: settled|bounded`, `reason_code`, `discussion_event_id`), `room.stop_requested`,
`room.disbanded`. `turn.failed`/`turn.deferred`/`room.renamed` are rendered but were not produced live.

`RoomTimeline.phase(of: userMessage)`: `settled(reason)` / `bounded(reason)` from the matching
`room.activity`; else `stopped` if a later `room.stop_requested` fence exists (the policy never plans
it again, `hosted_room_discussion.py` `_pending_discussion`); else `superseded` if a later user message
in the same thread exists; else `pending`. The UI shows "working…" while busy (§7.2) and the room
status from `driver_status`.

`groups.send` `accepted` is only the append: completion = `message.member`/`turn.settled` per
member, then `room.activity settled` with `working=false`. Harness `multi` (`evidence/m2/multi`): seq 1
user → 2/3 researcher reply + settled (11.8 s) → 4/5 reviewer reply + settled (18.0 s) → 6
`room.activity silent_round` (19.1 s), `working=false` [run].

### 7.5 Stop [src + run]

`groups.stop` durably cancels every task in `queued|running|indeterminate|deferred|stopping`
(`_STOPPABLE_STATUSES`, `hosted_room_service.py:36`) and appends the fence. Live, attached to Electron,
1200-word essay prompt to researcher (`evidence/m2/stop`): `cancelled=1` at 4.5 s → seq 2
`room.stop_requested` → seq 3 `turn.cancelled member=researcher` (5.7 s), 0 member replies, nothing new 8 s
later. Same through the app button (`evidence/m2/app-stop`: `ui.stop` → `groups.stop → cancelled 1` →
`turn.cancelled`; snapshots `r2-working.png`, `r4-stopped.png`) [run].

What Stop does NOT guarantee: that the member's model call has ended. The driver acknowledges the stop
through `session.interrupt {expected_hosted_task_id}` on the member session
(`hosted_room_driver.py:360-377`, `methods_session_interrupt.py:49-73`), which is cooperative. trial 308
(`trial-308/app-stop` + `trial-308/cleanup-stop`): `turn.cancelled` at 6.9 s and disband at 8.4 s, yet researcher's
member runtime stayed `working` (derived title) for ~135 s more, then went `idle` with the title
`Group: <room_id>` — which is only written after a `complete` turn (`prompt_turn.py:384-409`), so the
physical turn most likely ran to completion [run + src inference]. Nothing was published to the room
after `turn.cancelled` while the app watched. Cleanup therefore waits for `idle` (§7.8).

### 7.6 Retry [src + run]

Only `indeterminate|deferred` tasks are retryable, and only by an explicit `groups.retry`
(`_RETRYABLE_STATUSES`, `hosted_room_service.py:37,490-496`); the backend never re-runs them on its own
because the lost turn may have had side effects. Unknown/other task → error "no retryable room task
matches task_id".

`groups.retry` is lease-fenced: `retry_indeterminate` first takes the room lease
(`tui_gateway/hosted_room_driver.py:243-251` → `_ensure_lease` → `gateway/hosted_room_driver.py:505-531`).
While another live process generation holds the lease — the holder renews it every cycle while the
room has an unresolved task, and releases leases only when its worker stops
(`tui_gateway/hosted_room_driver.py:425-442,541-576`) — the call fails with
`5118 room driver lease is held by another generation`. So only the process that runs the room can
retry it; the app shows that hint on 5118. Same-home processes that run room workers: Electron
`desktop-serve`, the messaging gateway (no WS port), any other `hermes serve`.

How a task becomes retryable in practice: the process running the turn dies. Runs:
- Run 1 `retry-attach` (user install, attached to Electron): harness serve S on `~/.hermes` (private
  lock dir) ran researcher's turn; SIGKILL S → after expiry the lease row showed lease_generation 2 under
  the same process generation that held every app-created room (Electron) → `indeterminate`,
  `blocked=true`, pending `retry` → `groups.retry` → `queued` → reply + `turn.settled` +
  `room.activity silent_round`. Its `lease_before_kill` read came back blank (an unretried
  `immutable=1` read), so S's own generation was not recorded [run, weaker].
- trial 306 `retry-attach-2` (stricter probe: retried reads, `lease_takeover_proven` requires a
  readable before-row and a new process generation with a higher lease_generation): S generation
  `7587ec6e…|1` → SIGKILL at 7.8 s → `119d2c9b…|2` (Electron, the generation of the app-created rooms)
  at 34.0 s → pending retry (`indeterminate 1`, blocked) → `groups.retry` via Electron →
  `{retried: true, task.status: queued}` → `message.member` + `turn.settled` + `room.activity`
  (249.6 s) → disband. `turn.deferred` was never emitted: retry came from `indeterminate` [run].
- trial 306 `retry-attach` (first attempt): the takeover went to ANOTHER generation (`35067914…|2`,
  not Electron's) → `groups.retry` via Electron → 5118. `lease-after-failure.txt`: that process kept
  renewing the lease every ~15 s while the task sat `deferred`, so retry through Electron could not
  succeed. The room was then disbanded through Electron (a `deferred` task is cancelled directly in the
  DB, no lease needed: `tui_gateway/hosted_room_driver.py:202-221`) [run]. Which process held
  `35067914…` was not proven (the only other same-home worker running was the messaging gateway).
- Isolated home, app Retry button: run 1 `app-retry-iso` and trial 306 `trial-306/app-retry-iso`
  (`r-retry-pending.png`: retry bar with the side-effects warning, status `blocked · indeterminate 1`
  → Retry → `groups.retry → queued` → settled at 60 s) [run].

### 7.7 Approve [src + run]

Approvals happen only when the member profile's `approvals.mode` asks (`manual`). Every profile of the
user's install has `approvals.mode` off (`false`/`"off"`: `~/.hermes/config.yaml`,
`profiles/*/config.yaml`), so no approval can trigger there without changing bot config, which the
card forbids. Approve was therefore proven in an isolated `HERMES_HOME`
(`~/.hermes-bot-app-spike/m2/home`, `approvals.mode: manual`, profiles `default` + `bravo`, own serve
and lock dir):
- Harness `approve-iso`: prompt asks alpha to run `rm -rf /tmp/hba-approve-probe-…` (a
  `DANGEROUS_PATTERNS` hit) → pending action `approval` with `description: "delete in root path"`,
  `choices: [once, deny]`, probe still present → `groups.approve choice=once` → `{approved: true,
  result: {resolved: 1}}` → command ran (probe gone) → reply + settled. Repeating the same approve →
  `5119 room approval is no longer pending` [run].
- App (`evidence/m2/app-approve-iso`): the approval bar shows member, description and the command;
  `HERMES_BOT_APP_AUTOROOM_APPROVE=once` presses the same button → `groups.approve once → resolved` →
  `/tmp/hba-approve-ui-probe` deleted → settled (`r-approval-pending.png`, `r5-settled.png`) [run].

Matching is exact on `(request_id, task_id, execution_generation)` for `(room_id, member_id)`
(`hosted_room_service.py:498-534`); the app copies these from the pending action. Because pending
approvals live in the memory of the process running the turn (§7.3), `groups.state`/`groups.approve`
through a *different* backend process do not see it. In the user's install that process is whichever
worker holds the room lease (Electron `desktop-serve`, the messaging gateway, or another serve).

### 7.8 Cleanup and leftovers [src + run]

Rooms:
- `groups.disband` is the only removal. It stops the room first and refuses with 5114 ("room work is
  still stopping") while a stop is unacknowledged; the harness retries every 10 s. The id is retired
  for good. The tombstone row and its dependent rows (tasks, leases, policy tables) stay until pruning:
  90 days, beyond 512 tombstones, or retained event bytes over the cap (`hosted_rooms.py:37-38,568-605`;
  pruning still reserves the id). There is no
  API to purge earlier.

Member sessions (each member gets a hidden `Group: <room_id>` session, `source=bot_room`, in its
profile DB, created through `hosted_room_server_rpc.py` in the process whose worker runs the turn):
- No reaper ends a live room session: it has no client transport (`session_lifecycle.py:219-227`).
  While live, `session.delete` refuses it with 4023 (`methods_session.py:1181-1204`: a live
  `session_key` match, or `SessionActiveWriteGuardError` while a turn's write guard is held).
- It CAN be closed explicitly: `session.close {session_id: <runtime id>}` pops exactly that runtime
  and tears it down (`methods_session.py:2202-2206` → `session_lifecycle.py:552-585`, end_reason
  `tui_close`; no source restriction) → `{closed: true}`. After that the stored row deletes normally.
  No backend restart is needed. (The M2 run 1 text said a restart was required; that was wrong — the
  harness had only tried `session.delete`.)
- Title phases of a member session (why a title is NOT an identity) [src + run]:
  1. `session.create {title: "Group: <room_id>", source: bot_room, hidden, room_plumbing}`
     (`hosted_room_server_rpc.py:59-62`) only queues the title as `pending_title`; there is no row yet.
  2. At the start of the first turn the agent writes an instant `derived` title from the first line of the
     prompt (`agent/title_generator.py:343-354,621-636`: ≤48 chars, cut at a word boundary + `…`), e.g.
     `[Discussion: "hba app hba-e6dfb4cab02f"] You…`; the title model may upgrade it to an `llm` title
     (arbitrary text). `session.active_list` shows the DB title first and `pending_title` only as a
     fallback (`server.py:3055-3059`), so while the first turn runs the live row shows that auto title too.
  3. `pending_title` is written (with `user` authority, overriding derived/llm) only after a `complete` turn
     (`prompt_turn.py:384-409`). A turn that never completes (process killed mid-turn — the retry
     scenarios SIGKILL serve S) leaves the row with its derived title or none.
  trial 308 saw phase 2 → 3 live: after Stop + disband, researcher's session stayed `working` with the derived
  title for ~135 s, then turned `idle` with `Group: hba-e6dfb4cab02f` (§7.5).
- Ownership is proven per stored row, never from a generic `hba` prefix (`RoomSessionClassifier`,
  `Sources/HermesGatewayKit/RoomSessionCleanup.swift`), against a manifest of the test rooms
  (`{room_id, name, created_at, members}` per line, written at `groups.create` by the harness and, with
  `HERMES_BOT_APP_ROOM_MANIFEST`, by the app; test room names embed the room id). Title and preview of a
  `source == bot_room` row are judged separately, then combined:
  - title exactly `Group: <room_id>` of a manifest room (the driver's own identity,
    `hosted_room_driver.py:877-885`) → that room, if the row's profile is a member of it (else
    `member_mismatch`); `Group: <other id>` → another room (positive foreign proof);
  - preview (head of the FIRST user message, ≤60 chars + `...`, `hermes_state_common.py:26-31,148-166`)
    or a derived title that is a prefix of the exact opening the driver sends that member
    (`hosted_room_discussion.py:518-530`): `[Discussion: "<name>"] You are @<handle>, one participant
    with <peers> and the user.` → that room, with the whole quoted name visible, the row's profile equal
    to that member's profile, `started_at` not before the room's `created_at` (−120 s skew), and the name
    unique among the manifest and the live rooms; an opening naming another room → foreign proof;
  - any other title (an `llm`/user title, `agent/title_generator.py:642-687`) says nothing; any other
    non-empty preview is "no proof either way".
  A row is owned only when something names a manifest room and nothing points elsewhere (another
  room's title/opening, or a preview that is no room opening → `conflicting_provenance`; two test rooms →
  `ambiguous_room`). A row with positive foreign proof is skipped (`hba`-looking ones are listed as
  `foreign_not_touched`). A row with no proof either way is NOT assumed absent when it is in scope — a
  member profile of a manifest room, `started_at` unknown or not before that profile's first test room
  (−120 s): `unattributed_empty` (no title, no preview) or `unattributed` (e.g. an `llm` title with an
  empty preview). Out of scope (other profiles, older rows) it is ignored.
  Live runtimes (`session.active_list`: `{id, session_key, title, status}`, no profile/source,
  `server.py:3062-3083`). Stored ids are timestamp-based and can repeat across profiles; the backend itself
  matches a runtime on `(profile_home, key)` (`server.py:3090-3097`), which the read-only API does not
  expose. A runtime is therefore owned (= may be closed) only when
  1. its `session_key` is the id of an owned row, and no other row with that id is visible in the listings
     of the scanned profiles (else `key_collision`);
  2. no other runtime holds the same key (else `key_collision` for each);
  3. its live title — the runtime's own DB title, else its `pending_title` (`server.py:3055-3059`) — is
     empty, equal to the row's stored title, the room's `Group:` title, or an opening of the same room for
     that profile (title phases can change between the two reads); anything else is positive foreign
     evidence → `live_title_conflict`;
  4. an EXACT-id lookup of the key in every profile of `profiles.list` (default + every named profile dir,
     `hermes_cli/profiles.py:1049-1067`) proves the id stored in the owning profile and in no other one.
     Step 1 alone is not enough: `session.list` is a human listing, not an inventory — even with
     `include_hidden` it drops `kanban`/`tool`/`oneshot` rows (`methods_session.py:133-157,549-571`,
     `INTERNAL_LISTING_SOURCES`), archived rows and compression children, and stops at the window
     (`limit`, `hermes_state_sessions.py:1348-1373,1421,1461-1462`), so absence there proves nothing. The
     lookup is `GET /api/sessions/{id}?profile=<p>` on the attached backend's own HTTP port, header
     `X-Hermes-Session-Token: <rendezvous token>` (`web_routers/sessions.py:562-582`: `db.get_session` on
     that profile's store, no source/hidden/archive/window filter; read-only open). Mapping
     (`AttachedSessionGateway.presence`): 200 with `id` equal to the key (and `profile` stamp equal to the
     requested profile) → present (with its `source`); 200 with ANOTHER id → absent, because
     `resolve_session_id` tries the exact id first and only then a unique prefix
     (`hermes_state_sessions.py:900-908`) — it is never counted as present; 404 `{"detail": "Session not
     found"}` → absent; anything else (404 for an unknown profile, `web_server_cron.py:122-123`; 400/401/
     503 corrupt store; transport error; non-object body; no REST access) → unknown. Results:
     present in another profile (any source) → `key_collision` (detail names profile + source); any
     unknown → `key_inventory_unknown`; the owned row itself absent on lookup → `key_inventory_changed`.
     Only `id`/`source`/`profile` of the answer are read; the payload is not stored; the token is only a
     header and every error goes through `Redaction` (which also masks `X-Hermes-Session-Token`).
  Other runtimes that name a test room: `title_only_live` (title `Group: <id>`, key not an owned row),
  `live_unmapped` (opening of a test room). Unresolved items are never closed or deleted (an owned row
  whose id an unresolved runtime still holds is not deleted either), and they fail the run.
  Residual, not provable through the API: a runtime whose stored row exists in NO profile store of
  `profiles.list` — not yet flushed, or a profile home outside the profile root — holding the same id and
  showing a blank or agreeing title. Resumed runtimes always have a stored row (they resume one); a fresh
  runtime gets a newly minted timestamp+random id, so this needs an id collision at mint time.

Deleted keys can come back (found in review) [src + run]. Deleting a member row does not end
every writer of that id. The model title upgrade of a member's first turn runs in a daemon thread
(`agent/title_generator.py:642-687`: set accounting context → `generate_title` → persist); `session.close`
joins the turn thread only, not that upgrade (`tui_gateway/session_lifecycle.py:568-584`). When its LLM
call returns after the delete, `record_auxiliary_usage` first re-inserts the missing row
(`hermes_state_usage.py:388-391`: `_insert_session_row(session_id, "unknown")`) and the title persist then
names it. Result: the SAME id in the same profile, `source=unknown`, `message_count=0`, an arbitrary `llm`
title, a `session_model_usage` row `task=title_generation`. The provenance rules above only look at
`source == bot_room`, so such a row is invisible to them. The call is bounded by
`auxiliary.title_generation.timeout` (default 30 s, `hermes_cli/config_defaults.py:774-785`,
`agent/auxiliary_client.py:6250,6353-6361`; no same-provider retry on timeout, `:3548-3550`, but a
fallback provider may follow). No backend change is made or needed; the cleanup handles it:
- Session ledger (`Sources/HermesGatewayKit/RoomSessionLedger.swift`, JSON lines, default
  `evidence/m2/session-ledger.jsonl`, `HBA_SESSION_LEDGER`): every owned row is appended as `proven`
  `{scope, profile, id, room_id, evidence}` BEFORE its runtime is closed or the row deleted (a failed
  append → that key is neither closed nor deleted, and the run is not ok), then `deleted` / `redeleted`.
  `scope` = the rendezvous lock dir the process discovers in, so keys of the isolated home are never read
  back against the user install and vice versa.
- Every round (and every `audit`) reads each remembered key of the rooms back by EXACT id in its own
  profile (`GET /api/sessions/{id}?profile=`, as above — no source/title/listing filter, no runtime
  needed): absent → fine; present as the placeholder shape (`source=unknown` AND `message_count == 0`) →
  `ledger_recreated`, deleted again once no runtime holds the id (same 4023/4007 handling); present in
  any other shape (other source, messages, count missing) → `ledger_key_present`, never deleted;
  not provable → `ledger_readback_unknown`. Each of these makes the pass non-empty. Only keys in the
  ledger are ever re-deleted; unrelated `unknown` rows are never touched.

`group-chat-harness cleanup <@manifest.jsonl | ids | @ids.txt>` (attach-only; ids are looked up in
`evidence/m2/room-manifest.jsonl`, or taken from `groups.list` while live):
1. `groups.disband` the live ones (5114 → retry every 10 s).
2. `RoomSessionCleaner` rounds (`HBA_CLEANUP_ROUNDS` default 36 × `HBA_RETRY_EVERY` 10 s). Each round
   re-reads `profiles.list`, `session.list {profile, include_hidden: true, limit: 500}` for the member
   profiles and every other profile (candidate discovery only), and `session.active_list`, classifies as
   above, runs the exact-id lookup of every close candidate's key in every profile (step 4) and the exact
   readback of every ledger key, records new owned keys, then
   `session.close {session_id: runtime}` for owned runtimes that are `idle` (a `working`/`starting`/
   `waiting` one is left alone and re-checked next round), `session.delete {session_id, profile}` for
   owned rows and re-created ledger placeholders that no runtime (owned or not) holds any more —
   `session.delete` itself refuses a bare-key match with 4023 (`methods_session.py:1191-1192`) (4007 =
   already gone; 4023 = still live/write guard → next round).
3. Success only after `settle` consecutive empty passes (nothing owned, nothing unresolved, every ledger
   key absent by exact readback). `settle` = `HBA_CLEANUP_QUIET` (default 90 s = three title-call windows)
   / `HBA_RETRY_EVERY` + 1 → 10 rounds; the old fixed 2 rounds (20 s) ended before the late write.
   Out of rounds → exit 1 with what is left and why (still working, rows left with their last error,
   re-created keys, unresolved kinds). An id without a manifest entry that is no longer live also fails.
`audit <same>` is the read-only single discovery incl. the exact readback of the rooms' ledger keys (exit
1 if anything owned/unresolved/re-created is left) plus an install-wide, informational list of `bot_room`
rows that look like any hba room (it cannot show re-created `unknown` rows; the ledger readback does).
`ledger-audit` / `ledger-cleanup` do the same for EVERY key of the scope's ledger without a room manifest;
`ledger-import <dir,…>` (`HBA_IMPORT_BACKEND=<backend substring>`) adds the keys earlier cleanups deleted
(`session.delete` requests answered with a result in their `wire.log`, plus the report's `deleted[]`) as
`imported_deleted` with the dir as origin; dirs whose `backend` does not match are refused.
Limits: a session live in a backend other than the attached one is not in its `active_list`; its delete
keeps failing 4023 and the run fails (not forced). A writer later than the quiet window re-creates a key
after the cleanup returned: the next `audit`/`ledger-audit` then fails on it (exact readback) and
`ledger-cleanup` removes it; a key that was never proven by a run (no ledger record) cannot be recalled.
After disband the driver's state calls refuse the room (`gateway/hosted_room_driver.py:346-357`), so no new
member turn — and no new member session — is expected.

Trial 306 (attached to Electron `desktop-serve` pid 29903) [run] — historical: trial 306 mapped sessions by
exact title (+ an explicit `HBA_EXTRA_SESSIONS` list for untitled rows). A later review showed that misses a
member session whose first turn is still running under its auto title (cleanup exited 0 with one left);
superseded by the provenance rounds above (trial 308 below):
- `trial-306/audit-before`: 10 stored `Group: hba-*` rows (researcher 7, reviewer 3), all 10 live and
  `idle` in Electron's `active_list`, 0 title-only matches.
- `trial-306/cleanup-old`: 10 × `session.close` → `closed: true`, then 10 × `session.delete` ok on the
  first attempt; after: 0 rooms, 0 stored, 0 live. `trial-306/audit-after-old`: 0 `Group: hba-` sessions
  in `active_list`. Electron health stayed 200, same pid.
- The rerun app evidence (§7.9) added 2 rooms; `trial-306/cleanup-final` closed 3 runtimes and deleted 3
  rows the same way.
- The two `retry-attach` runs (§7.6) added 2 rooms. The failed one was disbanded by
  `trial-306/cleanup-retry-room` (0 sessions mapped by title). `trial-306/audit-untitled` then found 2
  untitled researcher `bot_room` rows previewing `hba M2 retry 1793708891` (run 1) and `hba M2 retry
  1793714398`: S's sessions; `trial-306/cleanup-untitled` deleted them. `trial-306/cleanup-retry2`: 1 close +
  1 delete + 1 untitled delete for the second run.
- Final, `trial-306/audit-final` + `trial-306/list-final`: for all 11 card rooms 0 live rooms, 0 stored
  rows, 0 live runtimes, 0 untitled hba rows; `groups.list` 0 `hba-*`; `active_list` 0 `Group: hba-`.
  In total 14 runtimes closed and 17 hidden rows deleted (14 titled + 3 untitled) through the gateway
  API; Electron (`desktop-serve` 29903, started 12:25:14) health 200 throughout, never restarted.
- Not exercised in trial 306: the 4023 retry branch (every delete went through on attempt 1), a session
  live in a backend other than the attached one.

Trial 308 (review round 2 rework; attached to Electron `desktop-serve` pid 29903; `evidence/m2/trial-308/`) [run]:
- `audit-baseline`: 0 hba rooms live, 0 hba-looking `bot_room` rows in any of the 6 profiles, 0 active
  titles with `hba`.
- The reviewer's repro, live: `app-stop` (Stop at 5.8 s → `turn.cancelled`, disband 8.4 s) → immediate
  `cleanup-stop @room-manifest.jsonl`. Rounds 1–13 (~130 s): stored `researcher` row with derived title
  `[Discussion: "hba app hba-e6dfb4cab02f"] You…`, owned via `opening_preview`, its runtime `f9f6c90d`
  `working` → no close, delete deferred. Round 14: same key, title `Group: hba-e6dfb4cab02f`, `idle` →
  `session.close` → `closed: true`, `session.delete` ok. Rounds 15–16 empty → exit 0.
- `app-multi` (2 replies, `settled: 2`, `working=false` at 22 s, disband) → `cleanup-multi`: 2 close +
  2 delete in round 1, 2 empty rounds → exit 0.
- `retry-attach` (S SIGKILLed mid-turn, lease `…|1` → Electron `…|2`, `groups.retry` → settled) →
  `cleanup-retry`: Electron's runtime closed + its `Group:` row deleted (`exact_title`), and S's dead
  row (title empty) deleted via `opening_preview` — no `HBA_EXTRA_SESSIONS` (removed) needed.
- `audit-final @all-rooms-manifest.jsonl`: 0 owned, 0 unresolved, 0 foreign; install-wide 0 hba-looking
  `bot_room` rows, 0 active titles with `hba`.
- Unit coverage: `Tests/HermesGatewayKitTests/RoomSessionCleanupTests.swift` (12): opening shape, manifest,
  derived-title/working → owned, exact/preview/derived evidence, unrelated controls (other room, other
  source, user rooms, foreign hba) never touched, unprovable kinds, same-name ambiguity, truncated name,
  transient working → `Group:` idle (close only once idle, delete only after close, unrelated rows/runtimes
  survive), still-working-at-end fails, 4023 retried across rounds, persistent 4023 / title-only fail,
  late appearance needs 2 empty rounds. Disabling the preview/derived-title provenance fails 17 assertions.

Trial 310 (review round 3 rework; attached to Electron `desktop-serve` pid 29903;
`evidence/m2/trial-310/`) [test + run]:
- Unit (`RoomSessionCleanupTests`, 20 = 12 + 8 new): the reviewer's probe (`researcher:same-key` owned,
  `reviewer:same-key` titled `Group: unrelated-user-room`, two live runtimes on that key) → 0 close,
  0 delete, 2 × `key_collision`, `ok: false`; collision with a non-member profile / another source;
  two runtimes on a unique id; live title of another room → `live_title_conflict` (controls: empty,
  same stored title, own `Group:` title → owned); duplicate owned ids (nothing while a runtime holds the id,
  both deleted once none does); `llm` title + empty preview in scope → `unattributed`, also with a
  `working` runtime (0 close/delete, `ok: false`); controls: `llm` title over a valid opening preview owned,
  another room's opening/`Group:` skipped, own opening + other `Group:` title → `conflicting_provenance`,
  non-member/older rows ignored, exact title in a non-member profile → `member_mismatch`. Mutations (each
  guard removed in turn: id-collision, multi-runtime, live-title, unattributed scope, defer-on-any-runtime)
  each fail at least one test.
- `audit-baseline @all-rooms-manifest.jsonl` (trial 308 rooms) with the new rules: 6 profiles scanned, 0 owned,
  0 unresolved, 0 hba rooms live.
- `app-stop` (`hba-3019f4b2a098`, researcher + reviewer): Stop at 7.0 s → `cancelled 1` → disband 9.9 s →
  immediate `cleanup-stop`: rounds 1–3 researcher runtime `e27f9d56` `working` with the derived title → wait;
  round 4 `idle` → `session.close` → `closed: true`, `session.delete` ok (`exact_title`); rounds 5–6 empty →
  exit 0.
- `app-multi` (`hba-39955ba0f349`): 2 replies, `settled: 2`, `working=false` at 29.8 s, disband →
  `cleanup-multi`: round 1 closes both runtimes (researcher, reviewer) and deletes both rows, rounds 2–3
  empty → exit 0.
- `audit-final @all-rooms-manifest.jsonl` (5 rooms): 0 owned, 0 unresolved, 0 foreign, 0 hba-looking
  `bot_room` rows in any profile, 0 active titles with `hba`; `groups.list` 0 `hba-*`.
  `db-readonly-final.txt` (read-only snapshot of `shared-state.db`): 19 retired `hba-*` rooms, 0 not retired,
  19 lease rows, 0 active.

Trial 312 (review round 4 rework; attached to Electron `desktop-serve` pid 29903;
`evidence/m2/trial-312/`) [test + run]:
- Adapter-boundary tests (`Tests/HermesGatewayKitTests/AttachedSessionGatewayTests.swift`, 6): the real
  `AttachedSessionGateway` + `RoomSessionCleaner` against an in-process fake backend (WS JSON-RPC whose
  `session.list` hides unlisted rows + HTTP detail route over the whole store). The reviewer's repro — own
  `researcher:same-key` bot_room row, foreign `reviewer:same-key` row with source `kanban`/`tool`/`oneshot`
  or archived/out-of-window (never in `session.list`), one idle runtime on `same-key`, live title blank or
  agreeing — now gives 0 close, 0 delete, `key_collision` (detail `reviewer present(source=…)`),
  `ok: false`, foreign row and runtime untouched (8 variants). Controls: unique key (404 elsewhere) → close
  + delete + ok; prefix-resolved 200 for a longer id → absent (close allowed); no REST access, wrong
  token (401), 503, unknown-profile 404, 200 without id, dead port → `key_inventory_unknown`, 0 close/delete,
  not ok, no token in the report; own row gone on lookup → `key_inventory_changed`; status/body mapping.
  `mutations.txt`: removing the inventory gate fails 77 assertions; accepting a prefix id as present fails 4.
- `key-inventory` (read-only, `key-inventory-console.log`): reviewer's newest `kanban` session and
  researcher's newest `oneshot` session are `not listed` by `session.list {include_hidden, limit 500}` in every
  profile, yet the exact lookup answers `present(source=kanban)` / `present(source=oneshot)` in their own
  profile and `absent(not_found)` in the other 5; an unused id is absent everywhere; a listed `desktop` row
  is `listed` + `present` (control).
- `app-stop` (`hba-9d00002f6183`): Stop at 6.7 s → `cancelled 1` → `turn.cancelled` (seq 3, 7.9 s) →
  disband → immediate `cleanup-stop`: rounds 1–7 researcher runtime `59fbd241` `working` under the derived title,
  key inventory `researcher present(source=bot_room)`, 5 × `absent(not_found)` → wait, delete deferred; round 8
  `idle` → `session.close` → `closed: true`, `session.delete` ok; rounds 9–10 empty → exit 0 (96 s).
- `app-multi` (`hba-bf337f0f66f5`): 2 replies, `settled: 2`, `working=false` at 34.1 s, disband →
  `cleanup-multi`: round 1 both keys proven unique (6 profiles each), 2 close + 2 delete; rounds 2–3 empty →
  exit 0.
- `audit-final @all-rooms-manifest.jsonl` (9 rooms): 0 owned, 0 unresolved, 0 foreign, 0 hba-looking
  `bot_room` rows in any profile, 0 active titles with `hba`; `list-final`: `groups.list` 0 `hba-*`;
  `db-readonly-final.txt`: 23 retired `hba-*` rooms, 0 not retired, 23 lease rows, 0 active.
  Fresh `swift build --scratch-path` 0 warnings; `swift test` 74/74; token scan 0 hits.

Trial 314 (review round 5 rework; attached to Electron `desktop-serve` pid 29903;
`evidence/m2/trial-314/`) [test + run]:
- Tests (84 = 74 + 10): `RoomSessionLedgerTests` (8) — the reviewer's probe (owned `bot_room` row → delete →
  the same id re-appears as `source=unknown`, llm title, 0 messages before the 2nd empty round) now
  re-deletes it and is ok only with no row left (ledger `proven → deleted → redeleted`); ordinary control;
  re-created every round → not ok; re-creation after the run → listing-only discovery is blind, audit from
  the ledger file fails, a new run from the ledger alone (empty manifest) cleans it; another scope's keys are
  never read; unrelated `unknown` row untouched; other source / messages / count missing / 503 → unresolved,
  0 delete; placeholder held by a runtime → deferred, not closed; ledger write failure → 0 close/0 delete,
  not ok; file round trip. `AttachedSessionGatewayTests` (+2) at the real adapter boundary (fake WS + HTTP
  detail route with `message_count`): delete → backend re-creates the id → exact readback → redelete → ok,
  unrelated `unknown` row untouched, audit from the file absent; re-creation after the run → audit fails
  until `ledger-cleanup`, with messages or no count → `ledger_key_present`. `mutations.txt`: dropping the
  readback fails 34 assertions (8 tests), treating any present row as the placeholder 11, ignoring a ledger
  write failure 2, skipping the redelete 24. Fresh `swift build --scratch-path` 0 warnings; `swift test` 84/84.
- Leftovers: `ledger-import` of every earlier attached cleanup dir (runs 306–313, implementer + reviewer,
  `HBA_IMPORT_BACKEND="role=desktop-serve pid=29903"`; 4 isolated-serve dirs refused) → 38 keys.
  `ledger-audit-before`: 31 absent, 7 `present(source=unknown, messages=0)` — exactly the reviewer's 7
  (`researcher:…214700_3c5d33`, `…215158_aea571`, `…222927_ec9a92`, `…231649_03185e`, `reviewer:…215041_2503fc`,
  `…223056_f8bbe9`, `…231935_6107a5`). `ledger-cleanup-historical`: 7 × `session.delete` (re-created
  placeholder) ok, then 7 empty rounds with all 38 absent → exit 0.
- `app-stop` (`hba-cc21e8b2df5e`): Stop at 5.6 s → `room.stop_requested`, `turn.cancelled` (cursor 3, 5.8 s,
  `working=false`, `cancelled 1`) → disband → immediate `cleanup-stop`: rounds 1–4 researcher runtime `5ea78cb0`
  `working` → wait; round 5 (42 s) idle → close + delete `researcher:20261104_000322_2cb6e9`; round 6 (53 s) the
  exact readback finds the SAME key `present(source=unknown, messages=0)` — the re-creation case, live —
  → deleted again; rounds 7–16 empty with the key absent → exit 0 (157 s).
- `app-multi` (`hba-e5b0d8fcbd6c`): 2 replies, `settled 2`, cursor 6, `working=false` at 30.1 s → disband →
  `cleanup-multi`: round 1 2 close + 2 delete; no re-creation; 10 empty rounds → exit 0.
- Final: `audit-final @all-rooms-manifest.jsonl` (13 rooms, 17 ledger keys of those rooms): 0 owned, 0
  unresolved, 17 absent, 0 re-created, 0 hba rooms live; `ledger-audit-final` and `-final2` (00:10, ~4 min
  after the last cleanup): all 41 ledger keys absent; `list-final`: `groups.list` 0 `hba-*`.

What stays by design: `hba-*` tombstones in `shared-state.db` with their unreleased lease rows (expire
within 30 s of the last renewal; 0 active afterwards), until backend pruning. They are not listed by
`groups.list` and cannot be removed through the API. The card owner accepted "0 live room / 0 active lease
/ 0 hba session" as the meaning of the card's "0 room/lease `hba-*`" (decision 2026-11-03); the waiver
covers tombstones and expired lease rows only, not session rows.
Correction (found in review): the "0 hba sessions" figures written after runs 306–312 counted only
`bot_room` rows / `hba` titles. They are withdrawn as proof of total cleanup: 7 keys those runs had deleted
were stored again as `source=unknown` placeholders (trial 314 below found exactly those 7 among 38 imported
keys and removed them). Session cleanliness is now stated only from the exact readback of the ledger.

M2 status of the §6 risks: polling implemented (§7.2); member token streaming still invisible (only
final `message.member`); same-home worker / lease takeover exercised (§7.6); approval locality is a
new risk (§7.7); hidden sessions are cleaned through `session.close` + `session.delete` as above.

### 7.9 Scripted app runs (no clicks)

`HERMES_BOT_APP_AUTOROOM="<botA,botB>|<prompt>"` creates an `hba-` room with those bots, opens it and
sends. `HERMES_BOT_APP_OPEN_ROOM=<room_id>` opens an existing room. Optional:
`HERMES_BOT_APP_AUTOROOM_STOP_AFTER=<s>`, `HERMES_BOT_APP_AUTOROOM_APPROVE=once|deny`,
`HERMES_BOT_APP_AUTOROOM_RETRY=1` press the same buttons/functions as the UI;
`HERMES_BOT_APP_DISBAND_ROOMS=1` disbands those rooms on quit and snapshots `r6-after-disband.png`
(sidebar without the room). `HERMES_BOT_APP_ROOM_MANIFEST=<path>` appends each created room to that
manifest (§7.8); scripted rooms are named `hba app <room_id>`. `scripts/run-app-evidence.sh <dir> <max-s>`
wraps a run with a watchdog and exits with the app's status, 124 if the watchdog stopped it (137 if it
also needed SIGKILL); exit 0 only means the app quit by itself — the flow's outcome is asserted from
`<dir>/ui-log.json`. For the isolated home, `group-chat-harness serve-iso <dir> <s> [retry]` keeps
a serve up (with `retry`: after leaving a room with a lost turn) and the app attaches with
`HERMES_BOT_APP_LOCK_DIR=~/.hermes-bot-app-spike/m2/locks`.

Trial 306 reruns from the final candidate (all attach-only or isolated; console + snapshots in
`evidence/m2/trial-306/`):
- `app-multi` (Electron): `groups.create hba-fb3514c6c12b` → send → `cursor=1 working queued:1` (1.6 s) →
  `cursor=3 [message.member, turn.settled]` (13.3 s) → `cursor=6 [message.member, turn.settled,
  room.activity] working=false settled:2` (22.0 s) → disband → removed from the sidebar.
- `app-stop` (Electron): Stop at 4.6 s → `groups.stop → cancelled 1` → `room.stop_requested` →
  `turn.cancelled` (5.8 s), phase `stopped` → disband.
- `app-retry-iso`, `app-approve-iso` (isolated home): retry as in §7.6; approval bar `default needs
  approval: delete in root path` + command → `groups.approve once → resolved` → probe dir deleted →
  settled (14.3 s) → disband.

### 7.10 Not proven

- `turn.failed`, `turn.deferred`, `room.renamed`, `bounded` discussions, multi-thread rooms, `deny`
  through a real approval (only `once` was exercised live; `deny` is only rendered as a button), peer/RoomLink members.
- An approval in the user's real install (config forbids changing `approvals.mode`).
- Approve/state through a backend process other than the one running the turn (§7.7, source-only).
  Retry through a non-holder IS proven to fail (5118, §7.6); the app cannot reach the messaging
  gateway (no WS port), so a room whose lease that process holds cannot be retried from the app.
- Live member typing (needs backend support).
- Cleanup's 4023 retry branch live (covered by `RoomSessionCleanupTests` only) and a stored row live in a
  backend other than the attached one (§7.8). An `llm`-upgraded title on a row with an empty preview
  (`unattributed` → fail, never closed/deleted; unit-tested) and a cross-profile `session_key`
  collision (`key_collision` → fail; unit-tested at the real adapter boundary with an unlisted
  `kanban`/`tool`/`oneshot`/archived foreign row, §7.8 trial 312) were not seen live; no collision was
  created in the user's install on purpose.
- Ledger readback branches `ledger_key_present` (a remembered id stored again with another source or with
  messages) and `ledger_readback_unknown`, and a re-creation later than the cleanup's quiet window, were
  not seen live (unit + adapter-boundary tests only). Keys deleted before the ledger existed are known only
  from the imported reports/wire logs; a deleted key that no evidence recorded cannot be recalled.

### 7.11 Client lifecycle regressions (review round 1) [test + probe]

- `Tests/HermesGatewayKitTests/RoomPollerTests.swift` (8 tests): the reviewer's out-of-order repro
  (poll 1 held, stop/start, poll 2 applied, poll 1 released → cursors `[2]`, cursor stays 2, 1 dropped,
  no extra poll), nothing published or reported after `stop()`, single loop + nudge, stop during sleep,
  and the composer availability rules. With the generation guard removed, the two lifecycle tests fail.
- Scratch probe with the candidate `RoomModel` + `RoomView` extracted verbatim
  (`evidence/m2/trial-306/probe/`, fake in-process `/api/ws`; only `RoomView.onAppear` exposes the
  `@State` draft): lifecycle 5/5 runs `cursors [2]`, final 2, 1 stale dropped, 0 syncs after stop;
  quit with a poll in flight → 0 syncs, no restart; direct `send` after disband / during disband →
  refused, 0 `groups.send`; failed disband (5114) → `open`, send accepted. Real NSEvent Return (keyCode
  36) into `_SystemTextFieldFieldEditor`: live room → draft cleared, 1 send; Return while that send is in
  flight → draft kept, still 1; after it finished → sent (2); after disband → draft kept, 0 new sends.


## 8. Canonical Bot Chat (M3, desktop parity)

Status: **[src + test] only; no live run.** Code: `Sources/HermesGatewayKit/CanonicalBotChat.swift`
(`BotChatSession.openCanonical`), `BotChat.swift` (`detach`, `close`). Tests:
`Tests/HermesGatewayKitTests/CanonicalBotChatTests.swift` (fake gateway). Research with full citations:
`.omc/research/wire-parity.md` §1. Backend paths are relative to the reference checkout (header).

Identity: a bot's one forever chat is **(profile, session titled exactly `"Bot Chat"`)**, the same chat Hermes
Desktop opens. There is no session-id pin; never pick by recency or visibility. Constant
`SessionDB.CANONICAL_BOT_CHAT_TITLE` (`hermes_state.py:1610`), `tools/bot_mode_probe.py:31`. `UNIQUE(title)`
makes it at most one row per profile DB; a hidden "Bot Chat" row cannot be renamed
(`hermes_state_titles.py:100-109`).

### 8.1 Find: `session.list` with `title` [src + test]

- Params: `{profile, title: "Bot Chat", include_hidden: true, limit: 200}` (`contracts/sessions.py:222-225`).
  With `title` the handler does an exact, window-free `get_session_by_title`
  (`methods_session.py:522-555`). Hidden rows resolve; a Bot Chat archived by accident is auto-unarchived by
  the lookup (`:526-537`).
- Result `{sessions: [row]}`, at most one. `id` = registry id; `resolved_id` = compression-lineage tip, always
  present on a title lookup. **The app opens `resolved_id`, else `id`** (`CanonicalRow.openId`); identity stays
  `id`. A row matches when its lineage root title (`root_title`) is `"Bot Chat"`, or the root title is empty and
  its title is `"Bot Chat"` (mirrors Desktop `isCanonicalBotChatHistory`).
- **Fail closed**: any error or a missing `sessions` array throws `BotChatError.lookupFailed`; it is never read
  as "no chat" (Desktop: "not starting a new chat", `canonical-chat.ts:282-319`).

### 8.2 Absence confirmation, create, title [src + test]

Only an empty lookup leads to create, and only after confirming absence:

1. `profiles.list {include_sessions: true}`: if the bot's row still carries `canonical_session.id`
   (`methods_profiles.py:160-193`), the empty lookup is unconfirmed → `BotChatError.absenceUnconfirmed`, no mint
   (Desktop `canonical-chat.ts:328-338`).
2. `session.create {profile, title: "Bot Chat", hidden: true, follow_profile_config: true,
   close_on_disconnect: false, source: "desktop", cols}`. `title` goes on create (not only via
   `session.title`) because `pending_title` also feeds the agent's `_session_title_hint`, which turns on the
   Bot Mode prompt section before any DB row exists (`server.py:1091-1093`, `agent/system_prompt.py:344-365`).
   The row is still lazy.
3. `session.title {session_id, title: "Bot Chat"}` at once, to materialize the row with `user` provenance and
   close the duplicate-mint race (`methods_session.py:1226-1255`; Desktop `canonical-chat.ts:493-511`). An
   RPC error on this call other than 4022 is tolerated (older gateway: the first prompt persists the row from
   `pending_title`).
4. **4022** "Title 'Bot Chat' is already in use by session X" (or a message containing "already in use"):
   re-run the lookup and adopt the winner via resume (§8.3); the stray lazy session is abandoned and pruned by
   the backend. If the re-lookup finds nothing → `lookupFailed`.
- No kickoff prompt on open. The user speaks first (Desktop only sends one on genuine new-bot creation).
- Single-flight per `(backend, profile)` (`CanonicalFlight`): concurrent opens share one result, so a double
  click cannot mint twice.

### 8.3 Resume with history [src + test]

`session.resume {session_id: <resolved_id || id>, profile, cols, source: "desktop", close_on_disconnect: false,
inline_images: false}`, cold (no `defer_history`/`omit_messages`) so the reply carries the transcript
(`contracts/sessions.py:183-195`, modes `methods_session.py:1058-1093`).
- The reply `session_id` is the **runtime** id. `messages` decode to `ChatHistoryMessage`
  (`BotChatSession.history`): roles user/assistant/tool/system; rows with `display_kind: "hidden"` and empty
  non-tool rows are dropped; tool rows keep only `name` + `context` (history has no tool results,
  `session_history.py:285-364`). `inline_images: false` yields `[image]` placeholders, not data URIs.
- `open_requests` of the reply become `BotChatSession.openRequests` (§9.5).
- **4007** "session no longer live; retry resume" and **4009** "session disconnect interrupt settling" are
  retried once after 0.5 s (`session_lifecycle.py:819-828`). Other errors propagate.
- If the session is already live in this process (e.g. Desktop on the same backend), resume reattaches to the
  same runtime id alongside the other clients; both get every event and every server→client request
  (`methods_session.py:877-900`, `session_transports.py`).

### 8.4 `source: "desktop"` and `close_on_disconnect: false` [src]

Matches Desktop (which sends neither `close_on_disconnect` nor, on create, `source`; the app sets `source`
explicitly). With `close_on_disconnect: false` a dropped socket detaches instead of reaping the runtime; with
`source: "desktop"` automatic orphan cleanup does not end the DB row (`session_lifecycle.py:60, 363-367,
420-424`). This is what keeps the chat alive across app restarts and next to Desktop.

### 8.5 Teardown = detach only [src + test]

`BotChatSession.close(deleteStored:)` on a canonical session only calls `detach()` (stops routing events,
requests and disconnects to this client) and returns the note "canonical Bot Chat: detached only". It sends
**no** `session.close`, **no** `session.delete`, **no** rename (`session.close` is per runtime, not per
client: it would pop the shared session and end the row, even for Desktop, `methods_session.py:2202-2206`,
`session_lifecycle.py:400-440`). Consequences:
- The M1 "chats are deleted on quit" behavior no longer applies to Bot Chat; the app no longer reads
  `HERMES_BOT_APP_KEEP_SESSIONS`.
- Bots can message other bots from this chat: `message_agent` is authorized only for a session titled
  `"Bot Chat"` on an install where some profile has `ui_meta['hermes-bots']` (`tools/bot_mode_dm.py:123-138`,
  `tools/bot_mode_probe.py:110-129`). [src; not exercised]

### 8.6 4090 `SESSION_NOT_OWNED` [src + test]

`prompt.submit` answers error **4090** with `data.reason == "SESSION_NOT_OWNED"` while another live backend
process holds the session's active lease (`methods_prompt.py:774-777`, `session_lifecycle.py:120-136`,
`hermes_cli/active_sessions.py:100-117`). `BotChatSession.send` maps 4090 to `BotChatError.sessionNotOwned`
("<bot>'s Bot Chat is running in another Hermes app. Open it in the Hermes app that runs it."). The app does
not take the lease over; it relies on attach-first (§1) to land on the process that hosts the session.
The lease lifetime across processes was not traced (research "Unknowns").

### 8.7 Session-id changes: `session.info` and `session.reclaimed` [src + test]

Two things can change a canonical chat's ids under an open `BotChatSession`
(`BotChat.swift`, tests `BotChatRebindTests`, `CanonicalBotChatTests`):
- **Compression moves the stored id.** `session.info {stored_session_id}` (compress rotates the lineage tip)
  updates `storedSessionId` in place (`BotChat.swift`, the `session.info` case of event delivery). The
  runtime id is unchanged. `BotChatSession.compress` also returns `CompressOutcome` with the replacement
  `history` when the backend sends `messages` (§11.4). Identity stays the title, so the next open (§8.1)
  finds the right tip.
- **The backend reclaims the runtime.** `session.reclaimed {session_id, stored_session_id, reason}` is a
  session-less broadcast (idle TTL, LRU cap, orphan reap). `attach()` subscribes to it globally; `reclaimed(_:)`
  matches it to this chat by runtime id (or by stored id when the payload has no runtime id) and ignores it once
  detached or while a recovery runs. A canonical chat emits `.other("session.reclaimed")`, then
  `resumeAfterReclaim()` does the §8.1 lookup again and a cold `session.resume` (`cols` as at open, 4007/4009
  retried once), and `rebind(to:stored:)` moves event and server-request subscriptions to the new runtime id.
  It then emits `.other("session.resumed")` and re-emits the resume's `open_requests` as new requests (§9.5).
  If lookup or resume fails it emits `.error("Hermes closed this Bot Chat's live session and it could not be
  reopened: …")`. A non-canonical session only reports `session.reclaimed`.
  `ChatModel` reacts to both events (`ChatModel.swift`).

## 9. Server→client requests (M3)

Status: **[src + test]; no live run.** Code: `ServerRequests.swift`, `Backend.swift`
(`advertiseCapabilities`), `GatewayClient.swift` (`respond`/`respondError`, `onRequest`). Tests:
`Tests/HermesGatewayKitTests/ServerRequestTests.swift`. Research: `.omc/research/wire-parity.md` §4.

### 9.1 Advertise [src + test]

Once per connection, right after `gateway.ready`: `client.capabilities {server_requests: true}` →
`{server_requests: [methods], declines_not_shown: bool}` (`contracts/liveness.py:29-48`,
`methods_voice.py:442-450`). Handlers are installed before the call, so no request can arrive unrouted.
- Without an advertising client every request fails fast with no frame: approval is withdrawn (not denied),
  clarify returns `outcome: "undelivered"`, value prompts return `""` (`server_requests.py:120-157`,
  `session_transports.py:38-47`).
- A backend without the method (older build): the failure is logged, `declines_not_shown` is treated as
  false, and the app keeps running.

### 9.2 Frames [src + test]

Request: `{"jsonrpc":"2.0","id":"srq-…","method":M,"params":{"session_id":sid,…}}` (`server_requests.py:84-86`).
A frame with `id` + `method` is a request; the answer echoes the **wire id exactly as received** (string or
number) as `{"id":…,"result":{…}}` or `{"id":…,"error":{code,message}}`. First answer wins; later ones are
dropped (`:364-366`). Routing is by `params.session_id` to the `BotChatSession` that owns it.

### 9.3 Handled methods [src + test]

| method | app surface | answer |
|---|---|---|
| `approval` | approval card: command (already redacted), description, choices ⊆ `once|session|always|deny` (all four when none offered) | `{choice, all}` |
| `clarify` | question list with optional choices and `multi_select` | `{answers: {qid: str\|null}}`; `{}` (no `answers`) cancels all |
| `sudo`, `secret` | masked input | `{value}`; `""` declines |

- **Approval, two paths.** A live `approval` request is answered by replying to the frame
  (`BotChatSession.answer`). Desktop instead answers through RPC `approval.respond {session_id, choice, all?,
  request_id?}` → `{resolved}` (`contracts/prompt_voice.py:296-331`; `apps/desktop/src/store/prompts.ts:377-406`).
  The app does not use that RPC: every approval it shows comes with an open frame (live, or re-shown from
  `open_requests` on resume), so it always replies to the frame. `request_id` in that RPC is the approval
  **queue** id from the params, not the `srq-` id.
  The app calls `approval.received` once per approval card when the card is on screen
  (`ChatModel+Requests.swift`, `BotChatSession.approvalReceived`); not run live.
- **Clarify early lock.** `clarify.lock {request_id, question_id, answer}` → `{status: ok|expired}`
  (`prompt_voice.py:253-274`) is not used: the card answers the whole batch at once. Replayed batches carry
  `params.answers` (`ClarifyPrompt.replayAnswers`).
- **Wire tap.** Server→client request frames are logged as `{id, method, params:<omitted>}`, answers as
  `{id, result:<omitted>}`, and outbound `clarify.lock` / `approval.respond` params are omitted too.
- Defaults: `sudo`/`secret` prompt text falls back to "sudo password" / "value".

### 9.4 Decline policy [src + test]

| case | reply |
|---|---|
| Unknown method | error `-32601` "method not found: M" (settles as unanswered, `server_requests.py:299-306`) |
| Known but not shown here: `terminal.read`, `preview.read`, `preview.act`, `window.read`, `tour`, `setup_choose`, `vault.unlock_prompt`, `vault.save_login`, `vault.code`, `display.install.sudo` | error **4404** "This window is not showing the session." (Desktop's text, `gateway-event/server-requests.ts:116`) |
| `approval`/`clarify`/`sudo`/`secret` for a session no open chat owns | held up to 5 s (≤256 frames) for a chat that is attaching, then 4404 |
| User stops the turn with a request open | error `-32603` "session interrupted" (`BotChatSession.decline`, Desktop `server-requests.ts:269-277`) |

- The backend attaches our socket to a session inside `session.resume` / `session.create`, before the reply,
  so events and requests can precede the reply that lets the chat subscribe. Unrouted session-scoped events
  and requests are therefore held (`UnroutedHold`: ≤256 frames, ≤5 s) and replayed in order to the first
  subscriber of that session id; only an unclaimed request is declined, when its hold expires.
- 4404 only settles once **every** attached client declined, so Desktop can still answer
  (`server_requests.py:107-111, 260-284`). That holds only if the backend advertised `declines_not_shown`:
  when it did not, the first error would settle the request for everyone, so the app **sends nothing** for
  4404 cases (Desktop does the same). `-32601` is always sent.

### 9.5 Cancel and replay [src + test]

- `request.cancel {id, method, reason: timeout|interrupted|shutdown|resolved|session_closed}` → clear only that
  request (`ChatEvent.requestCancelled`; `contracts/server_requests.py:252-267`).
- `approval.cancelled {request_ids, …}` → `ChatEvent.approvalsCancelled(requestIds)`; the ids are approval
  **queue** ids (match `ApprovalPrompt.requestId`).
- `open_requests: [{id, method, params}]` on `session.resume` become `BotChatSession.openRequests` and are shown
  as if just received, also after a reclaim re-resume (§8.7) (`server_requests.py:15-18, 339-344`; `server.py:781-794`). Not wired for
  `session.activate`/`session.events.since` (the app does not call them).
- Timeouts are backend-side: clarify 300 s default (`<=0` unlimited), value prompts 300 s
  (`server.py:1398-1413`); approval uses its own queue timeout (default value not confirmed).

## 10. Tool activity (M3)

Status: **[src + test]; no live run.** Code: `ToolActivity.swift`, `ChatTranscript.swift`
(`ToolLine`, `startTool`/`completeTool`). Tests: `ChatTranscriptToolTests.swift`.

Events (`contracts/events.py:268-308`; emitters `tool_progress.py:276-368`):
- `tool.generating {name}`: transient "drafting <tool>" status, not a row. Cleared by `tool.start` and at the
  end of the turn (`ChatTranscript.draftingTool`).
- `tool.start {tool_id, name, context?, preview?, labels?}`: a running tool row keyed by `tool_id`. Text =
  `context` (≈80 chars), else `preview`; label = `labels[].text` joined with " · " (render `text`, never parse
  tool names, `contracts/common.py:136-154`).
- `tool.complete {tool_id, name, duration_s?, summary?, error?}`: finishes the row (duration, summary). The
  contract has no error field; like Desktop, a truthy `error` marks the call failed. A turn that ends with a
  tool still running settles it as failed.
- Gating: emitted only when `display.tool_progress != "off"` (default `"all"`), except card tools (`clarify`,
  `delegate_task`, file edits, todo) which always emit (`server.py:1969-1977, 2132-2160`).
- Resumed history has tool rows with `name` + `context` only (done state, no `tool_id`, no result).
- Not used: `args`/`result`/`inline_diff`/`todos`, `tool.output_risk`, `todo.updated`, `status.update`
  (decoded as `ChatEvent.status`, not rendered as rows). `message.interim` commentary is sealed as its own
  segment (§4.5). Unknown event types become `ChatEvent.other`.

## 11. Slash commands (M3)

Status: **[src + test]; no live run.** Code: `SlashCommands.swift`. Tests: `SlashCommandTests.swift`.
Research: `.omc/research/wire-parity.md` §2. The backend does not interpret `/text` sent through
`prompt.submit` (it would reach the model literally), so commands go through dedicated RPCs.

### 11.1 Catalog [src + test]

`commands.catalog {session_id}` (profile and cwd scoped, `methods_tools.py:503-536`) → `categories[].pairs`,
`pairs`, `canon`, `commands{name: {argument_mode, desktop, desktop_subcommands}}`, `warning`. The app keeps a
built-in only when `commands[name].desktop` is null (hides terminal-only, messaging-only, settings, advanced,
composer-voice ones); skills, quick and plugin commands have no `desktop` entry and are kept. Duplicate names
collapse (categories first). `desktop_subcommands` narrows commands such as `/skills`. The popover filter
returns prefix matches first, then substring matches. `complete.slash` is not used.

### 11.2 Execution [src + test]

1. `slash.exec {session_id, command: "name args"}` (no leading slash). Plain `{output, warning?}` is a system
   line (a `warning` is prefixed); a result with `type` is a directive.
2. On an RPC error → `command.dispatch {session_id, name, arg}` (quick > plugin > bundle > skill > built-in,
   `methods_tools.py:1093-1110`). If that fails with "not a quick/plugin/(bundle/)skill command" (4018), the
   **original** `slash.exec` error is rethrown as the real failure. A transport error (socket gone) skips the
   fallback.
3. Directives (`type`): `exec`/`plugin` → output line; `alias` → re-run `/<target> <arg>` (up to 3 hops, then
   the alias is returned); `send`/`skill` → show `notice` if any, then `prompt.submit {session_id, text:
   message}` showing `display`, never the expanded `message`; `prefill` → `message` into the composer (e.g.
   `/undo`) with `notice`. Unknown `type` → "invalid directive" error.
4. Subcommand gate: a command with `desktop_subcommands` runs only with an allowed first word; otherwise a
   system line says what is available.

### 11.3 Client-side rewrites [src + test]

`SlashInvocation.classify(text, canonical:)` runs before anything is sent. Not a command: empty, `/` alone,
or `//…`.

| typed | canonical Bot Chat | other session |
|---|---|---|
| `/new`, `/reset`, `/clear` | rewritten to `session.compress` with notice "Bot chats are one continuous conversation — compacting instead." (Desktop rewrites to `/compact`, `plugins/hermes-bots/plugin.tsx:771-799`) | unavailable |
| `/compress [focus]`, `/compact [focus]` | `session.compress` | same |
| `/stop` | `session.interrupt` | same |
| `/help`, `/commands` | shows the catalog | same |
| `/title` | unavailable: "The Bot Chat keeps its name" | unavailable |
| Desktop-owned actions and pickers: `/branch /fork /yolo /reasoning /wake /handoff /profile /skin /browser /journey /btw /bg /background /pet /hatch /generate-pet /model /resume /sessions /switch /save /status /learning /memory-graph`, Ink-only `/density /details /logs /mouse /pets` | unavailable: "/x is not available in Hermes Bot." | same |
| anything else | `slash.exec` path | same |

### 11.4 `session.compress` [src + test]

`session.compress {session_id, focus_topic?}` with a **660 s** timeout (LLM-bound, Desktop
`use-prompt-actions/slash.ts:82-89`) → `CompressOutcome {compressed, message?, before_messages?,
after_messages?, history?}`. `history` is set only when the reply has a `messages` array. Following a changed
session id: §8.7.

## 12. Attachments in Bot Chat (M3)

Status: **[src + test]; no live run.** Code: `ChatAttachments.swift`. Tests: `ChatAttachmentTests.swift`.
Research: `.omc/research/wire-parity.md` §5, §6. All attach RPCs take the **runtime** `session_id` and must run
before `prompt.submit` on that session (`server.py:1253-1260`); unknown session → 4001.

### 12.1 RPCs [src + test]

| kind (by extension) | call | result used |
|---|---|---|
| image: `png jpg jpeg gif webp bmp tiff tif svg ico` (`hermes_cli/cli_terminal_input.py:33-36`) | `image.attach {session_id, path}` | `name`, `path`; queued on the session and consumed by the next turn (`prompt_turn.py:147-149`) |
| `pdf` | `pdf.attach {session_id, path}` | `filename`, `pages_attached`, `pages[].path` (kept for rollback); the backend renders pages to PNG with **`pdftoppm`**, max **25 pages** per call (4019), 50 MB (`methods_prompt.py:972-1027, 1288-1328`). **5028** (`pdftoppm` missing or failed) → the PDF is sent with `file.attach` instead |
| anything else | `file.attach {session_id, path, name}` | `ref_text` (`@file:<ref>`), required; a missing `ref_text` is an error |
| take back a staged image / every PDF page path | `image.detach {session_id, path}` | `count` |

When: chips are LOCAL until Send (only `ChatAttachments.check` runs at pick time). `BotChatSession.submit(_:files:)`
runs the attach RPCs in order and then `prompt.submit`, in one task. If a file fails, or `prompt.submit`
fails, every image and PDF page path staged by that send is detached again (`StageFailure` names the file),
so nothing stays queued on the shared Bot Chat for someone else's turn [src + test].

Paths are absolute host paths (valid for a loopback backend, like Desktop; bytes variants are for remote
backends and are not used). `tools/path_security.py` is **not** applied to attach RPCs: the backend checks
only existence and extension. `attached: false` in a result is an error with the backend's `message`.
Backend errors 4015/4016/4017/4018/4019/5028 reach the user as `RPCError` text.

### 12.2 Prompt text, ref_text prefix rule [src + test]

Images and PDF pages are queued server-side; the prompt text need not mention them. **Files are not queued:
the client must put each `ref_text` in the prompt.** `ChatAttachments.promptText`: all `ref_text` lines (one
per line), a blank line, then the user text (Desktop `submit.ts:218-234`). With no text and no refs, images get
the caption "What do you see in this image?"; otherwise `""`. Always use `ref_text` verbatim: a raw
`@file:/abs/path` outside the workspace blocks the whole turn with an `error` event unless it sits in a
Hermes-staged dir (`prompt_turn.py:704-719`, `agent/context_references.py:487-535`).

### 12.3 Client-side checks [src + test]

Before any RPC (`ChatAttachments.check`): resolve symlinks; must exist (`notFound`) and be a regular file
(`notRegularFile`); images ≤ 25 MB; PDFs ≤ 50 MB, readable by `CGPDFDocument` and ≤ 25 pages (`tooManyPages`,
`unreadablePDF`). `file.attach` has no backend size cap and none is added client-side. A `.pdf` needs
`pdftoppm` on the **backend** host; the app does not fall back to `file.attach` when it is missing (5028 is
shown).

### 12.4 Group Chat attachments travel as file references (backend is text-only) [src + test]

`groups.send` validates `payload` as an exact field set `{text, thread_id}` and rejects any extra key such as
`attachments` (`gateway/hosted_room_discussion.py:60, 198-203`; handler `methods_groups.py:382-393`; RoomLink
catalog `attachments=False`, `methods_groups.py:162`). The app's payload stays exactly
`{text: ..., thread_id: "main"}` (§7.1), so the user cannot attach files in a room. Desktop avoids this by
orchestrating Group Chat itself over per-member sessions (`plugins/hermes-bots/group-turns.ts`), which the app
does not do.

The app therefore sends files as references (`RoomAttachments.swift`, `RoomAttachmentStore.swift`): each file is
copied to `~/Library/Application Support/HermesBotApp/Room Attachments/<room_id>/<random>/<name>` (0700
folders; removed on disband) and the text gets a trailing block

    [Attached files: local copies on this Mac, open them with your file tools]
    - /absolute/path/of/the/copy

which the room's (local) members read with their file tools. The payload is still exactly `{text, thread_id}`.
The app folds a well-formed block back into attachments (`RoomAttachments.split`); other clients show it as
text. Limits: 10 files of 50 MB per message (the room's text cap is 64 KiB).

Privacy: the block puts absolute paths (with the macOS user name) into room history, which Hermes Desktop and
the room's bots see; the backend is local. Because room history is shared state, the app checks and thumbnails
only paths that are its own copies for that room (`RoomAttachmentStore.contains`); any other path in a user
message waits for a click, like a protected folder. A send that fails keeps its copies (a timed-out send may
still have been posted) and gives the chips and text back to the composer.

## 13. Files from bots: `MEDIA:` tags (M3)

Status: **[src + test]; no live run.** Code: `MediaTags.swift` (parser, `MediaSafety`), `MediaViews.swift`
(UI). Tests: `MediaTagsTests.swift`, `Tests/HermesBotAppTests/MediaViewsTests.swift`. Research:
`.omc/research/wire-parity.md` §7.

### 13.1 Where tags appear [src]

The gateway passes model text through unchanged: `MEDIA:<path>` is raw in `message.delta`,
`message.complete.text`, history `text` and `message.member.text`. No event has a structured media list
(`contracts/events.py:183-213`). Extraction is the client's job, in both Bot Chat and Group Chat.

### 13.2 Regex [src + test]

Port of `MEDIA_TAG_CLEANUP_RE` (`gateway/platforms/base.py:1328-1333`, used by `gateway/stream_consumer.py:966`),
case-insensitive:

```
[`"'*_]{0,3}MEDIA:\s*(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:EXT))
  (?=[\s`"'*_,;:)\]}\[<CJK terminators>]|MEDIA:|\.(?:\s|$)|$)[`"'*_]{0,3}\.?
```

`EXT` = `MEDIA_DELIVERY_EXTS` longest first (`base.py:1289-1301`): images, video, audio, documents, data,
geo, slides and archives (`png jpg jpeg gif webp bmp tiff svg`, `mp4 mov avi mkv webm 3gp`, `mp3 m2a wav ogg opus
m4a flac`, `pdf docx doc odt rtf txt md epub`, `xlsx xls ods csv tsv json xml yaml yml`, `kmz kml geojson gpx`,
`pptx ppt odp key`, `zip tar gz tgz bz2 xz 7z rar apk ipa`, `html htm`). Anchors: `~/`, `/`, `X:\`.

### 13.3 What is parsed and what is ignored [src + test]

- Parsed: backtick/double/single-quoted paths (escape hatch for odd names), unquoted paths with interior spaces
  when they end in a known extension, up to 3 `*`/`_`/quote markers around the tag, glued tags split at
  `MEDIA:`; a sentence-final `.` is not part of the path. A leading `~/` is expanded to the home directory.
  Refs are de-duplicated on the expanded path and kept in order. Kinds: image, audio, video, pdf, file.
- **Ignored (tag stays as text)**: tags inside fenced code blocks, inline code spans and `>` blockquote lines
  (masked before matching; a backtick path *directly after* `MEDIA:` is a quoted path, not a code span); tags
  with an unknown or no extension (the Python delivers those only after on-disk validation,
  `MEDIA_EXTENSIONLESS_TAG_RE`, not ported); a whole tag inside inline code (Python keeps it only when the file
  exists). JSON-string masking and `<|eos|>` are not ported.
- Directives `[[audio_as_voice]]` and `[[as_document]]` are removed from display and recorded on the ref.
- Parse settled or accumulated text, not single deltas (a tag can split across chunks): a half tag mid-stream
  stays plain text until it completes (`Components.swift` calls `MediaTags.split` on the full bubble text).

### 13.4 Display stripping [src + test]

`MediaTags.split` deletes deliverable tags (overlapping spans merged, back to front), collapses runs of 3+
newlines to a blank line and right-trims, like `strip_media_directives_for_display` (`base.py:3352-3360`).
Text with no `MEDIA:`/directive is returned unchanged.

### 13.5 `MediaSafety` deny rules [src + test]

Port of `validate_media_delivery_path` (`base.py:1168-1204`, denylists `:829-854`). `MediaSafety.check`:
- Path must be absolute (`notAbsolute`), exist after `realpath` (`notFound`), and be a regular file
  (`notRegularFile`). Both the resolved target **and** the lexical path are checked against the rules below
  (`forbidden`).
- Denied system prefixes: `/etc /private/etc /System /bin /sbin /usr /dev /proc /sys /root /boot /var/log
  /var/lib /var/run /private/var/{log,db,run,root} /Library/Keychains`; `/usr/local` is allowed.
- Denied under the home dir: `.ssh .aws .gnupg .kube .docker .config .azure .gcloud Library/Keychains`; under
  `~/.hermes`: `pairing mcp-tokens sessions browser-profile auth credentials`, `state.db*`, `kanban.db*`,
  `config.yaml`, and any name containing `token secret auth credential password oauth apikey api_key`.
- Denied by name anywhere: `.env`, `.env.*`, `*.env`, `id_rsa*/id_dsa*/id_ecdsa*/id_ed25519*`, `*.pem *.key *.p12 *.pfx`.
- Not ported: strict mode (`HERMES_MEDIA_DELIVERY_STRICT`, `HERMES_MEDIA_ALLOW_DIRS`, recency).

### 13.6 Open only on click, re-check, symlink extension rule [src + test]

(`MediaViews.swift`, `MediaResolver`.) Images render as an inline thumbnail, everything else as a file chip;
the disk check and thumbnail decode run lazily off the main thread and are cached per path. **Nothing opens
without a user click.** Every Open / Reveal runs `MediaSafety.check` again at click time (the file may have
changed). **Symlink extension rule**: the resolved target must keep the tagged extension (case-insensitive);
otherwise the ref is unavailable with "The file's real name does not match the attachment, so it will not be
opened." (a `report.pdf` link to `run.command` would otherwise launch a script on Open). Matches Desktop's rule
that guest content never opens the OS shell without a trusted click (`apps/desktop/AGENTS.md:83-89`).

## 14. M3 not proven (honest status)

Nothing in §8-§13 was run against a live backend. Tests are unit tests against in-process fake gateways and
pure functions (`swift test`); the backend behavior is read from source (citations above), as in
`.omc/research/wire-parity.md` ("Nothing here was exercised live").

- Canonical chat: the lookup, 4022 adoption, resume with history, `message_agent`/bot-to-bot messaging, and
  coexisting with Hermes Desktop on one session. 4090 across two backend processes. Lease lifetime.
  Whether `hidden: true` from create survives until `session.title` materializes the row (Desktop relies on
  it; not traced). §8.7 against a live backend: a real `session.reclaimed` and a real compression-rotated
  stored id (both covered by in-process fakes only).
- Server→client requests: a real approval, clarify, sudo or secret round trip; 4404 settling with Desktop
  attached; `approval.respond` against a live backend; `approval.received`.
- Tool activity: a live turn with tools; behavior with `display.tool_progress` off.
- Slash commands: a live `commands.catalog`, `slash.exec` → `command.dispatch` fallback, each directive type,
  and `session.compress` (including its 660 s timeout).
- Attachments: a live `image.attach`, `pdf.attach` (needs `pdftoppm` on the backend), `file.attach` with a real
  turn; `ref_text` handling for paths outside the workspace.
- `MEDIA:` files: a real bot sending a file; the UI check on Open / Reveal.
- App wiring: the app uses the canonical flow (`BotChatSession.openCanonical`, detach-only teardown); the
  M1 `BotChatSession.open` is kept in the kit only for non-canonical sessions and the harnesses. The UI itself
  (cards, composer, chips, media views) is covered by headless model tests and window layout tests, not by a
  live run against a backend.
