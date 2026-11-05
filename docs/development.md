# Development notes

Contributor-facing notes: code layout, tests, harness CLIs, test-only environment variables, backend
lifecycle and the test-data cleanup rules. End-user setup lives in the [README](../README.md).

Protocol references:
- [gateway-contract.md](gateway-contract.md): connection (attach-first, spawn-if-absent), Bots, Bot Chat 1:1,
  streaming; Group Chat in §7.
- [groups-contract.md](groups-contract.md): the `groups.*` API, WS framing, error envelope.

Tags such as `[run]`, `[src]` and `[test]` in those docs say how a claim was established. `[run]` claims
point at local evidence logs (`evidence/`, git-ignored, never published because they hold raw wire traffic).

## History

The app was built in three steps; the contracts still use these names.
- **M0**: `spike-harness`, a `groups.*` round trip on a private, isolated Hermes home.
- **M1**: Bots + Bot Chat 1:1 with streaming (`profiles.list`, `session.create` → `session.title` →
  `prompt.submit` → pushed `message.start/delta/complete`).
- **M2**: Group Chat on hosted rooms (`groups.list/create/send/log/state/stop/retry/approve`, disband). Rooms
  are followed by polling `groups.log {since_seq}` + `groups.state`; there is no push for rooms.

## Layout

