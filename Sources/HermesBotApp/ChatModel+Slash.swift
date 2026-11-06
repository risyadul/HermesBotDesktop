import Foundation
import HermesGatewayKit

/// Slash commands typed in the composer (`SlashInvocation.classify`, Desktop `DESKTOP_COMMAND_SPECS`).
/// Backend commands run through `slash.exec` / `command.dispatch` (`runSlash`), also mid-turn; the directive decides
/// what shows: output → system line, send / skill → a turn showing the display text, prefill → composer.
extension ChatModel {
    /// Handles a classified slash command. Returns true when the draft was taken (and cleared).
    func runSlash(_ inv: SlashInvocation) -> Bool {
        guard let s = session else { return false }
        switch inv {
        case .stop:
            draft = ""
            if busy || !requests.isEmpty { stop() } else { transcript.appendSystem("Nothing is running.") }
            return true
        case .help:
            draft = ""
            Task {
                let catalog = await self.ensureCatalog()
                self.transcript.appendSystem(Self.helpText(catalog))
            }
            return true
        case .unavailable(let message):
            draft = ""
            transcript.appendSystem(message)
            return true
        case .compress(let focus, let rewrittenFrom):
            guard !busy, activity == nil else { return false }
            draft = ""
            if rewrittenFrom != nil { transcript.appendSystem(SlashInvocation.neverResetsNotice) }
            activity = "Compacting the conversation"
            Task {
                defer { self.activity = nil }
                do {
                    let outcome = try await s.compress(focus: focus)
                    // The backend's compacted transcript replaces the shown one when it sends it (idle only).
                    if let history = outcome.history { self.transcript.seed(history: history) }
                    self.transcript.appendSystem(Self.compressText(outcome))
                } catch {
                    self.transcript.appendSystem("Compacting failed: \(Self.message(error, bot: self.bot))")
                }
            }
            return true
        case .exec(let name, let arg):
            // Allowed mid-turn: the backend refuses what a running turn forbids (`methods_slash.py`
            // `_MUTATES_WHILE_RUNNING`, "session busy" texts) and its answer shows as a system line.
            guard activity == nil else { return false }
            let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = ""
            activity = "Running /\(name)"
            Task {
                defer { self.activity = nil }
                do {
                    let catalog = await self.ensureCatalog()
                    // Built-ins Desktop hides (terminal-only, messaging, settings…) are refused when typed too;
                    // without a catalog, Desktop's offline registry copy decides (never fail open).
                    let refusal = catalog.map { $0.unavailableMessage(name) } ?? SlashCatalog.offlineUnavailableMessage(name)
                    if let refusal { return self.transcript.appendSystem(refusal) }
                    let d = try await s.runSlash(name: name, arg: arg, catalog: catalog)
                    self.render(d, typed: typed)
                } catch {
                    self.transcript.appendSystem("/\(name) failed: \(Self.message(error, bot: self.bot))")
                }
            }
            return true
        }
    }

    /// Shows a directive. Alias hops are already resolved by `runSlash`; one surfacing here looped.
    func render(_ d: SlashDirective, typed: String) {
        switch d {
        case .output(let text):
            transcript.appendSystem(text)
        case .send(let message, let display, let notice):
            if let notice { transcript.appendSystem(notice) }
            sendDirect(message, display: display ?? typed)
        case .skill(let name, let message, let display):
            sendDirect(message, display: display ?? "/\(name)")
        case .prefill(let message, let notice):
            if let notice { transcript.appendSystem(notice) }
            draft = message
        case .alias(let target):
            transcript.appendSystem("/\(target) is an alias that did not resolve.")
        }
    }

    /// Fetches `commands.catalog` once per chat; concurrent callers share the request. A failed fetch is
    /// retried on the next call.
    func ensureCatalog() async -> SlashCatalog? {
        if let catalog { return catalog }
        if let task = catalogTask { return await task.value }
        guard let s = session else { return nil }
        let bot = bot
        let task = Task<SlashCatalog?, Never> {
            do { return try await s.slashCatalog() } catch {
                self.log("commands.catalog failed for \(bot.name): \(Redaction.describe(error))")
                return nil
            }
        }
        catalogTask = task
        let result = await task.value
        catalogTask = nil
        if let result { catalog = result }
        return result
    }

    func loadCatalog() {
        Task { _ = await self.ensureCatalog() }
    }

    static func helpText(_ catalog: SlashCatalog?) -> String {
        guard let catalog, !catalog.commands.isEmpty else {
            return "Commands could not be loaded. /stop and /compress always work here."
        }
        let rows = catalog.commands.map { c in c.description.isEmpty ? c.name : "\(c.name) — \(c.description)" }
        return (["Commands:"] + rows).joined(separator: "\n")
    }

    static func compressText(_ o: CompressOutcome) -> String {
        if let m = o.message, !m.isEmpty { return m }
        guard o.compressed else { return "Nothing to compact yet." }
        if let before = o.beforeMessages, let after = o.afterMessages {
            return "Conversation compacted: \(before) → \(after) messages."
        }
        return "Conversation compacted."
    }
}
