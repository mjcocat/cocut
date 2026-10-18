import AppKit
import CoreGraphics

/// A rectangle on one display, in that display's local points with a top-left origin
/// (the same space ScreenCaptureKit's `sourceRect` uses).
struct CaptureRegion: Codable, Equatable {
    var displayID: CGDirectDisplayID
    var rect: CGRect

    /// The matching screen, if it is still connected.
    @MainActor var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// The region in global Cocoa window coordinates (bottom-left origin).
    @MainActor var globalFrame: CGRect? {
        guard let screen else { return nil }
        return CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
