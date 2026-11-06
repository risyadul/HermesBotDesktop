import AppKit
import XCTest

/// Rasterize the complete window: NSHostingController layers inside a tall cell are not reliably
/// included in a standalone NSScrollView cacheDisplay capture. Crop chrome out after compositing.
enum TranscriptViewportPixels {
    static func pixelRect(screenRegion: CGRect, screenContent: CGRect, bitmap: NSBitmapImageRep) -> CGRect {
        let region = screenRegion.intersection(screenContent)
        let sx = CGFloat(bitmap.pixelsWide) / screenContent.width
        let sy = CGFloat(bitmap.pixelsHigh) / screenContent.height
        return CGRect(x: (region.minX - screenContent.minX) * sx,
                      y: (screenContent.maxY - region.maxY) * sy,
                      width: region.width * sx, height: region.height * sy)
    }

    static func contrast(_ bitmap: NSBitmapImageRep, in region: CGRect) -> CGFloat {
        let rect = region.intersection(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        var lightest: CGFloat = 0, darkest: CGFloat = 1
        for y in stride(from: Int(ceil(rect.minY)), to: Int(floor(rect.maxY)), by: 4) {
            for x in stride(from: Int(ceil(rect.minX)), to: Int(floor(rect.maxX)), by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                let light = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                lightest = max(lightest, light); darkest = min(darkest, light)
            }
        }
        return max(0, lightest - darkest)
    }
}

final class TranscriptViewportPixelTests: XCTestCase {
    func testBlankViewportCannotPassFromSidebarOrComposerText() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ink = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        let background = NSColor(deviceRed: 0.15, green: 0.15, blue: 0.15, alpha: 1)
        for y in 0..<200 {
            for x in 0..<300 {
                let jumpOverlay = x >= 120 && x < 200 && y >= 130 && y < 154
                let chrome = x < 50 || y < 30 || y >= 160 || jumpOverlay
                bitmap.setColor(chrome && (x / 4).isMultiple(of: 2) ? ink : background, atX: x, y: y)
            }
        }
        let screen = CGRect(x: 80, y: 100, width: 300, height: 200)
        let viewport = CGRect(x: 140, y: 175, width: 220, height: 85)
        let region = TranscriptViewportPixels.pixelRect(screenRegion: viewport, screenContent: screen, bitmap: bitmap)
        XCTAssertGreaterThan(TranscriptViewportPixels.contrast(bitmap, in: CGRect(x: 0, y: 0, width: 300, height: 200)), 0.15)
        XCTAssertEqual(TranscriptViewportPixels.contrast(bitmap, in: region), 0, accuracy: 0.001)
        for y in 48..<64 { for x in 80..<120 { bitmap.setColor(ink, atX: x, y: y) } }
        XCTAssertGreaterThan(TranscriptViewportPixels.contrast(bitmap, in: region), 0.15)
    }
}
