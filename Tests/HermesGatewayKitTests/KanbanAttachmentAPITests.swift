import Foundation
import XCTest
@testable import HermesGatewayKit

/// Requeue (`POST /tasks/{id}/reclaim`) and attachment routes (`plugin_api.py:464-528`) against the in-process
/// stub: request shapes (multipart body, headers, `?board=`), size refusal before sending, decoding, download
/// bytes and errors. Every name and byte is a placeholder.
final class KanbanAttachmentAPITests: XCTestCase {
    private func api(_ table: [String: StubURLProtocol.Reply]) -> (KanbanAPI, Int) {
        let port = PluginStub.routes(table)
        return (KanbanAPI(rest: PluginStub.rest(port: port, plugin: "kanban")), port)
    }

    static let row = #"{"id":7,"task_id":"t_1","filename":"notes.txt","content_type":"text/plain","size":2048,"uploaded_by":"desktop","stored_path":"/srv/x/notes.txt","created_at":1760000400}"#

    // MARK: - reclaim

    func testReclaimPostsAnEmptyBodyWithTheBoard() async throws {
        let (api, port) = api(["POST /api/plugins/kanban/tasks/t/1/reclaim": .init(json: #"{"ok":true,"task_id":"t/1"}"#)])
        try await api.reclaim("t/1", board: "b")
        try await api.reclaim("t/1", board: nil, reason: "off the rails")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.method), ["POST", "POST"])
        XCTAssertTrue(seen[0].url.absoluteString.contains("/tasks/t%2F1/reclaim"))
        XCTAssertEqual(seen[0].body, [:], "Desktop's reclaimTask sends {}")
        XCTAssertEqual(PluginStub.query(seen[0]), ["board": "b"])
        XCTAssertEqual(seen[0].headers["X-Hermes-Session-Token"], PluginStub.token)
        XCTAssertEqual(seen[1].body, ["reason": "off the rails"], "ReclaimBody's only field")
        XCTAssertEqual(PluginStub.query(seen[1]), [:])
    }

    func testReclaimOfATaskThatIsNotRunningIsAConflict() async {
        let (api, _) = api(["POST /api/plugins/kanban/tasks/t_1/reclaim":
                                .init(status: 409, json: #"{"detail":"cannot reclaim t_1: not in a claimable state"}"#)])
        do { try await api.reclaim("t_1", board: nil); XCTFail("expected 409") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .http(status: 409, detail: "cannot reclaim t_1: not in a claimable state"))
        }
    }

    // MARK: - list

    func testAttachmentListDecodesAndDropsRowsWithoutId() async throws {
        let (api, port) = api(["GET /api/plugins/kanban/tasks/t_1/attachments":
                                .init(json: #"{"attachments":[\#(Self.row),{"filename":"no id"},{"id":8,"size":null}]}"#)])
        let list = try await api.attachments(taskId: "t_1", board: "b")
        XCTAssertEqual(list.map(\.id), [7, 8])
        let a = list[0]
        XCTAssertEqual(a.taskId, "t_1")
        XCTAssertEqual(a.filename, "notes.txt")
        XCTAssertEqual(a.contentType, "text/plain")
        XCTAssertEqual(a.size, 2048)
        XCTAssertEqual(a.uploadedBy, "desktop")
        XCTAssertEqual(a.createdAt, 1760000400)
        XCTAssertEqual(list[1].size, 0)
        XCTAssertEqual(list[1].filename, "")
        XCTAssertEqual(PluginStub.query(StubURLProtocol.requests(port: port)[0]), ["board": "b"])
    }

    func testTaskDetailCarriesTypedAttachments() throws {
        let d = try KanbanTaskDetail(json: try JSONDecoder().decode(JSONValue.self, from: Data(#"{"task":{"id":"t_1"},"attachments":[\#(Self.row)]}"#.utf8)))
        XCTAssertEqual(d.attachments.map(\.filename), ["notes.txt"])
    }

    // MARK: - upload

    func testUploadIsOneFileMultipartWithTheFileField() async throws {
        let (api, port) = api(["POST /api/plugins/kanban/tasks/t_1/attachments": .init(json: #"{"attachment":\#(Self.row)}"#)])
        let bytes = Data([0x00, 0x01, 0xFF, 0x0D, 0x0A, 0x42])
        let a = try await api.uploadAttachment(taskId: "t_1", filename: "a\"b\r\n.txt", contentType: "text/plain", data: bytes, board: "b")
        XCTAssertEqual(a?.id, 7)
        let seen = try XCTUnwrap(StubURLProtocol.requests(port: port).first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(PluginStub.query(seen), ["board": "b"])
        XCTAssertEqual(seen.headers["X-Hermes-Session-Token"], PluginStub.token)
        let type = try XCTUnwrap(seen.headers["Content-Type"])
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="), type)
        let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertFalse(boundary.isEmpty)
        let body = try XCTUnwrap(seen.rawBody)
        var expected = Data()
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"uploaded_by\"\r\n\r\nhermes-bot-app\r\n".utf8))
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a_b__.txt\"\r\nContent-Type: text/plain\r\n\r\n".utf8))
        expected.append(bytes)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertEqual(body, expected, "raw bytes kept; quotes and line breaks in the name cannot break the part header")
    }

    func testMultipartWithoutTypeIsOctetStream() {
        let body = PluginREST.multipart(filename: "", contentType: nil, data: Data("x".utf8), boundary: "B")
        XCTAssertEqual(body.contentType, "multipart/form-data; boundary=B")
        XCTAssertEqual(String(decoding: body.data, as: UTF8.self),
                       "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\nContent-Type: application/octet-stream\r\n\r\nx\r\n--B--\r\n")
    }

    func testUploadOverTheServerLimitIsRefusedBeforeSending() async {
        let (api, port) = api(["POST /api/plugins/kanban/tasks/t_1/attachments": .init(json: "{}")])
        let big = Data(count: KanbanAPI.maxAttachmentBytes + 1)
        do { _ = try await api.uploadAttachment(taskId: "t_1", filename: "big.bin", contentType: nil, data: big, board: nil); XCTFail("expected refusal") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .refused("attachment is larger than 25 MB"))
        }
        XCTAssertTrue(StubURLProtocol.requests(port: port).isEmpty, "nothing was sent")
        XCTAssertEqual(KanbanAPI.maxAttachmentBytes, 25 * 1024 * 1024, "kanban_db.KANBAN_ATTACHMENT_MAX_BYTES")
    }

    func testRawSendKeepsTheLoopbackRuleAndScrubsTheToken() async {
        let remote = KanbanAPI(rest: PluginStub.rest(port: 1, plugin: "kanban", host: "example.com"))
        do { _ = try await remote.uploadAttachment(taskId: "t", filename: "a", contentType: nil, data: Data(), board: nil); XCTFail("expected refusal") } catch {
            guard case PluginREST.Failure.refused = error else { return XCTFail("\(error)") }
        }
        let (api, _) = api(["POST /api/plugins/kanban/tasks/t_1/attachments":
                                .init(status: 413, json: #"{"detail":"attachment exceeds 25 MB limit \#(PluginStub.token)"}"#)])
        do { _ = try await api.uploadAttachment(taskId: "t_1", filename: "a", contentType: nil, data: Data("x".utf8), board: nil); XCTFail("expected 413") } catch {
            guard case PluginREST.Failure.http(413, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(detail.contains(PluginStub.token))
            XCTAssertFalse(String(describing: error).contains(PluginStub.token))
        }
    }

    // MARK: - download, delete

    func testDownloadReturnsTheBytesAndDeleteCallsTheRoute() async throws {
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF])
        let (api, port) = api([
            "GET /api/plugins/kanban/attachments/7": .init(data: bytes, contentType: "application/pdf"),
            "DELETE /api/plugins/kanban/attachments/7": .init(json: #"{"ok":true,"id":7}"#),
        ])
        let got = try await api.downloadAttachment(7, board: "b")
        XCTAssertEqual(got, bytes)
        try await api.deleteAttachment(7, board: "b")
        let seen = StubURLProtocol.requests(port: port)
        XCTAssertEqual(seen.map(\.method), ["GET", "DELETE"])
        XCTAssertEqual(seen[0].headers["Accept"], "*/*")
        XCTAssertTrue(seen.allSatisfy { PluginStub.query($0) == ["board": "b"] && $0.headers["X-Hermes-Session-Token"] == PluginStub.token })
    }

    func testMissingAttachmentIsA404AndAnOversizedDownloadIsRefused() async throws {
        let (api, port) = api(["DELETE /api/plugins/kanban/attachments/9": .init(status: 404, json: #"{"detail":"attachment not found"}"#),
                               "GET /api/plugins/kanban/attachments/5": .init(data: Data(count: 2048))])
        do { try await api.deleteAttachment(9, board: nil); XCTFail("expected 404") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .http(status: 404, detail: "attachment not found"))
        }
        do { _ = try await api.rest.download("/attachments/5", maxBytes: 1024); XCTFail("expected refusal") } catch {
            XCTAssertEqual(error as? PluginREST.Failure, .refused("download is larger than 1 KB"))
        }
        XCTAssertEqual(StubURLProtocol.requests(port: port).count, 2)
    }
}
