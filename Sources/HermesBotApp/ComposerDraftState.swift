import Combine
import Foundation

/// Shared by a chat's editors, independently of transcript and status publications.
/// Keeping this object on the model preserves drafts across panes and windows without making every
/// keystroke invalidate the entire chat. There is deliberately no forwarding to the parent model.
@MainActor
final class ComposerDraftState: ObservableObject {
    @Published var text: String {
        didSet { if text != oldValue { onChange?(text) } }
    }
    var onChange: ((String) -> Void)?

    init(_ text: String = "") { self.text = text }
}

/// Room drafts stay in memory, with a separate observable object for each thread's editor.
@MainActor
final class RoomDraftStates {
    private var states: [String: ComposerDraftState] = [:]

    func state(for thread: String) -> ComposerDraftState {
        if let state = states[thread] { return state }
        let state = ComposerDraftState()
        states[thread] = state
        return state
    }

    var values: [String: String] {
        get { states.mapValues(\.text) }
        set {
            for thread in Set(states.keys).union(newValue.keys) {
                state(for: thread).text = newValue[thread] ?? ""
            }
        }
    }
}

/// Coalesces persistence, not editing. A single pending value and cancellation generation prevent a
/// delayed save from reviving a sent draft or overwriting a newer one. Store validation still runs
/// before every write. UserDefaults schedules its own disk persistence; no synchronize() is used.
@MainActor
final class DraftPersistence {
    private let store: ChatDraftStore
    private let bot: String
    var delay: UInt64 = 300_000_000
    private var pending: String?
    private var generation = 0
    private var task: Task<Void, Never>?

    init(store: ChatDraftStore, bot: String) {
        self.store = store
        self.bot = bot
    }

    func schedule(_ text: String) {
        cancel()
        pending = text
        // Sending/clearing is a tombstone: commit it now, never leave an older saved prompt behind.
        if text.isEmpty { flush(); return }
        let current = generation
        let delay = delay
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.flush()
        }
    }

    func flush() {
        let text = pending
        cancel()
        if let text { store.save(text, for: bot) }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        pending = nil
    }

    deinit { task?.cancel() }
}
