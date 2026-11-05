import Foundation
import HermesGatewayKit

// MARK: - attachments

extension ChatModel {
    /// Adds files (paperclip, drop, paste) as LOCAL chips: only the client-side checks run now, and a refused
    /// file shows its error on its chip. Nothing reaches the session until Send (`submit`). A file already
    /// pending is skipped; re-adding a refused one replaces its chip.
    func addAttachments(_ urls: [URL]) {
        guard phase == .ready else { return }
        for url in urls where url.isFileURL {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard !pending.contains(where: { $0.key == key && !$0.isFailed }) else { continue }
            pending.removeAll { $0.key == key && $0.isFailed }
            let chip = PendingAttachment(url: url, key: key, check: checkFile)
            if let why = chip.error { log("attach refused: \(chip.name): \(why)") }
            pending.append(chip)
        }
    }

    /// Removes a chip (not while its send is staging it). Nothing to undo on the session: chips are local.
    /// A pasted image file is deleted with its chip.
    func removeAttachment(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }), !pending[i].isSending else { return }
        let chip = pending.remove(at: i)
        PasteboardAttachments.delete([chip.url], folder: pasteFolder)
    }
}

// MARK: - server requests

extension ChatModel {
    /// A request for this chat (live, or re-shown from `open_requests`). Duplicates are ignored.
    func receive(_ r: ServerRequest) {
        guard !requests.contains(where: { $0.id == r.id }) else { return }
        requests.append(r)
    }

    func dropRequests(where match: (ServerRequest) -> Bool) {
        let gone = requests.filter(match).map(\.id)
        guard !gone.isEmpty else { return }
        requests.removeAll { gone.contains($0.id) }
        for id in gone { requestErrors[id] = nil; answering.remove(id) }
    }

    /// The card is on screen: an approval starts its backend timeout clock (`approval.received`), once.
    func cardShown(_ r: ServerRequest) {
        guard case .approval(let a) = r.kind, let queueId = a.requestId, let s = session,
              acknowledged.insert(r.id).inserted else { return }
        Task {
            do { try await s.approvalReceived(requestId: queueId) } catch {
                self.log("approval.received failed: \(Redaction.describe(error))")
            }
        }
    }

    /// Answers a card. It stays (buttons disabled) until the answer is on the wire; a failed answer keeps
    /// the card with the error so the user can try again.
    func respond(_ r: ServerRequest, _ answer: ServerRequestAnswer) {
        guard let s = session, !answering.contains(r.id) else { return }
        answering.insert(r.id)
        requestErrors[r.id] = nil
        Task {
            do {
                try await s.answer(r, answer)
                self.dropRequests { $0.id == r.id }
            } catch {
                self.answering.remove(r.id)
                self.requestErrors[r.id] = Self.message(error, bot: self.bot)
            }
        }
    }
}
