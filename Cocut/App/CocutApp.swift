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

        Window("Find Rallies", id: "rallies") {
            RallyFinderView()
                .environment(model)
        }
        .defaultSize(width: 1240, height: 820)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // Their own windows (not sheets), so they can be moved off the Find Rallies window.
        Window("Identify Players", id: "identify") {
            IdentifyPlayersWindow()
                .environment(model)
        }
        .defaultSize(width: 1440, height: 900)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Check Accuracy", id: "accuracy") {
            CheckAccuracyWindow()
                .environment(model)
        }
        .defaultSize(width: 1440, height: 900)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Reel Preview", id: "preview") {
            ReelPreviewView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .restorationBehavior(.disabled)
        .commandsRemoved()

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
    @Environment(\.openWindow) private var openWindow

    @MainActor
    private static func route(text selector: String, rallies: () -> Void, library: () -> Void) {
        let window = NSApp.keyWindow
        // A text field with its own edits to undo gets ⌘Z first.
        if let text = window?.firstResponder as? NSTextView, let manager = text.undoManager,
           selector == "undo:" ? manager.canUndo : manager.canRedo {
            NSApp.sendAction(Selector(selector), to: nil, from: nil)
        } else if window?.title == "Find Rallies" {
            rallies()
        } else {
            library()
        }
    }

    var body: some Commands {
        // Undo/Redo go to whatever you're working in: a text field being edited, the Find Rallies
        // window, or the clip library.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { Self.route(text: "undo:", rallies: { model.rallies.undo() }, library: { model.library.undo() }) }
                .keyboardShortcut("z", modifiers: [.command])
            Button("Redo") { Self.route(text: "redo:", rallies: { model.rallies.redo() }, library: { model.library.redo() }) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

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

            Button("Find Rallies in a Match…") {
                openWindow(id: "rallies")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button("Preview Reel") {
                openWindow(id: "preview")
            }
            .keyboardShortcut("y", modifiers: [.command])
            .disabled(model.library.includedClips.isEmpty)

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
