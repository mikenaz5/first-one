import AVFoundation
import ImageIO
import UIKit

/// Makes the small copy of a photo or video that goes to the client, and reads the facts about the original.
///
/// The first delivery's copy is reduced and carries a "PREVIEW" watermark across it, because the client sees it before paying.
/// A revision is never locked, so its copy is only the small picture a grid tile needs. The original is never touched: it is
/// sent exactly as it is.
///
/// Photos use ImageIO, so a large photo is never fully decoded. Photos are covered by tests. The video path (AVFoundation) has
/// not been run on a device yet.
struct PreviewMaker: FilePreparing {
    func prepare(_ pick: PickedFile, kind: FileKind, style: PreviewStyle) async throws -> PreparedFile {
        let contentType = try Self.contentType(of: pick)
        guard FileRules.kind(forContentType: contentType) == kind else { throw SlateError.unsupportedFileType }
        let bytes = Self.byteCount(at: pick.url)
        guard bytes > 0 else { throw SlateError.fileRefused(.empty) }
        switch kind {
        case .photo: return try Self.preparePhoto(pick, contentType: contentType, style: style, originalBytes: bytes)
        case .video: return try await Self.prepareVideo(pick, contentType: contentType, style: style, originalBytes: bytes)
        }
    }

    // MARK: - Reading the file

    /// The content type the file will be filed under: what the picker said, or what its ending says.
    static func contentType(of pick: PickedFile) throws -> String {
        guard let type = pick.resolvedContentType else { throw SlateError.unsupportedFileType }
        return type
    }

    static func byteCount(at url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func temporaryURL(ending: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slate-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(UUID().uuidString).\(ending)")
    }

    // MARK: - Photos

    private static func preparePhoto(_ pick: PickedFile, contentType: String, style: PreviewStyle, originalBytes: Int64) throws -> PreparedFile {
        guard let source = CGImageSourceCreateWithURL(pick.url as CFURL, nil) else { throw SlateError.mediaUnreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = properties?[kCGImagePropertyPixelWidth] as? Int
        var height = properties?[kCGImagePropertyPixelHeight] as? Int
        // Orientations 5 to 8 lie on their side, so what a person sees has width and height the other way round.
        if let orientation = properties?[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }

        let longEdge = style == .watermarked ? PreviewSpec.photoLongEdge : PreviewSpec.thumbnailLongEdge
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let reduced = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw SlateError.mediaUnreadable }
        var image = UIImage(cgImage: reduced)
        if style == .watermarked { image = Watermark.apply(to: image) }

        let cap = FileRules.maxPreviewBytes(.photo)
        var quality = style == .watermarked ? PreviewSpec.photoQuality : PreviewSpec.thumbnailQuality
        guard var data = image.jpegData(compressionQuality: quality) else { throw SlateError.mediaUnreadable }
        while Int64(data.count) > cap, quality > 0.2 {
            quality -= 0.1
            guard let smaller = image.jpegData(compressionQuality: quality) else { break }
            data = smaller
        }
        guard Int64(data.count) <= cap else { throw SlateError.fileRefused(.previewTooLarge(maxBytes: cap)) }
        let url = try temporaryURL(ending: "jpg")
        try data.write(to: url)
        return PreparedFile(
            name: pick.name, kind: .photo, contentType: contentType, originalURL: pick.url, previewURL: url,
            width: width, height: height, durationSeconds: nil, originalBytes: originalBytes, previewBytes: Int64(data.count)
        )
    }

    // MARK: - Videos

    private static func prepareVideo(_ pick: PickedFile, contentType: String, style: PreviewStyle, originalBytes: Int64) async throws -> PreparedFile {
        let asset = AVURLAsset(url: pick.url)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw SlateError.mediaUnreadable }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SlateError.mediaUnreadable }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // What a person sees: the shape after the video is turned the way it was filmed.
        let shown = natural.applying(transform)
        let width = Int(abs(shown.width).rounded())
        let height = Int(abs(shown.height).rounded())
        guard width > 0, height > 0 else { throw SlateError.mediaUnreadable }

