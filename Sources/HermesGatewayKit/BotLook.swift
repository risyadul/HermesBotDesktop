import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bot's shape avatar in Hermes Desktop's vocabulary (`avatar.tsx`, `avatar-picker.tsx`, `types.ts` `BotMeta`),
/// so both apps read and write the same `ui_meta["hermes-bots"]` fields:
/// - `shape`: one of Desktop's picker shapes (`AVATAR_PICKER_SHAPES`); `color`: a CSS colour (`hsl(h 68% 58%)` from
///   Desktop's swatches), absent = the name's own hue (`profileColor`); `imageKind`: `"shape"` or `"photo"`;
///   `custom: true` once the user picked a look (Desktop's `editedLook`).
/// - The face is drawn the way Desktop's `BotFace` draws its static frame (outline from `sampleFaceRing`, two eyes
///   and catchlights in a 40 × 44 box) and pushed as a 160 px PNG with `profiles.set_asset`, exactly like Desktop's
///   roster backfill (`profile-ops.ts` `pushLocalAvatars`). Desktop recognises a 160 × 160 PNG as that face raster
///   (`isBackfilledFacePng`) and keeps drawing the live shape from `ui_meta`; this app shows the raster.
/// Desktop's name-seeded "blobatar" faces come from a library this app cannot reproduce, so they are not offered.
public enum BotLook {
    /// Desktop's `AVATAR_PICKER_SHAPES`.
    public static let shapes = ["circle", "blob", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"]
    /// Desktop's `AVATAR_SHAPES` (what `defaultShapeFor` picks from).
    static let defaultShapes = ["circle", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"]
    /// The face raster's edge (`rasterizeSvgToPng(svg, 160)`).
    public static let faceEdge = 160
    /// Desktop's `PRIMARY_AVATAR_COLOR`.
    public static let primaryColor = "#8b5cf6"
    static let saturation = 68
    static let lightness = 58

    // MARK: colour

    /// Desktop's `PROFILE_SWATCHES`: twelve hues at the deterministic palette's saturation and lightness.
    public static let swatches: [String] = (0..<12).map { "hsl(\($0 * 30) \(saturation)% \(lightness)%)" }

    /// Desktop's `profileColor`: the name's hue, nil for an empty name or `default`.
    public static func profileColor(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "default" else { return nil }
        var hash: UInt32 = 0
        for unit in key.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return "hsl(\(hash % 360) \(saturation)% \(lightness)%)"
    }

    /// Desktop's `avatarColor`: a picked colour wins, else the name's hue, else the primary violet.
    public static func color(_ picked: String?, name: String) -> String {
        if let picked, !picked.isEmpty { return picked }
        return profileColor(name) ?? primaryColor
    }

    /// Desktop's `defaultShapeFor`.
    public static func defaultShape(for name: String) -> String {
        var hash: UInt32 = 0
        for scalar in name.unicodeScalars { hash = hash &* 31 &+ UInt32(String(scalar).utf16.first ?? 0) }
        return defaultShapes[Int(hash % UInt32(defaultShapes.count))]
    }

    /// sRGB components 0...255 of `#rgb`, `#rrggbb` or `hsl(h s% l%)` (commas allowed); nil for anything else.
    public static func rgb(_ css: String) -> (r: Double, g: Double, b: Double)? {
        let s = css.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
            return (Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255))
        }
        guard s.hasPrefix("hsl(") && s.hasSuffix(")") else { return nil }
        let parts = s.dropFirst(4).dropLast().split(whereSeparator: { $0 == " " || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "%deg")) }
        guard parts.count >= 3, let h = Double(parts[0]), let sat = Double(parts[1]), let light = Double(parts[2]) else { return nil }
        return hsl(h, sat / 100, light / 100)
    }

    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
        let a = s * min(l, 1 - l)
        func f(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return (l - a * max(-1, min(k - 3, 9 - k, 1))) * 255
        }
        return (f(0), f(8), f(4))
    }

    /// Desktop's `isDarkColor`, quirk included: it parses the colour as hex after the first character, so an
    /// `hsl(…)` colour reads as 0 and counts as dark (Desktop draws cream eyes on every swatch colour).
    public static func isDark(_ css: String) -> Bool {
        let digits = css.dropFirst().prefix { $0.isHexDigit }.prefix(16)
        let n = UInt64(digits, radix: 16).map { UInt32(truncatingIfNeeded: $0) } ?? 0
        let r = Double((n >> 16) & 255), g = Double((n >> 8) & 255), b = Double(n & 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 110
    }

    // MARK: face geometry (Desktop's 40 × 44 face box)

    /// Desktop's `sampleFaceRing` for the picker shapes: the face outline, in the 40 × 40 part of the box.
    public static func ring(_ shape: String, steps: Int = 52) -> [CGPoint] {
        switch shape {
        case "drop", "teardrop": return dropRing(steps)
        case "cloud": return cloudRing(steps)
        default: break
        }
        return (0..<steps).map { i in
            let a = Double(i) / Double(steps) * .pi * 2 - .pi / 2
            let c = cos(a), s = sin(a)
            var r = 16.2
            switch shape {
            case "blob": r = 16 + 1.7 * sin(3 * a) + 0.7 * cos(5 * a)
            case "squircle": r = 16.2 / nonZero(pow(pow(abs(c), 5) + pow(abs(s), 5), 1.0 / 5))
            case "pill": r = 16 / nonZero(pow(pow(abs(c), 8) + pow(abs(s / 0.72), 8), 1.0 / 8))
            case "triangle":
                let u = (a + .pi / 2 + .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
                let sector = (u / (.pi * 2 / 3)).truncatingRemainder(dividingBy: 1)
                r = 13.5 / max(0.42, cos((sector - 0.5) * 1.9))
            case "hexagon":
                let seg = Double.pi / 3
                r = 16.2 * (cos(seg / 2) / cos(a - seg * (a / seg).rounded(.toNearestOrAwayFromZero)))
            default: break
            }
            return CGPoint(x: 20 + r * c, y: 20 + r * s)
        }
    }

    private static func nonZero(_ d: Double) -> Double { d == 0 ? 1 : d }

    private static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private static func dropRing(_ steps: Int) -> [CGPoint] {
        let n = max(8, steps / 3)
        var pts: [CGPoint] = []
        for i in 0..<n {
            pts.append(cubic(CGPoint(x: 20, y: 3), CGPoint(x: 20, y: 3), CGPoint(x: 6, y: 20), CGPoint(x: 6, y: 27), Double(i) / Double(n)))
        }
        for i in 0...n {
            let t = Double(i) / Double(n) * .pi
            pts.append(CGPoint(x: 20 - 14 * cos(t), y: 27 + 13.5 * sin(t)))
        }
        for i in 1...n {
            pts.append(cubic(CGPoint(x: 34, y: 27), CGPoint(x: 34, y: 20), CGPoint(x: 20, y: 3), CGPoint(x: 20, y: 3), Double(i) / Double(n)))
        }
        return pts
    }

    struct Arc { let cx, cy, rx, ry, theta1, dtheta: Double }

    /// Desktop's `svgArc`: an SVG endpoint arc in centre form.
    static func arc(_ x1: Double, _ y1: Double, _ rx0: Double, _ ry0: Double, _ fa: Int, _ fs: Int,
                    _ x2: Double, _ y2: Double) -> Arc {
        var rx = rx0, ry = ry0
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        var rx2 = rx * rx, ry2 = ry * ry
        let lam = dx * dx / rx2 + dy * dy / ry2
        if lam > 1 { let s = lam.squareRoot(); rx *= s; ry *= s; rx2 = rx * rx; ry2 = ry * ry }
        let num = rx2 * ry2 - rx2 * dy * dy - ry2 * dx * dx
        let den = rx2 * dy * dy + ry2 * dx * dx
        var sq = max(0, num / den).squareRoot()
        if fa == fs { sq = -sq }
        let cx = sq * (rx * dy / ry) + (x1 + x2) / 2
        let cy = sq * (-ry * dx / rx) + (y1 + y2) / 2
        func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let n = hypot(ux, uy) * hypot(vx, vy)
            var a = acos(max(-1, min(1, (ux * vx + uy * vy) / (n == 0 ? 1 : n))))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = ang(1, 0, (x1 - cx) / rx, (y1 - cy) / ry)
        var dtheta = ang((x1 - cx) / rx, (y1 - cy) / ry, (x2 - cx) / rx, (y2 - cy) / ry)
        if fs == 0 && dtheta > 0 { dtheta -= .pi * 2 }
        if fs != 0 && dtheta < 0 { dtheta += .pi * 2 }
        return Arc(cx: cx, cy: cy, rx: rx, ry: ry, theta1: theta1, dtheta: dtheta)
    }

    private static func sample(_ a: Arc, _ n: Int) -> [CGPoint] {
        (0..<n).map { i in
            let th = a.theta1 + a.dtheta * Double(i) / Double(n)
            return CGPoint(x: a.cx + a.rx * cos(th), y: a.cy + a.ry * sin(th))
        }
    }

    private static func cloudRing(_ steps: Int) -> [CGPoint] {
        let a1 = arc(11, 32, 7.5, 7.5, 0, 1, 10, 17.1)
        let a2 = arc(10, 17.1, 9.5, 9.5, 0, 1, 29, 12.5)
        let a3 = arc(29, 12.5, 7, 7, 0, 1, 30, 32)
        let l1 = abs(a1.dtheta) * a1.rx, l2 = abs(a2.dtheta) * a2.rx, l3 = abs(a3.dtheta) * a3.rx, l4 = 19.0
        let total = l1 + l2 + l3 + l4
        let n = max(64, steps)
        let n1 = max(8, Int((Double(n) * l1 / total).rounded()))
        let n2 = max(10, Int((Double(n) * l2 / total).rounded()))
        let n3 = max(10, Int((Double(n) * l3 / total).rounded()))
        let n4 = max(4, n - n1 - n2 - n3)
        var pts = sample(a1, n1) + sample(a2, n2) + sample(a3, n3)
        for i in 0..<n4 { pts.append(CGPoint(x: 30 + (11 - 30) * Double(i) / Double(n4), y: 32)) }
        return pts
    }

    /// The idle eye line (`eyeY0`): the cloud's body sits lower.
    static func eyeLine(_ shape: String) -> Double { shape == "cloud" ? 22 : 17.2 }

    // MARK: rendering

    /// The face as Desktop's `BotFace` draws its idle frame, in an `edge`-pixel square (the 40 × 44 box fitted in,
    /// centred horizontally like an SVG `meet`), transparent around it. Nil only if CoreGraphics fails.
    public static func render(shape: String, color: String?, name: String, edge: Int = faceEdge) -> CGImage? {
        let css = self.color(color, name: name)
        guard edge > 0, let body = rgb(css),
              let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let side = Double(edge), scale = side / 44
        ctx.translateBy(x: (side - 40 * scale) / 2, y: side)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)
        let outline = ring(shape)
        if let first = outline.first {
            ctx.move(to: first)
            for p in outline.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
            ctx.setFillColor(red: body.r / 255, green: body.g / 255, blue: body.b / 255, alpha: 1)
            ctx.fillPath()
        }
        let dark = isDark(css)
        let y = eyeLine(shape)
        // Eyes: cream on dark bodies, near-black otherwise; catchlights flip with them.
        if dark { ctx.setFillColor(red: 232 / 255, green: 220 / 255, blue: 195 / 255, alpha: 0.95) } else {
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.85)
        }
        for x in [15.4, 24.6] { ctx.fillEllipse(in: CGRect(x: x - 2.2, y: y - 2.3, width: 4.4, height: 4.6)) }
        if dark { ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.6) } else { ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.85) }
        for x in [14.8, 24.0] { ctx.fillEllipse(in: CGRect(x: x - 0.65, y: y - 0.7 - 0.65, width: 1.3, height: 1.3)) }
        return ctx.makeImage()
    }

    /// The 160 px PNG for `profiles.set_asset` (Desktop's face raster size).
    public static func facePNG(shape: String, color: String?, name: String) -> Data? {
        guard let image = render(shape: shape, color: color, name: name) else { return nil }
        return png(image)
    }

    static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Desktop's `isBackfilledFacePng`: a 160 × 160 PNG is a face raster, not a picture.
    public static func isFaceRaster(_ data: Data) -> Bool {
        guard ProfileAvatar.format(data) == .png, data.count >= 24 else { return false }
        let b = [UInt8](data.prefix(24))
        let w = UInt32(b[16]) << 24 | UInt32(b[17]) << 16 | UInt32(b[18]) << 8 | UInt32(b[19])
        let h = UInt32(b[20]) << 24 | UInt32(b[21]) << 16 | UInt32(b[22]) << 8 | UInt32(b[23])
        return w == UInt32(faceEdge) && h == UInt32(faceEdge)
    }

    // MARK: ui_meta

    /// A `ui_meta["hermes-bots"]` change: fields laid over the server's namespace, and keys taken out of it
    /// (Desktop writes `color: undefined` for "match the name", which drops the key from the written object).
    public struct Patch: Sendable, Equatable {
        public var fields: [String: JSONValue]
        public var removing: Set<String>

        public init(fields: [String: JSONValue] = [:], removing: Set<String> = []) {
            self.fields = fields; self.removing = removing
        }
    }

    /// The Edit sheet's shape pick (Desktop's `editedLook` with shape and colour changed).
    public static func shapePatch(shape: String, color: String?) -> Patch {
        var fields: [String: JSONValue] = ["shape": .string(shape), "imageKind": "shape", "custom": true]
        if let color { fields["color"] = .string(color) }
        return Patch(fields: fields, removing: color == nil ? ["color"] : [])
    }

    /// The Edit sheet's image change (`editedLook`: `imageKind` follows the image; the image itself is an asset).
    public static func imagePatch(hasImage: Bool) -> Patch {
        Patch(fields: ["imageKind": .string(hasImage ? "photo" : "shape"), "custom": true])
    }

    /// New Bot's look, as Desktop's create dialog saves it: `{shape, color?, imageKind, title, created}`.
    public static func createPatch(shape: String?, color: String?, hasImage: Bool, title: String, created: Date) -> Patch {
        var fields: [String: JSONValue] = ["imageKind": .string(hasImage ? "photo" : "shape"), "title": .string(title),
                                           "created": .number((created.timeIntervalSince1970 * 1000).rounded())]
        if let shape { fields["shape"] = .string(shape) }
        if let color { fields["color"] = .string(color) }
        return Patch(fields: fields)
    }

    /// `BotMetaSync.save` with removals: read the current namespace, lay the patch over it, drop `removing`, and
    /// write with the CAS revision (up to `BotMetaSync.attempts` reads on a conflict).
    public static func save(name: String, patch: Patch, call: BotMetaSync.Call) async throws -> BotMetaSync.Outcome {
        for _ in 0..<BotMetaSync.attempts {
            let list = try await call("profiles.list", ["include_sessions": false])
            guard let row = (list["profiles"]?.array ?? []).first(where: { $0["name"]?.string == name }) else {
                return .notFound
            }
            let server = BotMetaSync.serverMeta(row: row)
            let fields = BotMetaSync.merged(server.fields, patch: patch.fields).filter { !patch.removing.contains($0.key) }
            let result = try await call("profiles.configure",
                                        BotMetaSync.configureParams(name: name, fields: fields, revision: server.revision))
            if let conflicts = result["applied"]?["ui_meta_conflicts"], conflicts != .null { continue }
            guard let applied = result["applied"], applied.object != nil else { return .unsupported }
            guard applied["ui_meta"]?.bool == true else { return .failed }
            return .persisted(BotUIMeta(row: ["ui_meta": .object([BotMetaSync.namespace: .object(fields)])]))
        }
        return .failed
    }
}
