import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One image the user attached to an Explain window, made smaller for the
/// model. It lives only in memory; Gantry does not save it.
public struct ExplainImage: Identifiable, @unchecked Sendable, Equatable {
    public let id: UUID
    public let name: String
    /// Upright, with the longer side at most `ExplainImageLimits.maxPixelSide`.
    public let cgImage: CGImage

    public init(id: UUID = UUID(), name: String, cgImage: CGImage) {
        self.id = id
        self.name = name
        self.cgImage = cgImage
    }

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }

    public static func == (a: ExplainImage, b: ExplainImage) -> Bool {
        a.id == b.id
    }
}

/// How many images, how big a file and how many pixels the model gets.
public enum ExplainImageLimits {
    public static let maxCount = 3
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxPixelSide = 1024

    public static var maxMegabytes: Int { maxBytes / (1024 * 1024) }
}

/// Why Gantry did not add an item.
public enum ExplainImageRejection: Error, Sendable, Equatable {
    case tooMany(limit: Int)
    case tooLarge(limitMB: Int)
    case notAnImage

    public var message: String {
        switch self {
        case .tooMany(let limit):
            String(localized: "You can attach up to \(limit) images.", bundle: .module)
        case .tooLarge(let limitMB):
            String(localized: "The image is larger than \(limitMB) MB.", bundle: .module)
        case .notAnImage:
            String(localized: "This file is not an image.", bundle: .module)
        }
    }
}

/// What the user gave: a file, or image data from the clipboard or a drop.
public enum ExplainImageSource: Sendable {
    case file(URL)
    case data(Data, name: String)
}

/// Reads an image, checks the limits and makes it smaller.
public enum ExplainImagePreparer {
    /// The name of an image without a file, for example a pasted one.
    public static var pastedName: String {
        String(localized: "Pasted Image", bundle: .module)
    }

    public static func prepare(_ source: ExplainImageSource) throws(ExplainImageRejection) -> ExplainImage {
        switch source {
        case .file(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > ExplainImageLimits.maxBytes {
                throw .tooLarge(limitMB: ExplainImageLimits.maxMegabytes)
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw .notAnImage }
            return try prepare(data: data, name: url.lastPathComponent)
        case .data(let data, let name):
            return try prepare(data: data, name: name)
        }
    }

    public static func prepare(data: Data, name: String) throws(ExplainImageRejection) -> ExplainImage {
        guard data.count <= ExplainImageLimits.maxBytes else {
            throw .tooLarge(limitMB: ExplainImageLimits.maxMegabytes)
        }
        guard let image = downscale(data, maxPixelSide: ExplainImageLimits.maxPixelSide) else {
            throw .notAnImage
        }
        return ExplainImage(name: name, cgImage: image)
    }

    /// Decodes at the reduced size and applies the orientation. A small
    /// image keeps its size.
    public static func downscale(_ data: Data, maxPixelSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let side = min(maxPixelSide, max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Adds prepared items to `existing` up to the count limit. Returns the
    /// new list and the first rejection, if any.
    public static func adding(
        _ sources: [ExplainImageSource],
        to existing: [ExplainImage]
    ) -> (images: [ExplainImage], rejection: ExplainImageRejection?) {
        var images = existing
        var rejection: ExplainImageRejection?
        for source in sources {
            guard images.count < ExplainImageLimits.maxCount else {
                rejection = rejection ?? .tooMany(limit: ExplainImageLimits.maxCount)
                break
            }
            do {
                images.append(try prepare(source))
            } catch {
                rejection = rejection ?? error
            }
        }
        return (images, rejection)
    }
}
