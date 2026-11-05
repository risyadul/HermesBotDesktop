import Foundation

/// One offered `/command` from `commands.catalog` (`contracts/tools_commands.py:188-229`).
public struct SlashCommand: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// With the leading slash, e.g. `/goal`.
    public let name: String
    public let description: String
    public let category: String?
    /// `options | text | mixed`, nil when the registry does not say.
    public let argumentMode: String?
}

/// The `commands.catalog` result, curated like Desktop (`apps/desktop/src/AGENTS.md:36-63`): built-ins
/// whose `commands[name].desktop` disposition is non-null (terminal-only, messaging-only, settings,
/// advanced, hidden, composer-voice) are hidden; skills, quick and plugin commands are always kept.
public struct SlashCatalog: Sendable, Equatable {
    public let commands: [SlashCommand]
    /// `/alias` (lowercased) → `/canonical`.
    public let canon: [String: String]
    /// `/cmd` → subcommands that the desktop surface may run (`desktop_subcommands`).
    public let desktopSubcommands: [String: [String]]
    /// `/cmd` → its non-null `desktop` disposition (`terminal`, `messaging`, `settings`, `advanced`, …):
    /// hidden from the menu AND refused when typed (`unavailableMessage`).
    public let dispositions: [String: String]
    public let warning: String?

