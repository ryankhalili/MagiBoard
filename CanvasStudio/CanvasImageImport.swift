import UIKit
import ImageIO

/// Decode bounded pixel data, including HEIC and rotated camera photos, without
/// creating a full-resolution intermediate bitmap on the main canvas.
enum CanvasImageImport {
    static func object(from data: Data, title: String, viewport: CanvasRect) throws -> CanvasObject {
        guard !data.isEmpty, data.count <= 80_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw NotebookError.invalid("This image could not be opened. Choose a supported photo or image under 80 MB.")
        }
        let image = UIImage(cgImage: cgImage)
        guard let encoded = image.pngData(), encoded.count <= 20_000_000 else {
            throw NotebookError.invalid("The decoded image is too large. Export a smaller image and try again.")
        }
        let width = min(500, Double(cgImage.width))
        let object = CanvasObject(kind: "image", title: String(title.prefix(200)),
                                  x: viewport.x + 100, y: viewport.y + 180,
                                  width: width, height: max(1, width * Double(cgImage.height) / Double(cgImage.width)), imageData: encoded)
        try NotebookValidation.validate(object)
        return object
    }
}
