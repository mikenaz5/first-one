import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo or video chosen in the Photos picker, handed over as a file the app owns (the picker's own file is deleted
/// afterwards). The original is never re-encoded: Slate Files sends the file exactly as it is.
struct PickedMedia: Transferable {
    let url: URL
    let name: String
    let contentType: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in try PickedMedia.keep(received.file) }
        FileRepresentation(importedContentType: .movie) { received in try PickedMedia.keep(received.file) }
    }

    /// Copies a file into the app's own temporary folder, keeping its name and ending.
    static func keep(_ file: URL) throws -> PickedMedia {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slate-picked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ending = file.pathExtension
        let copy = folder.appendingPathComponent(UUID().uuidString + (ending.isEmpty ? "" : ".\(ending)"))
        try FileManager.default.copyItem(at: file, to: copy)
        return PickedMedia(url: copy, name: file.lastPathComponent, contentType: FileNames.contentType(forExtension: ending))
    }

    var pickedFile: PickedFile { PickedFile(url: url, name: name, contentType: contentType) }
}

enum FileImport {
    /// Turns what the Files app handed back into files the app owns. A file the Files app can't hand over is left out.
    static func pickedFiles(from result: Result<[URL], Error>) -> [PickedFile] {
        guard case .success(let urls) = result else { return [] }
        return urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (try? PickedMedia.keep(url))?.pickedFile
        }
    }
}
