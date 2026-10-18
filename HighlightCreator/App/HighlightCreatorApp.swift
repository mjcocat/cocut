import AppKit
import SwiftUI

@main
struct HighlightCreatorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Highlight Creator", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
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
        }
    }
}
