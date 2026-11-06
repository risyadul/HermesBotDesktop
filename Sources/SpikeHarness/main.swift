import Foundation
import HermesGatewayKit

// Headless M0 harness: runs RoundTrip (RoundTrip.swift), printing a timestamped log and
// writing evidence (roundtrip.json + wire.log) to ./evidence/<stamp>/ (override: argv[1]).
// Exit 0 only when a bot reply AND turn.settled were read back through groups.log.

setvbuf(stdout, nil, _IOLBF, 0)
@Sendable func say(_ s: String) {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    print("[\(fmt.string(from: Date()))] \(s)")
}

var options = RoundTrip.Options()
let stamp = Int(Date().timeIntervalSince1970)
let evidence = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/\(stamp)")
options.evidenceDir = evidence

let rt = RoundTrip(options: options, log: say)
let code: Int32
do {
    let summary = try await rt.run()
    say("SUMMARY \(summary)")
    code = summary["ok"]?.bool == true ? 0 : 2
} catch {
    say("FAILED: \(Redaction.describe(error))")
    code = 1
}

// Defence in depth: the token lives in env, the ws URL and the backend's 0600 host-serve.token,
// never in our artifacts; make sure no evidence file holds it.
if let token = rt.serve?.sessionToken, !token.isEmpty {
    let files = [evidence.appendingPathComponent("roundtrip.json"), evidence.appendingPathComponent("wire.log"),
                 options.serve.logFile]
    for f in files {
        guard let s = try? String(contentsOf: f, encoding: .utf8), s.contains(token) else { continue }
        try? s.replacingOccurrences(of: token, with: "[REDACTED]").write(to: f, atomically: true, encoding: .utf8)
        say("redacted session token occurrences in \(f.lastPathComponent)")
    }
}
exit(code)
