#if DEBUG
import AppKit
import SwiftUI
import HermesGatewayKit

// Scripted verification (no clicks). Debug builds only: none of this, nor the `screencapture`
// shell-out in `snapshot`, is compiled into a release build. AppModel calls in at a few `#if DEBUG`
// hook points (connect, chat/room model creation, room create, shutdown).
//   HERMES_BOT_APP_AUTOCHAT="<profile>|<prompt>"   select that bot and send the prompt once connected
//   HERMES_BOT_APP_AUTOROOM="<botA,botB>|<prompt>" create an hba- room with those bots, open it, send
//   HERMES_BOT_APP_AUTOROOM_STOP_AFTER=<s>         press Stop <s> seconds after a task is running
//   HERMES_BOT_APP_AUTOROOM_APPROVE=once|deny      answer the first pending room approval (as the button does)
//   HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER=<s>      ...after leaving the card on screen <s> seconds (evidence)
//   HERMES_BOT_APP_AUTOROOM_RETRY=1                press Retry on the first pending retry action
//   HERMES_BOT_APP_OPEN_ROOM=<room_id>             open an existing room instead of creating one
//   HERMES_BOT_APP_DISBAND_ROOMS=1                 disband the rooms this run created/opened on quit
//   HERMES_BOT_APP_ROOM_MANIFEST=<path>            append created rooms to that JSON-lines manifest
//   HERMES_BOT_APP_EVIDENCE=<dir>                  write window snapshots + ui-log.json there
//   HERMES_BOT_APP_AUTOQUIT=1                      quit after the reply completed / room settled (normal cleanup)
//   HERMES_BOT_APP_AUTOSWITCH="<seconds>|<items>"   switch panes like sidebar clicks: items are `room:<index>`
//                                                  (sidebar order) or `bot:<profile>`, comma-separated (read only)
//   HERMES_BOT_APP_AUTOATTACH="<path>,<path>"       after AUTOSWITCH, add those files as chips to the open
//                                                  room or Bot Chat composer (nothing is sent)

/// Scripted-run state, stored on `AppModel` (`evidence`).
struct EvidenceState {
    var uiLog: [JSONValue] = []
    var autoQuit = false
    let evidenceDir = ProcessInfo.processInfo.environment["HERMES_BOT_APP_EVIDENCE"].map { URL(fileURLWithPath: $0) }
    /// Rooms this app run created (disbanded on quit only with HERMES_BOT_APP_DISBAND_ROOMS=1).
    var createdRooms: [String] = []
    var autoRoomState: (sent: Bool, sawWorking: Bool, sawReply: Bool, stopAt: Date?, stopped: Bool, done: Bool) =
        (false, false, false, nil, false, false)
    var autoActed: Set<String> = []
}

extension AppModel {
    // MARK: scripted evidence

