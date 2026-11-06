// Draws Herald's app icon (a winged speech bubble on a graphite squircle) and writes an .iconset folder.
//
//   swift scripts/app-icon.swift <out.iconset>
//   iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
//
// scripts/make-icon.sh runs both. The committed Resources/AppIcon.icns is what scripts/package-app.sh bundles;
// rerun make-icon.sh after changing the drawing here.

import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// DESIGN.md: graphite chrome; the teal is status-ok, lifted for contrast on graphite.
let glyph = rgb(0xF2F2F4)
let accent = rgb(0x2FA3AD)
let graphiteTop = rgb(0x3A3A40)
let graphiteBottom = rgb(0x1D1D1F)

/// macOS icon grid: an 824-pt body centred on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185

func drawBackground(_ c: CGContext) {
    let shape = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    c.addPath(shape)
    c.setFillColor(graphiteBottom)
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(shape)
    c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [graphiteTop, graphiteBottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    let rim = body.insetBy(dx: 2, dy: 2)
    c.addPath(CGPath(roundedRect: rim, cornerWidth: bodyRadius - 2, cornerHeight: bodyRadius - 2, transform: nil))
    c.setStrokeColor(rgb(0xFFFFFF, 0.10))
    c.setLineWidth(4)
    c.strokePath()
    c.restoreGState()
}

/// A tapered, slightly curved feather from `root` to `tip`, round at the root.
func feather(_ root: CGPoint, _ tip: CGPoint, width w: CGFloat, bend: CGFloat) -> CGPath {
    let dx = tip.x - root.x, dy = tip.y - root.y
    let length = (dx * dx + dy * dy).squareRoot()
    let normal = CGPoint(x: -dy / length, y: dx / length)
    let mid = CGPoint(x: root.x + dx * 0.55, y: root.y + dy * 0.55)
    func offset(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + normal.x * d, y: p.y + normal.y * d) }
    let path = CGMutablePath()
    path.move(to: offset(root, w / 2))
    path.addQuadCurve(to: tip, control: offset(mid, w * 0.55 + bend))
    path.addQuadCurve(to: offset(root, -w / 2), control: offset(mid, -w * 0.45 + bend))
    path.addArc(center: root, radius: w / 2, startAngle: atan2(-normal.y, -normal.x),
                endAngle: atan2(normal.y, normal.x), clockwise: true)
    path.closeSubpath()
    return path
}

func point(from origin: CGPoint, degrees: CGFloat, length: CGFloat) -> CGPoint {
    CGPoint(x: origin.x + cos(degrees * .pi / 180) * length, y: origin.y + sin(degrees * .pi / 180) * length)
}

/// Three feathers sweeping back and up from `root`, the longest on top.
func drawWing(_ c: CGContext, root: CGPoint, scale s: CGFloat) {
    let feathers: [(degrees: CGFloat, length: CGFloat, width: CGFloat, rootOffset: CGFloat)] = [
        (152, 330, 74, 40), (170, 280, 66, -18), (188, 215, 58, -72),
    ]
    c.setFillColor(glyph)
    for f in feathers {
        let r = CGPoint(x: root.x, y: root.y + f.rootOffset * s)
        c.addPath(feather(r, point(from: r, degrees: f.degrees, length: f.length * s), width: f.width * s, bend: 26 * s))
        c.fillPath()
    }
}

/// The speech bubble and its tail, filled one after the other so their windings never cancel.
func drawBubble(_ c: CGContext, _ r: CGRect, radius: CGFloat) {
    c.setFillColor(glyph)
    c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.fillPath()
    let x0 = r.minX + r.width * 0.20
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: x0, y: r.minY + 40))
    tail.addLine(to: CGPoint(x: x0 + r.width * 0.24, y: r.minY + 40))
    tail.addQuadCurve(to: CGPoint(x: x0 - r.width * 0.05, y: r.minY - r.height * 0.20),
                      control: CGPoint(x: x0 + r.width * 0.10, y: r.minY - r.height * 0.08))
    tail.addQuadCurve(to: CGPoint(x: x0, y: r.minY + 40),
                      control: CGPoint(x: x0 + r.width * 0.02, y: r.minY - r.height * 0.04))
    tail.closeSubpath()
    c.addPath(tail)
    c.fillPath()
}

/// The icon at 1024 × 1024. Below 64 px the typing dots are dropped: they would blur into the bubble.
func drawIcon(_ c: CGContext, showDots: Bool) {
    drawBackground(c)
    let bubble = CGRect(x: 395, y: 330, width: 410, height: 330)
    drawWing(c, root: CGPoint(x: 440, y: 560), scale: 0.95)
    drawBubble(c, bubble, radius: 110)
    guard showDots else { return }
    c.setFillColor(accent)
    for i in 0..<3 {
        c.addEllipse(in: CGRect(x: bubble.midX - 95 + CGFloat(i) * 75, y: bubble.midY - 22, width: 44, height: 44))
    }
    c.fillPath()
}

func render(pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(c, showDots: pixels >= 64)
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasSuffix(".iconset") else {
    FileHandle.standardError.write(Data("usage: swift scripts/app-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: dir.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: dir.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("wrote \(dir.path)")
