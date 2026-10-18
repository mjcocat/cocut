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
