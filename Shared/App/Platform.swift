import AVFoundation
import Foundation
import SwiftUI

// The few places where the Mac and iPhone/iPad differ for the shared engine (library, Player
// Card, Find Rallies, reel export). Everything else in Shared/ is plain AVFoundation, Vision,
// Core Graphics and SwiftUI, which both platforms have.

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

enum Platform {
    /// Where Cocut keeps projects, clips and exports: ~/Movies/Cocut on the Mac, the app's
    /// Documents/Cocut on iPhone and iPad (visible in the Files app).
    static var moviesRoot: URL {
        let fm = FileManager.default
        #if os(macOS)
        return fm.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appending(path: "Movies")
        #else
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// ~/Library/Logs/Cocut on the Mac; the app's own Library/Logs/Cocut on iOS.
    static var logsDirectory: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Cocut", directoryHint: .isDirectory)
        #else
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Cocut", directoryHint: .isDirectory)
        #endif
    }

    /// Moves a file or folder to the Trash and returns where it went (so it can be put back).
    /// iOS has no Trash, so there it goes to a hidden .Trash folder inside Cocut's folder.
    @discardableResult
    static func moveToTrash(_ url: URL) throws -> URL? {
        #if os(macOS)
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
        #else
        let trash = moviesRoot.appending(path: "Cocut/.Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appending(path: "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
        #endif
    }

    /// Shows files in Finder (Mac only; does nothing on iOS, where the Files app shows Cocut's folder).
    static func reveal(_ urls: [URL]) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        #endif
    }

    /// Opens a folder in Finder (Mac only).
    static func openFolder(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: Images

    static func loadImage(at url: URL) -> PlatformImage? {
        #if os(macOS)
        return NSImage(contentsOf: url)
        #else
        return UIImage(contentsOfFile: url.path(percentEncoded: false))
        #endif
    }

    static func image(from data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }

    /// Redraws the image upright (applying orientation), at most `maxSide` pixels on its longest
    /// side, and encodes it as PNG.
    static func normalizedPNG(_ image: PlatformImage, maxSide: CGFloat) -> Data? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
        #else
        // UIImage.size is in points and already accounts for orientation.
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let scale = min(1, maxSide / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let redrawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return redrawn.pngData()
        #endif
    }

    // MARK: Colors

    /// A color's sRGB components (0...1).
    static func sRGB(_ color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        #if os(macOS)
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func clamp(_ v: CGFloat) -> Double { Double(min(1, max(0, v))) }
        return (clamp(r), clamp(g), clamp(b), clamp(a))
        #endif
    }

    static func cgColor(_ color: Color) -> CGColor {
        PlatformColor(color).cgColor
    }
}

/// Lets a file URL drive a sheet (`.sheet(item:)`).
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension Image {
    /// SwiftUI image from an NSImage (Mac) or UIImage (iOS).
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Reads still frames from videos (spotlight editor, spotlight cards in the reel).
enum VideoFrames {
    /// The frame at `seconds`, upright, cropped to `crop` (unit coordinates, top-left origin).
    static func firstFrame(url: URL, at seconds: Double, crop: CGRect?) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let full = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        guard let crop else { return full }
        let w = CGFloat(full.width), h = CGFloat(full.height)
        let rect = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral
        return full.cropping(to: rect) ?? full
    }
}