        let previewURL: URL
        switch style {
        case .thumbnail:
            previewURL = try await poster(of: asset, longEdge: PreviewSpec.thumbnailLongEdge)
        case .watermarked:
            previewURL = try await watermarkedCopy(of: asset, track: track, transform: transform, shown: CGSize(width: width, height: height), duration: duration)
        }
        let previewBytes = byteCount(at: previewURL)
        let cap = FileRules.maxPreviewBytes(.video)
        guard previewBytes > 0 else { throw SlateError.mediaUnreadable }
        guard previewBytes <= cap else { throw SlateError.fileRefused(.previewTooLarge(maxBytes: cap)) }
        return PreparedFile(
            name: pick.name, kind: .video, contentType: contentType, originalURL: pick.url, previewURL: previewURL,
            width: width, height: height, durationSeconds: duration.seconds, originalBytes: originalBytes, previewBytes: previewBytes
        )
    }

    /// A still from near the start, as a small JPEG.
    private static func poster(of asset: AVURLAsset, longEdge: CGFloat) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        let total = try await asset.load(.duration).seconds
        let seconds = min(1, total / 2)
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        guard let data = UIImage(cgImage: frame).jpegData(compressionQuality: PreviewSpec.thumbnailQuality) else { throw SlateError.mediaUnreadable }
        let url = try temporaryURL(ending: "jpg")
        try data.write(to: url)
        return url
    }

    /// A reduced copy of the video with the watermark across it.
    private static func watermarkedCopy(
        of asset: AVURLAsset, track: AVAssetTrack, transform: CGAffineTransform, shown: CGSize, duration: CMTime
    ) async throws -> URL {
        let scale = min(1, PreviewSpec.videoLongEdge / max(shown.width, shown.height))
        // Video encoders want even sizes.
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        let renderSize = CGSize(width: even(shown.width * scale), height: even(shown.height * scale))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let video = CALayer()
        video.frame = parent.frame
        let overlay = CALayer()
        overlay.frame = parent.frame
        overlay.contents = Watermark.overlay(size: renderSize).cgImage
        parent.addSublayer(video)
        parent.addSublayer(overlay)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)

        let url = try temporaryURL(ending: "mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw SlateError.mediaUnreadable
        }
        session.videoComposition = composition
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw SlateError.backend(session.error?.localizedDescription ?? "The preview couldn't be made.")
        }
        return url
    }
}

// MARK: - The watermark

/// "PREVIEW" repeated across a picture at an angle, light enough to see through and heavy enough that cropping doesn't remove it.
enum Watermark {
    /// The picture with the watermark drawn over it.
    static func apply(to image: UIImage) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            draw(in: context.cgContext, size: size)
        }
    }

    /// Only the watermark, on a clear background (for laying over video).
    static func overlay(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(in: context.cgContext, size: size)
        }
    }

    private static func draw(in context: CGContext, size: CGSize) {
        let fontSize = max(16, min(size.width, size.height) / 11)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: UIColor.white.withAlphaComponent(0.4),
            .kern: fontSize / 8,
            .shadow: shadow,
        ]
        let text = NSString(string: PreviewSpec.watermarkText)
        let textSize = text.size(withAttributes: attributes)
        let step = CGSize(width: textSize.width * 1.7, height: textSize.height * 2.6)

        context.saveGState()
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -CGFloat.pi / 6)
        let reach = hypot(size.width, size.height)
        var row = 0
        var y = -reach / 2
        while y < reach / 2 {
            var x = -reach / 2 + (row.isMultiple(of: 2) ? 0 : step.width / 2)
            while x < reach / 2 {
                text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                x += step.width
            }
            y += step.height
            row += 1
        }
        context.restoreGState()
    }
}