```
Sources/HermesGatewayKit/   reusable: HostRendezvous (attach discovery), Backend (attach-first /
                            spawn-if-absent + event routing), BotChat (Bot, BotChatSession),
                            ChatTranscript (submit gate, turn settling, tool lines, history seeding), Redaction (token-safe errors),
                            ServeProcess (owned backend), GatewayClient (JSON-RPC/WS),
                            GroupsAPI (raw groups.* calls), GroupChat (typed groups.* views + calls),
                            RoomTimeline (log reducer, phases, send gate, poll policy, RoomSync, RoomThreads),
                            RoomPoller (one generation-guarded poll loop per room), RoomDigest (sidebar
                            preview, age, @user rule), JSONValue
  CanonicalBotChat.swift      the bot's one "Bot Chat": find -> resume, create only when absent, detach-only teardown
  ChatAttachments.swift       image/pdf/file attach RPCs, client-side checks, prompt text
  ChatControls.swift          composer controls: session.redirect, model.options, config.set model (--session) and
                              reasoning (no scope), session.usage / context_breakdown, CompactionPhase
  ChatRewind.swift            B3/B4: RewindPlanner (regenerate / edit / restore plans, row id by content),
                              RewindParams (Desktop's truncating prompt.submit), RewindReceipt (survivor rebinding),
                              BranchPlanner (session.branch count), session.history, BotChatSession.rewind/branch
  ChatRecovery.swift          B10: ErrorSurface, TurnFailure, ErrorRecoveryPlan, ErrorDiagnostics (redacted)
  ContextRefs.swift           B11: @url / @folder refs (Desktop formatRefValue), LargePaste (3000-char rule)
  ChatApprovalMode.swift      B14: approvals.mode via profile-scoped config.get / config.set
  ChangedFiles.swift          B16: file-edit tool lines folded per file (+/- counts, diffs), cards per finished turn
  MediaTags.swift             MEDIA:<path> parsing + MediaSafety (deny rules for Open/Reveal)
  ServerRequests.swift        server->client requests (approval, clarify, sudo, secret): frames, answers, cancel
  SlashCommands.swift         commands.catalog (curated like Desktop) + invocation classification
  ToolActivity.swift          tool.start/progress/complete payloads
  PluginREST.swift            /api/plugins/<name>/ REST client (session token header, loopback, no redirects;
                              streamed answers capped: 8 MB JSON, downloads per call; multipart upload; `+` in
                              query values sent as %2B)
  KanbanAPI.swift             kanban plugin calls (always ?board=); KanbanModels.swift: lenient models;
                              KanbanWorkers.swift: K5 /workers/active, /runs/{id}[/inspect|/terminate];
                              KanbanAI.swift: K6 estimate / decompose / specify (longer timeouts; ok:false is
                              not an error), /model-options, the model-override PATCH (explicit clear_* flags);
                              KanbanBoardsAPI.swift: K7 boards create/rename/archive (never delete=true or
                              /switch), export/import by path (loopback backend only), /orchestration, /profiles
  Routines.swift              A15 cron.manage: RoutineJob/RoutineList, Desktop's naming ([bot:<name>]), prompt
                              (plain in the bot's own store, v2 delegation when the scope is unproven), add
                              payload, tag-filter fallback; `{success: false}` replies throw
  BotActivityAPI.swift        bot-activity plugin calls; install/enable/remove via plugins.manage (pinned ref,
                              provenance check); BotActivityProfileSwitch: per-profile `plugins enable/disable`;
                              BotActivityFeed.swift: paging merge, cursor, member phases
  BackgroundServe.swift       opt-in LaunchAgent keeping `hermes serve` running (plist, launchctl; job state
                              parsed from `launchctl print`: running / loaded-not-running / not loaded)
  BotProfileAPI.swift         profiles.describe/configure/set_asset/get_asset/create + model.options, typed
  SoulProtocol.swift          Desktop's "Messaging other agents" SOUL section (soul.ts), verbatim
  BotMentions.swift           B1 Bot Chat @mentions (Desktop data.ts / mention middleware): handle, tag, name
                              forms, roster resolution (self excluded, code ignored, shared forms resolve to
                              neither), the identification note appended for the model, stripNote (history)
  ProfileAvatar.swift         avatar upload: ≤15 MB, PNG/JPEG by magic bytes, 256 px centred square PNG
  ProfileAvatar.swift         avatar upload: ≤15 MB, PNG/JPEG by magic bytes, 256 px centred square PNG (generated
                              images: any format ImageIO reads)
  ProfileCLI.swift            `hermes profile delete <name> --yes` (never default) and `config unset model`
                              (Inherit), trusted hermes, no shell, clean env
  BotDuplicate.swift          Duplicate: <name>-2… name, profiles.create {clone_from}, copy look and avatar
  BotCreate.swift             A7 New Bot: Desktop's slugifyProfileName / displayName / composeSoul, the exact
                              profiles.create payload, setup.runtime_check {profile}
  BotLook.swift               A10 Desktop avatar vocabulary: shapes, swatches, profileColor, the static face
                              (sampleFaceRing + eyes) as a 160 px PNG, ui_meta look patches, CAS save with removals
  AvatarSources.swift         A10 image.generate (probe, Desktop's prompts, data URL only) and pet.gallery/pet.thumb
  SkillsHub.swift             A13 skills.manage search / install (profile-scoped)
  MCPServers.swift            A14 mcp.servers.list/add/set_api_key/test and the OAuth flow (start → loopback
                              check → browser → poll → cancel on failure)
  SetupCheck.swift            E2 setup.runtime_check (read-only) → ready / noModel / unknown; retries the
                              gateway's "probe in progress" error (5097), anything unclear is `.unknown`
  DesktopGroupArchive.swift   E4/D17 parser for Hermes Desktop's ui_meta["hermes-bots-groups"] projection
                              (v1–v3, tombstones; rooms/members/messages/characters capped again), read via
                              profiles.list only
  GatewayStatus.swift         kanban dispatcher (`hermes gateway`) state + start; CommandRunner.swift: no-shell runner
                              (output read while running and capped, cancellation terminates, no wait on a
                              pipe a grandchild still holds)
Sources/BotChatHarness/     CLI: attach/spawn → profiles.list → one streamed 1:1 turn → cleanup
Sources/SpikeHarness/       CLI: the M0 groups.* round trip (isolated home): RoundTrip, GroupsAPI+Spike
                            (M0-only raw calls: profiles, create, disband, Member)
Sources/GroupChatHarness/   CLI: Group Chat scenarios (multi/stop/retry/approve/cleanup/audit)
Sources/HermesBotApp/       SwiftUI app:
  HermesBotApp.swift          @main App: the scenes only (main window, detached panes, Settings, menu bar extra)
  AppDelegate.swift           launch wiring, signals, quit cleanup with deadline, last-window / reopen policy
  RootView.swift              the main window: split view, detail pane, sheets
  Updates/                    E3 update check: AppVersion (semver order), UpdatePolicy (GitHubRelease from
                              `releases/latest`, release-page allowlist, daily schedule, what is shown when),
                              UpdateChecker (fetch, hourly tick, NSAlert with notes + Download = open the page),
                              UpdateViews (app menu Check for Updates…, Settings → Updates)
  AppModel.swift              connection (ConnectFlow), bots, rooms, backend loss, shutdown
  ChatModel.swift             one Bot Chat 1:1 (open/seed/send gate, wraps ChatTranscript)
  ChatModel+Slash.swift       slash command execution and directives
  ChatModel+Requests.swift    attachments staging and server request cards state
  ChatModel+Queue.swift       B8: Return steers (session.redirect), ⌘Return queues, auto-drain, Stop pauses, edit
  ChatModel+Controls.swift    B7/B9: model + reasoning per chat (optimistic, rollback, confirm), context usage
  ChatModel+Rewind.swift      B3 regenerate / edit / restore (confirm, row-id resolution, rollback), B4 branch,
                              B10 error-card actions (retry, switch provider, diagnostics, dismiss)
  ChatModel+Attachments.swift B11 URL / folder chips and long paste, B14 approval mode (optimistic, rollback)
  ChatCards.swift             B10 ErrorCardRow, B16 ChangedFilesCard / DiffText, B3 MessageEditSheet, B11 AttachURLSheet
  ChatSheets.swift            the dialogs a chat surface presents (rewind confirm, edit, URL, image zoom)
  BranchChatSheet.swift       B4 read-write branch sheet; BotChatActions (per-message actions, error card)
  ImageZoomSheet.swift        B11 zoom/pan sheet (Quick Look rendition), ImageZoomState, imageZoom environment
  ChatSessionLink.swift       protocol ChatModel needs from a chat (BotChatSession in prod, fake in tests)
  ChatComposer.swift          composer: paperclip, drop/paste, slash menu, Send/Steer/Queue/Save, Stop, status row
  ChatComposerControls.swift  model menu, reasoning menu, context gauge + breakdown popover
  ChatQueuePanel.swift        queued messages above the composer (Edit, Send now, Delete, Resume)
  MessageCopy.swift           B2: Copy message / Copy full response (hover + context menu), B5 hover time
  ChatModel+Composer.swift    B12 PromptHistory (ring from the chat's user lines, caret rule, stash) and
                              ChatDraftStore (UserDefaults hba.botChatDrafts, 20,000-char / 64-bot caps, off
                              under XCTest); B1 roster candidates, mention handles, modelText (note on submit,
                              steer and queued sends), BotMentionCompletion; BotMentionSuggestions.swift: popover
  TranscriptFollow.swift      B6 TranscriptFollow (stop following only on a user scroll-up), UnreadCounter,
                              ScrollToBottomButton; B5 MessageTime texts, TurnDurationLabel
  ChatFind.swift              B13 ChatFind (matches, current, wrap, refresh), find bar, findQuery environment,
                              TextStyling.highlightFind, FindCurrentRing
  ChatExport.swift            B15 Markdown export (messages, tool summary lines, Redaction.scrub; no args,
                              results or Thought rows) and the save panel
  SlashCommandMenu.swift      slash menu keyboard model
  AttachmentChips.swift       staged attachment chips, pasteboard file import
  ToolActivityRow.swift       compact tool-call row
  ServerRequestCards.swift    approval/clarify/secret cards; RequestCardModels.swift: their labels and answers
  MediaViews.swift            MEDIA files: inline images, file chips, click-time safety check
  SidebarView.swift           Group Chats + Bots + Boards sidebar, filter field, bot row (preview, age, unread,
                              attention), bot row menu, section blocks + drag and drop, Hidden (n), row style,
                              connection footer; SidebarFilter.swift: filter, BotRoster (pinned, then newest
                              activity; section blocks; hidden section), BotRowMenu; BotRowBadges.swift
  BotMetaModel.swift          Pin / Hide / section per bot: optimistic, saved with BotMetaSync (HermesGatewayKit
                              BotUIMeta.swift: ui_meta["hermes-bots"] read-patch-write with CAS, like Desktop)
  BotActivityHub.swift        A4/A6: profiles.list {include_sessions: true} every 10 s (HermesGatewayKit
                              BotRosterActivity.swift: Desktop's activity/preview/recent-session rules), unread
                              watermark per bot (UserDefaults hba.botReadThrough, seeded on first sight),
                              needs-attention from failed turns (HermesGatewayKit BotAttention.swift)
  BotSections.swift           A5: BotSectionsModel (local list hba.botSections + collapsed hba.botSectionsCollapsed;
                              membership sectionId/sectionName on each bot via BotMetaModel; adopt / backfill
                              like Desktop's user-sections.ts), BotSectionBlock, BotDrag (@handle payload);
                              BotSectionViews.swift: header, empty slot, name sheet, Undo line
  RecentSessionView.swift     A17: read-only sheet of a bot's newest non-Bot-Chat session (HermesGatewayKit
                              SessionTranscriptREST.swift: GET /api/sessions/{id}/messages, read-only store)
  BotEditor/                  A7-A14 bot management: BotProfileService (protocol; live = gateway + CLI,
                              fake in tests), BotEditorModel + BotEditorView + BotAdvancedSection (Edit sheet:
                              changed fields only, per-field errors, expensive-model confirm), BotModelPicker
                              (Desktop's ModelPicker rules, shared by Edit and New Bot), BotCreateModel/View +
                              AppModel+BotCreate (A7 New Bot: steps, warnings, readiness, intro once the Bot Chat
                              is ready; File menu command), BotAvatarPicker (A10 Shape/Upload/Generate/Pet and the
                              preview tile), BotCapabilityModels/Views (A13 Find Skills, A14 MCP list/add/key/
                              test/OAuth), BotLifecycleModels/Views (Duplicate progress, Delete confirmation),
                              AppModel+BotManagement (BotSheet, roster refresh, forgetting a deleted bot)
  Notifications/              D1/D2: NotificationPolicy (when to notify, content, routes, Dock badge count,
                              @user grammar), RoomAttention (+ RoomAttentionWatcher: fed by RoomDigestHub's
                              passes and the open room's poller; it does not poll), NotificationCoordinator
                              (chats + rooms → posts, withdrawals,
                              badge), UserNotificationPoster (UNUserNotificationCenter; .app bundle only, never
                              under XCTest), AppModel+Notifications (click and Approve/Deny routing),
                              NotificationMutes (D15: muted bots/rooms in UserDefaults `hba.mutedNotifications`;
                              no banner, the Dock badge still counts them)
  Voice/                      B17: SpeechText (what Read Aloud says: markdown flattened, code blocks, MEDIA tags,
                              Thought and tool rows left out), ReadAloud (SpeechSynthesizing protocol,
                              ReadAloudController: one voice app-wide, Esc watcher while speaking, auto-read on
                              `message.complete` behind `hba.readRepliesAloud`), SystemSpeechSynthesizer
                              (AVSpeechSynthesizer, system voice), Dictation (SpeechRecognizing protocol,
                              DictationController: lazy permissions, partials at the caret, silence stop,
                              DictationInsertion, DictationError), SystemSpeechRecognizer (SFSpeechRecognizer +
                              AVAudioEngine, on-device when supported; needs the Info.plist usage strings, so a
                              `swift run` build reports "outside the app"), VoiceViews (mic button, error banner,
                              Read Aloud button/menu items, Settings › Voice)
  AppCommands.swift           D5/D9/D10/D13 menus: Go (⌘K, ⇧⌘F, ⌘1…9, Open in New Window), File → room
                              templates; SidebarItemMenu (Open in New Window, Save as Template…, Mute) for rows
  QuickSwitch.swift           pure: SidebarShortcuts (⌘1…9 = rooms then bots in sidebar order), FuzzyMatch,
                              QuickSwitch candidates/ranking, MessageSearch (sources from loaded transcripts,
                              open room logs and RoomDigestHub tails; snippets); CommandPaletteView.swift: the
                              ⌘K / ⇧⌘F palette; AppModel+Navigation.swift: PaletteMode, MessageJumpCenter +
                              MessageJumpTarget (scroll a pane to a found message), search sources
  PaneWindows.swift           D9: WindowGroup(for: SidebarItem) content on the main window's models, SidebarItem
                              Codable token, PaneViewers (RoomModel / RoomActivityModel poll while ANY view shows
                              them; one poller per room however many windows), connectOnce (first window connects)
  QuickLook.swift             D8: QuickLookPolicy (previewable = checked and not reveal-only; Space bar rule),
                              MediaDrag (drag out = file URL re-checked by MediaSafety at drag time),
                              QuickLookController (QLPreviewPanel data source; the app delegate is its controller)
  RoomTemplates.swift         D13: RoomTemplateStore (UserDefaults `hba.roomTemplates`, 2–6 members, prompt), the
                              Save as Template sheet, File menu items; creating from one reuses CreateRoomPrefill
                              under XCTest), AppModel+Notifications (click and Approve/Deny routing)
  MacIntegration/             D3/D4/D6/D7/D12: QuickSend (QuickSender: the one send path into a bot's Bot Chat via
                              ChatModel.sendDirect, the composer's gate, or a room's `main` via groups.send;
                              QuickReply: a quick turn's reply from the lines after its user line; prefill for
                              Services; AppModel.openFromIntegration), MenuBarExtra (MenuBarStatus rows/pending,
                              MenuBarScene with `hba.menuBarExtra`, quick send), GlobalHotKey (HotKeyShortcut,
                              HotKeyRegistering: CarbonHotKeyRegistrar in the app, QuickAskHotKey settings
                              `hba.quickAsk.enabled` / `hba.quickAsk.shortcut`, ShortcutRecorder), QuickAskPanel
                              (non-activating NSPanel, QuickAskModel, QuickReplyView), ServicesProvider
                              (ServiceInput, HermesServicesProvider `sendToHermesBot:userData:error:`,
                              ServicesRegistering, SendChooserModel + window), HermesIntents (AppIntents: Ask Bot,
                              Send to Group Chat, Bot/Room entities; IntentRunner waits for the connection),
                              RoomCatchUp (prompt from RoomDigestHub.leftAt, the toolbar button and sheet),
                              MacIntegration (install at launch with injected registrars; Settings section)
  KanbanHub.swift             board list for the sidebar, per-board models (pruned when unlisted), polling paused
                              while no main window is on screen (setActive), dispatcher polling while a board shows
  DispatcherStatusModel.swift the one dispatcher status model (board chip + Settings), generation-guarded (K8)
  BackgroundServeSettingsModel.swift  Settings → Background: confirmations (path, env override, Switch Now /
                              At Next Launch, turning off while attached); SettingsSections.swift: the Settings window (SettingsView, SettingsForm) and the views
  KanbanBoardModel.swift      one board: polling (suspendable), lanes, optimistic actions + rollback, details,
                              `.gone` when the board is deleted or archived while open (KanbanService)
  KanbanBoardView.swift       board pane: header, lanes, cards, card menus, dispatcher chip
  KanbanBoardFilters.swift    K4 filter menu: profile (client-side), Show archived (include_archived),
                              Group Running by profile (@AppStorage hba.kanbanGroupRunning)
  KanbanWorkersModel.swift    K5 Workers sheet state: polling /workers/active while open, inspect, terminate,
                              reclaim; KanbanWorkersView.swift: the sheet
  KanbanCardAI.swift          K6 KanbanCardAIModel (board.ai): per-card estimate / decompose / specify results,
                              one action per card, confirmation for decompose/specify, model override; the
                              inspector's AI section, Model menu, card-menu items
  KanbanBoardManagement.swift K7 KanbanHub board actions (create/rename/archive/export/import, boardNote),
                              KanbanOrchestrationModel + sheet, board name sheet, the header's Board menu
  KanbanIntegrations.swift    K9 KanbanTaskSeed / compose request (Create Task from Message), KanbanWatchList
                              (UserDefaults hba.kanbanWatchedCards), KanbanCardWatcher (own 15 s /board loop
                              while connected, baseline first, done/blocked events), KanbanCardNotice (content +
                              route), KanbanComposePresenter; AppModel+Kanban.swift: compose, Open Bot Chat,
                              open a card from its notification
  RoutinesModel.swift         A15 one bot's routines (20 s refresh while open, optimistic pause/resume, legacy
                              auto-pause, create); RoutinePresentation.swift: schedule picker + texts;
                              RoutinesView.swift: the sheet; RoutinesToolbarButton sets ChatModel.routinesShown and
                              BotChatView presents it from the pane (not from the toolbar item)
  KanbanTaskInspector.swift   card details inspector (attachments, message worker / requeue), New Task sheet;
                              KanbanSidebar.swift: Boards rows
  KanbanAttachments.swift     card attachments on disk: upload read + size cap, download name sanitising,
                              caches folder, open-or-reveal check (never runs files)
  BotChatView.swift           Bot Chat pane (transcript, composer, streaming text)
  BotInspector.swift          bot details inspector, DefaultTag
  RoomModel.swift             SidebarItem, RoomModel (polling, send gate, room actions, rename, per-thread
                              drafts, Reply to @bot / Reply in thread); talks to `any RoomActions`
  RoomView.swift              Group Chat pane; RoomRows.swift (ribbon, timeline rows),
                              RoomActionViews.swift (approval/retry cards, @mentions), CreateRoomView.swift,
                              RoomRenameView.swift, RoomThreadViews.swift (thread pane, thread links,
                              message action strip), RoomMembersView.swift (Change Members sheet)
  RoomMemberChange.swift      C2.2 Change Members: RoomCarryOver (the context message: last 12 `main`
                              messages, 4000-char cap, one `> ` line each, control frames relabelled, @ dropped,
                              file names only) and RoomMemberChange (groups.create → carry-over groups.send →
                              keep / rename "(old)" / disband the old room); AppModel+RoomMembers.swift wires
                              it to the sidebar and selection
  RoomDigests.swift           RoomDigestHub (sidebar room rows: groups.list → log tails → state for unsettled
                              rooms, seen-through per room in UserDefaults) and the room row view
  RoomActivityModel.swift     per-room Activity inspector state: bot-activity polling, plugin enable/remove;
                              RoomActivityPresentation.swift (rows, chips, turn-state fallback),
                              RoomActivityPanel.swift (panel, enable sheet)
  RoomSidebarOrder.swift      C1.4 RoomOrder (pinned first, then the user's order; Move Up/Down and drops stay
                              inside a group) + RoomOrderStore (UserDefaults `hba.rooms.pinned` /
                              `hba.rooms.arranged`) + the room row's menu and drag and drop
  RoomPicture.swift           C1.8 RoomPictureStore (local picture: ProfileAvatar 256 px PNG in Application
                              Support/HermesBotApp/Room Pictures, 0700/0600, removed on disband), RoomAvatar,
                              RoomAvailability ("N of M available": bot exists, last turn not failed/deferred)
  RoomAttachmentViews.swift   C2.1 Group Chat attachment tiles: Quick Look on click, Open / Reveal / Copy Path,
                              deleted-copy note; MediaSafety rules as in MediaViews (own copies checked on appear,
                              re-check on click, reveal-only formats never previewed)
  Onboarding.swift            E2 SetupIssue (from the spawn error / setup.runtime_check), which first-run screen
                              shows, the commands offered (never run); OnboardingView.swift: the screens, CommandRow;
                              AppModel+Onboarding.swift: checkSetup (once per connection) and Check Again
  DesktopArchiveModel.swift   E4/D17 read-only Desktop archive: listing for the import sheet, import/remove,
                              JSON file store (Application Support, 0600), Continue-in-a-new-room helpers;
                              DesktopArchiveViews.swift: File menu command, import sheet, sidebar section, pane;
                              AppModel+DesktopArchive.swift: app actions (prefilled create sheet + carry-over draft)
  RoomPresentation, Identity, Components, DesignSystem, MotionSheet, ConnectFlow: shared view logic
  EvidenceDriver.swift        scripted runs + window snapshots, #if DEBUG only (see below)
Tests/HermesGatewayKitTests/ ChatTranscript rules, token-leak regressions, GroupChat logic + groups.* wire
                            shapes, RoomPoller lifecycle + room availability
                            + parity suites: CanonicalBotChat, BotChatRebind (reclaim/session.info), ChatAttachment,
                            ChatTranscriptTool, MediaTags, ServerRequest, SlashCommand, ChatControls,
                            ChatRewind (B3/B4 payloads + planners), ChatRecovery (B10/B11/B14/B16)
                            (ParityTestSupport: fakes); BotRosterActivity (A4-A6/A17 parsing, attention
                            classes, section ui_meta merge, read-only transcript route)
Tests/HermesBotAppTests/    ChatModel (with FakeChatLink; ChatModelQueue, ChatModelControls, ChatComposerFeatures: B1/B12,
                            ChatRewindModel: B3/B4/B10/B11/B14),
                            BotChatTranscriptFeatures (B5/B6/B13/B15), BotChatUIModel, MediaViews, RoomModel Group Chat
                            actions + RoomDigestHub + Change Members (RoomMemberChangeTests; with FakeRoomActions,
                            no real room is created, sent to, renamed or disbanded), RoomOrder (C1.4),
                            RoomPicture + availability (C1.8), RoomAttachmentViews (C2.1); BotRoster (order, unread, attention,
                            recent session) and BotSections (CRUD, Desktop adoption, layout, drag payload), all
                            with fakes and throwaway UserDefaults suites; app regressions: Try Again reconnects after a failed load (ConnectFlow + real
                            AppModel.connect against a local fake backend, needs /usr/bin/python3),
                            approval ripple vs the motion gate, rendered monogram contrast ≥ 4.5:1,
                            create-room sheet vs the motion gate; macOS integration (PaneWindowTests,
                            QuickSwitchTests, QuickLookTests, RoomTemplateMuteTests); real-window suites are opt-in
                            (WindowTestGate: HERMES_BOT_APP_WINDOW_TESTS=1; PaneWindowLiveTests hosts one room in
                            two windows, local opt-in only); E3: UpdateCheckTests (fixture JSON, fake fetch, never
                            the real GitHub API), PackageScriptTests (`bash -n` and `--dry-run` of package-app.sh)
scripts/package-app.sh       release .app + zip: --universal (lipo), --dry-run, Developer ID + notarization by env
scripts/HermesBot.entitlements  hardened-runtime entitlements for a Developer ID signature (no sandbox)
                            create-room sheet vs the motion gate; macOS integration (QuickSendTests,
                            MacIntegrationTests, RoomCatchUpTests: QuickSendFixture over FakeChatLink and
                            FakeRoomActions, recording hot key / Services registrars); real-window suites are opt-in
                            (WindowTestGate: HERMES_BOT_APP_WINDOW_TESTS=1)
scripts/run-app-evidence.sh  scripted app run with a watchdog
scripts/sigint-regression.sh Ctrl+C cleanup check against a fake backend (scripts/fixtures/)
```

