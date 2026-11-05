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

    public enum Failure: Error, RedactionSafeError, Equatable {
        case tooLarge(Int)
        case notAnImage
        case unreadable

        public var description: String {
            switch self {
            case .tooLarge: return "The image is larger than 15 MB."
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.unreadable }
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

    /// `data:image/png;base64,…` (or jpeg), as Desktop sends it.
    public static func dataURL(_ data: Data) -> String {
        let mime = format(data) == .jpeg ? "image/jpeg" : "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}
