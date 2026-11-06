import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An uploaded avatar, prepared the way Hermes Desktop prepares one (`avatar-image.ts`): at most 15 MB on
/// disk (`pickImageFromDevice`), then the centred square cropped and scaled to 256 × 256 and encoded as PNG
/// (`normalizeAvatarImage`). Only PNG and JPEG are accepted (by their bytes, never the file name); the
/// gateway's own limit (`profiles.set_asset`, 2 MB, PNG/JPEG/WebP sniffed) is far above a 256 px PNG.
public enum ProfileAvatar {
    public static let maxBytes = 15_000_000
    public static let edge = 256
    /// A side longer than this is refused before any pixel is decoded: a few KB of PNG can declare a
    /// 100k × 100k canvas (a decompression bomb) that a full decode would try to allocate.
    public static let maxPixelSide = 16_384
    /// Decoding goes through ImageIO's thumbnailer capped at this edge, so the bitmap stays small.
    public static let decodeEdge = 4_096

    public enum Failure: Error, RedactionSafeError, Equatable {
        case tooLarge(Int)
        case tooManyPixels
        case notAnImage
        case unreadable

        public var description: String {
            switch self {
            case .tooLarge: return "The image is larger than 15 MB."
            case .tooManyPixels: return "The image is larger than 16384 pixels on a side."
            case .notAnImage: return "Choose a PNG or JPEG image."
            case .unreadable: return "The image could not be read."
            }
        }
    }

    public enum Format: Equatable { case png, jpeg }

    /// PNG or JPEG by magic bytes (`_ASSET_MAGIC` in `methods_profiles.py`).
    public static func format(_ data: Data) -> Format? {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.count >= 8, Array(data.prefix(8)) == png { return .png }
        if data.count >= 3, Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF] { return .jpeg }
        return nil
    }

    /// Reads a picked file with the size check first (a 2 GB file is never loaded).
    public static func read(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { throw Failure.tooLarge(size) }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return data
    }

    /// The 256 px PNG for `profiles.set_asset`.
    public static func normalize(_ data: Data) throws -> Data {
        if data.count > maxBytes { throw Failure.tooLarge(data.count) }
        guard format(data) != nil else { throw Failure.notAnImage }
        return try square(data)
    }

    /// A generated image (`image.generate` may answer WebP or another format ImageIO reads), as the same 256 px PNG.
    public static func normalizeGenerated(_ data: Data) throws -> Data { try square(data) }

    private static func square(_ data: Data) throws -> Data {
        if data.count > maxBytes { throw Failure.tooLarge(data.count) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let size = pixelSize(source)
        else { throw Failure.unreadable }
        guard size.width <= maxPixelSide, size.height <= maxPixelSide else { throw Failure.tooManyPixels }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: decodeEdge,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        let side = min(image.width, image.height)
        guard side > 0,
              let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                     width: side, height: side)),
              let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.unreadable }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        guard let scaled = context.makeImage() else { throw Failure.unreadable }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(dest, scaled, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable }
        return out as Data
    }

    /// The declared pixel size, read from the header without decoding.
    private static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// True when an image from elsewhere (a gateway avatar, a pet thumbnail) is safe to hand to `NSImage`:
    /// its header is readable and no side exceeds `maxPixelSide`.
    public static func isSafeToDecode(_ data: Data) -> Bool {
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = pixelSize(source) else { return false }
        return size.width <= maxPixelSide && size.height <= maxPixelSide
    }

    /// `data:image/png;base64,…` (or jpeg), as Desktop sends it.
    public static func dataURL(_ data: Data) -> String {
        let mime = format(data) == .jpeg ? "image/jpeg" : "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}
