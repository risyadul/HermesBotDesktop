import Foundation

/// E3: a semantic version as release tags and CFBundleShortVersionString write it: "1.2.3", "v1.2", "1",
/// "1.0.0-beta.2", "1.0.0+build.7". Missing minor/patch components count as 0; build metadata is ignored.
/// Ordering follows semver 2.0.0 §11: a pre-release sorts before its release, identifiers compare numerically
/// when both are numeric, numeric before alphanumeric, a shorter identifier list first when all else is equal.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    /// major, minor, patch.
    let core: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pre.allSatisfy(Self.isIdentifier) else { return nil }
            s = s[..<dash]
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy(\.isASCIIDigit), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        core = numbers + Array(repeating: 0, count: 3 - numbers.count)
        prerelease = pre
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, _): return false          // a release is never below its own pre-releases
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Self.number(x), Self.number(y)) {
            case let (m?, n?): return m < n
            case (.some, nil): return true    // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return x < y     // ASCII order
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    /// A numeric identifier: ASCII digits only (so "-5" stays alphanumeric).
    private static func number(_ s: String) -> Int? {
        s.allSatisfy(\.isASCIIDigit) ? Int(s) : nil
    }

    /// [0-9A-Za-z-]+, and no leading zero on a numeric identifier (semver §9), so that equal order means equal.
    private static func isIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") })
        else { return false }
        return number(s) == nil || s == "0" || !s.hasPrefix("0")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
