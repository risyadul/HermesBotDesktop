import Foundation
import HermesGatewayKit

/// E2: is a model configured? Asked once per connection (and by Check Again), read-only.
extension AppModel {
    func checkSetup() async {
        guard let b = backend else { return }
        let client = b.client
        let readiness = await SetupCheck.run(call: { method, params in try await client.call(method, params, timeout: 30) })
        guard backend === b else { return }  // lost or replaced meanwhile
        setupIssue = Onboarding.issue(for: readiness)
        log("setup.runtime_check → \(readiness == .ready ? "ready" : setupIssue == nil ? "unknown" : "no model")")
    }

    /// Check Again on a first-run screen: the roster (a bot added in Terminal) and the model check.
    func recheckSetup() async {
        await refreshBots()
        await checkSetup()
    }
}
