import Foundation
import HermesGatewayKit

/// An expensive model pick the backend wants confirmed (`confirm_required`) before it switches.
struct ModelConfirm: Equatable, Identifiable {
    var id: String { provider + "/" + model }
    let model: String
    let provider: String
    let message: String
}

/// Model and reasoning effort for this chat (B7) and its context usage (B9).
///
/// Scope, as Hermes Desktop's composer: a pick changes THIS chat's session only. The model goes out as
/// `config.set {key: "model", value: "<model> --provider <p> --session"}` and the effort as
/// `config.set {key: "reasoning"}` without a scope; neither writes any profile's `config.yaml`.
/// The pick is painted at once and rolled back if the backend refuses it (unless a newer `session.info`
/// arrived meanwhile).
extension ChatModel {
    var currentModel: String { modelInfo?.model ?? bot.model ?? "" }
    var currentProvider: String { modelInfo?.provider ?? bot.provider ?? "" }
    var reasoningEffort: String { modelInfo?.reasoningEffort ?? "" }

    private var currentCapabilities: ModelCatalog.Capabilities? {
        modelCatalog?.capabilities(provider: currentProvider, model: currentModel)
    }

    /// Hidden only when the catalog says the model has no reasoning control (unknown → shown, like Desktop).
    var showsReasoning: Bool { currentCapabilities?.reasoning != false }
    var reasoningOptions: [String] { ReasoningEffort.options(canDisable: currentCapabilities?.canDisableReasoning ?? false) }
    var canChangeControls: Bool { isReady && !reconnecting && session != nil }

    func loadModelOptions() {
        guard let s = session else { return }
        Task {
            do { self.modelCatalog = try await s.modelOptions() } catch {
                self.log("model.options failed: \(Self.message(error, bot: self.bot))")
            }
        }
    }

    // MARK: model

    func selectModel(provider: String, model: String) {
        guard canChangeControls, let s = session, model != currentModel || provider != currentProvider else { return }
        switchModel(s, provider: provider, model: model, confirmed: false)
    }

    /// The user agreed to the expensive pick: send it again with `confirm_expensive_model`.
    func confirmModelSwitch() {
        guard let c = modelConfirm else { return }
        modelConfirm = nil
        guard canChangeControls, let s = session else { return }
        switchModel(s, provider: c.provider, model: c.model, confirmed: true)
    }

    func cancelModelSwitch() { modelConfirm = nil }

    private func switchModel(_ s: any ChatSessionLink, provider: String, model: String, confirmed: Bool) {
        let previous = modelInfo
        modelInfo = SessionInfoSnapshot(model: model, provider: provider, reasoningEffort: previous?.reasoningEffort ?? "",
                                        reasoningEffortWire: "", usage: previous?.usage)
        let painted = modelInfo
        Task {
            do {
                let o = try await s.switchModel(model: model, provider: provider, confirmExpensive: confirmed)
                self.log("config.set model → value=\(o.value) deferred=\(o.deferred) confirm=\(o.confirmRequired)")
                if o.confirmRequired {
                    self.rollBack(to: previous, ifStill: painted)
                    self.modelConfirm = ModelConfirm(model: model, provider: provider,
                                                     message: o.confirmMessage.isEmpty ? Self.expensiveNote(model) : o.confirmMessage)
                    return
                }
                if !o.warning.isEmpty { self.transcript.appendSystem(o.warning) }
                if o.deferred {
                    self.transcript.appendSystem(Self.deferredModelNote(model))
                } else {
                    self.loadModelOptions()
                }
            } catch let e as GatewayClient.RPCError where e.code == Self.busyModelSwitchCode {
                // An older backend refuses a switch mid-turn instead of deferring it (Desktop keeps the pick).
                self.transcript.appendSystem(Self.deferredModelNote(model))
            } catch {
                self.rollBack(to: previous, ifStill: painted)
                self.transcript.appendSystem("Couldn't switch the model: \(Self.message(error, bot: self.bot))")
            }
        }
    }

    /// `4009`: an older gateway refusing a model switch while a turn runs (Desktop `isBusySessionModelSwitch`).
    nonisolated static let busyModelSwitchCode = 4009

    nonisolated static func deferredModelNote(_ model: String) -> String {
        "\(model) takes over when the current reply finishes."
    }

    nonisolated static func expensiveNote(_ model: String) -> String {
        "\(model) costs more per message than your current model."
    }

    /// A failed pick paints the previous state back, unless something newer (a `session.info`, another
    /// pick) replaced the optimistic one meanwhile.
    private func rollBack(to previous: SessionInfoSnapshot?, ifStill painted: SessionInfoSnapshot?) {
        guard modelInfo == painted else { return }
        modelInfo = previous
    }

    // MARK: reasoning

    func selectReasoning(_ effort: String) {
        guard canChangeControls, let s = session, ReasoningEffort.isLevel(effort), effort != reasoningEffort else { return }
        let previous = modelInfo
        var next = modelInfo ?? SessionInfoSnapshot(model: currentModel, provider: currentProvider)
        next.reasoningEffort = effort
        next.reasoningEffortWire = ""
        modelInfo = next
        Task {
            do {
                let applied = try await s.setReasoning(effort)
                self.log("config.set reasoning → \(applied)")
            } catch {
                self.rollBack(to: previous, ifStill: next)
                self.transcript.appendSystem("Couldn't change the reasoning effort: \(Self.message(error, bot: self.bot))")
            }
        }
    }

    // MARK: context usage

    func refreshUsage() {
        guard let s = session else { return }
        Task {
            do {
                if let u = try await s.usage() { self.contextUsage = u }
            } catch {
                self.log("session.usage failed: \(Self.message(error, bot: self.bot))")
            }
        }
    }

    /// The gauge as the chat opens, read-only. `session.usage` first; a resumed chat whose agent has not run a
    /// turn in this backend reports no context figures there, so (like Desktop's status bar) the
    /// `session.context_breakdown` estimate fills it, retried after `usageRetryDelays` while the backend answers
    /// with a zeroed breakdown (no agent built yet). Stops once any figure arrives (a turn's usage, too).
    func primeUsage() {
        guard let s = session else { return }
        usageTask?.cancel()
        usageTask = Task {
            do {
                if let u = try await s.usage() { self.contextUsage = u; return }
            } catch {
                self.log("session.usage failed: \(Self.message(error, bot: self.bot))")
            }
            for delay in [0] + self.usageRetryDelays {
                if delay > 0 { try? await self.usageSleep(delay) }
                guard !Task.isCancelled, !self.closed, self.session === s, self.contextUsage == nil else { return }
                do {
                    let b = try await s.contextBreakdown()
                    guard self.contextUsage == nil else { return }
                    if let u = b.usage {
                        self.contextUsage = u
                        self.contextBreakdown = b
                        return
                    }
                } catch {
                    self.log("session.context_breakdown failed: \(Self.message(error, bot: self.bot))")
                }
            }
        }
    }

    /// `session.context_breakdown` for the usage popover (also refreshes the gauge's figure).
    func loadContextBreakdown() {
        guard let s = session, !breakdownLoading else { return }
        breakdownLoading = true
        Task {
            defer { self.breakdownLoading = false }
            do {
                let b = try await s.contextBreakdown()
                self.contextBreakdown = b
                if let u = b.usage { self.contextUsage = ContextUsage(used: u.used, max: u.max, percent: u.percent,
                                                                      estimated: u.estimated,
                                                                      compressions: self.contextUsage?.compressions) }
            } catch {
                self.log("session.context_breakdown failed: \(Self.message(error, bot: self.bot))")
            }
        }
    }
}
