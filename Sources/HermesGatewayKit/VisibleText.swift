import Foundation

/// Makes model- or backend-chosen text safe to show where the user decides something (approval commands,
/// request cards, file chip names). Pure, so it is tested without a view:
/// - characters that are invisible, blank-looking or reorder text are shown as `⟨U+XXXX⟩` (`isHidden`);
/// - more than `maxCombiningMarks` combining marks stacked on one base are all shown by code point (a
///   "zalgo" pile can paint over neighbouring lines);
/// - a run of more than `maxWhitespaceRun` horizontal whitespace characters (padding that pushes the
///   dangerous tail of a command off screen) is shown as `␠×N`;
/// - more than `maxBlankLines` blank lines in a row (pushing the tail below the fold) become `↵×N`.
/// Single newlines and tabs stay as they are.
public enum VisibleText {
    public static let maxWhitespaceRun = 8
    public static let maxCombiningMarks = 2
    public static let maxBlankLines = 3
    /// Blank-looking letters that are not whitespace: Braille blank, Hangul fillers.
    static let blankLookalikes: Set<UInt32> = [0x2800, 0x3164, 0x115F, 0x1160, 0xFFA0]

    /// True for a scalar that must be shown by its code point: C0 controls except `\n` and `\t`, DEL, C1
    /// controls, every format character (`Cf`: bidi marks / embeddings / overrides / isolates, zero-width
    /// characters, soft hyphen, tag characters, interlinear annotation, U+061C, U+180E…), every default
    /// ignorable code point (variation selectors, U+034F, U+2060–206F, U+FEFF…), the line / paragraph
    /// separators and blank-looking letters.
    public static func isHidden(_ v: UInt32) -> Bool {
        switch v {
        case 0x0A, 0x09: return false
        case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x2028, 0x2029: return true
        default:
            guard let s = Unicode.Scalar(v) else { return true }
            return s.properties.isDefaultIgnorableCodePoint || s.properties.generalCategory == .format
                || blankLookalikes.contains(v)
        }
    }

    static func isCombiningMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    static func codePoint(_ v: UInt32) -> String { "⟨U+" + String(format: "%04X", v) + "⟩" }

    public static func reveal(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.unicodeScalars.count)
        var space: [Unicode.Scalar] = []
        var marks: [Unicode.Scalar] = []
        func flushMarks() {
            if marks.count > maxCombiningMarks { marks.forEach { out += codePoint($0.value) } }
            else { out.unicodeScalars.append(contentsOf: marks) }
            marks = []
        }
        func flushSpace() {
            let newlines = space.filter { $0.value == 0x0A }.count
            if newlines > maxBlankLines + 1 {
                out += "\n↵×\(newlines)\n"
            } else {
                let lines = space.split(separator: Unicode.Scalar(0x0A), omittingEmptySubsequences: false)
                out += lines.map { seg in
                    seg.count > maxWhitespaceRun ? "␠×\(seg.count)" : String(String.UnicodeScalarView(seg))
                }.joined(separator: "\n")
            }
            space = []
        }
        for s in text.unicodeScalars {
            if !isHidden(s.value), s.properties.isWhitespace {
                flushMarks()
                space.append(s)
                continue
            }
            if !space.isEmpty { flushSpace() }
            if isCombiningMark(s), !isHidden(s.value) {
                marks.append(s)
                continue
            }
            flushMarks()
            if isHidden(s.value) { out += codePoint(s.value) } else { out.unicodeScalars.append(s) }
        }
        flushMarks()
        if !space.isEmpty { flushSpace() }
        return out
    }

    /// The DISPLAYED form of a command: `reveal`, then every line wrapped in LEFT-TO-RIGHT OVERRIDE …
    /// POP DIRECTIONAL FORMATTING so right-to-left letters cannot visually reorder its parts. Display only:
    /// what is answered or copied for the backend is never this string.
    public static func forcedLeftToRight(_ text: String) -> String {
        reveal(text).split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\u{202D}" + $0 + "\u{202C}" }.joined(separator: "\n")
    }

    /// True when `text` has any non-ASCII scalar (the approval card then says so).
    public static func hasNonASCII(_ text: String) -> Bool {
        text.unicodeScalars.contains { !$0.isASCII }
    }
}
