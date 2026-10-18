import AppKit
import SwiftUI

enum RecordingPhase: Equatable {
    case idle
    case selecting
    case starting
    case recording(startedAt: Date)
    case saving
}

@MainActor
@Observable
final class AppModel {
    let library = ClipLibrary()

    private(set) var phase: RecordingPhase = .idle
    private(set) var lastRegion: CaptureRegion? {
        didSet { Self.store(lastRegion, forKey: Keys.lastRegion) }
    }
    private(set) var aspect: AspectPreset {
        didSet { UserDefaults.standard.set(aspect.rawValue, forKey: Keys.aspect) }
    }
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    var errorMessage: String?

    var isBusy: Bool { phase != .idle }
    var canRecordLastRegion: Bool { !isBusy && lastRegion?.screen != nil }

    @ObservationIgnored private let selector = RegionSelectionController()
    @ObservationIgnored private let hud = RecordingHUDController()
    @ObservationIgnored private var recorder: RegionRecorder?
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []

    private enum Keys {
        static let lastRegion = "lastCaptureRegion"
        static let aspect = "selectionAspect"
    }

    init() {
        lastRegion = Self.load(CaptureRegion.self, forKey: Keys.lastRegion)
        aspect = AspectPreset(rawValue: UserDefaults.standard.string(forKey: Keys.aspect) ?? "") ?? .widescreen
    }

    // MARK: Permission

    func refreshPermission() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            openPermissionSettings()
        }
        refreshPermission()
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Recording flow

    func recordNewRegion() async {
        guard !isBusy, ensurePermission() else { return }
        phase = .selecting
        hideAppWindows()

        let region = await selector.selectRegion(initial: lastRegion, aspect: aspect)
        aspect = selector.currentAspect

        guard let region else {
            restoreAppWindows()
            phase = .idle
            return
        }
        lastRegion = region
        await startRecording(region)
    }

    func recordLastRegion() async {
        guard !isBusy, ensurePermission() else { return }
        guard let region = lastRegion, region.screen != nil else {
            await recordNewRegion()
            return
        }
        hideAppWindows()
        await startRecording(region)
    }

    func stopRecording() async {
        guard case .recording = phase, let recorder else { return }
        hud.dismiss()
        restoreAppWindows()
        phase = .saving
        do {
            let url = try await recorder.stop()
            await library.addClip(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
        self.recorder = nil
        phase = .idle
    }

    func discardRecording() async {
        guard case .recording = phase, let recorder else { return }
        hud.dismiss()
        await recorder.discard()
        self.recorder = nil
        restoreAppWindows()
        phase = .idle
    }

    private func startRecording(_ region: CaptureRegion) async {
        phase = .starting
        let recorder = RegionRecorder()
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in await self?.handleUnexpectedStop(error) }
        }

        do {
            try await recorder.start(region: region, outputURL: library.makeNewClipURL())
        } catch {
            restoreAppWindows()
            phase = .idle
            refreshPermission()
            errorMessage = hasScreenPermission
                ? error.localizedDescription
                : "Highlight Creator needs Screen Recording permission to capture video."
            return
        }

        self.recorder = recorder
        let startedAt = Date()
        phase = .recording(startedAt: startedAt)
        hud.show(
            region: region,
            startedAt: startedAt,
            onStop: { [weak self] in Task { await self?.stopRecording() } },
            onDiscard: { [weak self] in Task { await self?.discardRecording() } }
        )
    }

    private func handleUnexpectedStop(_ error: Error) async {
        guard case .recording = phase else { return }
        // Keep whatever was captured before the interruption.
        await stopRecording()
        errorMessage = "Recording stopped unexpectedly: \(error.localizedDescription)"
    }

    private func ensurePermission() -> Bool {
        refreshPermission()
        if hasScreenPermission { return true }
        requestPermission()
        return false
    }

    // MARK: Window management

    /// Gets the app's own windows out of the way while picking a region and recording.
    private func hideAppWindows() {
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is OverlayWindow) }
        hiddenWindows.forEach { $0.orderOut(nil) }
    }

    private func restoreAppWindows() {
        hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        hiddenWindows.removeAll()
        NSApp.activate()
    }

    // MARK: Defaults helpers

    private static func store<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