Look, tokens and motion: [DESIGN.md](../DESIGN.md), mirrored in `Sources/HermesBotApp/DesignSystem.swift`.

## Build and test

`Package.swift` declares swift-tools 6.0 and macOS 14. Tested with Xcode 26 / Swift 6.3.

```
swift build
swift test                                                         # headless, no live backend needed
HERMES_BOT_APP_WINDOW_TESTS=1 swift test                           # also the real-window suites (before UI changes)
.build/debug/HermesBotApp                                          # attach-first, else spawn
.build/debug/bot-chat-harness evidence/<name> [profile] [prompt]   # exit 0 = ≥2 deltas + complete
.build/debug/bot-chat-harness --delete <profile> <stored_session_id>   # remove a leftover test session
.build/debug/spike-harness evidence/<name>                         # M0 groups.* round trip
.build/debug/group-chat-harness <scenario> evidence/<name> [args]  # scenarios in its header comment
```

### Intel (x86_64)

Release builds are universal (arm64 + x86_64). CI runs `swift build` + `swift test` on GitHub's Intel image
(`macos-15-intel`, job `build-and-test-intel`). On an Apple silicon Mac with Rosetta 2, cross-build the tests
for x86_64 and run the bundle with the universal `xctest` under Rosetta:

```
arch -x86_64 /usr/bin/true || softwareupdate --install-rosetta --agree-to-license   # Rosetta present?
swift build --build-tests --arch x86_64 --scratch-path .build/x86_64-rosetta
arch -x86_64 "$(xcrun -f xctest)" .build/x86_64-rosetta/x86_64-apple-macosx/debug/HermesBotAppPackageTests.xctest
```

