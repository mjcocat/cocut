import AppKit
import SwiftUI

/// Shows the Cocut logo for a moment at launch, then fades it out and reveals the main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var splash: NSWindow?
    private var revealedWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        showSplash()
    }

    private func showSplash() {
        let size = CGSize(width: 420, height: 420)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40)

        let window = NSWindow(contentRect: CGRect(origin: origin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

        let host = NSHostingView(rootView: SplashView())
        host.sizingOptions = []
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        splash = window

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }

        // Keep the main window out of sight until the splash has had its moment.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revealedWindows = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.canBecomeMain }
            self.revealedWindows.forEach { $0.alphaValue = 0 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.dismissSplash()
        }
    }

    private func dismissSplash() {
        guard let window = splash else { return }
        let main = revealedWindows
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            window.animator().alphaValue = 0
            main.forEach { $0.animator().alphaValue = 1 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                // In case the animation was skipped, make sure the main window is fully visible.
                main.forEach { $0.alphaValue = 1 }
                self?.splash = nil
                self?.revealedWindows = []
                NSApp.activate()
            }
        })
    }
}

struct SplashView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "Version \(short)"
    }

    var body: some View {
        Image("Splash")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .overlay(alignment: .bottom) {
                Text(version)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
