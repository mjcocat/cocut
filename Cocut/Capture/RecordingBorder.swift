import AppKit
import SwiftUI

/// A red outline just outside the region being recorded. It belongs to Cocut,
/// so ScreenCaptureKit leaves it out of the clip.
@MainActor
final class RecordingBorderController {
    private var window: NSWindow?

    func show(around region: CaptureRegion) {
        hide()
        guard let frame = region.globalFrame else { return }

        let pad: CGFloat = 4
        let window = NSWindow(contentRect: frame.insetBy(dx: -pad, dy: -pad),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: RecordingBorderView())
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

struct RecordingBorderView: View {
    @State private var glow = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.red.opacity(glow ? 0.95 : 0.55), lineWidth: 3)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: glow)
            .onAppear { glow = true }
    }
}
