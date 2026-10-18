import AppKit
import SwiftUI

@main
struct CocutApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Cocut", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.updater.checkNow()
                }
                .disabled(model.isRecording)
            }

            CommandMenu("Record") {
                Button("Record Region…") {
                    Task { await model.recordNewRegion() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isBusy)

                Button("Record Same Region") {
                    Task { await model.recordLastRegion() }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.canRecordLastRegion)

                Divider()

                Button("Show Clips Folder") {
                    model.library.revealInFinder()
                }
            }

            CommandGroup(after: .help) {
                Button("Show Log") { Log.reveal() }
            }
        }

        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}
