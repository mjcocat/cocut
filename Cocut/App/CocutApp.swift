import AppKit
import SwiftUI

@main
struct CocutApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Cocut", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1220, height: 780)
        .windowToolbarStyle(.unified)
        // The splash opens this window once it's finished.
        .defaultLaunchBehavior(.suppressed)
        .commands { AppCommands(model: model) }

        Window("Cocut Splash", id: "splash") {
            SplashView()
                .containerBackground(.clear, for: .window)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultWindowPlacement { _, _ in WindowPlacement(.center) }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                model.updater.checkNow()
            }
            .disabled(model.isBusy)
        }

        CommandGroup(after: .newItem) {
            Button("Import Videos…") {
                Task { await model.importVideosWithPanel() }
            }
            .keyboardShortcut("i", modifiers: [.command])
            .disabled(model.isBusy)

            Button("Export Highlight Reel…") {
                model.requestedSection = .export
            }
            .keyboardShortcut("e", modifiers: [.command])
        }

        CommandMenu("Record") {
            Button("Record Region…") {
                Task { await model.recordNewRegion() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.isBusy)

            Button("Record Full Screen") {
                Task { await model.recordFullScreen() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.isBusy)

            Button("Record Same Region") {
                Task { await model.recordLastRegion() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!model.canRecordLastRegion)

            Divider()

            Toggle("Record Sound", isOn: Binding(
                get: { model.captureAudio },
                set: { model.setCaptureAudio($0) }
            ))
            .disabled(model.isBusy)

            Toggle("Record When Video Plays", isOn: Binding(
                get: { model.captureMode == .auto },
                set: { model.setCaptureMode($0 ? .auto : .manual) }
            ))
            .disabled(model.isBusy)

            Button("Done Recording") {
                Task { await model.stopSession() }
            }
            .disabled(!model.isSessionActive)

            Divider()

            Button("Show Clips Folder") {
                model.library.revealInFinder()
            }
        }

        CommandGroup(after: .help) {
            Button("Setup Guide…") { model.showingSetupGuide = true }
            Button("Show Log") { Log.reveal() }
        }
    }
}
