import AppKit
import SwiftUI

/// The launch splash: the full logo on its own, no window chrome, version along the bottom.
/// It's the only window shown at launch; when it's done it opens the main window and closes itself,
/// so the main window never flashes up first.
struct SplashView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var visible = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Version \(short)"
    }

    var body: some View {
        Image("Splash")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: 420, height: 420)
            .overlay(alignment: .bottom) {
                Text(version)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(CenterOnScreen())
            .scaleEffect(visible ? 1 : 0.96)
            .opacity(visible ? 1 : 0)
            .task {
                withAnimation(.easeOut(duration: 0.3)) { visible = true }
                try? await Task.sleep(for: .seconds(1.5))
                openWindow(id: "main")
                withAnimation(.easeIn(duration: 0.3)) { visible = false }
                try? await Task.sleep(for: .seconds(0.35))
                dismissWindow(id: "splash")
            }
    }
}

/// Centers its window on the screen with the pointer once the window exists. SwiftUI's own
/// placement runs before a plain window knows its size, which can leave the splash off center.
private struct CenterOnScreen: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? window.screen ?? NSScreen.main
                guard let visible = screen?.visibleFrame else { return }
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(),
                                              y: (visible.midY - size.height / 2).rounded()))
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}
