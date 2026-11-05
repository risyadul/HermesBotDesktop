import Foundation

/// Where an avatar picture can come from besides a file, as Hermes Desktop's avatar picker gets it
/// (`avatar-image.ts`, `avatar-picker.tsx`, `pet.tsx`):
/// - `image.generate {probe: true}` says whether an image backend is configured; `image.generate {prompt,
///   aspect_ratio: "square"}` renders one and answers a data URL (`image_data`), allowed 90 s.
/// - `pet.gallery` lists the petdex companions; `pet.thumb {slug, url}` crops a pet's first frame server-side
///   into a small PNG data URI, which becomes the avatar as it is (Desktop does not rescale pets).
public enum AvatarSources {
    /// Desktop's `IMAGE_GENERATE_TIMEOUT_MS`.
    public static let generateTimeout: TimeInterval = 90
    /// Desktop's `PET_THUMB_TIMEOUT_MS`.
    public static let thumbTimeout: TimeInterval = 15

    public struct Failure: Error, RedactionSafeError, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    // MARK: image.generate

    public static let probeParams: JSONValue = ["probe": true]

    public static func available(_ r: JSONValue) -> Bool { r["available"]?.bool ?? false }

    /// The prompt Desktop sends: the user's own description, or a robot mascot named after the bot.
    public static func prompt(custom: String, name: String, title: String, description: String) -> String {
        let own = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty {
            return "\(own). Avatar for an AI agent: centered, bold flat vector style, solid color background, no text."
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = [t.isEmpty ? name : t, description.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: " — ")
        return "Cute minimal robot avatar for an AI agent named \"\(who)\". "
            + "Friendly simple mascot face, bold flat vector style, solid color background, centered, no text."
    }

    public static func generateParams(prompt: String) -> JSONValue {
        ["prompt": .string(prompt), "aspect_ratio": "square"]
    }

    /// The image bytes of an `image.generate` reply (`image_data`, else `image` when that is a data URL).
    public static func generatedImage(_ r: JSONValue) throws -> Data {
        guard r["success"]?.bool == true else {
            let why = r["error"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(why.isEmpty ? "generation failed" : Redaction.scrub(String(why.prefix(300))))
        }
        for key in ["image_data", "image"] {
            if let url = r[key]?.string, let data = decodeDataURL(url) { return data }
        }
        throw Failure("Hermes made the image but could not send it to the app.")
    }

    /// The bytes of a base64 `data:` URL; nil for anything else (a link or a file path is never followed).
    public static func decodeDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    // MARK: pets

    /// One petdex companion as `pet.gallery` reports it.
    public struct Pet: Sendable, Hashable, Identifiable {
        public var id: String { slug }
        public let slug: String
        public let displayName: String
        public let installed: Bool
        public let curated: Bool
        /// Empty for locally hatched pets.
        public let spritesheetURL: String

        public init(slug: String, displayName: String = "", installed: Bool = false, curated: Bool = false, spritesheetURL: String = "") {
            self.slug = slug; self.displayName = displayName; self.installed = installed; self.curated = curated
            self.spritesheetURL = spritesheetURL
        }

        public var label: String { displayName.isEmpty ? slug : displayName }
    }

    public static func pets(_ r: JSONValue) -> [Pet] {
        (r["pets"]?.array ?? []).compactMap { p in
            guard let slug = p["slug"]?.string, !slug.isEmpty else { return nil }
            return Pet(slug: slug, displayName: p["displayName"]?.string ?? "", installed: p["installed"]?.bool ?? false,
                       curated: p["curated"]?.bool ?? false, spritesheetURL: p["spritesheetUrl"]?.string ?? "")
        }
    }

    /// Desktop's Pet tab: the query matches the name (any case) or the slug; installed pets first, then curated.
    public static func ranked(_ pets: [Pet], query: String) -> [Pet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? pets : pets.filter { $0.displayName.lowercased().contains(q) || $0.slug.contains(q) }
        func rank(_ p: Pet) -> Int { p.installed ? 0 : p.curated ? 1 : 2 }
        return filtered.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    public static func thumbParams(_ pet: Pet) -> JSONValue { ["slug": .string(pet.slug), "url": .string(pet.spritesheetURL)] }

    /// The PNG of a `pet.thumb` reply; nil when the backend could not crop one.
    public static func thumb(_ r: JSONValue) -> Data? {
        guard r["ok"]?.bool == true, let uri = r["dataUri"]?.string, let data = decodeDataURL(uri),
              ProfileAvatar.format(data) != nil, ProfileAvatar.isSafeToDecode(data) else { return nil }
        return data
    }
}
