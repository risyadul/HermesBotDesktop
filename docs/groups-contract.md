# `groups.*` contract — as proven by the M0 spike

> M1 note: the connection procedure (attach-first to `host-serve`/`host-desktop-serve`,
> spawn-if-absent with `--isolated` on `~/.hermes`) and the 1:1 Bot Chat methods live in
> [gateway-contract.md](gateway-contract.md). §1 below describes the M0 spike's ISOLATED home only.
> §2 (transport/framing), §5 (no room push) and §6 (error envelope) still apply.
>
> M2 note: the final `groups.*` contract the Group Chat uses (list/create/send/log/state,
> stop/approve/retry/disband, the polling update model, cleanup limits) is
> [gateway-contract.md §7](gateway-contract.md#7-group-chat-m2). It supersedes §3.8 and §7 here.

Status: M0 spike, 2026-11-03.
Reference source (read-only): [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) @ `8a7a5a905fc6` (local checkout `~/.hermes/hermes-agent`)
(Hermes Agent v0.21.6). Paths below are relative to that checkout.

Each claim is tagged:
- **[run]**: observed on the wire in `evidence/run1`, `evidence/run2` or `evidence/app-*`
  (`roundtrip.json` holds the full responses, `wire.log` the raw frames).
- **[src]**: read from source only. Not exercised in M0.

---

## 1. Backend ownership and isolation

The app starts its own `hermes serve --host 127.0.0.1 --port 0` (`Sources/HermesGatewayKit/ServeProcess.swift`).

| Concern | Fact | Tag |
|---|---|---|
| Port | `--port 0` lets the OS pick a port. The real port is the first stdout line `HERMES_BACKEND_READY port=N`, followed by the legacy `HERMES_DASHBOARD_READY port=N` (`hermes_cli/web_server.py:1475-1477`). | run |
| Session token | `HERMES_DASHBOARD_SESSION_TOKEN` from env, otherwise random per start (`hermes_cli/web_server.py:382-386`, `_resolve_session_token`). The app mints 32 random bytes per start and hands them to the child via env. The token does NOT stay memory-only: see the next row. | run |
| Session token on disk | After bind, a serve that wins the `ROLE_SERVE` host lock publishes its rendezvous record WITH the live token (`hermes_cli/web_server.py:1361-1368`). `publish_record` writes `<lock dir>/host-serve.token` owner-only (POSIX: tmp file created `0600`, then atomic replace) next to `host-serve.json`, which carries only a sha256 fingerprint (`gateway/host_rendezvous.py:216-222`, `373-399`, `465-507`). For the spike the file is `~/.hermes-bot-app-spike/locks/host-serve.token`. Cleanup: `cleanup_on_exit` removes record + token on atexit and on SIGTERM (prepended handler; `host_rendezvous.py:538-611`), and the parent-death watchdog exits through SIGTERM too (`web_server_lifecycle.py:303-323`; a 10 s `os._exit` ceiling backstops a stalled unwind and would skip the cleanup). A SIGKILL/crash skips that, so the token file can outlive the process. It is only retracted when the next serve in the same lock dir runs `discard_dead_record` on the provably dead owner (`web_server.py:1286-1315`, `host_rendezvous.py:518-535`). The token is per start, so a leftover file is useless after that backend is gone, but it is still a credential at rest while it lives. | run (`evidence/round2-framing-token-probe.txt`: file present while running, mode `0o600`, content equal to the session token by boolean check only, record holds only the fingerprint; file and record gone after SIGTERM. `evidence/coexistence-round2.txt`: same cleanup when the app is SIGTERMed and the watchdog stops the serve) + src |
| Rooms DB | `default_db_path()` = `<root>/shared-state.db`. A profile home under `<root>/profiles/<name>` resolves to the ROOT file (`gateway/hosted_rooms.py:398-413`). | src + run |
| Authority | `local_authority_gateway_id()` = `install:<install_id of root>` (`gateway/hosted_rooms.py:416-422`, `hermes_cli/install_identity.py:88`). | src + run |
| Room worker scope | `HostedRoomService.bindings()` picks up every room in that DB whose authority equals the local install id (`tui_gateway/hosted_room_service.py:140-145`). The worker holds a durable per-room lease keyed by `process_generation` (`tui_gateway/hosted_room_driver.py:541-556`). | src |
| Who runs a worker | Every `hermes serve` (`hermes_cli/web_server.py:229-243`) and the messaging gateway (`gateway/run_startup.py:822-842`). | src |
| Host rendezvous | Per-OS-user lock dir `~/.local/state/hermes/gateway-locks/host-*.json`, override `HERMES_GATEWAY_LOCK_DIR` (`gateway/status.py:319-335`). A non-desktop serve claims `ROLE_SERVE` and may reap a provably orphaned holder (`hermes_cli/web_server.py:1286-1347`). | src |
| Desktop-owned | Only when `HERMES_DESKTOP=1` and a token is present. That mode enables the desktop orphan reap and the code-skew exit (`hermes_cli/process_identity.py:243-259`, `web_server.py:1406-1432`). | src |
| Parent watchdog | `HERMES_PARENT_PID=<pid>` without marker/nonce arms exit-on-parent-death (`hermes_cli/web_server_lifecycle.py:326-347`). | src (the app was killed with SIGTERM and the serve was gone 5 s later; `evidence/coexistence-after-app-quit.txt`) |

Consequence: a second serve under `~/.hermes` is not isolated, even on a different port. It shares
`~/.hermes/shared-state.db` and the same authority with the Electron backend (pid 29903) and the
messaging gateway (pid 1023). Either worker could lease and run the spike's room, and the spike serve
would claim the machine `ROLE_SERVE` rendezvous record. The spike therefore runs with:

```
HERMES_HOME=~/.hermes-bot-app-spike/home              # outside ~/.hermes → root = this dir
HERMES_GATEWAY_LOCK_DIR=~/.hermes-bot-app-spike/locks # private rendezvous dir
HERMES_PARENT_PID=<app pid>                           # no HERMES_DESKTOP, clean env otherwise
```

Observed [run]:
- The spike root has its own `install_id` (different from `~/.hermes/install_id`) and authority
  `install:007a8f1b…`.
- The spike serve opens only `~/.hermes-bot-app-spike/home/{state.db,runs_idempotency.db}` plus that
  root's `shared-state.db`.
- `~/.hermes/shared-state.db` mtime stayed `Sep 23 13:37` across all runs.
- `~/.local/state/hermes/gateway-locks/` was unchanged.
- The private lock dir does hold the spike's own `host-serve.{json,lock,token}` while the serve is up
  (see the "Session token on disk" row).

Attach-first behaviour [run]: a second `hermes serve` started with the SAME lock dir while the first
is alive does not bind. It prints `Hermes backend already running on this host: PID …, port …` and
exits 0 without a READY line (`hermes_cli/main_dashboard.py:905-940`). `ServeProcess` reports that
as `exitedBeforeReady(0)`. A client must therefore keep at most one owned serve per lock dir, or
reuse/stop the running one before starting another. The M0 app stops its previous backend before a
rerun (`evidence/app-rerun-console.log`: pid 15615 stopped, then a fresh serve 15734 replied `pong`).
- `groups.list` returns only spike rooms.

The isolated home needs its own `config.yaml`, provider key, and at least two profiles:
`default` plus `profiles/bravo` (see §4, roster ≥ 2).

## 2. Transport: `/api/ws`

- URL: `ws://127.0.0.1:<port>/api/ws?token=<session token>`. On a loopback bind without an auth
  provider, auth is the legacy `?token=`, compared in constant time
  (`hermes_cli/web_server_chat.py:250-375`, last branch). This is the same query param the Electron
  local connection uses (`apps/desktop/electron/connection-config.ts:88`).
- Subprotocol: `hermes-gateway-v1` is selected only on the gated ticket path, when the client offers
  `hermes-gateway-v1` together with `hermes-gateway-ticket.<ticket>` (`web_server_chat.py:207-222`,
  `299-317`). On loopback token auth the server calls `accept()` with no subprotocol
  (`tui_gateway/ws.py:353`).
  - [run] Offering `["hermes-gateway-v1"]` on loopback still connected, with negotiated protocol
    `<none>`; URLSession tolerated the missing header.
  - The client should therefore NOT require a negotiated protocol in local mode, and should not offer
    one there. The original card premise ("handshake subprotocol hermes-gateway-v1") only holds for
    gated/remote mode.
- Framing: exactly ONE JSON-RPC 2.0 object per WebSocket text message, both directions.
  - Client → server: the read loop takes one `receive_text()`, strips it, and `json.loads` the whole
    message (`tui_gateway/ws.py:397-425`). A trailing newline is fine. Two objects in one message
    are NOT split: the reviewer's probe (one frame holding two newline-separated requests) got
    `-32700 parse error` with `id: null`, reproduced in `evidence/round2-framing-token-probe.txt`
    [run] (case B; cases A and C show single-object frames and a trailing newline both work).
    The client must never batch requests into one frame.
  - Server → client: every serialized object goes out in its own `send_text` (`ws.py:190-205`,
    `_safe_send_many` loops one frame per object).
  - The module docstring's "newline-delimited JSON-RPC both ways" (`ws.py:1-4`) describes the
    stdio transport's wire, not WS message boundaries. Do not rely on it for WS.
  - `GatewayClient` still splits received text on `\n`. That is a client-side tolerance only, not
    a server guarantee.
- First frame after accept [run]: `{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":…,"change_events":true,"heartbeat":true,"replay_epoch":"<hex>"}}}`.
- Heartbeat: `{"method":"gateway.ping"}` → `{"result":{"ok":true}}`. It is answered on the read loop
  even while a handler blocks (`ws.py:420-424`). The client pings every 15 s; the send deadline is
  30 s (`ws.py:69`).
- Responses: `{"jsonrpc":"2.0","id":N,"result":{…}}` or `{"jsonrpc":"2.0","id":N,"error":{"code":C,"message":M[,"data":D]}}`.
  All `groups.*` are in `LONG_HANDLERS` and answer from the RPC pool, so ordering is per id, not
  FIFO (`tui_gateway/methods_groups.py:18-23`).
- Unknown method [run]: `-32601`, message `unknown method: groups.nope — the client and the Hermes backend are out of sync…`.

## 3. Methods exercised in M0

Typed wire contract: `tui_gateway/contracts/groups_bot_relay.py`. Handlers:
`tui_gateway/methods_groups.py`. Row shapes: `gateway/hosted_rooms.py` (`_room_from_row`,
`_event_from_row`, `read_events`).

### 3.1 `groups.capabilities` [run]
- Params: `{}`. Optional `profile` routes room-link policy to that profile.
- Result:
  ```
  {protocol_version: 2, driver: bool, persistent_process: bool, authority_gateway_id: "install:<id>",
   room_link: {enabled, profile, catalog{installation_id, protocol_versions[2], link_modes["direct"],
               persistent_process, text, attachments:false, execution_policy{version, target_profile,
               enabled_toolsets, approval_mode, max_iterations, policy_digest}, endpoint, catalog_digest},
               endpoint{available:false, reason:"not_configured"}} | {enabled:false, reason},
   features: [authority_epoch, coordinator_fencing, room_identity, monotonic_log, idempotent_send,
              replayable_disband, typed_events, actor_identity, log_replication, authority_takeover],
   methods: [18 groups.* names], max_log_limit: 500}
  ```
- `driver` is true only while the process-owned service runs
  (`methods_groups.py:220-221`, `72-81`). The service starts on a background thread after bind
  (`web_server.py:229-243`), so poll until `driver: true` before `create`/`send`. In M0 it was
  already true at the first call, about 0.5 s after READY.

### 3.2 `profiles.list` [run]
- Params: `{include_sessions?: bool}`. The default `true` adds session preview fields.
- Result: `{profiles: [{name, path, is_default, model, provider, description, display_name, skill_count, previous_names, ui_meta_revisions, has_avatar, [last_session, worker_session, canonical_session]}], bot_mode_protocol: true, install_id}`
  (`tui_gateway/methods_profiles.py:281-303`).
- M0 saw `default` (is_default) and `bravo`.
- Room membership is validated separately against `HostedRoomService.local_profiles()`:
  `default` + `profiles/*` dirs with an identity marker (config.yaml/.env/state.db), excluding
  dot-dirs and deleted profiles (`hosted_room_service.py:126-138`). In practice this is the same set.

### 3.3 `groups.create` [run]
- Params: `{room_id, name, members: [{member_id, profile, handle, display_name?, target?}]}`. A
  client-supplied `authority_gateway_id` is ignored.
- Rules (`gateway/hosted_room_discussion.py:233-276`):
  - 2–6 members.
  - `member_id`/`profile`/`handle` match `^[A-Za-z0-9][A-Za-z0-9._:-]*$`, max 128 chars.
  - `profile` must be local unless `target.kind == "peer"`.
  - Handles are unique and cannot be `all`/`everyone`.
  - Unique local profiles and unique member_ids.
  - Cross-gateway fields (`connectionId`, `targetProfile`, …) are rejected.
  - `room_id` uses the same identifier pattern. `name` is non-empty, max 200 chars.
- Result `{room}`:
  ```
  {room_id, name, members:[{member_id, profile, handle, display_name?, target:{kind:"local", profile}}],
   authority_gateway_id, authority_epoch: 1, revision: 1, created_at, updated_at, idempotent: false}
  ```
  `target` is filled in by the server. No `latest_seq` on create.
- Idempotent [run]: repeating identical params returns the same room with `idempotent: true`.
  Different name/members under the same id → `RoomConflictError`. A disbanded id can never be reused.
  At most 256 active rooms (`hosted_rooms.py:857-896`).
- Requires the live worker. Otherwise error 4123 "Group Chat worker is unavailable…"
  (`methods_groups.py:357-364`).

### 3.4 `groups.send` [run]
- Params: `{room_id, event_id, payload: {text, thread_id}}`. The payload must have exactly these two
  fields: `text` ≤ 64 KiB, `thread_id` an identifier (`hosted_room_discussion.py:198-203`).
  - `event_id` is the client retry key. The contract model marks it optional, but it is effectively
    required: `user_event_id()` validates it as an identifier (`hosted_rooms.py:244-246`).
- Server behaviour:
  - Stores the event as `user:<sha256(event_id)>`, kind `message.user`, actor `{kind:"user", id:"desktop"}`.
  - The actor is server-owned. Every native-app user message is attributed to `desktop`.
  - Then runs `prepare_room` and wakes the worker (`hosted_room_service.py:454-466`).
- Result:
  ```
  {event: {room_id, seq, event_id, kind:"message.user", actor, authority_epoch, payload, created_at,
           idempotent}, client_event_id, accepted: true, driver_started: true}
  ```
  `accepted`/`driver_started` are constants (`methods_groups.py:391-393`). They prove only the
  append, not that a bot turn ran or will run.
- Idempotent [run]: the same `event_id` and payload return the original event (`seq: 1`,
  `idempotent: true`). The same id with a different payload → `EventConflictError`.

### 3.5 `groups.log` [run]
- Params: `{room_id, since_seq = 0, limit = 100 (1..500), include_disbanded?}`.
- Result: `{events: [RoomEvent], cursor, latest_seq, has_more, authority: {gateway_id, epoch}}`.
  - `cursor` = seq of the last returned event (or `since_seq` if none).
  - Pages are bounded by count and by 2 MiB serialized (`hosted_rooms.py:1140-1189`).
  - The next call uses `since_seq = cursor`.
- `RoomEvent` = `{room_id, seq, event_id, kind, actor, authority_epoch, payload, created_at, idempotent}`.
- Events seen in the M0 turn [run]:

  | seq | kind | actor | payload |
  |---|---|---|---|
  | 1 | `message.user` | `{kind:user, id:desktop}` | `{text, thread_id}` |
  | 2 | `message.member` | `{kind:member, id:alpha, profile:default, display_name:Alpha}` | `{text:"pong", member_id, member_index, round_index, thread_id, task_id:"dtask:…", turn_id:"d1.r0.p0.s1.m…", discussion_event_id:"user:…"}` |
  | 3 | `turn.settled` | `{kind:gateway, id:install:…}` | coordinates above + `{message_event_id:"dmessage:…", passed:false, seen_through_seq:1}` |
  | 4 | `room.activity` | gateway | `{status:"settled", reason_code:"silent_round", thread_id, discussion_event_id}` |
  | 5 (run2) | `room.stop_requested` | gateway | `{cancel_id}` (after `groups.stop`) |

- Other kinds the log may carry [src] (`hosted_rooms.py:49-55`):
  - `turn.started|failed|cancelled|deferred|reassigned`
  - `member.unavailable`
  - `room.created|renamed|members_changed|disbanded`
  - `authority.claimed|lost`
- Terminal payload extras [src] (`hosted_room_discussion.py:64-68`):
  - `turn.failed`: `error`, optional `reason_code`.
  - `turn.cancelled`: `reason`.
  - `turn.deferred`: `execution_generation`, `reason`.
- Errors [run]: `since_seq` ahead of the log → 4112 "since_seq is ahead of the hosted room log";
  `limit: 501` → 4112 "limit must be between 1 and 500".

### 3.6 `groups.state` [run]
- Params: `{room_id, include_disbanded?}`.
- Result: `{room: {…create shape…, latest_seq, [authority_claim]}, driver_status?}`.
  `driver_status` is present only while the service runs and the room is live
  (`methods_groups.py:367-378`):
  ```
  {running, working, blocked, counts: {<task status>: n}, pending_actions: [], peer_routes: []}
  ```
  - `working` = any task `queued|running|stopping`.
  - `blocked` = room in runtime blocked set, or any `indeterminate|stopping` task.
  - `pending_actions` = `{kind:"retry", task_id}` for `indeterminate|deferred` tasks, plus
    approval actions (`hosted_room_service.py:536-556`).
- Observed transitions [run]: `{working:true, counts:{running:1}}` right after send →
  `{working:false, counts:{settled:1}}` about 6–22 s later.
- Unknown room [run]: 4114 "hosted room not found".

### 3.7 `groups.list` [run]
- Params: `{limit = 500 (1..500), offset = 0, include_disbanded?}`.
- Result: `{rooms: [Room], next_offset}`. Ordered by `updated_at DESC, room_id ASC`.
  `next_offset` is non-null only when the page is full.

### 3.8 `groups.stop` [run, minimal]
- Params: `{room_id, cancel_id = "desktop-stop"}`.
- Appends an idempotent `room.stop_requested` fence keyed by `cancel_id`, then cancels
  `queued|running|indeterminate|deferred|stopping` tasks (`hosted_room_service.py:468-488`).
- Result `{cancelled: <tasks touched>}`. On a settled room [run] → `{cancelled: 0}` plus the fence event.
- Fence semantics [src]: user messages with `seq` below the latest stop fence are never planned again
  (`hosted_room_discussion.py:571-581`).

### 3.9 Error-path probes only (no live task) [run]
- `groups.retry {room_id, task_id}` with an unknown task → 5118 "no retryable room task matches task_id".
- `groups.approve {room_id, member_id, task_id, execution_generation, choice ∈ {once, deny}, request_id}`
  with nothing pending → 5119 "room approval is no longer pending".

## 4. Discussion policy (what makes a bot reply)

[src] `gateway/hosted_room_discussion.py:617-662`. The policy replays the whole log and plans at most
one task at a time.

- Round 0 responders:
  - members `@handle`-mentioned in the user text;
  - no mention, or `@all`/`@everyone`, → every member.
- Rounds 1–2: only members a bot explicitly cited and who have not spoken since.
- Bounds: 3 rounds, 10 member messages per user message. These end with
  `room.activity {status:"bounded", reason_code: max_rounds|max_messages}`.
- A round where nobody posts → `room.activity {status:"settled", reason_code:"silent_round"}`.
  This is the "discussion finished" signal for a `discussion_event_id`.
- A reply of `(pass)` is silence: `turn.settled.passed = true`, no `message.member` event.
- Only the latest user message per `thread_id` that is not yet settled and not stopped is pending.
  A second user message in the same thread before the first settles supersedes it.
- Each member turn runs as a hidden in-process session titled `Group: <room_id>`
  (`session.create … hidden:true, room_plumbing:true`, `tui_gateway/hosted_room_server_rpc.py:59-62`).
  It uses that member profile's own config (model/toolsets/approvals).
- M0 used `@alpha` so exactly one bot turn ran: round 0 = alpha, round 1 silent → settled.

## 5. Streaming / push

- [run] No room-scoped push exists. During the turn the WS client received only `gateway.ready`,
  `sessions.changed` and `projects.changed` global broadcasts (`roundtrip.json → ws_events_seen`).
  The room's progress is visible only via polling `groups.log` / `groups.state`.
- [run] The hidden member session's token stream does not reach WS clients. It has no transport, so
  its frames (`session.info`, `message.start`, `thinking.delta`, `reasoning.delta`, `message.delta`,
  `message.complete`, all with `session_id`) are written to the backend's stdout
  (`~/.hermes-bot-app-spike/serve.log`).
  - Consequence: the app must drain the child's stdout continuously, or the backend's writes would
    block once the pipe fills (`ServeProcess` does this).
  - Live typing indicators for room members are NOT available through this contract.
- Driver cadence [src]: idle fallback poll 5 s, active 0.25 s (`hosted_room_service.py:30-31`).
  A client poll of about 1 s is sufficient.

## 6. Error envelope

`_room_method` (`methods_groups.py:182-213`) maps errors as follows:

- `HostedRoomError` (and subclasses) → the method's `room_code` (41xx) with `data: {"reason"}` when
  the exception carries one.
- Every other exception → the method's generic `code` (51xx).
- Validation from the Discussion layer (`DiscussionValidationError`, not a `HostedRoomError`)
  therefore surfaces as 51xx [run]:

| Probe [run] | Code | Message |
|---|---|---|
| create with 1 member | 5111 | members must contain between 2 and 6 entries |
| create with non-local profile | 5111 | member 1 profile 'nope' is not local to this gateway |
| send without `thread_id` | 5112 | user payload is missing fields: thread_id |
| send with extra payload field | 5112 | user payload has unknown fields: x |
| state of unknown room | 4114 | hosted room not found |
| log since_seq ahead / limit 501 | 4112 | (see §3.5) |
| retry unknown task | 5118 | no retryable room task matches task_id |
| approve with nothing pending | 5119 | room approval is no longer pending |

Codes from source, not triggered:
- 4123: worker unavailable (create/send/disband).
- 4115: worker unavailable (stop/approve/retry).
- Room codes: 4110 create, 4111 send, 4113 disband, 4117 rename.
- Generic codes: 5110 list, 5114 disband, 5116 stop, 5117 rename.
- Collision: 5116/5117/5118/5119 are reused across methods (stop/replicate, rename/replica_state,
  retry/promote, approve/demote). Clients must key on method + code.

## 7. Not proven in M0 (open for M1/M2)

- `groups.approve` / `groups.retry` happy paths. These need a member turn that requests approval or
  ends `indeterminate`/`deferred`. The `pending_actions` shape for approvals is only read from source
  (`hosted_room_service.py:305-311`, `tui_gateway/hosted_room_driver.py:392` `_report_pending_action`).
- `groups.stop` while a turn is running (`stopping` → acknowledged cancel → `turn.cancelled`).
- `groups.rename`, `groups.disband`; replication/promote/demote; `groups.peer.*` (RoomLink).
- Multi-member rounds (`@all`, bot-to-bot mentions), `(pass)`, `turn.failed` reasons, `member.unavailable`.
- Backend restart recovery (lease takeover, `indeterminate` reconciliation), `replay_epoch` handling
  on reconnect.
- Gated/remote auth (ticket subprotocol).

## 8. Clarifying questions from room members (C2.3 spike)

Question: can a room member's clarifying question (the `clarify` tool) be answered from the app?
**Answer: no, not through any existing API.** Read from source against Hermes Agent `main` (`8a7a5a905fc`),
2026-11-06 [src]; no live room was created for this.

- `groups.state.driver_status.pending_actions` has two kinds only: `{kind:"retry", task_id}` and
  `{kind:"approval", …}` (`tui_gateway/hosted_room_service.py` `status`). The room driver reports a member's
  pending action from its hidden session's `info` (`tui_gateway/hosted_room_driver.py` `_report_pending_action`),
  and `HostedRoomServerRPC.info` (`tui_gateway/hosted_room_server_rpc.py`) fills only `pending_approval`. A clarify
  is never reported.
- The only answer method in `groups.*` is `groups.approve`, which takes `choice ∈ {once, deny}` for a pending
  approval (`hosted_room_service.py` `approve_room_task`). There is no `groups.answer` or equivalent, and
  `groups.log` has no clarify event kind (the room log carries `message.*`, `turn.*`, `room.*` only).
- What happens instead: a member turn runs in a hidden `bot_room` session (`room_plumbing`, no client transport).
  If the member calls `clarify`, the session's callback (`tui_gateway/server.py` `_clarify_block`) opens a
  server→client `clarify` request (`tui_gateway/server_requests.py` `send`). With no WebSocket client attached the
  request counts as answerable, so it is registered and its frame goes to the backend's stdout like every other
  frame of the hidden session (§5); nobody sees it. The turn then waits until the clarify timeout
  (`clarify.timeout`, default 3600 s) or the room's turn deadline (`HERMES_AGENT_TIMEOUT` + 30 s, `turn.failed`
  with `reason_code: turn_deadline_exceeded`), whichever comes first; on a timeout the tool gets
  `outcome: timed_out` (or `undelivered`) with no answers.
- The only way to reach that request would be to attach a client to the member's hidden session
  (`session.resume` / `session.activate` replay `open_requests`) and send a JSON-RPC response to its `srq-…` id.
  That is not a room API: it takes over room plumbing the room driver owns (lease, transport), bypasses the
  fenced `groups.*` channel, and breaks the ground rule that Group Chat stays on `groups.*`. The app does not do it.

Conclusion for the app: no answer card. A member that needs the user should write `@user` in its reply; the room
row shows the "Needs you" badge for that (C1.5) and the user answers in the room. Answering real clarify requests
needs a backend change (for example a `{kind:"clarify", questions}` pending action from
`server_requests.open_requests` plus a `groups.answer` method, or turning the `clarify` toolset off for `bot_room`
sessions as the API server's toolset does). That stays in the roadmap backlog.
