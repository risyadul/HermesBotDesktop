import Foundation

// B10: actionable error cards. The backend stamps a failed turn's `message.complete {status: "error"}` with a
// structured `error_surface {layer, code, retryable, provider?, model?}` (`agent/error_surface.py`,
// `session_auto_continue.py` `_fail_turn`, `prompt_turn.py`); Hermes Desktop picks the card's buttons from it
// (`lib/error-surface.ts` `errorRecoveryPlan`) and copies a plain-text blob (`formatErrorDiagnostics`).

/// `error_surface` of a failed turn.
public struct ErrorSurface: Sendable, Equatable {
    public var layer: String
    public var code: String
    /// False when retrying unchanged reproduces the same failure.
    public var retryable: Bool
    public var provider: String?
    public var model: String?

    public init(layer: String, code: String, retryable: Bool, provider: String? = nil, model: String? = nil) {
        self.layer = layer; self.code = code; self.retryable = retryable; self.provider = provider; self.model = model
    }

    /// nil without a layer (an older backend, or no surface at all).
    public init?(_ v: JSONValue?) {
        guard let v, let layer = v["layer"]?.string, !layer.isEmpty else { return nil }
        self.init(layer: layer, code: v["code"]?.string ?? "", retryable: v["retryable"]?.bool ?? true,
                  provider: v["provider"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                  model: v["model"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// What an error line in the transcript knows about its failure (the card's buttons and diagnostics).
public struct TurnFailure: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// `message.complete {status: "error"|…}` for a turn the backend ran.
        case turn
        /// `error {message}` event.
        case event
        /// The submit never reached the backend (its user line was taken back, the draft restored).
        case send
        /// The socket dropped.
        case disconnected
    }

    public var source: Source
    /// The raw error text (provider/gateway detail), as shown in the card's details.
    public var message: String
    public var surface: ErrorSurface?

    public init(source: Source, message: String, surface: ErrorSurface? = nil) {
        self.source = source; self.message = message; self.surface = surface
    }
}

/// Which buttons an error card shows (Desktop `errorRecoveryPlan`, reduced to what the app can do).
public struct ErrorRecoveryPlan: Sendable, Equatable {
    /// Re-run the failed prompt (Desktop's Retry = regenerate that turn).
    public var retry: Bool
    /// Open the composer's model picker (`SWITCH_PROVIDER_LAYERS`: auth, billing, endpoint, provider).
    public var switchProvider: Bool

    public static let switchProviderLayers: Set<String> = ["auth", "billing", "endpoint", "provider"]
    /// Credential rejections: fixing the credential changes the outcome, so Retry stays (Desktop keeps it for
    /// `oauthReauth` / `apiKeyRejected`, both on the auth layer).
    static let retryDespiteDeterministic: Set<String> = ["auth"]

    public init(retry: Bool, switchProvider: Bool) { self.retry = retry; self.switchProvider = switchProvider }

    public init(_ failure: TurnFailure) {
        let s = failure.surface
        switch failure.source {
        case .disconnected, .send:
            // Nothing ran: the draft is back in the composer (send), or there is no socket to retry on.
            retry = false
        case .turn, .event:
            retry = s.map { $0.retryable || Self.retryDespiteDeterministic.contains($0.layer) } ?? true
        }
        switchProvider = s.map { Self.switchProviderLayers.contains($0.layer) } ?? false
    }
}

public enum ErrorDiagnostics {
    /// Desktop's "Copy error details" blob, every line passed through `redact` (gateway tokens and provider
    /// keys stay out of the clipboard). `now` is injectable for tests.
    public static func text(_ f: TurnFailure, bot: String, model: String, provider: String, appVersion: String?,
                            now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        let s = f.surface
        let lines: [String?] = [
            "── Hermes error details ──",
            "time: \(iso.string(from: now))",
            "bot: \(bot)",
            s.map { "layer: \($0.layer)" },
            s.map { "code: \($0.code)" },
            s.map { "retryable: \($0.retryable)" },
            (s?.provider ?? (provider.isEmpty ? nil : provider)).map { "provider: \($0)" },
            (s?.model ?? (model.isEmpty ? nil : model)).map { "model: \($0)" },
            appVersion.map { "app: \($0)" },
            "error: \(f.message)",
        ]
        return lines.compactMap { $0 }.map(redact).joined(separator: "\n")
    }

    /// `Redaction.scrub` (gateway tokens, bearer headers) plus provider credential shapes a provider error can
    /// echo back: `sk-…` / `sk-ant-…` / `sk-or-…` keys, Google `AIza…`, GitHub `ghp_`/`gho_`/`github_pat_`,
    /// Slack `xox?-`, and `api_key=` / `"api_key": "…"` values.
    public static func redact(_ s: String) -> String {
        var out = Redaction.scrub(s)
        for (pattern, template) in keyPatterns {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    private static let keyPatterns: [(NSRegularExpression, String)] = [
        (#"\bsk-[A-Za-z0-9_-]{16,}"#, Redaction.mask),
        (#"\bAIza[0-9A-Za-z_-]{20,}"#, Redaction.mask),
        (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"#, Redaction.mask),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, Redaction.mask),
        (#"(?i)((?:api[_-]?key|access[_-]?token|secret)["']?\s*[:=]\s*["']?)[^\s"'&,}]+"#, "$1\(Redaction.mask)"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
