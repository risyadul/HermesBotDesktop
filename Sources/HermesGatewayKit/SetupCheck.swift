import Foundation

/// E2: is a model configured? `setup.runtime_check` (read-only, `tui_gateway/methods_config.py`) runs the same
/// provider resolution as session creation and answers `{ok, provider, model, source, error}`: `ok == false`
/// means a chat would fail for lack of a usable provider, which the app shows as first-run guidance
/// (`hermes setup` / `hermes model`) instead of a doomed first message.
///
/// Anything that is not a clear answer (an older Hermes without the method, the readiness probe still running,
/// a transport error, a reply without `ok`) is `.unknown`: the app then behaves as before and shows nothing.
public enum SetupReadiness: Sendable, Equatable {
    case ready
    /// `ok == false`: the provider the backend blames, the model it resolved, and its one-sentence reason.
    case noModel(provider: String?, model: String?, reason: String?)
    case unknown
}

public enum SetupCheck {
    public static let method = "setup.runtime_check"
    /// JSON-RPC error the gateway answers while its single-flight readiness probe is still running
    /// (`_READINESS_IN_PROGRESS_ERR`); the probe continues, so asking again shortly gets the result.
    public static let inProgressCode = 5097
    public static let attempts = 3
    public static let retryDelay: TimeInterval = 2
    /// Backend-chosen text shown on screen: capped and made visible (`VisibleText`).
    static let maxFieldChars = 200

    public typealias Call = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    /// One `setup.runtime_check` reply.
    public static func interpret(_ result: JSONValue) -> SetupReadiness {
        switch result["ok"]?.bool {
        case true?: return .ready
        case false?:
            return .noModel(provider: field(result["provider"]), model: field(result["model"]),
                            reason: field(result["error"]))
        case nil: return .unknown
        }
    }

    /// Asks the backend (for the launch profile), retrying while its probe is still in progress.
    public static func run(call: Call,
                           sleep: Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async -> SetupReadiness {
        for attempt in 1...attempts {
            do {
                return interpret(try await call(method, [:]))
            } catch let e as GatewayClient.RPCError where e.code == inProgressCode && attempt < attempts {
                do { try await sleep(retryDelay) } catch { return .unknown }
            } catch {
                return .unknown
            }
        }
        return .unknown
    }

    static func field(_ v: JSONValue?) -> String? {
        guard let s = v?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let capped = s.count > maxFieldChars ? String(s.prefix(maxFieldChars)) + "…" : s
        return VisibleText.reveal(Redaction.scrub(capped))
    }
}
