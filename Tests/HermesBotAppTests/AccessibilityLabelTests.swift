import Foundation
import XCTest

/// Live UI test 2026-11-06 (round 5): the Settings switches were AXCheckBox elements with empty labels, so
/// VoiceOver said only "checkbox". Every Toggle and Picker in the app now names itself with
/// `.accessibilityLabel` (the visible title is not reliably carried over in grouped forms, and `labelsHidden`
/// controls have no visible title at all).
///
/// A source check: SwiftUI builds its accessibility tree only for an assistive client, and the test runner is
/// not one (an in-process walk of a hosted Settings form finds the switches with no label either way).
final class AccessibilityLabelTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HermesBotApp")
    }

    private static func indent(_ line: Substring) -> Int { line.prefix { $0 == " " }.count }

    /// The control's expression: its line, then the lines indented deeper or continuing it at the same depth
    /// (`.modifier`, a closing brace or parenthesis).
    private static func expression(_ lines: [Substring], at i: Int) -> String {
        let base = indent(lines[i])
        var out = [lines[i]]
        for line in lines[(i + 1)...] {
            let trimmed = line.drop { $0 == " " }
            if trimmed.isEmpty { break }
            if indent(line) > base || [".", "}", ")"].contains(where: trimmed.hasPrefix) { out.append(line) } else { break }
        }
        return out.joined(separator: "\n")
    }

    func testEveryToggleAndPickerHasAnAccessibilityLabel() throws {
        let control = try NSRegularExpression(pattern: #"(?<![A-Za-z_.])(Toggle|Picker)\("#)
        let files = FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                let s = String(line)
                guard control.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil,
                      !s.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                checked += 1
                XCTAssertTrue(Self.expression(lines, at: i).contains(".accessibilityLabel("),
                              "\(file.lastPathComponent):\(i + 1) has no .accessibilityLabel: \(s.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(checked, 30, "the app's toggles and pickers were found")
    }

    func testEverySettingsSwitchNamesItsRow() throws {
        let rows: [(String, String)] = [
            ("SettingsSections.swift", "Animate interface changes"), ("SettingsSections.swift", "Show notifications"),
            ("SettingsSections.swift", "Keep Hermes running in the background"),
            ("Voice/VoiceViews.swift", "Read replies aloud automatically"),
            ("MacIntegration/MacIntegration.swift", "Show in menu bar"), ("MacIntegration/MacIntegration.swift", "Quick Ask shortcut"),
            ("Updates/UpdateViews.swift", "Check for updates automatically"),
        ]
        for (file, title) in rows {
            let text = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("Toggle(\"\(title)\""), "\(title) is a Settings switch")
            XCTAssertTrue(text.contains(".accessibilityLabel(\"\(title)\")"), "\(title): VoiceOver reads the row's title")
        }
    }
}
