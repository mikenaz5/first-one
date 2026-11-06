import CoreGraphics
import ImageIO
import UIKit

// MARK: - Where the crop square sits on the picture

/// How a profile photo is moved and zoomed inside the square the person is cropping to. Pure arithmetic, so it is tested
/// without a screen.
///
/// The picture is shown at `scale` points per picture pixel. At zoom 1 it is as small as it can be while still covering the
/// whole crop square (so there are never empty edges); the person can zoom in up to `maxZoom` times that. `offset` is how far
/// the picture's centre has been dragged from the middle of the crop square, in points: right and down are positive.
struct CropGeometry: Equatable {
    /// How far in the person may zoom, as a multiple of the closest-fitting size.
    static let maxZoom: CGFloat = 5

    /// The picture's size in pixels.
    let imageSize: CGSize
    /// The side of the square being cropped to, in points.
    let cropSide: CGFloat

    init(imageSize: CGSize, cropSide: CGFloat) {
        self.imageSize = imageSize
        self.cropSide = max(cropSide, 1)
    }

    /// False for a picture with no size, which can't be cropped.
    var isUsable: Bool { imageSize.width >= 1 && imageSize.height >= 1 }

    /// Points per pixel at zoom 1: the smallest the picture can be and still cover the crop square.
    var coverScale: CGFloat {
        guard isUsable else { return 1 }
        return max(cropSide / imageSize.width, cropSide / imageSize.height)
    }

    func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, 1), Self.maxZoom)
    }

    func scale(atZoom zoom: CGFloat) -> CGFloat { coverScale * clampedZoom(zoom) }

    /// The picture's size on screen, in points.
    func displaySize(atZoom zoom: CGFloat) -> CGSize {
        let scale = scale(atZoom: zoom)
        return CGSize(width: max(imageSize.width, 1) * scale, height: max(imageSize.height, 1) * scale)
    }

    /// An offset pulled back so the picture still covers the crop square on every side.
    func clampedOffset(_ offset: CGSize, atZoom zoom: CGFloat) -> CGSize {
        let size = displaySize(atZoom: zoom)
        let limitX = max((size.width - cropSide) / 2, 0)
        let limitY = max((size.height - cropSide) / 2, 0)
        let x = offset.width.isFinite ? offset.width : 0
        let y = offset.height.isFinite ? offset.height : 0
        return CGSize(width: min(max(x, -limitX), limitX), height: min(max(y, -limitY), limitY))
    }

    /// The part of the picture inside the crop square, in picture pixels. Always a square that lies inside the picture.
    func sourceRect(atZoom zoom: CGFloat, offset: CGSize) -> CGRect {
        guard isUsable else { return .zero }
        let zoom = clampedZoom(zoom)
        let scale = scale(atZoom: zoom)
        let offset = clampedOffset(offset, atZoom: zoom)
        let side = min(cropSide / scale, min(imageSize.width, imageSize.height))
        let centreX = imageSize.width / 2 - offset.width / scale
        let centreY = imageSize.height / 2 - offset.height / scale
        let x = min(max(centreX - side / 2, 0), imageSize.width - side)
        let y = min(max(centreY - side / 2, 0), imageSize.height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

// MARK: - Reading and cutting the picture

/// A picture handed between tasks. `UIImage` is safe to read from anywhere once it exists, and nothing here changes it.
struct WorkingPhoto: @unchecked Sendable {
    let image: UIImage
}

enum PhotoCrop {
    /// The longest side, in pixels, of the picture the crop screen works on: enough detail to zoom into, small enough to
    /// stay quick.
    static let workingLongEdge: CGFloat = 2048
    /// The side, in pixels, of the finished square. It is never enlarged beyond what the chosen part of the photo holds.
    static let outputSide: CGFloat = 1024

    /// The photo upright (its camera rotation applied) and no bigger than `longEdge`. Nil when the data isn't a picture.
    static func workingPhoto(from data: Data, longEdge: CGFloat = workingLongEdge) -> WorkingPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return WorkingPhoto(image: UIImage(cgImage: image, scale: 1, orientation: .up))
    }

    /// Cuts `rect` (in the picture's pixels) out of the photo and returns it as a square JPEG no bigger than `maxSide`.
    static func croppedJPEG(
        from photo: WorkingPhoto,
        rect: CGRect,
        maxSide: CGFloat = outputSide,
        quality: CGFloat = 0.85
    ) -> Data? {
        guard let picture = photo.image.cgImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let pixels = rect.integral.intersection(bounds)
        guard pixels.width >= 1, pixels.height >= 1, let piece = picture.cropping(to: pixels) else { return nil }

        let side = max(1, min(maxSide, CGFloat(min(piece.width, piece.height))))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let rendered = UIGraphicsImageRenderer(size: square.size, format: format).image { _ in
            // A photo with see-through parts (a PNG) gets a white backing, since a JPEG can't be see-through.
            UIColor.white.setFill()
            UIRectFill(square)
            UIImage(cgImage: piece, scale: 1, orientation: .up).draw(in: square)
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
