import AppKit
import SwiftUI

/// Floating timer/stop panel plus a red outline around the region being recorded.
/// Both belong to our app, so they're excluded from the capture.
@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?
    private var border: NSWindow?

    func show(region: CaptureRegion, startedAt: Date,
              onStop: @escaping @MainActor () -> Void,
              onDiscard: @escaping @MainActor () -> Void) {
        dismiss()
        guard let screen = region.screen, let frame = region.globalFrame else { return }

        // Outline just outside the captured area.
        let pad: CGFloat = 4
        let borderWindow = NSWindow(contentRect: frame.insetBy(dx: -pad, dy: -pad),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        borderWindow.isOpaque = false
        borderWindow.backgroundColor = .clear
        borderWindow.hasShadow = false
        borderWindow.ignoresMouseEvents = true
        borderWindow.level = .statusBar
        borderWindow.isReleasedWhenClosed = false
        borderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let borderHost = NSHostingView(rootView: RecordingBorderView())
        borderHost.sizingOptions = []
        borderWindow.contentView = borderHost
        borderWindow.orderFrontRegardless()
        border = borderWindow

        // Control pill: below the region if there's room, else above, else inside the top edge.
        let size = CGSize(width: 268, height: 60)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 14)
        if origin.y < visible.minY + 8 {
            origin.y = frame.maxY + 14
        }
        if origin.y + size.height > visible.maxY - 8 {
            origin.y = frame.maxY - size.height - 16
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

        let hud = HUDPanel(contentRect: CGRect(origin: origin, size: size))
        let hudHost = NSHostingView(rootView: RecordingHUDView(startedAt: startedAt, onStop: onStop, onDiscard: onDiscard))
        hudHost.sizingOptions = []
        hud.contentView = hudHost
        hud.orderFrontRegardless()
        panel = hud
    }

    func dismiss() {
        panel?.orderOut(nil)
        border?.orderOut(nil)
        panel = nil
        border = nil
    }
}

/// A panel you can click without pulling focus away from the browser playing the video.
final class HUDPanel: NSPanel {
    convenience init(contentRect: CGRect) {
        self.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

struct RecordingBorderView: View {
    @State private var glow = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.red.opacity(glow ? 0.95 : 0.6), lineWidth: 3)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: glow)
            .onAppear { glow = true }
    }
}

struct RecordingHUDView: View {
    let startedAt: Date
    let onStop: @MainActor () -> Void
    let onDiscard: @MainActor () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                Text(Self.format(context.date.timeIntervalSince(startedAt)))
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 0)

            Button(action: onDiscard) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help("Discard this clip")

            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .help("Stop and save the clip")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(width: 268, height: 60)
        .glassEffect(.regular, in: Capsule())
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        let secs = Int(s) % 60
        let tenths = Int((s * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%02d:%02d.%d", minutes, secs, tenths)
    }
}
