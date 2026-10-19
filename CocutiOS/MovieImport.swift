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
        // Photos hands videos over as QuickTime or MPEG-4 files; accept any movie type.
        FileRepresentation(importedContentType: .quickTimeMovie) { received in try keep(received.file) }
        FileRepresentation(importedContentType: .mpeg4Movie) { received in try keep(received.file) }
        FileRepresentation(importedContentType: .movie) { received in try keep(received.file) }
    }

    /// The received file only exists during the import, so copy it somewhere it will last.
    private static func keep(_ file: URL) throws -> PickedMovie {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "CocutImports/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return PickedMovie(url: destination)
    }

    struct LoadResult {
        var urls: [URL] = []
        /// Why items couldn't be loaded, for the message shown afterwards.
        var problems: [String] = []
    }

    /// Loads the picked items as local files, in order. Every step is logged, and items that
    /// fail are reported in `problems`.
    static func load(_ items: [PhotosPickerItem]) async -> LoadResult {
        var result = LoadResult()
        Log.info("Photos picker returned \(items.count) item(s)")
        for (i, item) in items.enumerated() {
            let types = item.supportedContentTypes.map(\.identifier).joined(separator: ", ")
            Log.info("Item \(i + 1) types: \(types.isEmpty ? "none" : types)")
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path(percentEncoded: false))[.size] as? Int) ?? 0
                    Log.info("Item \(i + 1) loaded: \(movie.url.lastPathComponent), \(size / 1_000_000) MB")
                    result.urls.append(movie.url)
                } else {
                    Log.error("Item \(i + 1): Photos returned no movie (types: \(types))")
                    result.problems.append("A selected item isn't a video Cocut can read.")
                }
            } catch {
                Log.error("Item \(i + 1) couldn't be loaded from Photos: \(error)")
                result.problems.append(error.localizedDescription)
            }
        }
        return result
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
