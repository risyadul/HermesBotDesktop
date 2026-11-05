import AppKit
import HermesGatewayKit
import SwiftUI

// MARK: - message body

/// Message text as markdown blocks (`MarkdownBlock` / `MarkdownView`: headings, lists, quotes, GFM
/// tables, fenced code). `MEDIA:<path>` tags are lifted out of the text and shown below it as attachments
/// (`MediaAttachmentList`).
struct MessageBody: View, Equatable {
    let text: String
    /// Room member handles whose @mentions are highlighted (Group Chat); empty in Bot Chat.
    var mentions: Set<String> = []
    var body: some View {
        let content = Self.content(text)
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if !content.blocks.isEmpty {
                // Links take the tint: blue, not the graphite app accent. Media chips keep theirs.
                MarkdownView(blocks: content.blocks).tint(DS.Palette.link)
            }
            if !content.media.isEmpty {
                MediaAttachmentList(refs: content.media)
            }
        }
        .environment(\.mentionHandles, mentions)
        // Model text is untrusted: a rendered link opens only as a web page, never a file, share or app scheme.
        .environment(\.openURL, OpenURLAction { url in Self.opensLink(url) ? .systemAction : .discarded })
    }

    /// Only http and https links in model output are opened (file:, smb:, custom schemes are dropped).
    nonisolated static func opensLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Display blocks with the MEDIA tags removed, plus the refs in order. Parsed once per body evaluation;
    /// `MediaTags.split` returns early for text without a tag, and half a tag mid-stream stays plain text.
    static func content(_ text: String) -> (blocks: [MarkdownBlock], media: [MediaRef]) {
        let parts = MediaTags.split(text)
        if parts.media.isEmpty { return (MarkdownBlock.parse(text), []) }
        return (parts.text.isEmpty ? [] : MarkdownBlock.parse(parts.text), parts.media)
    }
}
