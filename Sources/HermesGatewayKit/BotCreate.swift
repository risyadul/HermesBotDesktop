import Foundation

/// New Bot, ported from Hermes Desktop's create dialog (`create-dialog.tsx` `CreateAgentDialog`, `labels.ts`
/// `slugifyProfileName` / `botProfileIdentity` / `displayName`, `soul.ts` `composeSoul`):
/// - The Name field becomes the profile id with Desktop's slug rules (`^[a-z0-9][a-z0-9_-]{0,63}$`); a name that
///   is not plain ASCII keeps its spelling as the title when Title is empty.
/// - `profiles.create` gets Desktop's exact payload: `{name, description, clone_from, no_skills, share_auth, soul}`
///   plus `model` / `provider` when both are set. `description` is "title — description"; `clone_from` is null
///   for a fresh profile; `soul` is the composed identity SOUL (or the user's own SOUL) with the messaging section.
/// - Then `setup.runtime_check {profile}` (only an explicit `ok: false` counts) decides whether the bot is ready
///   for the intro turn, "Hey, tell me about yourself!" (`canonical-chat.ts` `kickoffText`).
public enum BotCreate {
    public static let maxNameLength = 64
    public static let kickoff = "Hey, tell me about yourself!"

    // MARK: name

    /// Desktop's `NAME_RE`.
    public static func isValidName(_ slug: String) -> Bool {
        slug.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// Desktop's `slugifyProfileName`: accented Latin folds to its base letters, any other letter or digit becomes
    /// a `u<hex>` token per code point, everything else a dash; cut at 64 on a token boundary.
    public static func slug(_ name: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard isLetterOrNumber(scalar) else { folded.append(scalar); continue }
            let base = String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !isMark($0) }
            let text = String(String.UnicodeScalarView(base))
            let ascii = !text.isEmpty && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            folded.append(contentsOf: (ascii ? text : "-u\(String(scalar.value, radix: 16))-").unicodeScalars)
        }
        let collapsed = String(folded).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let slug = collapsed.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        guard slug.count > maxNameLength else { return slug }
        let chars = Array(slug)
        let cut = String(chars[0..<maxNameLength])
        let boundary = chars[maxNameLength] == "-" ? maxNameLength : (cut.lastIndex(of: "-").map { cut.distance(from: cut.startIndex, to: $0) } ?? -1)
        let kept = boundary > 0 ? String(chars[0..<boundary]) : cut
        return kept.replacingOccurrences(of: "-+$", with: "", options: .regularExpression)
    }

    private static func isLetterOrNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Desktop's `botProfileIdentity`: the profile id, and the title (the typed title, else a non-ASCII name as typed).
    public static func identity(name: String, title: String) -> (slug: String, title: String) {
        let entered = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let printableASCII = entered.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
        return (slug(entered), typed.isEmpty ? (printableASCII ? "" : entered) : typed)
    }

    /// Desktop's `displayName({name, title})`: the title, else `Hermes` for `default`, else the name with dashes
    /// and underscores as spaces and each word capitalised.
    public static func displayName(name: String, title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default" { return "Hermes" }
        let raw = name.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "", previousIsWord = false
        for c in raw {
            let word = c.isASCII && (c.isLetter || c.isNumber || c == "_")
            out += word && !previousIsWord ? c.uppercased() : String(c)
            previousIsWord = word
        }
        return out
    }

    // MARK: SOUL

    /// Desktop's `composeSoul`: the user's SOUL with the messaging section ensured, or the identity SOUL (heading,
    /// role, mission, who it is) followed by the section unless the backend injects it.
    public static func soul(name: String, title: String, description: String, custom: String,
                            roster: [SoulProtocol.Teammate], serverInjects: Bool) -> String {
        if !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SoulProtocol.ensure(custom, name: name, roster: roster, serverInjects: serverInjects)
        }
        let who = displayName(name: name, title: title)
        var lines = ["# \(who)", ""]
        if !title.isEmpty { lines.append("**Role:** \(title)") }
        if !description.isEmpty { lines.append("**Mission:** \(description)") }
        lines += ["", "You are \(who), a persistent named agent (profile `\(name)`) on this machine.",
                  "You keep your own memory, skills, and conversation history across sessions."]
        let identity = lines.joined(separator: "\n")
        return serverInjects ? identity : identity + "\n\n" + SoulProtocol.section(name: name, roster: roster)
    }

    // MARK: profiles.create

    public struct Request: Sendable, Equatable {
        public var name: String
        public var title: String
        public var description: String
        /// nil = a fresh profile (Desktop's `__none__`).
        public var cloneFrom: String?
        public var shareAuth: Bool
        public var noSkills: Bool
        public var soul: String
        public var provider: String
        public var model: String

        public init(name: String, title: String = "", description: String = "", cloneFrom: String? = "default",
                    shareAuth: Bool = true, noSkills: Bool = false, soul: String = "", provider: String = "", model: String = "") {
            self.name = name; self.title = title; self.description = description; self.cloneFrom = cloneFrom
            self.shareAuth = shareAuth; self.noSkills = noSkills; self.soul = soul; self.provider = provider; self.model = model
        }

        /// Desktop's `descriptionText`: title and description joined with " — ".
        public var descriptionText: String { [title, description].filter { !$0.isEmpty }.joined(separator: " — ") }

        public var params: JSONValue {
            var p: [String: JSONValue] = [
                "name": .string(name), "description": .string(descriptionText),
                "clone_from": cloneFrom.map { .string($0) } ?? .null,
                "no_skills": .bool(noSkills), "share_auth": .bool(shareAuth), "soul": .string(soul),
            ]
            let m = model.trimmingCharacters(in: .whitespaces), pr = provider.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty && !pr.isEmpty { p["model"] = .string(m); p["provider"] = .string(pr) }
            return .object(p)
        }
    }

    /// The `profiles.create` reply.
    public struct Created: Sendable, Equatable {
        public let name: String
        public let path: String
        public let soulWritten: Bool
        public let modelSet: Bool

        /// A reply without `soul_written` / `model_set` (an older gateway) reads as done.
        public init(name: String, path: String = "", soulWritten: Bool = true, modelSet: Bool = true) {
            self.name = name; self.path = path; self.soulWritten = soulWritten; self.modelSet = modelSet
        }

        public init(_ r: JSONValue, requested: String) {
            self.init(name: r["name"]?.string ?? requested, path: r["path"]?.string ?? "",
                      soulWritten: r["soul_written"]?.bool ?? true, modelSet: r["model_set"]?.bool ?? true)
        }
    }

    // MARK: readiness

    /// `setup.runtime_check {profile}` for the new bot. Only an explicit `ok: false` is "needs a model"; an older
    /// gateway, a failure or a missing answer reads as unknown and the intro goes ahead, as in Desktop. The
    /// gateway's in-progress answer (5097) is asked again a couple of times.
    public static func readiness(profile: String, call: SetupCheck.Call,
                                 sleep: SetupCheck.Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
        async -> SetupReadiness {
        for attempt in 1...SetupCheck.attempts {
            do {
                return SetupCheck.interpret(try await call(SetupCheck.method, ["profile": .string(profile)]))
            } catch let e as GatewayClient.RPCError where e.code == SetupCheck.inProgressCode && attempt < SetupCheck.attempts {
                do { try await sleep(SetupCheck.retryDelay) } catch { return .unknown }
            } catch {
                return .unknown
            }
        }
        return .unknown
    }
}

extension BotProfileAPI {
    /// `profiles.create` with New Bot's payload (`BotCreate.Request.params`).
    public func create(_ request: BotCreate.Request) async throws -> BotCreate.Created {
        BotCreate.Created(try await call("profiles.create", request.params), requested: request.name)
    }
}
