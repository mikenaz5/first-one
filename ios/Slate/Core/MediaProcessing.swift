import AVFoundation
import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Image and video helpers

enum MediaProcessing {
    /// Decodes `data` at no more than `maxPixel` on its longest side (applying EXIF orientation)
    /// and re-encodes it as JPEG. Uses ImageIO so large photos are never fully decoded.
    static func jpeg(from data: Data, maxPixel: CGFloat, quality: CGFloat = 0.82) -> (data: Data, size: CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = UIImage(cgImage: image).jpegData(compressionQuality: quality)
        else { return nil }
        return (encoded, CGSize(width: image.width, height: image.height))
    }

    struct PhotoVariants {
        var full: Data
        var thumbnail: Data
        var aspectRatio: Double
    }

    static func photoVariants(from data: Data) -> PhotoVariants? {
        guard let full = jpeg(from: data, maxPixel: 2400, quality: 0.85),
              let thumbnail = jpeg(from: full.data, maxPixel: 600, quality: 0.8),
              full.size.height > 0
        else { return nil }
        return PhotoVariants(full: full.data, thumbnail: thumbnail.data, aspectRatio: full.size.width / full.size.height)
    }

    struct VideoInfo {
        var poster: Data
        var thumbnail: Data
        var duration: TimeInterval
        var aspectRatio: Double
    }

    static func videoInfo(at url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SlateError.mediaUnreadable }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        let cgImage = try await generator.image(at: time).image

        guard let poster = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82),
              let thumbnail = jpeg(from: poster, maxPixel: 600, quality: 0.8),
              cgImage.height > 0
        else { throw SlateError.mediaUnreadable }

        return VideoInfo(
            poster: poster,
            thumbnail: thumbnail.data,
            duration: duration,
            aspectRatio: Double(cgImage.width) / Double(cgImage.height)
        )
    }
}

// MARK: - Transferable movie

/// Lets `PhotosPickerItem` hand us a video as a file we own (the picker's file is deleted afterwards).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

// MARK: - Importer

/// Turns `PhotosPickerItem`s into processed `NewPortfolioItem`s, reporting progress and skipped files.
@MainActor
@Observable
final class PortfolioImporter {
    private(set) var isImporting = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var skipped: [String] = []

    func load(_ picks: [PhotosPickerItem]) async -> [NewPortfolioItem] {
        guard !picks.isEmpty else { return [] }
        isImporting = true
        completed = 0
        total = picks.count
        skipped = []
        defer { isImporting = false }

        var results: [NewPortfolioItem] = []
        for pick in picks {
            do {
                results.append(try await loadOne(pick))
            } catch {
                skipped.append(error.localizedDescription)
            }
            completed += 1
        }
        return results
    }

    private func loadOne(_ pick: PhotosPickerItem) async throws -> NewPortfolioItem {
        let isVideo = pick.supportedContentTypes.contains { $0.conforms(to: .movie) }

        if isVideo {
            guard let movie = try await pick.loadTransferable(type: PickedMovie.self) else {
                throw SlateError.mediaUnreadable
            }
            do {
                let info = try await MediaProcessing.videoInfo(at: movie.url)
                guard info.duration <= Double(AppConfig.maxVideoSeconds) else {
                    throw SlateError.videoTooLong(maxSeconds: AppConfig.maxVideoSeconds)
                }
                return NewPortfolioItem(
                    kind: .video,
                    imageJPEG: info.poster,
                    thumbnailJPEG: info.thumbnail,
                    videoFile: movie.url,
                    duration: info.duration,
                    aspectRatio: info.aspectRatio
                )
            } catch {
                try? FileManager.default.removeItem(at: movie.url)
                throw error
            }
        }

        guard let data = try await pick.loadTransferable(type: Data.self) else {
            throw SlateError.mediaUnreadable
        }
        let variants = await Task.detached(priority: .userInitiated) {
            MediaProcessing.photoVariants(from: data)
        }.value
        guard let variants else { throw SlateError.mediaUnreadable }
        return NewPortfolioItem(
            kind: .photo,
            imageJPEG: variants.full,
            thumbnailJPEG: variants.thumbnail,
            videoFile: nil,
            duration: nil,
            aspectRatio: variants.aspectRatio
        )
    }
}
