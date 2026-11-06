import CoreGraphics
import Foundation

/// User attachments for the 1:1 Bot Chat (`.omc/research/wire-parity.md` §5). All attach RPCs take the
/// RUNTIME session id and must run before `prompt.submit` on the same session (`server.py:1253-1260`):
/// - images: `image.attach {session_id, path}` — queued, consumed by the next turn (`methods_prompt.py:913-938`).
/// - PDF: `pdf.attach {session_id, path}` — pages rendered to images (`methods_prompt.py:972-1027, 1288-1328`).
/// - other files: `file.attach {session_id, path, name}` → `ref_text` ("@file:…") that the CLIENT must put
///   in the prompt (`methods_prompt.py:1030-1050`); files are not queued.
/// Group Chat cannot carry attachments (`groups.send` payload is exactly `{text, thread_id}`).
public enum ChatAttachments {
    public enum Kind: String, Sendable, Equatable { case image, pdf, file }

    /// Extensions `image.attach` accepts (`hermes_cli/cli_terminal_input.py:33-36`).
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico"]
    /// `_ATTACH_BYTES_MAX_BYTES` (`prompt_attachments.py:16-61`).
    public static let maxImageBytes = 25 * 1024 * 1024
    /// `_PDF_ATTACH_MAX_BYTES` / `_PDF_ATTACH_MAX_PAGES` (`methods_prompt.py:1288-1328`).
    public static let maxPDFBytes = 50 * 1024 * 1024
    public static let maxPDFPages = 25
    /// Desktop's caption when only images are sent (`use-prompt-actions/submit.ts:218-234`).
    public static let imageOnlyCaption = "What do you see in this image?"

    public enum Failure: Error, RedactionSafeError, Equatable {
        case notFound(String)
        case notRegularFile(String)
        case tooLarge(String, limitMB: Int)
        case tooManyPages(String, pages: Int, limit: Int)
        case unreadablePDF(String)
        case rejected(String)

        public var description: String {
            switch self {
            case .notFound(let n): return "\(n) was not found."
            case .notRegularFile(let n): return "\(n) is not a regular file."
            case .tooLarge(let n, let mb): return "\(n) is too large; the limit is \(mb) MB."
            case .tooManyPages(let n, let p, let l): return "\(n) has \(p) pages; at most \(l) pages can be attached at once."
            case .unreadablePDF(let n): return "\(n) is not a readable PDF."
            case .rejected(let m): return m
            }
        }
    }

    /// A file checked on the client: symlinks resolved, regular file, within the size/page caps.
    public struct Checked: Sendable, Equatable {
        public let url: URL
        public let name: String
        public let kind: Kind
        public let bytes: Int
        /// Page count of a PDF; nil otherwise.
        public var pages: Int? = nil
    }

    /// A staged attachment failed while sending (`BotChatSession.submit(_:files:)`): `index` is the file
    /// in the submitted list; everything staged before it was taken back off the session.
    public struct StageFailure: Error, RedactionSafeError, Equatable {
        public let index: Int
        public let message: String
        public var description: String { message }
    }

    /// `pdftoppm` missing or failed on the backend host (`methods_prompt.py:1288-1328`): send the PDF as a
    /// file reference instead (research §5).
    static let pdfRenderFailedCode = 5028

    public static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        return ext == "pdf" ? .pdf : .file
    }

    /// Client-side checks before any RPC. The backend only checks existence + extension (no path policy,
    /// `.omc/research/wire-parity.md` §5), so the caps are enforced here with clear messages.
    public static func check(_ url: URL, fileManager: FileManager = .default) throws -> Checked {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard let attrs = try? fileManager.attributesOfItem(atPath: resolved.path) else { throw Failure.notFound(name) }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw Failure.notRegularFile(name) }
        let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let kind = kind(of: resolved)
        var pages: Int?
        switch kind {
        case .image where bytes > maxImageBytes: throw Failure.tooLarge(name, limitMB: maxImageBytes >> 20)
        case .pdf:
            if bytes > maxPDFBytes { throw Failure.tooLarge(name, limitMB: maxPDFBytes >> 20) }
            guard let doc = CGPDFDocument(resolved as CFURL) else { throw Failure.unreadablePDF(name) }
            if doc.numberOfPages > maxPDFPages { throw Failure.tooManyPages(name, pages: doc.numberOfPages, limit: maxPDFPages) }
            pages = doc.numberOfPages
        default: break
        }
        return Checked(url: resolved, name: name, kind: kind, bytes: bytes, pages: pages)
    }

    /// The text sent with attachments: every `ref_text` on its own line first, a blank line, then the user
    /// text (Desktop `[refs.join("\n"), text].filter(Boolean).join("\n\n")`). With no text and no refs,
    /// images get `imageOnlyCaption`; otherwise "".
    public static func promptText(refTexts: [String], userText: String, hasImages: Bool) -> String {
        let refs = refTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = [refs.joined(separator: "\n"), text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty && hasImages ? imageOnlyCaption : joined
    }
}

