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
    var streaming = false
    /// A semantic row ID protects a reused hosting view from briefly showing another message's result.
    var renderIdentity: String? = nil
    @StateObject private var rendering = MessageRenderState()

    init(text: String, mentions: Set<String> = [], streaming: Bool = false, renderIdentity: String? = nil) {
        self.text = text
        self.mentions = mentions
        self.streaming = streaming
        self.renderIdentity = renderIdentity
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.mentions == rhs.mentions && lhs.streaming == rhs.streaming
            && lhs.renderIdentity == rhs.renderIdentity
    }

    private var deferred: Bool { streaming || text.utf8.count > 2_048 }

    var body: some View {
        Group {
            if !deferred {
                prepared(PreparedMessageContent.parse(text))
            } else if let rendered = rendering.rendered, rendered.request.identity == renderIdentity {
                prepared(rendered.content)
            } else {
                // Cold rows remain fully readable while their first rich parse runs off the main actor.
                Text(verbatim: text)
                    .font(DS.Typeface.body).foregroundStyle(DS.Palette.ink)
                    .lineSpacing(DS.Typeface.proseLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.mentionHandles, mentions)
        // Model text is untrusted: a rendered link opens only as a web page, never a file, share or app scheme.
        .environment(\.openURL, OpenURLAction { url in Self.opensLink(url) ? .systemAction : .discarded })
        .onAppear { updateRendering() }
        .onChange(of: text) { _, _ in updateRendering() }
        .onChange(of: streaming) { _, _ in updateRendering() }
        .onChange(of: renderIdentity) { _, _ in updateRendering() }
        .onDisappear { rendering.cancel() }
    }

    private func updateRendering() {
        if deferred {
            rendering.request(MessageRenderRequest(text: text, identity: renderIdentity, streaming: streaming))
        } else {
            rendering.cancel()
        }
    }

    private func prepared(_ content: PreparedMessageContent) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if !content.blocks.isEmpty {
                // Links take the tint: blue, not the graphite app accent. Media chips keep theirs.
                MarkdownView(blocks: content.blocks).tint(DS.Palette.link)
            }
            if !content.media.isEmpty { MediaAttachmentList(refs: content.media) }
        }
    }

    /// Only http and https links in model output are opened (file:, smb:, custom schemes are dropped).
    nonisolated static func opensLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Display blocks with the MEDIA tags removed, plus the refs in order. Parsed once per body evaluation;
    /// `MediaTags.split` returns early for text without a tag, and half a tag mid-stream stays plain text.
    nonisolated static func content(_ text: String) -> (blocks: [MarkdownBlock], media: [MediaRef]) {
        let content = PreparedMessageContent.parse(text)
        return (content.blocks, content.media)
    }
}
