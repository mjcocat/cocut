import AppKit
import SwiftUI

/// The menu bar icon: scissors when idle, a ring while waiting for playback,
/// a filled dot and running time while a clip records.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 4) {
                Image(systemName: model.isPausedInClip ? "pause.circle" : "record.circle.fill")
                Text(model.elapsedText).monospacedDigit()
            }
        case .armed:
            HStack(spacing: 4) {
                Image(systemName: "record.circle")
                if model.clipsThisSession > 0 {
                    Text("\(model.clipsThisSession)").monospacedDigit()
                }
            }
        case .starting, .stopping:
            Image(systemName: "ellipsis.circle")
        default:
            // The app's layered logo as a one-color template, tinted by the menu bar like system icons.
            Image("MenuBarIcon")
                .accessibilityLabel("Cocut")
        }
    }
}

struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.phase {
        case .armed:
            Text("Waiting for the video to play…")
            Text(sessionSummary)
            Button("Done, Back to Cocut   \(AppModel.hotKeyHint)") {
                Task { await model.stopSession() }
            }
        case .recording:
            Text(model.recordingStatusText)
            if model.sessionMode == .auto, !model.isPausedInClip {
                Text("Pause the video to save this clip")
            }
            Button(model.sessionMode == .auto ? "Done, Back to Cocut   \(AppModel.hotKeyHint)" : "Stop and Save   \(AppModel.hotKeyHint)") {
                Task { await model.stopSession() }
            }
            Button("Discard This Clip") {
                Task { await model.discardCurrentClip() }
            }
        case .selecting:
            Text("Selecting a region…")
        case .starting:
            Text("Starting capture…")
        case .stopping:
            Text("Saving…")
        case .idle:
            Button("Record Region…   \(AppModel.newRegionHotKeyHint)") {
                Task { await model.recordNewRegion() }
            }
            Button("Record Full Screen   \(AppModel.fullScreenHotKeyHint)") {
                Task { await model.recordFullScreen() }
            }
            Button("Record Same Region   \(AppModel.hotKeyHint)") {
                Task { await model.recordLastRegion() }
            }
            .disabled(!model.canRecordLastRegion)
            Toggle("Record Sound", isOn: Binding(
                get: { model.captureAudio },
                set: { model.setCaptureAudio($0) }
            ))
            Toggle("Record When Video Plays", isOn: Binding(
                get: { model.captureMode == .auto },
                set: { model.setCaptureMode($0 ? .auto : .manual) }
            ))
        }

        Divider()

        Button("Open Cocut") { showMainWindow() }
        Button("Show Clips Folder") { model.library.revealInFinder() }

        Divider()

        Button(updateTitle) {
            showMainWindow()
            model.updater.checkNow()
        }
        .disabled(model.isBusy)
        SettingsLink { Text("Settings…") }
        Button("Setup Guide…") {
            showMainWindow()
            model.showingSetupGuide = true
        }
        Button("Show Log") { Log.reveal() }

        Divider()

        Button("Quit Cocut") { NSApp.terminate(nil) }
            .disabled(model.isSessionActive)
    }

    private var sessionSummary: String {
        switch model.clipsThisSession {
        case 0: return "Press play in your browser to start a clip"
        case 1: return "1 clip saved this session"
        default: return "\(model.clipsThisSession) clips saved this session"
        }
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
