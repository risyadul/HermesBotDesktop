import Foundation
import XCTest
@testable import HermesGatewayKit

/// A2: Pin / Hide are written to `ui_meta["hermes-bots"]` exactly like Hermes Desktop (`data.ts`
/// `persistBotMetaPatch`): fresh read, patch over the server's namespace, only the `hermes-bots` key sent,
/// per-key CAS revision, re-read on a conflict (3 attempts). A scripted fake stands in for the gateway;
/// nothing touches a real profile.
final class BotMetaSyncTests: XCTestCase {
    /// Records every call and answers from a script (`profiles.list` rows, `profiles.configure` replies).
    final class FakeGateway: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(String, JSONValue)] = []
        var lists: [JSONValue]
        var configures: [JSONValue]

        init(lists: [JSONValue], configures: [JSONValue]) { self.lists = lists; self.configures = configures }

        var call: BotMetaSync.Call {
            { method, params in
                try self.lock.withLock {
                    self.calls.append((method, params))
                    switch method {
                    case "profiles.list": return self.lists.count > 1 ? self.lists.removeFirst() : self.lists[0]
                    case "profiles.configure": return self.configures.count > 1 ? self.configures.removeFirst() : self.configures[0]
                    default: throw GatewayClient.ClientError.badFrame("unexpected \(method)")
                    }
                }
            }
        }

        var configureParams: [JSONValue] { lock.withLock { calls.filter { $0.0 == "profiles.configure" }.map(\.1) } }
    }

    private static func list(meta: JSONValue?, revision: Int?, name: String = "alpha") -> JSONValue {
        var row: [String: JSONValue] = ["name": .string(name)]
        if let meta { row["ui_meta"] = meta }
        if let revision { row["ui_meta_revisions"] = ["hermes-bots": .number(Double(revision))] }
        return ["profiles": [.object(row), ["name": "other"]]]
    }

    private static let applied: JSONValue = ["applied": ["ui_meta": true, "ui_meta_revisions": ["hermes-bots": 5]]]

    func testParsesPinnedAndHiddenFromProfilesListRow() {
        let row: JSONValue = ["name": "alpha", "ui_meta": ["hermes-bots": ["pinned": true, "hidden": false, "title": "A"]]]
        XCTAssertEqual(BotUIMeta(row: row), BotUIMeta(pinned: true, hidden: false))
        XCTAssertEqual(Bot(row)?.uiMeta, BotUIMeta(pinned: true, hidden: false))
        XCTAssertEqual(BotUIMeta(row: ["name": "b"]), BotUIMeta())
        XCTAssertEqual(BotUIMeta(row: ["name": "b", "ui_meta": ["hermes-bots": "junk"]]), BotUIMeta())
    }

    func testMergeKeepsOtherFieldsDropsStaleChatPointerPatchWins() {
        let merged = BotMetaSync.merged(["title": "A", "color": "#fff", "chat": "abc", "pinned": false], patch: ["pinned": true])
        XCTAssertEqual(merged, ["title": "A", "color": "#fff", "pinned": true])
    }

    func testRevisionNilOnOldGatewayZeroWhenKeyMissing() {
        XCTAssertNil(BotMetaSync.serverMeta(row: ["name": "a"]).revision)
        XCTAssertEqual(BotMetaSync.serverMeta(row: ["name": "a", "ui_meta_revisions": ["other": 3]]).revision, 0)
        XCTAssertEqual(BotMetaSync.serverMeta(row: ["name": "a", "ui_meta_revisions": ["hermes-bots": 4]]).revision, 4)
    }

    func testSavePatchesServerNamespaceAndSendsOnlyHermesBotsKeyWithRevision() async throws {
        let server: JSONValue = ["hermes-bots": ["title": "Alpha", "sectionId": "s1", "chat": "old"], "other-plugin": ["x": 1]]
        let gw = FakeGateway(lists: [Self.list(meta: server, revision: 4)], configures: [Self.applied])
        let outcome = try await BotMetaSync.save(name: "alpha", patch: ["pinned": true], call: gw.call)
        XCTAssertEqual(outcome, .persisted(BotUIMeta(pinned: true, hidden: false)))
        let params = try XCTUnwrap(gw.configureParams.first)
        XCTAssertEqual(params["name"], "alpha")
        // Only the `hermes-bots` key: the gateway merges key-wise, so `other-plugin` is never clobbered.
        XCTAssertEqual(params["ui_meta"]?.object?.keys.sorted(), ["hermes-bots"])
        XCTAssertEqual(params["ui_meta"]?["hermes-bots"], ["title": "Alpha", "sectionId": "s1", "pinned": true])
        XCTAssertEqual(params["ui_meta_expected_revisions"], ["hermes-bots": 4])
        XCTAssertEqual(gw.calls.first?.1, ["include_sessions": false])
    }

    func testConflictReReadsAndRetriesOnNewerBase() async throws {
        let conflict: JSONValue = ["applied": ["ui_meta": false, "ui_meta_conflicts": ["hermes-bots": ["expected": 1, "actual": 2]]]]
        let gw = FakeGateway(lists: [Self.list(meta: ["hermes-bots": ["title": "Old"]], revision: 1),
                                     Self.list(meta: ["hermes-bots": ["title": "New", "hidden": true]], revision: 2)],
                             configures: [conflict, Self.applied])
        let outcome = try await BotMetaSync.save(name: "alpha", patch: ["pinned": true], call: gw.call)
        XCTAssertEqual(outcome, .persisted(BotUIMeta(pinned: true, hidden: true)))
        let second = try XCTUnwrap(gw.configureParams.last)
        XCTAssertEqual(second["ui_meta"]?["hermes-bots"], ["title": "New", "hidden": true, "pinned": true])
        XCTAssertEqual(second["ui_meta_expected_revisions"], ["hermes-bots": 2])
    }

    func testGivesUpAfterThreeConflicts() async throws {
        let conflict: JSONValue = ["applied": ["ui_meta": false, "ui_meta_conflicts": ["hermes-bots": [:]]]]
        let gw = FakeGateway(lists: [Self.list(meta: nil, revision: 0)], configures: [conflict])
        let outcome = try await BotMetaSync.save(name: "alpha", patch: ["hidden": true], call: gw.call)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(gw.configureParams.count, BotMetaSync.attempts)
    }

    func testOldGatewaySendsNoRevisionAndReportsUnsupported() async throws {
        let gw = FakeGateway(lists: [Self.list(meta: nil, revision: nil)], configures: [["ok": true]])
        let outcome = try await BotMetaSync.save(name: "alpha", patch: ["hidden": true], call: gw.call)
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertNil(gw.configureParams.first?["ui_meta_expected_revisions"])
    }

    func testRejectedWriteIsFailedAndMissingProfileIsNotFound() async throws {
        let rejected = FakeGateway(lists: [Self.list(meta: nil, revision: 0)], configures: [["applied": ["ui_meta": false]]])
        let r1 = try await BotMetaSync.save(name: "alpha", patch: ["hidden": true], call: rejected.call)
        XCTAssertEqual(r1, .failed)
        let missing = FakeGateway(lists: [Self.list(meta: nil, revision: 0, name: "beta")], configures: [Self.applied])
        let r2 = try await BotMetaSync.save(name: "alpha", patch: ["hidden": true], call: missing.call)
        XCTAssertEqual(r2, .notFound)
        XCTAssertTrue(missing.configureParams.isEmpty)
    }
}
