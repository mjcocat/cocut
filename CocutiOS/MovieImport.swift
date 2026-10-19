import AVKit
import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from Photos, copied to a temporary folder (keeping its name).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "CocutImports/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }

    /// Loads the picked items as local files, in order. Items that fail are skipped (and logged).
    static func load(_ items: [PhotosPickerItem]) async -> [URL] {
        var urls: [URL] = []
        for item in items {
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    urls.append(movie.url)
                }
            } catch {
                Log.error("Couldn't load a video from Photos: \(error.localizedDescription)")
            }
        }
        return urls
    }

    /// Removes the temporary copies once they've been imported.
    static func cleanUp(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

/// Copies a file picked in the Files app into Cocut's Matches folder so it stays readable.
enum MatchFiles {
    static var directory: URL {
        let dir = Platform.moviesRoot.appending(path: "Cocut/Matches", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Moves (temporary copies) or copies (anything else) `source` into the Matches folder.
    static func keep(_ source: URL, move: Bool) throws -> URL {
        var destination = directory.appending(path: source.lastPathComponent)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = directory.appending(path: "\(base) \(n).\(ext)")
            n += 1
        }
        if move {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }
}

/// Saves a finished video to the photo library.
enum PhotoLibrarySaver {
    static func save(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