/// One attachment staged on the session (until the next `prompt.submit` consumes it).
public struct ChatAttachment: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let kind: ChatAttachments.Kind
    public let name: String
    /// The path as the backend returned it (what `image.detach` takes).
    public let path: String
    /// `@file:…` for files; nil for images and PDFs (queued on the session).
    public let refText: String?
    /// PDF pages turned into images.
    public let pages: Int?
    /// The queued page images of a PDF (`pages[].path` of `pdf.attach`): what `image.detach` takes back.
    public var pagePaths: [String] = []

    /// Every image this attachment queued on the session: the image itself, or a PDF's rendered pages.
    public var stagedImagePaths: [String] {
        switch kind {
        case .image: return [path]
        case .pdf: return pagePaths
        case .file: return []
        }
    }
}

/// Attachments are staged only when a message is SENT (Desktop `use-prompt-actions/submit.ts`): the Bot
/// Chat is shared with Hermes Desktop, so anything queued earlier could ride along with someone else's turn.
extension BotChatSession {
    /// Checks `url` (`ChatAttachments.check`) and stages it with the matching attach RPC.
    public func attach(_ url: URL, fileManager: FileManager = .default) async throws -> ChatAttachment {
        try await stage(try ChatAttachments.check(url, fileManager: fileManager))
    }

    /// Stages one checked file. Backend errors (4015/4016/4017/4018/4019) surface as `RPCError` with the
    /// backend's message; a PDF the backend cannot render (5028) is sent as a file reference instead.
    func stage(_ c: ChatAttachments.Checked) async throws -> ChatAttachment {
        let sid = JSONValue.string(sessionId), path = JSONValue.string(c.url.path)
        switch c.kind {
        case .image:
            let r = try await backend.client.call("image.attach", ["session_id": sid, "path": path])
            try Self.requireAttached(r, c.name)
            return ChatAttachment(kind: .image, name: r["name"]?.string ?? c.name,
                                  path: r["path"]?.string ?? c.url.path, refText: nil, pages: nil)
        case .pdf:
            let r: JSONValue
            do { r = try await backend.client.call("pdf.attach", ["session_id": sid, "path": path]) }
            catch let e as GatewayClient.RPCError where e.code == ChatAttachments.pdfRenderFailedCode {
                return try await stageFile(c)
            }
            try Self.requireAttached(r, c.name)
            let pagePaths = (r["pages"]?.array ?? []).compactMap { $0["path"]?.string }
            return ChatAttachment(kind: .pdf, name: r["filename"]?.string ?? c.name, path: c.url.path, refText: nil,
                                  pages: r["pages_attached"]?.int ?? r["pages"]?.array?.count, pagePaths: pagePaths)
        case .file:
            return try await stageFile(c)
        }
    }

    private func stageFile(_ c: ChatAttachments.Checked) async throws -> ChatAttachment {
        let r = try await backend.client.call("file.attach", ["session_id": .string(sessionId), "path": .string(c.url.path),
                                                              "name": .string(c.name)])
        try Self.requireAttached(r, c.name)
        guard let ref = r["ref_text"]?.string, !ref.isEmpty else {
            throw GatewayClient.ClientError.badFrame("file.attach: no ref_text")
        }
        return ChatAttachment(kind: .file, name: r["name"]?.string ?? c.name,
                              path: r["path"]?.string ?? c.url.path, refText: ref, pages: nil)
    }

    /// Takes every image `attachment` queued back off the session (`image.detach {session_id, path}` per
    /// image or PDF page) → the remaining queue size. Files need no call (they only live in the prompt text).
    @discardableResult
    public func detachStaged(_ attachment: ChatAttachment) async throws -> Int {
        var remaining = 0
        for p in attachment.stagedImagePaths {
            let r = try await backend.client.call("image.detach", ["session_id": .string(sessionId), "path": .string(p)])
            remaining = r["count"]?.int ?? 0
        }
        return remaining
    }

