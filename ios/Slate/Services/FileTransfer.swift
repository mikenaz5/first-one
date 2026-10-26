import AVFoundation
import ImageIO
import Photos
import UIKit

/// Fetching a delivered file and putting it in Photos. The bytes come from a short-lived link the backend made for this
/// person (or from the app's own folder on-device).
struct FileTransfer: FileTransferring {
    func download(_ source: FileSource, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)

        if !source.isRemote {
            try FileManager.default.copyItem(at: source.url, to: destination)
            progress(1)
            return destination
        }
        let watcher = DownloadWatcher(progress)
        let (temporary, response) = try await URLSession.shared.download(from: source.url, delegate: watcher)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw SlateError.fileUnavailable }
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }

    func saveToPhotos(_ url: URL, kind: FileKind) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SlateError.photosAccessDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: kind == .photo ? .photo : .video, fileURL: url, options: options)
        }
    }

    /// Reports how far a download has come, through the task's own progress.
    private final class DownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?

        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let report = report
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                report(progress.fractionCompleted)
            }
        }
    }
}

// MARK: - Pictures for the screens

/// Small pictures of delivered files, kept for a while so scrolling a grid doesn't fetch them again.
@MainActor
final class FileImageCache {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 300
    }

    func image(forKey key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, forKey key: String) { cache.setObject(image, forKey: key as NSString) }

    func removeAll() { cache.removeAllObjects() }
}

enum FileImages {
    /// The picture at a file's address: a JPEG or HEIC, reduced to `longEdge` pixels as it is read. A file on this phone is
    /// read in place; one at a web address is fetched first.
    static func image(at url: URL, isRemote: Bool, longEdge: CGFloat) async -> UIImage? {
        let source: CGImageSource?
        if isRemote {
            guard let data = (try? await URLSession.shared.data(from: url))?.0 else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// A still from a video at a file's address (streamed: only the part needed is fetched).
    static func poster(at url: URL, longEdge: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: frame)
    }
}
