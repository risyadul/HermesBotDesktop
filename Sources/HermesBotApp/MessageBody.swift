import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - message body

/// Message text: inline markdown per paragraph, fenced code as `code-block` with horizontal scroll.
/// Falls back to the plain string when markdown parsing fails, so no text is ever lost. `MEDIA:<path>`
/// tags are lifted out of the text and shown below it as attachments (`MediaAttachmentList`).
struct MessageBody: View, Equatable {
    let text: String
    var body: some View {
        let content = Self.content(text)
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let s):
                    Text(Self.inline(s))
                        .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                        .lineSpacing(DS.Typeface.proseLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    CodeBlock(text: s)
                }
            }
            if !content.media.isEmpty {
                MediaAttachmentList(refs: content.media)
            }
        }
        // Model text is untrusted: a rendered link opens only as a web page, never a file, share or app scheme.
        .environment(\.openURL, OpenURLAction { url in Self.opensLink(url) ? .systemAction : .discarded })
    }

    /// Only http and https links in model output are opened (file:, smb:, custom schemes are dropped).
    nonisolated static func opensLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
        return scheme == "http" || scheme == "https"
    }

    enum Block: Equatable { case prose(String), code(String) }

    /// Display blocks with the MEDIA tags removed, plus the refs in order. Parsed once per body evaluation;
    /// `MediaTags.split` returns early for text without a tag, and half a tag mid-stream stays plain text.
    static func content(_ text: String) -> (blocks: [Block], media: [MediaRef]) {
        let parts = MediaTags.split(text)
        if parts.media.isEmpty { return (blocks(parts.text), []) }
        return (parts.text.isEmpty ? [] : blocks(parts.text), parts.media)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = [], prose: [Substring] = [], code: [Substring] = [], inCode = false
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.isEmpty { out.append(.prose(s)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] } else { flushProse() }
                inCode.toggle()
            } else if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { out.append(.code(code.joined(separator: "\n"))) }
        flushProse()
        return out.isEmpty ? [.prose(text)] : out
    }

    static func inline(_ s: String) -> AttributedString {
        // List markers read better as bullets; the rest is CommonMark inline (bold, italic, code, links).
        let bulleted = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.drop(while: { $0 == " " })
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return String(line.prefix(line.count - t.count)) + "•  " + t.dropFirst(2) }
            return String(line)
        }.joined(separator: "\n")
        var a = (try? AttributedString(markdown: bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = DS.Typeface.code
            a[run.range].backgroundColor = DS.Palette.surface
        }
        return a
    }
}

struct CodeBlock: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(DS.Typeface.code).foregroundStyle(DS.Palette.ink)
                .lineSpacing(DS.Typeface.codeLineSpacing)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, DS.Space.s3).padding(.vertical, DS.Space.gutter)
        }
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }
}
