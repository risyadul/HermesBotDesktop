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
    /// Roster-unique monogram (`Monogram.assign`); nil = the title's own two letters.
    var uniqueMonogram: String? = nil

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

    var monogram: String { uniqueMonogram ?? Monogram.base(title) }
}

/// Two-letter monograms, unique within one roster. Only letters and digits count: the base is the first
/// characters of the first two words (or the first two of one word; a one-character title doubles it,
/// "R" → RR). Bots whose bases collide ("reviewer", "researcher" → RE) each take their first letter plus
/// the first letter after the prefix they share ("RV", "RS"), moving on to later letters when that pair
/// is taken. Deterministic: names are placed in sorted profile order.
enum Monogram {
    static func base(_ title: String) -> String {
        let words = title.split(whereSeparator: { !isMonogramCharacter($0) }).map { $0.map(upper) }
        guard let first = words.first?.first else { return "?" }
        let second = words.count >= 2 ? words[1][0] : words[0].dropFirst().first ?? first
        return String([first, second])
    }

    private static func isMonogramCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// One character in, one out: "ß" uppercases to "SS", which would make a three-letter monogram.
    private static func upper(_ c: Character) -> Character { String(c).uppercased().first ?? c }

    /// `bots`: (profile, title). Returns profile → monogram.
    static func assign(_ bots: [(profile: String, title: String)]) -> [String: String] {
        var titles: [String: String] = [:]
        for b in bots where titles[b.profile] == nil { titles[b.profile] = b.title }
        let profiles = titles.keys.sorted()
        let bases = Dictionary(uniqueKeysWithValues: profiles.map { ($0, base(titles[$0]!)) })
        let groups = Dictionary(grouping: profiles, by: { bases[$0]! })
        var out: [String: String] = [:]
        var taken = Set(groups.filter { $0.value.count == 1 }.keys)
        for p in profiles where out[p] == nil {
            guard let group = groups[bases[p]!], group.count > 1 else { out[p] = bases[p]; continue }
            let letters = group.map { titles[$0]!.filter(isMonogramCharacter).map(upper) }
            let shared = sharedPrefix(letters)
            for (member, chars) in zip(group, letters) {
                let first = chars.first.map(String.init) ?? "?"
                // Letters after the shared prefix first, then the shared ones (a title that is a prefix of another).
                let start = max(shared, 1)
                let picks = Array(chars.indices.dropFirst(start)) + Array(chars.indices.dropFirst().prefix(start - 1))
                let pick = picks.lazy.map { first + String(chars[$0]) }.first { !taken.contains($0) }
                    ?? (1...).lazy.map { first + "\($0)" }.first { !taken.contains($0) }!
                taken.insert(pick)
                out[member] = pick
            }
        }
        return out
    }

    private static func sharedPrefix(_ words: [[Character]]) -> Int {
        guard let shortest = words.map(\.count).min() else { return 0 }
        var i = 0
        while i < shortest, Set(words.map { $0[i] }).count == 1 { i += 1 }
        return i
    }
}

/// Avatar images per profile, fetched once per connection. `found: false` (no avatar) and failures both
/// leave the monogram in place.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var slots: [String: Int] = [:]
    @Published private(set) var monograms: [String: String] = [:]
    private var requested: Set<String> = []

    /// New connection: forget which avatars were requested, so the next `load` retries failed ones.
    func reset() { requested = [] }

    func load(bots: [Bot], backend: Backend?) {
        slots = IdentityPalette.assign(bots.map(\.name))
        monograms = Monogram.assign(bots.map { (profile: $0.name, title: $0.title) })
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

    /// A saved avatar (Edit sheet) shows at once; nil forgets it (removed, or the bot was deleted).
    func replace(_ profile: String, data: Data?) {
        images[profile] = data.flatMap(NSImage.init(data:))
    }

    func identity(profile: String, title: String? = nil) -> BotIdentity {
        BotIdentity(profile: profile, title: title ?? profile, slot: slots[profile] ?? IdentityPalette.hashSlot(profile),
                    uniqueMonogram: monograms[profile])
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
