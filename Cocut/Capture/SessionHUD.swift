import AppKit
import SwiftUI

/// A small floating control shown while a recording session runs: status, clip count,
/// keyboard hints for the video, and a Done button that ends the session and brings
/// Cocut back. It's a non-activating panel, so clicking it doesn't take keyboard focus
/// away from the browser. Like all of Cocut's windows, it's excluded from the capture.
@MainActor
final class SessionHUDController {
    private var panel: NSPanel?

    func show(near region: CaptureRegion, model: AppModel) {
        hide()
        guard let screen = region.screen, let frame = region.globalFrame else { return }

        let size = CGSize(width: 540, height: 128)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 14)
        if origin.y < visible.minY + 8 {
            // No room below: try above the region.
            origin.y = frame.maxY + 14
        }
        if origin.y + size.height > visible.maxY - 8 {
            // Full screen or a very tall region: tuck it into the top-right corner, over the picture
            // and well inside the recording outline. It's left out of the recording either way.
            origin.y = visible.maxY - size.height - 36
            origin.x = visible.maxX - size.width - 36
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

        let panel = HUDPanel(contentRect: CGRect(origin: origin, size: size))
        let host = NSHostingView(rootView: SessionHUDView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Clickable without activating Cocut, so the browser keeps keyboard focus.
final class HUDPanel: NSPanel {
    convenience init(contentRect: CGRect) {
        self.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the recording outline (at .statusBar), so its dashed line never crosses the control.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none // a second guard against showing up in screen captures
    }

    override var canBecomeKey: Bool { true }
}

struct SessionHUDView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)

                if model.isRecording {
                    Button {
                        Task { await model.discardCurrentClip() }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Throw away the clip being recorded")
                    .accessibilityLabel("Discard this clip")
                    // Kept apart from Done, so finishing never lands on it.
                    .padding(.trailing, 6)
                }

                Button {
                    Task { await model.stopSession() }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(SolidButtonStyle())
                .help("Finish recording and go back to Cocut (\(AppModel.hotKeyHint))")
            }

            KeyHints()
            Text("Click the video once so the keys reach the player. *Hudl's film-study player only.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 540, height: 128)
        // Nearly solid: it floats over busy video and web pages, and must stay readable.
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Design.hairline, lineWidth: 1))
    }

    private var statusDot: some View {
        RecordingDot(recording: model.isRecording && !model.isPausedInClip,
                     color: model.isRecording ? (model.isPausedInClip ? Color.orange : Design.record) : Color.secondary.opacity(0.6),
                     outlined: !model.isRecording)
            .accessibilityLabel(model.isRecording ? (model.isPausedInClip ? "Paused, saving" : "Recording") : "Waiting")
    }

    private var title: String {
        if model.isRecording {
            return model.recordingStatusText
        }
        return model.sessionMode == .auto ? "Ready, press play" : "Starting…"
    }

    private var subtitle: String {
        let saved: String
        switch model.clipsThisSession {
        case 0: saved = "No clips yet"
        case 1: saved = "1 clip saved"
        default: saved = "\(model.clipsThisSession) clips saved"
        }
        if model.isRecording, model.sessionMode == .auto {
            return "Pause to save this clip · \(saved)"
        }
        return saved
    }
}

/// Player keyboard shortcuts. The browser needs focus on the video (click it once) for these to work.
struct KeyHints: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                site("YouTube")
                hint(["Space"], "play/pause")
                hint(["←", "→"], "5s")
                hint(["J", "L"], "10s")
                hint([",", "."], "frame")
            }
            GridRow {
                site("Hudl")
                hint(["Space"], "play/pause")
                hint(["Z", "B"], "−2s / +5s*")
                hint(["X", "V"], "frame*")
                hint(["⏯"], "any site")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func site(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.8))
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            Text(label)
        }
    }
}

/// The status light: pulses while a clip records (steady with Reduce Motion), still otherwise.
private struct RecordingDot: View {
    let recording: Bool
    let color: Color
    let outlined: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: outlined ? 1 : 0))
            .opacity(recording && pulse ? 0.35 : 1)
            .animation(recording && !reduceMotion ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { pulse = recording && !reduceMotion }
            .onChange(of: recording) { _, on in pulse = on && !reduceMotion }
    }
}
