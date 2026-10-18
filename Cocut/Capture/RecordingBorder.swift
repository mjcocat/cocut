import AppKit
import SwiftUI

enum BorderStyle {
    /// Auto mode, waiting for the video to play.
    case armed
    /// A clip is being written.
    case recording
}

@MainActor
@Observable
final class BorderState {
    var style: BorderStyle = .armed
}

/// An outline just outside the captured region. It belongs to Cocut, so ScreenCaptureKit
/// leaves it out of the clip.
@MainActor
final class RecordingBorderController {
    private var window: NSWindow?
    private let state = BorderState()

    func show(around region: CaptureRegion, style: BorderStyle) {
        state.style = style
        guard window == nil else { return }
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
        window.sharingType = .none

        let host = NSHostingView(rootView: RecordingBorderView(state: state))
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
    }

    func setStyle(_ style: BorderStyle) {
        state.style = style
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

struct RecordingBorderView: View {
    let state: BorderState
    @State private var glow = false

    var body: some View {
        ZStack {
            switch state.style {
            case .armed:
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85),
                                  style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .shadow(color: .black.opacity(0.5), radius: 1)
            case .recording:
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.red.opacity(glow ? 0.95 : 0.55), lineWidth: 3)
            }
        }
        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: glow)
        .onAppear { glow = true }
    }
}