`arch -x86_64 swift test` does **not** do this with Xcode 26: its `swift-build` is arm64-only, so it quietly
builds arm64. `swift test --arch x86_64` builds the right bundle but its arm64-only test helper cannot load it.
The `xctest` route runs the XCTest suites only; the Swift Testing tests (`@Test`, HermesGatewayKit) run as
x86_64 on the Intel CI job. Last local run (2026-11-06, Xcode 26 / Swift 6.3.3): 1171 XCTest tests, 37 skipped
(window tests), 0 failures.

## Release process

1. Update `CHANGELOG.md` (move Unreleased under the new version) and merge to `main`.
2. Create and push a tag `vMAJOR.MINOR.PATCH` (for example `v0.2.0`). Tags must be numeric: the version becomes
   `CFBundleShortVersionString`, which the in-app update check compares with the latest release.
3. `.github/workflows/release.yml` runs `scripts/package-app.sh <version> --universal` on `macos-15`, writes
   `SHA256SUMS.txt` and publishes `Herald-<version>-macos-universal.zip` as a GitHub Release with generated
   notes. Installed apps see it at their next daily check (Herald → Check for Updates… at once).

Locally, `scripts/package-app.sh 0.2.0 --universal --dry-run` prints what a run would do; a real run prints
`lipo -info` and `codesign -dv` of the result.

