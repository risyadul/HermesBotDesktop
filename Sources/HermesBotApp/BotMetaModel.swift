import Foundation
import HermesGatewayKit

/// Pin / Hide per bot (A2), as the sidebar shows them. Seeded from `profiles.list` (`Bot.uiMeta`), changed
/// optimistically by the row menu, and saved to the profile's `ui_meta["hermes-bots"]` with Desktop's
/// compare-and-swap write (`BotMetaSync`). A save that did not apply rolls the row back and says why.
@MainActor
final class BotMetaModel: ObservableObject {
    typealias Saver = @Sendable (_ profile: String, _ patch: [String: JSONValue]) async throws -> BotMetaSync.Outcome

    @Published private(set) var meta: [String: BotUIMeta] = [:]
    /// The last failed save, for the sidebar's note line (nil once the next save succeeds).
    @Published private(set) var lastError: String?
    /// Saves in flight per bot: a second toggle waits for the first instead of racing it.
    private var inFlight: Set<String> = []
    private var generation = 0
    var saver: Saver?
    var log: (String) -> Void = { AppModel.shared.log($0) }

    /// The roster of a new connection (replaces everything; in-flight saves of an old one are ignored).
    func load(_ bots: [Bot]) {
        generation += 1
        inFlight = []
        lastError = nil
        meta = Dictionary(bots.map { ($0.name, $0.uiMeta) }, uniquingKeysWith: { a, _ in a })
    }

    func reset() { load([]) }

    /// A re-listed roster of the same connection (after an edit, duplicate or delete): bots with a save in
    /// flight keep their optimistic state, the rest take the server's, removed bots are dropped.
    func refresh(_ bots: [Bot]) {
        var next: [String: BotUIMeta] = [:]
        for bot in bots { next[bot.name] = inFlight.contains(bot.name) ? (meta[bot.name] ?? bot.uiMeta) : bot.uiMeta }
        meta = next
    }

    /// A deleted bot.
    func forget(_ name: String) {
        meta[name] = nil
        inFlight.remove(name)
    }

    subscript(name: String) -> BotUIMeta { meta[name] ?? BotUIMeta() }

    func isSaving(_ name: String) -> Bool { inFlight.contains(name) }

    func setPinned(_ name: String, _ pinned: Bool) { update(name, field: "pinned", value: pinned) { $0.pinned = pinned } }
    func setHidden(_ name: String, _ hidden: Bool) { update(name, field: "hidden", value: hidden) { $0.hidden = hidden } }

    private func update(_ name: String, field: String, value: Bool, _ change: (inout BotUIMeta) -> Void) {
        guard let saver, meta[name] != nil, !inFlight.contains(name) else { return }
        let before = self[name]
        var after = before
        change(&after)
        guard after != before else { return }
        meta[name] = after
        inFlight.insert(name)
        let gen = generation
        Task {
            let outcome: Result<BotMetaSync.Outcome, Error>
            do { outcome = .success(try await saver(name, [field: .bool(value)])) } catch { outcome = .failure(error) }
            guard gen == self.generation else { return }
            self.inFlight.remove(name)
            self.finish(name, field: field, before: before, outcome)
        }
    }

    private func finish(_ name: String, field: String, before: BotUIMeta, _ outcome: Result<BotMetaSync.Outcome, Error>) {
        let why: String
        switch outcome {
        case .success(.persisted(let saved)):
            meta[name] = saved
            lastError = nil
            log("profiles.configure ui_meta[\(BotMetaSync.namespace)].\(field) → saved for \(name)")
            return
        case .success(.failed): why = "Hermes did not save the change (another app may have changed this bot; try again)."
        case .success(.unsupported): why = "This Hermes Agent cannot store bot settings; update Hermes to pin or hide bots."
        case .success(.notFound): why = "Hermes no longer lists this bot."
        case .failure(let error): why = Redaction.describe(error)
        }
        meta[name] = before
        lastError = why
        log("profiles.configure ui_meta[\(BotMetaSync.namespace)].\(field) for \(name) not saved: \(why)")
    }

    /// The live saver for a gateway connection.
    static func saver(_ client: GatewayClient) -> Saver {
        { name, patch in
            try await BotMetaSync.save(name: name, patch: patch) { method, params in try await client.call(method, params) }
        }
    }
}
