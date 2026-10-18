import AppKit
import SwiftUI

/// The menu bar icon: scissors when idle, a stop symbol and running time while recording.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 4) {
                Image(systemName: "stop.circle.fill")
                Text(model.elapsedText).monospacedDigit()
            }
        case .starting, .saving:
            Image(systemName: "ellipsis.circle")
        default:
            Image(systemName: "scissors")
        }
    }
}

struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.phase {
        case .recording:
            Text("Recording · \(model.elapsedText)")
            Button("Stop and Save   \(AppModel.hotKeyHint)") {
                Task { await model.stopRecording() }
            }
            Button("Discard Recording") {
                Task { await model.discardRecording() }
            }
        case .selecting:
            Text("Selecting a region…")
        case .starting:
            Text("Starting capture…")
        case .saving:
            Text("Saving clip…")
        case .idle:
            Button("Record Region…") {
                Task { await model.recordNewRegion() }
            }
            Button("Record Same Region   \(AppModel.hotKeyHint)") {
                Task { await model.recordLastRegion() }
            }
            .disabled(!model.canRecordLastRegion)
        }

        Divider()

        Button("Open Cocut") { showMainWindow() }
        Button("Show Clips Folder") { model.library.revealInFinder() }

        Divider()

        Button(updateTitle) {
            showMainWindow()
            model.updater.checkNow()
        }
        .disabled(model.isRecording)
        Button("Show Log") { Log.reveal() }

        Divider()

        Button("Quit Cocut") { NSApp.terminate(nil) }
            .disabled(model.isRecording)
    }

    private var updateTitle: String {
        if let release = model.updater.availableRelease {
            return "Install Update (\(release.version))…"
        }
        return "Check for Updates…"
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