    public init(result r: JSONValue) {
        let meta = r["commands"]?.object ?? [:]
        func hidden(_ name: String) -> Bool {
            guard let d = meta[name]?["desktop"]?.string else { return false }
            return !d.isEmpty
        }
        var seen = Set<String>()
        var out: [SlashCommand] = []
        func add(_ pair: JSONValue, category: String?) {
            guard let name = pair[0]?.string, name.hasPrefix("/"), !seen.contains(name), !hidden(name) else { return }
            seen.insert(name)
            out.append(SlashCommand(name: name, description: pair[1]?.string ?? "", category: category,
                                    argumentMode: meta[name]?["argument_mode"]?.string))
        }
        for c in r["categories"]?.array ?? [] {
            for p in c["pairs"]?.array ?? [] { add(p, category: c["name"]?.string) }
        }
        for p in r["pairs"]?.array ?? [] { add(p, category: nil) }
        commands = out
        canon = (r["canon"]?.object ?? [:]).compactMapValues(\.string)
        desktopSubcommands = meta.compactMapValues { m in m["desktop_subcommands"]?.array?.compactMap(\.string) }
        dispositions = meta.compactMapValues { m in m["desktop"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        warning = r["warning"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Desktop `desktopSlashUnavailableMessage` (`desktop-slash-commands.ts:505-512, 775-790`) for a typed
    /// command whose `desktop` disposition hides it (aliases resolved through `canon`); nil = runnable.
    /// `hidden` only keeps a command out of the menu (Desktop `specFromCatalog`): it still runs.
    public func unavailableMessage(_ name: String) -> String? {
        let typed = "/" + name.lowercased().drop { $0 == "/" }
        let command = canon[typed] ?? typed
        return Self.message(command, reason: dispositions[command] ?? dispositions[typed])
    }

    /// The same refusal when `commands.catalog` could not be loaded: Desktop's offline copy of the registry
    /// dispositions (`desktop-slash-registry.json`, read by `registryDerivedSpecs`) decides instead, so a
    /// hidden built-in never fails open.
    public static func offlineUnavailableMessage(_ name: String) -> String? {
        let command = "/" + name.lowercased().drop { $0 == "/" }
        return message(command, reason: builtinDispositions[command])
    }

    static func message(_ command: String, reason: String?) -> String? {
        switch reason {
        case nil, "", "hidden": return nil
        case "terminal": return "\(command) is only available in the terminal interface."
        case "messaging": return "\(command) is only used from messaging platforms."
        case "settings": return "\(command) is managed from the Hermes Desktop sidebar."
        case "composer-voice": return "Voice chat lives in the Hermes Desktop composer, not in a slash command."
        default:
            return "\(command) is not shown in the slash palette here. Use the relevant Hermes Desktop control or "
                + "terminal interface instead."
        }
    }

    /// Non-null, non-`hidden` dispositions of Desktop's `desktop-slash-registry.json` (built-ins only;
    /// `/clear` is rewritten to compaction before this is consulted).
    static let builtinDispositions: [String: String] = {
        var d: [String: String] = [:]
        let groups: [String: [String]] = [
            "messaging": ["/approve", "/deny"],
            "terminal": ["/busy", "/clear", "/config", "/copy", "/cron", "/exit", "/footer", "/gateway", "/history",
                         "/image", "/indicator", "/paste", "/platforms", "/plugins", "/quit", "/redraw", "/reload",
                         "/restart", "/sb", "/set-home", "/sethome", "/snap", "/snapshot", "/statusbar", "/toolsets",
                         "/update", "/verbose"],
            "advanced": ["/curator", "/fast", "/insights", "/kanban", "/reload-mcp", "/reload-skills", "/reload_mcp",
                         "/reload_skills"],
            "settings": ["/login"],
            "composer-voice": ["/voice"],
        ]
        for (reason, names) in groups { for n in names { d[n] = reason } }
        return d
    }()

    /// Desktop `desktopSubcommandUnavailableMessage` (`desktop-slash-commands.ts:563-587`): nil = allowed.
    static func subcommandRefusal(_ command: String, arg: String, allowed: [String]) -> String? {
        if allowed.isEmpty { return "\(command) is not available here." }
        let first = arg.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        if first.isEmpty { return "\(command) needs a subcommand here: \(allowed.joined(separator: ", "))." }
        if !allowed.contains(where: { $0.lowercased() == first }) {
            return "\(command) \(first) is not available here. Available here: \(allowed.joined(separator: ", "))."
        }
        return nil
    }

    /// Commands for the composer popover: `query` is what follows "/" (case-insensitive). Prefix matches
    /// first (catalog order), then other substring matches. An empty query lists everything.
    public func filter(_ query: String) -> [SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased().drop { $0 == "/" }
        guard !q.isEmpty else { return commands }
        let key: (SlashCommand) -> String = { String($0.name.lowercased().dropFirst()) }
        let prefix = commands.filter { key($0).hasPrefix(q) }
        let rest = commands.filter { !key($0).hasPrefix(q) && key($0).contains(q) }
        return prefix + rest
    }
}

/// What the backend answered for a slash command (`slash.exec` / `command.dispatch`, shared parser
/// `apps/shared/src/slash.ts` `parseCommandDispatch`, handling `use-prompt-actions/slash.ts:312-415`).
public enum SlashDirective: Sendable, Equatable {
    /// Render as a system line (`exec` / `plugin` / plain `slash.exec` output).
    case output(String)
    /// Re-run `/<target> <arg>` (resolved by `runSlash`; only surfaces past the hop limit).
    case alias(target: String)
    /// Show `notice` (if any), then `prompt.submit` `message`, showing `display` (never `message`).
    case send(message: String, display: String?, notice: String?)
    /// Like `send`: `message` is the expanded skill body, model-facing only.
    case skill(name: String, message: String, display: String?)
    /// Show `notice` (if any) and put `message` in the composer (e.g. `/undo`).
    case prefill(message: String, notice: String?)

    /// Decodes a dispatch directive (`type` set) or nil.
    static func directive(_ r: JSONValue) -> SlashDirective? {
        let str: (String) -> String? = { r[$0]?.string }
        switch r["type"]?.string {
        case "alias": return str("target").map { .alias(target: $0) }
        case "exec", "plugin": return .output(str("output") ?? "")
        case "prefill": return str("message").map { .prefill(message: $0, notice: str("notice")) }
        case "send": return str("message").map { .send(message: $0, display: str("display"), notice: str("notice")) }
        case "skill": return str("name").map { .skill(name: $0, message: str("message") ?? "", display: str("display")) }
        default: return nil
        }
    }

    /// `slash.exec` result: a directive, else plain `{output, warning?}` (`contracts/tools_commands.py:289-305`).
    static func execResult(_ r: JSONValue, name: String) -> SlashDirective {
        if let d = directive(r) { return d }
        let body = r["output"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "/\(name): no output"
        if let w = r["warning"]?.string, !w.isEmpty { return .output("warning: \(w)\n\(body)") }
        return .output(body)
    }
}

/// How the client handles typed `/text` before anything is sent (Desktop `DESKTOP_COMMAND_SPECS`,
/// `src/lib/desktop-slash-commands.ts:185-330`; Bot Chat guard `plugins/hermes-bots/plugin.tsx:771-799`).
public enum SlashInvocation: Sendable, Equatable {
    /// Backend command: `runSlash(name:arg:)`.
    case exec(name: String, arg: String)
    /// `session.compress` (`/compress`, `/compact`). `rewrittenFrom` is set when `/new`-family was
    /// rewritten because the canonical Bot Chat never resets.
    case compress(focus: String, rewrittenFrom: String?)
    /// `session.interrupt`.
    case stop
    /// Show the catalog.
    case help
    /// Not offered here; show the text as a system line.
    case unavailable(String)

    /// Desktop-owned action / picker / Ink-only commands this app does not implement.
    static let clientOnly: Set<String> = [
        "branch", "fork", "yolo", "reasoning", "wake", "handoff", "profile", "skin", "browser", "journey",
        "btw", "bg", "background", "pet", "hatch", "generate-pet", "model", "resume", "sessions", "switch",
        "save", "status", "learning", "memory-graph", "density", "details", "logs", "mouse", "pets",
    ]

    /// nil when `text` is not a slash command. `canonical`: the chat is the bot's forever "Bot Chat".
    public static func classify(_ text: String, canonical: Bool) -> SlashInvocation? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), t.count > 1, !t.hasPrefix("//") else { return nil }
        let body = t.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        let arg = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        switch name {
        case "new", "reset", "clear":
            return canonical ? .compress(focus: "", rewrittenFrom: "/\(name)")
                : .unavailable("/\(name) is not available here.")
        case "compress", "compact": return .compress(focus: arg, rewrittenFrom: nil)
        case "stop": return .stop
        case "help", "commands": return .help
        case "title":
            return canonical ? .unavailable("The Bot Chat keeps its name; /title is not available here.")
                : .unavailable("/title is not available here.")
        case _ where clientOnly.contains(name): return .unavailable("/\(name) is not available in Hermes Bot.")
        default: return .exec(name: name, arg: arg)
        }
    }

    /// User-facing note for a `/new` rewrite (Desktop's toast text).
    public static let neverResetsNotice = "Bot chats are one continuous conversation — compacting instead."
}

/// `session.compress` outcome (`contracts/sessions.py:571-597`).
public struct CompressOutcome: Sendable, Equatable {
    public let compressed: Bool
    public let message: String?
    public let beforeMessages: Int?
    public let afterMessages: Int?
    /// Replacement transcript, when the backend returns one.
    public let history: [ChatHistoryMessage]?
}

extension BotChatSession {
    static let notDispatchable = try! NSRegularExpression(pattern: #"not a quick/plugin/(?:bundle/)?skill command"#,
                                                          options: [.caseInsensitive])
    static let maxAliasHops = 3

    /// `commands.catalog {session_id}` (profile + cwd scoped, `methods_tools.py:503-536`).
    public func slashCatalog() async throws -> SlashCatalog {
        SlashCatalog(result: try await backend.client.call("commands.catalog", ["session_id": .string(sessionId)]))
    }

    /// Runs a backend slash command: `slash.exec {session_id, command:"name arg"}`; on error falls back to
    /// `command.dispatch {session_id, name, arg}` (skills/quick/plugin). When the fallback only says
    /// "not a quick/plugin/skill command", the original `slash.exec` error is the real failure and is
    /// rethrown. `alias` directives are followed (up to 3 hops). `catalog`'s `desktop_subcommands` gate
    /// narrowed commands.
    public func runSlash(name: String, arg: String, catalog: SlashCatalog? = nil) async throws -> SlashDirective {
        var current = name.hasPrefix("/") ? String(name.dropFirst()) : name
        for _ in 0...Self.maxAliasHops {
            if let allowed = catalog?.desktopSubcommands["/\(current)"],
               let refusal = SlashCatalog.subcommandRefusal("/\(current)", arg: arg, allowed: allowed) {
                return .output(refusal)
            }
            let d = try await execOnce(name: current, arg: arg)
            guard case .alias(let target) = d else { return d }
            current = target.hasPrefix("/") ? String(target.dropFirst()) : target
        }
        return .alias(target: current)
    }

    private func execOnce(name: String, arg: String) async throws -> SlashDirective {
        let command = arg.isEmpty ? name : "\(name) \(arg)"
        let execError: Error
        do {
            let r = try await backend.client.call("slash.exec", ["session_id": .string(sessionId), "command": .string(command)])
            return SlashDirective.execResult(r, name: name)
        } catch let e as GatewayClient.ClientError {
            throw e  // the socket is gone: no fallback
        } catch {
            execError = error
        }
        do {
            let r = try await backend.client.call("command.dispatch", [
                "session_id": .string(sessionId), "name": .string(name), "arg": .string(arg),
            ])
            guard let d = SlashDirective.directive(r) else {
                throw GatewayClient.ClientError.badFrame("command.dispatch: invalid directive")
            }
            return d
        } catch let e as GatewayClient.RPCError {
            let range = NSRange(e.message.startIndex..., in: e.message)
            if Self.notDispatchable.firstMatch(in: e.message, range: range) != nil { throw execError }
            throw e
        }
    }

    /// `/compress [focus]` → `session.compress {session_id, focus_topic?}`. LLM-bound: Desktop allows 660 s
    /// (`use-prompt-actions/slash.ts:82-89`).
    public func compress(focus: String = "") async throws -> CompressOutcome {
        var p: [String: JSONValue] = ["session_id": .string(sessionId)]
        if !focus.isEmpty { p["focus_topic"] = .string(focus) }
        let r = try await backend.client.call("session.compress", .object(p), timeout: 660)
        return CompressOutcome(compressed: r["compressed"]?.bool ?? (r["removed"] != nil),
                               message: r["message"]?.string, beforeMessages: r["before_messages"]?.int,
                               afterMessages: r["after_messages"]?.int,
                               history: r["messages"]?.array != nil ? ChatHistoryMessage.decode(r["messages"]) : nil)
    }
}
