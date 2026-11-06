import Foundation

/// Token-safe error text for logs, UI and evidence files.
///
/// Foundation transport errors (`URLError` / `NSError` from `URLSessionWebSocketTask`) carry the
/// request URL in `userInfo` (`NSErrorFailingURLKey`, `NSErrorFailingURLStringKey`). The gateway URL
/// is `ws://…/api/ws?token=<session token>`, so interpolating such an error (`"\(error)"`) prints the
/// live token. Rules:
/// - `GatewayClient` converts every transport error into `GatewayClient.ClientError.transport` before
///   any continuation resumes, so no Foundation error with a URL leaves the client (first line).
/// - Every consumer that turns an error into text uses `Redaction.describe(_:)` (second line): known
///   error types keep their description, anything else is reduced to `domain code: localized message`
///   and `userInfo` is never rendered. The result is then scrubbed for token-shaped substrings.
/// An error whose `description` holds no secrets, so `Redaction.describe` keeps it (still scrubbed)
/// instead of reducing it to `domain code: message`. For harness-local failure types.
public protocol RedactionSafeError: Error, CustomStringConvertible {}

public enum Redaction {
    public static let mask = "[REDACTED]"

    /// Safe one-line description of any error.
    public static func describe(_ error: Error, secrets: [String] = []) -> String {
        let text: String
        switch error {
        case let e as GatewayClient.ClientError: text = e.description
        case let e as GatewayClient.RPCError: text = e.description
        case let e as ServeProcess.ServeError: text = e.description
        case let e as Backend.Failure: text = e.description
        case let e as RedactionSafeError: text = e.description
        case is CancellationError: text = "cancelled"
        default:
            // Never `"\(error)"`: for NSError/URLError that renders userInfo, including the failing URL.
            let ns = error as NSError
            text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        }
        return scrub(text, secrets: secrets)
    }

    /// Removes known secrets (raw and percent-encoded) and token-shaped substrings.
    public static func scrub(_ s: String, secrets: [String] = []) -> String {
        var out = s
        for secret in secrets where secret.count >= 8 {
            out = out.replacingOccurrences(of: secret, with: mask)
            if let enc = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics), enc != secret {
                out = out.replacingOccurrences(of: enc, with: mask)
            }
        }
        for (pattern, template) in patterns {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                   withTemplate: template)
        }
        return out
    }

    /// `?token=`/`&token=` query values, `Authorization: Bearer …`, `X-Hermes-Token: …`, and the gated
    /// `hermes-gateway-ticket.<ticket>` subprotocol.
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"(?i)([?&]token=)[^&\s"'#<>)\]}]+"#, "$1\(mask)"),
        (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1\(mask)"),
        (#"(?i)(x-hermes-token["']?\s*[:=]\s*["']?)[A-Za-z0-9._~+/=-]+"#, "$1\(mask)"),
        (#"(?i)(x-hermes-session-token["']?\s*[:=]\s*["']?)[A-Za-z0-9._~+/=-]+"#, "$1\(mask)"),
        (#"(?i)(hermes-gateway-ticket\.)[A-Za-z0-9._~+/=-]+"#, "$1\(mask)"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
