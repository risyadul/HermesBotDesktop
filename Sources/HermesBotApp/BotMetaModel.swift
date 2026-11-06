import Foundation
import HermesGatewayKit

/// Pin / Hide (A2) and section membership (A5) per bot, as the sidebar shows them. Seeded from `profiles.list` (`Bot.uiMeta`), changed
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

    func setPinned(_ name: String, _ pinned: Bool) { update(name, patch: ["pinned": .bool(pinned)]) { $0.pinned = pinned } }
    func setHidden(_ name: String, _ hidden: Bool) { update(name, patch: ["hidden": .bool(hidden)]) { $0.hidden = hidden } }

    /// Files the bot in a user section (A5), or back to Unassigned with nil. The section's name rides along
    /// (`sectionId` + `sectionName`, explicit nulls to clear), exactly as Desktop's `moveBotsToSection` writes
    /// it. Returns the save, or nil when nothing was sent (no change, unknown bot, a save in flight).
    @discardableResult
    func setSection(_ name: String, id: String?, sectionName: String?) -> Task<Void, Never>? {
        let patch: [String: JSONValue] = ["sectionId": id.map(JSONValue.string) ?? .null,
                                          "sectionName": (id == nil ? nil : sectionName).map(JSONValue.string) ?? .null]
        return update(name, patch: patch) {
            $0.sectionId = id
            $0.sectionName = id == nil ? nil : sectionName
        }
    }

    @discardableResult
    private func update(_ name: String, patch: [String: JSONValue], _ change: (inout BotUIMeta) -> Void) -> Task<Void, Never>? {
        guard let saver, meta[name] != nil, !inFlight.contains(name) else { return nil }
        let before = self[name]
        var after = before
        change(&after)
        guard after != before else { return nil }
        meta[name] = after
        inFlight.insert(name)
        let gen = generation
        let field = patch.keys.sorted().joined(separator: "+")
        return Task {
            let outcome: Result<BotMetaSync.Outcome, Error>
            do { outcome = .success(try await saver(name, patch)) } catch { outcome = .failure(error) }
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
        case .success(.unsupported): why = "This Hermes Agent cannot store bot settings; update Hermes to pin, hide or file bots."
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