### Signing and notarization

`package-app.sh` decides from its environment:

| `DEVELOPER_ID_APPLICATION` | `NOTARY_PROFILE` | Result |
|---|---|---|
| unset | unset | ad-hoc signature (`codesign -s -`), not notarized: users confirm the first launch |
| set | unset | Developer ID signature, hardened runtime, `scripts/HermesBot.entitlements`; not notarized |
| set | set | the above, then `xcrun notarytool submit --wait` (fails unless `Accepted`), `stapler staple`, `spctl` check |
| unset | set | error |

`NOTARY_KEYCHAIN` names the keychain holding the profile when it is not in the search list. Locally, once:
`xcrun notarytool store-credentials hermesbot-notary --apple-id <id> --team-id <TEAMID>` (asks for an
app-specific password), then `DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)"
NOTARY_PROFILE=hermesbot-notary scripts/package-app.sh 0.2.0 --universal`.

Entitlements (no App Sandbox: the app runs `hermes` and reads `~/.hermes`): `network.client` and
`device.audio-input` (the hardened runtime blocks the microphone without it; needed for dictation). No
hardened-runtime exceptions (JIT, unsigned memory, library validation).

The release workflow signs and notarizes when these **repository secrets** exist (Settings → Secrets and
variables → Actions); without them it publishes an ad-hoc signed release, as before:

