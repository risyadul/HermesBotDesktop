import Foundation
import HermesGatewayKit

/// B11 (URL, folder and long-paste attachments) and B14 (approval mode) on the chat model.
extension ChatModel {
    // MARK: B11 context refs and long paste

    /// Attach URL: a web page as an `@url:` chip (Desktop's URL dialog). False for anything that is not an
    /// `http(s)://` URL with a host; a URL already attached is not added twice.
    @discardableResult
    func addURL(_ raw: String) -> Bool {
        guard phase == .ready, let ref = ContextRef.url(raw) else { return false }
        addRef(ref)
        return true
    }

    /// Attach Folder: each folder as an `@folder:` chip (nothing is uploaded; the bot reads it from disk).
    func addFolders(_ urls: [URL]) {
        guard phase == .ready else { return }
        for url in urls {
            if let ref = ContextRef.folder(url) { addRef(ref) }
        }
    }

    private func addRef(_ ref: ContextRef) {
        guard !pending.contains(where: { $0.contextRef == ref }) else { return }
        pending.append(PendingAttachment(ref: ref))
    }

    /// Dropped or pasted file URLs: folders become `@folder:` chips (as Desktop's drop does), files the usual
    /// checked file chips.
    func addDropped(_ urls: [URL]) {
        let folders = urls.filter { Self.isDirectory($0) }
        addFolders(folders)
        addAttachments(urls.filter { !folders.contains($0) })
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// A paste over `LargePaste.threshold` characters (Desktop: 3 000) becomes a `.txt` attachment in the
    /// app's paste folder (0700, deleted once its turn settled, with its chip, or at quit) instead of landing
    /// in the composer. Returns true when the text was taken as an attachment.
    @discardableResult
    func attachLongPaste(_ text: String) -> Bool {
        guard phase == .ready, LargePaste.shouldAttach(text),
              let url = Self.writePaste(text, in: pasteFolder) else { return false }
        addAttachments([url])
        return true
    }

    nonisolated static func writePaste(_ text: String, in folder: URL) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let url = folder.appendingPathComponent(LargePaste.fileName())
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            return url
        } catch { return nil }
    }

    // MARK: B14 approval mode

    func loadApprovalMode() {
        guard let s = session else { return }
        Task {
            do {
                let mode = try await s.approvalMode()
                self.approvalMode = mode
            } catch {
                self.log("config.get approvals.mode failed: \(Self.message(error, bot: self.bot))")
            }
        }
    }

    /// Picks the bot's approval mode (`config.set approvals.mode`, scoped to this bot's profile, as Desktop's
    /// status bar menu). Painted at once; the previous mode comes back if the backend refuses.
    func selectApprovalMode(_ mode: ApprovalMode) {
        guard canChangeControls, let s = session, mode != approvalMode else { return }
        let previous = approvalMode
        approvalMode = mode
        Task {
            do {
                let applied = try await s.setApprovalMode(mode)
                self.log("config.set approvals.mode → \(applied.rawValue)")
                if self.approvalMode == mode { self.approvalMode = applied }
            } catch {
                if self.approvalMode == mode { self.approvalMode = previous }
                self.transcript.appendSystem("Couldn't change the approval mode: \(Self.message(error, bot: self.bot))")
            }
        }
    }
}