    func autochat() {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["HERMES_BOT_APP_AUTOCHAT"], let bar = spec.firstIndex(of: "|") else { return }
        evidence.autoQuit = env["HERMES_BOT_APP_AUTOQUIT"] == "1"
        let name = String(spec[..<bar]), prompt = String(spec[spec.index(after: bar)...])
        guard let bot = bots.first(where: { $0.name == name }), backend != nil else { log("autochat: no bot \(name)"); return }
        selection = .bot(bot.name)
        let chat = chat(for: bot)
        chat.open()
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)  // let the chat view appear
            while chat.phase == .loading { try? await Task.sleep(nanoseconds: 100_000_000) }
            snapshot("1-selected")
            guard chat.isReady else { log("autochat: Bot Chat did not open: \(chat.phase)"); return }
            chat.draft = prompt
            log("autochat: send accepted=\(chat.submit())")
        }
    }

    /// Rapid pane switching (the quick group/group/bot hops that showed an older room under the new
    /// pane), through the same non-animated transaction a sidebar click uses. Opens chats like a click does;
    /// sends nothing.
    func autoswitch() {
        guard let spec = ProcessInfo.processInfo.environment["HERMES_BOT_APP_AUTOSWITCH"],
              let bar = spec.firstIndex(of: "|"), let gap = Double(spec[..<bar]) else { return }
        let items: [SidebarItem] = spec[spec.index(after: bar)...].split(separator: ",").compactMap { part in
            let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            if kv[0] == "room", let i = Int(kv[1]), rooms.indices.contains(i) { return .room(rooms[i].roomId) }
            if kv[0] == "bot", bots.contains(where: { $0.name == kv[1] }) { return .bot(kv[1]) }
            return nil
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for item in items {
                log("autoswitch → \(item)")
                withTransaction(SidebarView.selectionTransaction) { selection = item }
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            }
            log("autoswitch done")
            if let files = ProcessInfo.processInfo.environment["HERMES_BOT_APP_AUTOATTACH"] {
                let urls = files.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                switch selection {
                case .room(let id)?: roomModel(id)?.addAttachments(urls)
                case .bot(let name)?: chats[name]?.addAttachments(urls)
                case .board?, .archive?, nil: break
                }
                log("autoattach → \(urls.count) file(s)")
            }
        }
    }

    func turnEvent(_ type: String, _ chat: ChatModel) {
        guard evidence.evidenceDir != nil || evidence.autoQuit else { return }
        if evidence.evidenceDir != nil {
            let t = Date().timeIntervalSince(started)
            let textCount = chat.streamingText.count
            evidence.uiLog.append(["t": .number(t), "event": .string(type), "ui_bot_text_chars": .number(Double(textCount)),
                      "ui_delta_count": .number(Double(chat.deltaCount))])
            log("ui \(type) → bubble chars=\(textCount) deltas=\(chat.deltaCount)")
        }
        // Snapshot on the next runloop turn, after SwiftUI applied the change.
        if type == "message.delta" && chat.deltaCount == 1 { DispatchQueue.main.async { self.snapshot("2-streaming") } }
        if type == "message.complete" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.snapshot("3-complete")
                if self.evidence.autoQuit { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
            }
        }
    }

    // MARK: scripted Group Chat evidence

    /// `createRoom` succeeded. With `HERMES_BOT_APP_ROOM_MANIFEST=<path>` (scripted test runs) the room is
    /// appended to that JSON-lines manifest so `group-chat-harness cleanup @<path>` can attribute its
    /// member sessions.
    func roomCreated(_ room: RoomSummary) {
        if let path = ProcessInfo.processInfo.environment["HERMES_BOT_APP_ROOM_MANIFEST"], !path.isEmpty {
            do { try RoomManifest.append(RoomManifestEntry(room: room), to: URL(fileURLWithPath: path)) }
            catch { log("room manifest append failed: \(Redaction.describe(error))") }
        }
        evidence.createdRooms.append(room.roomId)
    }

    /// Quit with `HERMES_BOT_APP_DISBAND_ROOMS=1`: disband the rooms this run created or opened.
    func disbandCreatedRooms() async {
        guard ProcessInfo.processInfo.environment["HERMES_BOT_APP_DISBAND_ROOMS"] == "1" else { return }
        for id in evidence.createdRooms {
            if let m = roomModel(id) { log("disband \(id) → \(await m.disband() ? "ok" : "failed")") }
        }
        if !evidence.createdRooms.isEmpty {
            try? await Task.sleep(nanoseconds: 500_000_000)  // let the sidebar drop the rows
            snapshot("r6-after-disband")
            log("sidebar rooms after disband: \(rooms.map(\.roomId)) selection=\(selection.map { "\($0)" } ?? "nil")")
        }
    }

    func autoroom() {
        let env = ProcessInfo.processInfo.environment
        if let open = env["HERMES_BOT_APP_OPEN_ROOM"], rooms.contains(where: { $0.roomId == open }) {
            evidence.autoQuit = env["HERMES_BOT_APP_AUTOQUIT"] == "1"
            evidence.createdRooms.append(open)
            selection = .room(open)
            evidence.autoRoomState.sent = true  // the scripted flow tracks an existing discussion
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); snapshot("r1-room") }
            log("autoroom: opened existing room \(open)")
            return
        }
        guard let spec = env["HERMES_BOT_APP_AUTOROOM"], let bar = spec.firstIndex(of: "|") else { return }
        evidence.autoQuit = env["HERMES_BOT_APP_AUTOQUIT"] == "1"
        let names = spec[..<bar].split(separator: ",").map(String.init)
        let prompt = String(spec[spec.index(after: bar)...])
        let members = names.compactMap { n in bots.first { $0.name == n }.flatMap(RoomMember.forBot) }
        Task {
            // The name embeds the id: a member's first prompt names the room (`[Discussion: "<name>"]`),
            // which is how cleanup attributes sessions that do not carry `Group: <id>` yet.
            let id = AppModel.mintRoomId()
            if let err = await createRoom(name: "hba app \(id)", members: members, roomId: id) {
                log("autoroom: create failed: \(err)"); return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)  // let the room view appear and poll once
            snapshot("r1-room")
            guard case .room(let id)? = selection, let m = roomModel(id) else { return }
            evidence.autoRoomState.sent = m.send(prompt)
            evidence.uiLog.append(["t": .number(Date().timeIntervalSince(started)), "event": "ui.send", "accepted": .bool(evidence.autoRoomState.sent)])
            log("autoroom: send accepted=\(evidence.autoRoomState.sent)")
        }
    }

    func roomSynced(_ m: RoomModel, _ new: [RoomEvent]) {
        guard evidence.evidenceDir != nil || evidence.autoRoomState.sent else { return }
        let t = Date().timeIntervalSince(started)
        let d = m.driver
        evidence.uiLog.append(["t": .number(t), "event": "room.sync", "room_id": .string(m.room.roomId),
                      "cursor": .number(Double(m.timeline.cursor)), "new_kinds": .array(new.map { .string($0.kind) }),
                      "working": d.map { .bool($0.working) } ?? .null,
                      "counts": .object((d?.counts ?? [:]).mapValues { .number(Double($0)) }),
                      "awaiting_discussion": .bool(m.timeline.awaitingDiscussion),
                      "pending_actions": .array((d?.pendingActions ?? []).map { .string($0.id) }),
                      "ui_lines": .number(Double(m.lines.count)), "next_poll_s": .number(m.pollInterval)])
        if !new.isEmpty || d?.working == true {
            log("ui room.sync cursor=\(m.timeline.cursor) new=\(new.map(\.kind)) working=\(d?.working ?? false) counts=\(d?.counts ?? [:]) lines=\(m.lines.count)")
        }
        guard evidence.autoRoomState.sent, !evidence.autoRoomState.done, case .room(let id)? = selection, id == m.room.roomId else { return }
        if d?.working == true && !evidence.autoRoomState.sawWorking {
            evidence.autoRoomState.sawWorking = true
            DispatchQueue.main.async { self.snapshot("r2-working") }
            if let s = ProcessInfo.processInfo.environment["HERMES_BOT_APP_AUTOROOM_STOP_AFTER"].flatMap(Double.init) {
                evidence.autoRoomState.stopAt = Date().addingTimeInterval(s)
            }
        }
        if let at = evidence.autoRoomState.stopAt, !evidence.autoRoomState.stopped, Date() >= at, (d?.counts["running"] ?? 0) > 0 {
            evidence.autoRoomState.stopped = true
            log("autoroom: pressing Stop")
            evidence.uiLog.append(["t": .number(t), "event": "ui.stop"])
            m.stop()
        }
        let env = ProcessInfo.processInfo.environment
        for action in d?.pendingActions ?? [] where !evidence.autoActed.contains(action.id) {
            switch action {
            case .approval(let a):
                guard let choice = env["HERMES_BOT_APP_AUTOROOM_APPROVE"] else { continue }
                evidence.autoActed.insert(action.id)
                log("autoroom: approval pending (\(a.command ?? "?")) → pressing \(choice)")
                // HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER=<s>: leave the card on screen that long first, so
                // the snapshot shows it at rest rather than mid-arrival with the buttons already busy.
                if let after = env["HERMES_BOT_APP_AUTOROOM_APPROVE_AFTER"].flatMap(Double.init), after > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        self.snapshot("r-approval-pending")
                        self.evidence.uiLog.append(["t": .number(Date().timeIntervalSince(self.started)), "event": "ui.approve",
                                           "choice": .string(choice), "request_id": .string(a.requestId)])
                        m.approve(a, choice: choice)
                    }
                    continue
                }
                snapshot("r-approval-pending")
                evidence.uiLog.append(["t": .number(t), "event": "ui.approve", "choice": .string(choice), "request_id": .string(a.requestId)])
                m.approve(a, choice: choice)
            case .retry(let taskId):
                guard env["HERMES_BOT_APP_AUTOROOM_RETRY"] == "1" else { continue }
                evidence.autoActed.insert(action.id)
                log("autoroom: retry pending (\(taskId)) → pressing Retry")
                snapshot("r-retry-pending")
                evidence.uiLog.append(["t": .number(t), "event": "ui.retry", "task_id": .string(taskId)])
                m.retry(taskId)
            case .other: continue
            }
        }
        if new.contains(where: { $0.kind == "message.member" }) && !evidence.autoRoomState.sawReply {
            evidence.autoRoomState.sawReply = true
            DispatchQueue.main.async { self.snapshot("r3-first-reply") }
        }
        if evidence.autoRoomState.stopped && new.contains(where: { $0.kind == "turn.cancelled" }) {
            DispatchQueue.main.async { self.snapshot("r4-stopped") }
        }
        let pendingLeft = !(d?.pendingActions.isEmpty ?? true)
        if !m.active && !pendingLeft && m.timeline.userMessages.count > 0 && (evidence.autoRoomState.sawWorking || evidence.autoRoomState.sawReply) {
            evidence.autoRoomState.done = true
            log("autoroom: settled (working=false, discussion \(m.timeline.userMessages.last.map { "\(m.timeline.phase(of: $0))" } ?? "?"))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.snapshot("r5-settled")
                if self.evidence.autoQuit { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
            }
        }
    }

    /// Window image as composited by the window server (`screencapture -l`), so the sidebar material and
    /// the unified toolbar show as they do on screen; `cacheDisplay` (no material, no toolbar) is the
    /// fallback when the capture fails.
    func snapshot(_ name: String) {
        guard let dir = evidence.evidenceDir, let window = NSApp.windows.first(where: \.isVisible), let view = window.contentView else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        var how = "screencapture"
        var captured = false
        if (try? capture.run()) != nil {
            capture.waitUntilExit()
            captured = capture.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
        }
        if !captured {
            how = "cacheDisplay"
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        log("snapshot → \(url.lastPathComponent) via \(how) (bubble chars=\(chats[selectedBot ?? ""]?.streamingText.count ?? 0))")
    }

    func writeEvidence() {
        guard let dir = evidence.evidenceDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc: JSONValue = ["mode": .string(modeText), "bots": .array(bots.map { .string($0.name) }),
                              "ui_events": .array(evidence.uiLog),
                              "final_bot_text": .string(chats[selectedBot ?? ""]?.streamingText ?? ""),
                              "rooms_created": .array(evidence.createdRooms.map(JSONValue.string))]
        try? doc.compactJSON().write(to: dir.appendingPathComponent("ui-log.json"), atomically: true, encoding: .utf8)
    }
}
#endif
