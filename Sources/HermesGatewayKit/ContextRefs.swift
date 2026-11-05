import Foundation

/// B11: context references the Bot Chat composer attaches without uploading anything, as Hermes Desktop's
/// composer does (`app/chat/hooks/use-composer-actions.ts` `addContextRefAttachment`,
/// `app/chat/composer/url-dialog.tsx`): a web page as `@url:<url>` and a folder as `@folder:<path>`. The
/// gateway expands these directives when the turn runs; they ride in the prompt text, one per line before it.
public struct ContextRef: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable { case url, folder }
    public let kind: Kind
    /// The URL or the absolute folder path.
    public let value: String

    public init(kind: Kind, value: String) { self.kind = kind; self.value = value }

    /// `@url:…` / `@folder:…` with Desktop's quoting (`formatRefValue`).
    public var refText: String { "@\(kind.rawValue):\(Self.formatValue(value))" }

    /// A web URL the dialog accepts: `http(s)://` with a host (Desktop `URL_HINT` plus a host check, so a
    /// bare scheme is not attached). Surrounding spaces are ignored.
    public static func url(_ raw: String) -> ContextRef? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil,
              let u = URL(string: t), let host = u.host, !host.isEmpty else { return nil }
        return ContextRef(kind: .url, value: t)
    }

    /// A local folder (`isDirectory`), by its standardized path.
    public static func folder(_ url: URL) -> ContextRef? {
        guard url.isFileURL else { return nil }
        return ContextRef(kind: .folder, value: url.standardizedFileURL.path)
    }

    /// Desktop `formatRefValue`: values with whitespace, brackets or quotes are wrapped in the first quote
    /// character they do not contain (backtick, then `"`, then `'`); otherwise left bare.
    public static func formatValue(_ value: String) -> String {
        guard value.range(of: "[\\s()\\[\\]{}<>\"'`]", options: .regularExpression) != nil else { return value }
        for q in ["`", "\"", "'"] where !value.contains(q) { return q + value + q }
        return value
    }

    /// The prompt with ref lines first (Desktop `[refs.join("\n"), text].filter(Boolean).join("\n\n")`).
    public static func prompt(_ refs: [ContextRef], text: String) -> String {
        let lines = refs.map(\.refText).joined(separator: "\n")
        return [lines, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// B11: a paste longer than `threshold` characters becomes a text attachment instead of flooding the composer
/// (Desktop `app/chat/composer/large-paste.ts`: `LARGE_PASTE_ATTACHMENT_THRESHOLD = 3_000`).
public enum LargePaste {
    public static let threshold = 3_000

    public static func shouldAttach(_ text: String, threshold: Int = LargePaste.threshold) -> Bool {
        threshold > 0 && text.utf16.count > threshold  // JS `length`: UTF-16 units
    }

    /// The chip's size label (Desktop `pasteSizeLabel`, UTF-8 bytes).
    public static func sizeLabel(_ text: String) -> String { byteLabel(text.utf8.count) }

    public static func byteLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// Desktop's saved-paste file name shape (`pasted_content_<stamp>_<hex>.txt`).
    public static func fileName(now: Date = Date(), suffix: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        "pasted_content_\(Int(now.timeIntervalSince1970))_\(suffix).txt"
    }

    public static func isPastedContent(_ name: String) -> Bool {
        name.range(of: "^pasted_content_[\\w-]+\\.txt$", options: .regularExpression) != nil
    }
}
