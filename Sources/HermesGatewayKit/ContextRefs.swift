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
    /// bare scheme is not attached). Surrounding spaces are ignored; whitespace or control characters inside
    /// are refused (a newline would start a second directive line), and the normalised `absoluteString` is
    /// what rides in the prompt.
    public static func url(_ raw: String) -> ContextRef? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || isControl($0) }),
              t.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil,
              let u = URL(string: t), let host = u.host, !host.isEmpty else { return nil }
        return quotable(ContextRef(kind: .url, value: u.absoluteString))
    }

    /// A local folder (`isDirectory`), by its standardized path. Plain spaces are fine (the value is quoted);
    /// newlines, tabs and other control characters are refused.
    public static func folder(_ url: URL) -> ContextRef? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        guard !path.unicodeScalars.contains(where: {
            $0 != " " && (CharacterSet.whitespacesAndNewlines.contains($0) || isControl($0))
        }) else { return nil }
        return quotable(ContextRef(kind: .folder, value: path))
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(s) || s.properties.generalCategory == .format
    }

    /// A ref whose value needs quoting but already holds every quote character cannot be written unambiguously.
    private static func quotable(_ ref: ContextRef) -> ContextRef? {
        needsQuoting(ref.value) && ["`", "\"", "'"].allSatisfy { ref.value.contains($0) } ? nil : ref
    }

    private static func needsQuoting(_ value: String) -> Bool {
        value.range(of: "[\\s()\\[\\]{}<>\"'`]", options: .regularExpression) != nil
    }

    /// Desktop `formatRefValue`: values with whitespace, brackets or quotes are wrapped in the first quote
    /// character they do not contain (backtick, then `"`, then `'`); otherwise left bare.
    public static func formatValue(_ value: String) -> String {
        guard needsQuoting(value) else { return value }
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
