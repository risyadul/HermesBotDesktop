import Foundation

/// Streaming events of one 1:1 turn, decoded from `{"method":"event","params":{"type","session_id","payload"}}`
/// frames (`tui_gateway/server.py:701-711`, payload models `tui_gateway/contracts/events.py:113-213`).
public enum ChatEvent: Sendable, Equatable {
    case started                                   // message.start (no payload)
    case delta(String)                             // message.delta {text, rendered?}
    case reasoning(String)                         // reasoning.delta {text}: streamed model reasoning
    case reasoningAvailable(String)                // reasoning.available {text}: a step's think-tag content (≤500 chars), not streamed
    case interim(String, alreadyStreamed: Bool)    // message.interim {text, already_streamed}
    case status(kind: String, text: String)        // status.update {kind, text}
    case toolGenerating(name: String)              // tool.generating {name}: transient status, no row
    case toolStarted(ToolStart)                    // tool.start
    case toolCompleted(ToolCompletion)             // tool.complete
    case request(ServerRequest)                    // server→client request for this session (ServerRequests.swift)
    case requestCancelled(id: String, reason: String) // request.cancel {id, method, reason}
    case approvalsCancelled(requestIds: [String])  // approval.cancelled {request_ids}: approval QUEUE ids
    case completed(ChatCompletion)                 // message.complete
    case error(String)                             // error {message}
    case disconnected(String)                      // client-side: the socket is gone (token-free reason)
    /// Client-side: the canonical chat was resumed again after `session.reclaimed`, with the new reply's
    /// history and the turn it reports running (nil when idle). Open requests follow as `.request`.
    case resumed(history: [ChatHistoryMessage], inflight: InflightTurn?)
    /// `session.info` reporting `running: false` (`server.py` `_session_info`): the backend has no turn
    /// running on this session. Settles a joined turn whose end this client missed.
    case idle
    /// `session.info` with a model (`SessionInfoSnapshot`): the composer's model, effort and context gauge.
    /// Delivered before the `.idle` / `.other("session.info")` of the same frame.
    case info(SessionInfoSnapshot)
    /// `session.usage {usage}`: a mid-turn context usage tick.
    case usage(ContextUsage)
    case other(String)                             // anything else for this session_id
}

/// The `message.complete` fields the transcript needs to settle a turn
/// (`MessageCompletePayload`, `tui_gateway/contracts/events.py:189-213`; producer
/// `prompt_turn.py:930-975`).
public struct ChatCompletion: Sendable, Equatable {
    /// Final reply text: `payload.text` when it is a string, else `payload.rendered`, else nil (the
    /// streamed buffer is then the answer). `text` is `str | JsonValue` on the wire; this mirrors the
    /// TUI (`ui-tui/src/app/turnController.ts` `recordMessageComplete`).
    public var text: String?
    /// `complete | error | interrupted`; nil is treated as complete.
    public var status: String?
    public var error: String?
    /// The final text is the response already published as an interim (`prompt_turn.py:952-958`).
    public var responsePreviewed: Bool
    /// The final text is a response this turn already delivered; it adds no text (`events.py:200-201`).
    public var responseReused: Bool
    /// An output hook rewrote the final after streaming: it is the authoritative replacement even
    /// without a prefix relationship to what streamed (`prompt_turn.py:962-965`).
    public var responseTransformed: Bool
    /// The turn's final context usage (`usage`), when the payload carries context figures.
    public var usage: ContextUsage?

    public init(text: String?, status: String? = "complete", error: String? = nil,
                responsePreviewed: Bool = false, responseReused: Bool = false, responseTransformed: Bool = false,
                usage: ContextUsage? = nil) {
        self.text = text; self.status = status; self.error = error
        self.responsePreviewed = responsePreviewed; self.responseReused = responseReused
        self.responseTransformed = responseTransformed
        self.usage = usage
    }

    init(payload p: JSONValue?) {
        self.init(text: p?["text"]?.string ?? p?["rendered"]?.string,
                  status: p?["status"]?.string, error: p?["error"]?.string,
                  responsePreviewed: p?["response_previewed"]?.bool ?? false,
                  responseReused: p?["response_reused"]?.bool ?? false,
                  responseTransformed: p?["response_transformed"]?.bool ?? false,
                  usage: ContextUsage(p?["usage"]))
    }
}