    /// Stages `files` in order, then `prompt.submit` (ref lines first, then the text,
    /// `ChatAttachments.promptText`), all in this one task. If a file fails, or the submit itself fails,
    /// everything staged here is detached again before the error is rethrown (a file failure as
    /// `ChatAttachments.StageFailure` naming its index), so nothing stays queued for a later turn.
    ///
    /// Race (inherent, Hermes Desktop has the same one): the image queue is per SESSION, not per client. If
    /// another client (Hermes Desktop) submits on the shared Bot Chat between our attaches and our
    /// `prompt.submit`, its turn consumes our images. Nothing on the wire can prevent that; the window is
    /// the few attach round-trips of one send.
    ///
    /// Every staged image path is recorded in `StrandedImages` until the submit settles: if the socket drops
    /// in between, the detach below cannot reach the backend and the images would stay queued on the shared
    /// session (`close_on_disconnect: false` keeps the runtime alive). The next `openCanonical` of this bot
    /// takes them back off (`detachStranded`).
    @discardableResult
    public func submit(_ userText: String, files: [ChatAttachments.Checked]) async throws -> JSONValue {
        var staged: [ChatAttachment] = []
        let key = bot.name
        defer { StrandedImages.shared.settle(key, staged.flatMap(\.stagedImagePaths)) }
        for (i, c) in files.enumerated() {
            do {
                let a = try await stage(c)
                staged.append(a)
                StrandedImages.shared.record(key, a.stagedImagePaths)
            } catch {
                await unstageAll(staged)
                let why = (error as? GatewayClient.RPCError).map { Redaction.scrub($0.message) } ?? Redaction.describe(error)
                throw ChatAttachments.StageFailure(index: i, message: why)
            }
        }
        do { return try await send(userText, attachments: staged) } catch {
            await unstageAll(staged)
            throw error
        }
    }

    /// Best effort: a detach that fails (the socket is gone) leaves its paths in `StrandedImages`.
    private func unstageAll(_ staged: [ChatAttachment]) async {
        for a in staged {
            if (try? await detachStaged(a)) == nil { StrandedImages.shared.strand(bot.name, a.stagedImagePaths) }
        }
    }

    /// Takes back images an earlier submit of this bot staged but could not submit or detach (socket drop).
    /// Best effort; a path the backend no longer queues answers `detached: false`, which is fine.
    func detachStranded() async {
        let paths = StrandedImages.shared.take(bot.name)
        guard !paths.isEmpty else { return }
        for p in paths {
            do { _ = try await backend.client.call("image.detach", ["session_id": .string(sessionId), "path": .string(p)]) }
            catch is GatewayClient.ClientError { StrandedImages.shared.strand(bot.name, [p]) }  // gone again: keep for later
            catch {}
        }
    }

    /// Sends `userText` with staged attachments: ref lines first, then the text (`ChatAttachments.promptText`).
    @discardableResult
    public func send(_ userText: String, attachments: [ChatAttachment]) async throws -> JSONValue {
        let text = ChatAttachments.promptText(refTexts: attachments.compactMap(\.refText), userText: userText,
                                              hasImages: attachments.contains { $0.kind != .file })
        return try await send(text)
    }

    private static func requireAttached(_ r: JSONValue, _ name: String) throws {
        if r["attached"]?.bool == false {
            throw ChatAttachments.Failure.rejected(r["message"]?.string ?? "\(name) could not be attached.")
        }
    }
}

/// Image paths a submit staged on a bot's shared Bot Chat and could not take back (see `submit`). Keyed by
/// profile name; process-wide because a reconnect makes a new `Backend` and a new session object.
/// `record` marks paths in flight, `settle` ends the flight (the submit returned or was unstaged), `strand`
/// keeps paths whose detach failed until `take` hands them to the next open.
final class StrandedImages: @unchecked Sendable {
    static let shared = StrandedImages()
    private let lock = NSLock()
    private var inFlight: [String: Set<String>] = [:]
    private var stranded: [String: Set<String>] = [:]

    func record(_ bot: String, _ paths: [String]) { lock.withLock { inFlight[bot, default: []].formUnion(paths) } }

    func strand(_ bot: String, _ paths: [String]) { lock.withLock { stranded[bot, default: []].formUnion(paths) } }

    func settle(_ bot: String, _ paths: [String]) { lock.withLock { inFlight[bot]?.subtract(paths) } }

    /// Stranded paths plus any still marked in flight from a submit that never returned.
    func take(_ bot: String) -> [String] {
        lock.withLock {
            let all = (stranded.removeValue(forKey: bot) ?? []).union(inFlight[bot] ?? [])
            return all.sorted()
        }
    }
}
