import AppKit
import HermesGatewayKit
import SwiftUI

// Bot identity (DESIGN.md "Bot identity colours", component `avatar`): a colour slot derived from the
// profile name, two-letter monogram, and the profile's own avatar image fetched at runtime with
// `profiles.get_asset {name, asset: "avatar"}`. Images are never bundled.

/// Profile name → colour slot. FNV-1a of the lowercased name picks a slot; within one roster, names are
/// placed in sorted order and a taken slot probes to the next free one, so up to eight bots never share
/// a colour and the result does not depend on server order.
enum IdentityPalette {
    static var slots: Int { DS.Palette.bots.count }

    static func hashSlot(_ name: String) -> Int {
        var h: UInt32 = 0x811C9DC5
        for b in name.lowercased().utf8 { h ^= UInt32(b); h = h &* 0x0100_0193 }
        return Int(h % UInt32(slots))
    }

    static func assign(_ names: [String]) -> [String: Int] {
        var out: [String: Int] = [:], taken = Set<Int>()
        for n in Set(names).sorted() {
            var s = hashSlot(n)
            if taken.count < slots { while taken.contains(s) { s = (s + 1) % slots } }
            taken.insert(s); out[n] = s
        }
        return out
    }
}

struct BotIdentity: Equatable {
    let profile: String
    let title: String
    let slot: Int

    var hex: UInt32 { DS.Palette.bots[slot] }
    /// Avatar tile / chip border: the base colour in both modes.
    var color: Color { Color(hex: hex) }
    /// Monogram gradient bottom stop: the base colour shaded 14% toward black. The gradient only ever
    /// darkens from the base, so the lightest pixel behind the white letters is the base colour itself
    /// (every base passes 5:1 with white) and contrast holds over the whole glyph area.
    var shaded: Color {
        Color(nsColor: NSColor(hex: hex).blended(withFraction: DS.Palette.monogramShade, of: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) ?? NSColor(hex: hex))
    }
    /// Member names: base colour in light; in dark the base mixed 45% with white (55% colour, DESIGN.md).
    var nameColor: Color {
        let base = NSColor(hex: hex)
        return Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? base.blended(withFraction: DS.Palette.nameLiftDark, of: .white) ?? base : base
        })
    }

    var monogram: String {
        let parts = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        let letters = parts.count >= 2 ? [parts[0].first, parts[1].first] : [title.first, title.dropFirst().first]
        return String(letters.compactMap { $0 }).uppercased()
    }
}

/// Avatar images per profile, fetched once per connection. `found: false` (no avatar) and failures both
/// leave the monogram in place.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var slots: [String: Int] = [:]
    private var requested: Set<String> = []

    func load(bots: [Bot], backend: Backend?) {
        slots = IdentityPalette.assign(bots.map(\.name))
        guard let backend else { return }
        for bot in bots where !requested.contains(bot.name) {
            requested.insert(bot.name)
            Task {
                do {
                    let r = try await backend.client.call("profiles.get_asset", ["name": .string(bot.name), "asset": "avatar"])
                    guard r["found"]?.bool == true, let url = r["data"]?.string, let comma = url.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                          let image = NSImage(data: data) else { return }
                    images[bot.name] = image
                } catch {
                    AppModel.shared.log("profiles.get_asset \(bot.name) failed: \(Redaction.describe(error))")
                }
            }
        }
    }

    func identity(profile: String, title: String? = nil) -> BotIdentity {
        BotIdentity(profile: profile, title: title ?? profile, slot: slots[profile] ?? IdentityPalette.hashSlot(profile))
    }
}

/// `avatar` component: pixel-art avatar over a 22% tint of the bot colour, cropped to the head; monogram
/// on a same-hue gradient when the profile has none.
struct AvatarView: View {
    let identity: BotIdentity
    var size: CGFloat = DS.Size.avatarRow
    @ObservedObject private var store = AvatarStore.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let image = store.images[identity.profile] {
                shape.fill(DS.Palette.window)
                shape.fill(identity.color.opacity(DS.Palette.avatarTint))
                headCrop(image)
            } else {
                shape.fill(LinearGradient(colors: [identity.color, identity.shaded], startPoint: .top, endPoint: .bottom))
                Text(identity.monogram)
                    .font(DS.Typeface.monogram(DS.Typeface.monogramSize(for: size)))
                    .foregroundStyle(DS.Palette.onBot)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var radius: CGFloat { AvatarView.radius(for: size) }

    /// Tiles of chip size and below (18-20 pt) use `rounded.avatar-small`.
    static func radius(for size: CGFloat) -> CGFloat {
        size <= DS.Size.avatarChip ? DS.Radius.avatarSmall : DS.Radius.avatar
    }

    /// Pixel art is scaled nearest-neighbour; a portrait (taller than wide, the Hermes pet frame) is
    /// zoomed to its upper part where the head is, a square image is shown whole with a small zoom.
    private func headCrop(_ image: NSImage) -> some View {
        let portrait = image.size.height > image.size.width * 1.02
        let zoom: CGFloat = portrait ? 1.75 : 1.18
        return Image(nsImage: image)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fill)
            .frame(width: size * zoom, height: size * zoom * (image.size.height / max(1, image.size.width)))
            .frame(width: size, height: size, alignment: portrait ? .top : .center)
            .offset(y: portrait ? size * 0.04 : 0)
    }
}

/// Room avatar for sidebar rows and the room toolbar: the first two members as 18 pt tiles, the second
/// offset 10 pt down-right inside the 28 pt slot. The back tile is cut out around the front one (a
/// transparent gap, not a stroke in a guessed background colour), so the pair reads cleanly over the
/// sidebar material and the toolbar alike, and neither tile is clipped by the slot.
struct RoomAvatarStack: View {
    let identities: [BotIdentity]
    var body: some View {
        let tile = DS.Size.stackTile, off = DS.Size.stackOffset, gap = DS.Size.stackCutout
        let ids = Array(identities.prefix(2))
        ZStack(alignment: .topLeading) {
            if let back = ids.first {
                AvatarView(identity: back, size: ids.count > 1 ? tile : DS.Size.avatarRow)
                    .mask {
                        if ids.count > 1 {
                            Rectangle()
                                .overlay(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: AvatarView.radius(for: tile) + gap, style: .continuous)
                                        .frame(width: tile + gap * 2, height: tile + gap * 2)
                                        .offset(x: off - gap, y: off - gap)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                        } else {
                            Rectangle()
                        }
                    }
            }
            if ids.count > 1 {
                AvatarView(identity: ids[1], size: tile).offset(x: off, y: off)
            }
        }
        .frame(width: DS.Size.avatarRow, height: DS.Size.avatarRow, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
