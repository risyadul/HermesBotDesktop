import AppKit
import SwiftUI
import XCTest
@testable import HermesBotApp

/// The monogram fallback drew white letters on a gradient lifted toward white,
/// which dropped below 4.5:1 (3.42:1 measured on teal). This renders the real `AvatarView` (no avatar
/// image loaded, so the monogram path) for every bot colour at every size that carries letters, and
/// measures the lightest tile pixel behind the glyphs in the actual bitmap, not the token swatch.
///
/// Measurement: the tile gradient is vertical, so within one pixel row the background is uniform and the
/// glyph (white) and its antialiasing are only ever lighter than it. The darkest pixel of a row, taken
/// over the columns clear of the rounded corners, is that row's background. The worst row is compared
/// with the brightest glyph pixel. Set HBA_TEST_ARTIFACTS=<dir> to also write the rendered sheet.
///
/// Pixels are read as raw bytes after drawing the render into an sRGB bitmap context (Core Graphics
/// colour-matches whatever space the render is in). `NSBitmapImageRep.colorAt(...).usingColorSpace(.sRGB)`
/// is not used: it returns calibrated (Generic RGB) colours and converting those to sRGB brightens them
/// (#1C7A82 drawn reads back as #1D8C94), which understates contrast.
@MainActor
final class AvatarContrastTests: XCTestCase {
    private let sizes: [CGFloat] = [
        DS.Size.avatarPass, DS.Size.avatarChip, DS.Size.avatarSuggestion, DS.Size.avatarRow,
        DS.Size.avatarMessage, DS.Size.avatarInspector, DS.Size.avatarEmpty,
    ]
    private let scale: CGFloat = 2

    override func setUp() async throws {
        try WindowTestGate.requireMetalRendering()
    }

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// Raw sRGB bytes (RGBA, premultiplied; the measured area is opaque).
    struct SRGBPixels {
        let width: Int, height: Int
        let bytes: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let o = (y * width + x) * 4
            return (Double(bytes[o]) / 255, Double(bytes[o + 1]) / 255, Double(bytes[o + 2]) / 255)
        }
    }

    static func srgbPixels(_ cg: CGImage) throws -> SRGBPixels {
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buf in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return SRGBPixels(width: w, height: h, bytes: bytes)
    }

    private func render(slot: Int, size: CGFloat) throws -> SRGBPixels {
        let identity = BotIdentity(profile: "contrast-fixture-\(slot)", title: "MW", slot: slot)
        let renderer = ImageRenderer(content: AvatarView(identity: identity, size: size).environment(\.colorScheme, .light))
        renderer.scale = scale
        let cg = try XCTUnwrap(renderer.cgImage, "render failed slot \(slot) size \(size)")
        return try Self.srgbPixels(cg)
    }

    /// Guards the reader itself: a flat token colour must read back as exactly that hex.
    func testPixelReaderReturnsTheDrawnSRGBValue() throws {
        let renderer = ImageRenderer(content: Rectangle().fill(Color(hex: 0x1C7A82)).frame(width: 4, height: 4))
        let px = try Self.srgbPixels(try XCTUnwrap(renderer.cgImage))
        let (r, g, b) = px.rgb(2, 2)
        XCTAssertEqual([Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())], [0x1C, 0x7A, 0x82])
    }

    func testWhiteMonogramKeepsNormalTextContrastOnEveryRenderedTile() throws {
        var report: [String] = []
        var worst = Double.infinity
        for slot in 0..<DS.Palette.bots.count {
            for size in sizes {
                let rep = try render(slot: slot, size: size)
                let px = Int((size * scale).rounded())
                XCTAssertEqual(rep.width, px)
                let inset = Int((AvatarView.radius(for: size) * scale).rounded()) + 1
                var lightestBackground = 0.0, brightestGlyph = 0.0, hex = ""
                for y in 1..<(rep.height - 1) {
                    var rowMin = Double.infinity, rowMinHex = ""
                    for x in inset..<(rep.width - inset) {
                        let (r, g, b) = rep.rgb(x, y)
                        let l = Self.luminance(r, g, b)
                        brightestGlyph = max(brightestGlyph, l)
                        if l < rowMin {
                            rowMin = l
                            rowMinHex = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
                        }
                    }
                    if rowMin > lightestBackground { lightestBackground = rowMin; hex = rowMinHex }
                }
                let ratio = Self.contrast(brightestGlyph, lightestBackground)
                worst = min(worst, ratio)
                report.append(String(format: "slot=%d size=%.0f lightest-bg=%@ glyph-L=%.3f contrast=%.2f", slot, size, hex, brightestGlyph, ratio))
                XCTAssertGreaterThan(brightestGlyph, 0.95, "glyph should render white (slot \(slot), size \(size))")
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "slot \(slot) size \(size): white on \(hex) is \(ratio):1")
            }
        }
        report.append(String(format: "worst=%.2f", worst))
        if let dir = ProcessInfo.processInfo.environment["HBA_TEST_ARTIFACTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try report.joined(separator: "\n").write(toFile: dir + "/avatar-contrast.txt", atomically: true, encoding: .utf8)
            try writeSheet(to: URL(fileURLWithPath: dir).appendingPathComponent("avatar-contrast-sheet.png"))
        }
    }

    private func writeSheet(to url: URL) throws {
        let sheet = VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(sizes, id: \.self) { size in
                HStack(spacing: DS.Space.s3) {
                    ForEach(0..<DS.Palette.bots.count, id: \.self) { slot in
                        AvatarView(identity: BotIdentity(profile: "contrast-fixture-\(slot)", title: "MW", slot: slot), size: size)
                    }
                }
            }
        }
        .padding(DS.Space.s4).background(Color.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = scale
        let cg = try XCTUnwrap(renderer.cgImage)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