| Secret | Value |
|---|---|
| `MACOS_DEVELOPER_ID_P12_BASE64` | the "Developer ID Application" certificate and its private key exported as .p12, base64 (`base64 -i cert.p12`) |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | the .p12 export password |
| `MACOS_DEVELOPER_ID_APPLICATION` | the identity name, e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_API_KEY_P8_BASE64` | an App Store Connect API key (.p8, role Developer), base64 |
| `NOTARY_API_KEY_ID` | that key's ID |
| `NOTARY_API_ISSUER_ID` | the issuer ID (App Store Connect → Users and Access → Integrations) |

The three certificate secrets alone give a signed, not notarized release (the workflow warns). The workflow
imports the certificate into a throwaway keychain, stores the notary profile there, and deletes it at the end.
**Not yet exercised:** this project has no Developer ID yet, so the signed and notarized paths have only been
checked with `--dry-run` and by review; the first real run needs the maintainer's Apple Developer account.
## Packaging, Services and App Intents

`scripts/package-app.sh` builds the release binary with `-emit-const-values` (plus a
`-const-gather-protocols-file` listing the App Intents protocols), then runs Xcode's
`appintentsmetadataprocessor` on `HermesBotApp.swiftconstvalues` to write
`Herald.app/Contents/Resources/Metadata.appintents`: SwiftPM does not do this itself, and without it
Shortcuts does not list the Ask Bot / Send to Group Chat actions. Without Xcode (Command Line Tools only) the
step is skipped with a warning. `Info.plist` declares the `NSServices` entry (`NSMessage` `sendToHermesBot`,
text and file send types). Check: `plutil -lint dist/Herald.app/Contents/Info.plist` and
`ls dist/Herald.app/Contents/Resources/Metadata.appintents`. Services and App Intents only work from the
packaged app (a `swift run` binary has no bundle).

## Test-only environment variables

User-facing variables are in the README. These exist for scripted runs and tests. The scripted-run ones
(`AUTOCHAT`, `EVIDENCE`, `AUTOQUIT`, Group Chat scripting, `ROOM_MANIFEST`) live in
`EvidenceDriver.swift` and exist only in debug builds (`swift build`; the scripts use `.build/debug`);
a release build ignores them. `LOCK_DIR` and `FORCE_SPAWN` work in every build.
- `notificationsEnabled` (user default, not an environment variable; default true): `false` stops native
  notifications (the Dock badge stays). Settings → Notifications → Show notifications writes it.
- `HERMES_BOT_APP_LOCK_DIR=<dir>`: discover in this lock dir and give it to a spawned backend. An empty dir
  means "no backend running" for tests. It does **not** change the Hermes home (still `~/.hermes`).
- `HERMES_BOT_APP_FORCE_SPAWN=1`: skip discovery and always spawn.
- `HERMES_BOT_APP_AUTOCHAT="<profile>|<prompt>"`, `HERMES_BOT_APP_EVIDENCE=<dir>`,
  `HERMES_BOT_APP_AUTOQUIT=1`: scripted app run with window renders.
- Group Chat scripting: `HERMES_BOT_APP_AUTOROOM="<botA,botB>|<prompt>"`, `HERMES_BOT_APP_OPEN_ROOM`,
  `HERMES_BOT_APP_AUTOROOM_STOP_AFTER`, `HERMES_BOT_APP_AUTOROOM_APPROVE`,
  `HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER=<s>` (leave the approval card on screen `<s>` seconds before
  answering), `HERMES_BOT_APP_AUTOROOM_RETRY`, `HERMES_BOT_APP_DISBAND_ROOMS=1`,
  `HERMES_BOT_APP_ROOM_MANIFEST=<path>` (gateway-contract §7.9).
- Harness: `HBA_ROOM_MANIFEST`, `HBA_SESSION_LEDGER`, `HBA_CLEANUP_QUIET` (see below).

## Backend lifecycle

- An attached backend is never stopped by the app.
- A spawned backend (`hermes serve --host 127.0.0.1 --port 0 --isolated` on `~/.hermes`, log at
  `~/Library/Logs/HermesBotApp/serve.log`) gets `HERMES_PARENT_PID`. It is stopped with SIGTERM on quit. If
  the app crashes, the backend exits through its parent-death watchdog.
- Closing the last window quits only while the menu bar extra is off; with it shown (the default) the app
  keeps running (status item, notifications, Quick Ask) and the Dock icon or "Open Herald" reopens the
  main window (`WindowLifecyclePolicy`, AppDelegate.swift).
- Quit (⌘Q, or the last window closed with the menu bar extra off), SIGTERM and SIGINT (Ctrl+C in the launching terminal) all run the same
  graceful cleanup, once; a repeated signal during cleanup is ignored. The spawned backend runs in its own
  process group (Foundation `Process`), so the terminal's Ctrl+C reaches only the app, which then uses the
  backend for cleanup and stops it with SIGTERM. SIGKILL skips cleanup.
  Regression check: `scripts/sigint-regression.sh` (needs tmux and a GUI session; exit 0 = pass). It runs the
  canonical Bot Chat flow against a fake backend and asserts that Ctrl+C sends no `session.close` /
  `session.delete` (the Bot Chat is only detached) and that the quit completes.
- Session tokens are read from the 0600 rendezvous file (attach) or minted per start (spawn). They are never
  logged or written to repo/evidence files.

## M0 spike home

The M0 spike harness uses its own isolated home at `~/.hermes-bot-app-spike/home` (groups-contract §1): a
minimal `config.yaml` plus `.env` with the provider key, and a second profile at `profiles/bravo`. Its backend
binds `127.0.0.1` on an OS-assigned port, printed as `READY port=N`. The per-start session token lands in
`~/.hermes-bot-app-spike/locks/host-serve.token` (0600) while that backend runs and is removed on a graceful
exit. The app itself does not use this home.

## Test data and cleanup

Live tests run against a real `~/.hermes`, so they must clean up after themselves.

- Bot Chat test sessions made by the harness are titled `hba-…` and deleted after each run (the app's own
  canonical "Bot Chat" is never deleted). The app changes profiles only on the user's action: Pin / Hide and
  the title (`pinned` / `hidden` / `title` inside `ui_meta["hermes-bots"]`), Edit (`profiles.configure`,
  `profiles.set_asset`, `hermes --profile <name> config unset model`), Duplicate (`profiles.create`) and Delete
  (`hermes profile delete --yes`). Tests never do any of this for real: kit tests use a scripted fake gateway
  and `FakeCommandRunner`, app tests a fake `BotProfileService` (`BotManagementTests`); no profile is created,
  edited or deleted, no hermes runs, no asset is uploaded. Bot Chat model and effort picks are
  session-scoped (`--session` / no scope).
- Routines and kanban workers are tested with fakes only (`FakeCron` records `cron.manage` params,
  `FakeKanbanService` the worker calls): tests never send a real `cron.manage` mutation, terminate or reclaim.
  Room pins/order (`RoomOrderTests`) use a throwaway UserDefaults suite and room pictures (`RoomPictureTests`,
  `RoomAttachmentLayoutTests`) a temp folder, never the app's preferences or Application Support.
  The same holds for K6/K7/K9: estimate, decompose, specify, the model override, board create / rename /
  archive / export / import and `PUT /orchestration` are exercised against `FakeKanbanService`
  (`KanbanAIActionsTests`, `KanbanBoardManagementTests`, `KanbanIntegrationTests`) and the in-process stub server
  (`KanbanManagementAPITests`); export/import paths are placeholders the fakes only record. Watched cards in
  tests live in memory or a throwaway UserDefaults suite.
- Bot Chat @mentions (B1) are tested with `FakeChatLink` and an injected roster: tests check the note on the
  submitted text and that nothing else is sent; no prompt reaches a real bot. Drafts (B12) are tested in a
  throwaway UserDefaults suite; `ChatDraftStore.app` is nil under XCTest.
- Update checks never reach GitHub in tests: `UpdateChecker` takes an injected fetch (UpdateCheckTests answers
  with a fixture), and the schedule only starts from the app delegate. Package script tests use `--dry-run` only.
- The macOS integration (D3/D4/D6/D7/D12) is tested headless: every quick send, Quick Ask, Services chooser,
  Shortcuts action and Summarize goes to `QuickSendFixture` (`FakeChatLink` chats, `FakeRoomActions` rooms), so
  no prompt reaches a real bot and no room message is posted. No global hot key is registered (`RecordingHotKeys`
  stands in for `CarbonHotKeyRegistrar`) and no Services provider is installed (`RecordingServices` instead of
  `NSApp.servicesProvider`); the provider test uses a private named pasteboard. Settings live in throwaway
  UserDefaults suites. The real registrars run only from `AppDelegate` (`MacIntegration.shared.install()`).
- Regenerate / edit / restore (B3), branches (B4) and the approval mode (B14) are tested only against
  `FakeChatLink` (it records each rewind's exact `text`, `rowId`, `confirmDeep` and `rebind`, each branch's
  `count` and key) and the in-process `FakeGateway` (exact `prompt.submit`, `session.branch`, `session.history`,
  `config.get` / `config.set` params). Never rewind, branch or change the approval mode of a real bot from a
  test: a rewind archives the real Bot Chat's later messages, and `approvals.mode` is the profile's config.
  Long-paste tests write into a temp paste folder (`pasteFolder`), never the app's.
- Notifications are never posted by tests: `UserNotificationPoster` exists only inside an `.app` bundle and
  not under XCTest; coordinator tests use a recording poster.
- Voice (B17) never touches the microphone, the recognizer or the speakers in tests: `DictationTests` drive
  `DictationController` with a scripted `SpeechRecognizing` fake and `ReadAloudTests` use a recording
  `SpeechSynthesizing` fake and a hand-fired Esc monitor; `ReadAloudController.shared` is silent under XCTest.
  The real engines need `Herald.app` (`scripts/package-app.sh` writes `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`); try them by hand there.
- Group Chat test rooms are `hba-…` and get disbanded after each run. Disband leaves a tombstone until backend
  pruning. The hidden member sessions are cleaned without restarting anything:
  `group-chat-harness cleanup <evidence-dir> @<room-manifest.jsonl>` disbands, then re-discovers the rooms'
  member sessions by provenance (exact `Group: <id>` title or the driver's opening prompt in the
  preview/derived title; the title is not reliable during a first turn), closes owned runtimes once `idle`,
  deletes the stored rows (4023 → next round) and succeeds only after a quiet window of consecutive empty
  discoveries (`HBA_CLEANUP_QUIET`, default 90 s). It exits 1 if anything owned or unprovable is left
  (gateway-contract §7.8).
- A runtime is closed only when an exact-id lookup (`GET /api/sessions/{id}?profile=` in every profile, not the
  filtered `session.list`) proves its session key is stored in the owning profile only, one runtime holds it,
  and its live title agrees. A member profile's `bot_room` row from the test window that names no room is
  unresolved, never ignored.
- Every proven key goes into a session ledger (`evidence/m2/session-ledger.jsonl`, `HBA_SESSION_LEDGER`) before
  it is touched and is read back by exact id afterwards: the backend's late title-generation usage write can
  re-create a deleted id as `source=unknown` (§7.8), which is deleted again. `audit`, `ledger-audit` and
  `ledger-cleanup` use the same readback.
- The harness writes the room manifest at `groups.create` (`evidence/m2/room-manifest.jsonl`,
  `HBA_ROOM_MANIFEST`); the app does so with `HERMES_BOT_APP_ROOM_MANIFEST=<path>`.
- Approvals are tested only in an isolated home (`~/.hermes-bot-app-spike/m2`), because approvals may be off in a
  real install.
