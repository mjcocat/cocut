import AppKit
import Carbon.HIToolbox
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
    let updater = Updater()

    private(set) var phase: RecordingPhase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastRegion: CaptureRegion? {
        didSet { Self.store(lastRegion, forKey: Keys.lastRegion) }
    }
    private(set) var aspect: AspectPreset {
        didSet { UserDefaults.standard.set(aspect.rawValue, forKey: Keys.aspect) }
    }
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { if case .recording = phase { return true } else { return false } }
    var canRecordLastRegion: Bool { !isBusy && lastRegion?.screen != nil }
    var elapsedText: String { Self.formatElapsed(elapsed) }

    /// Shown in menus next to the global record/stop shortcut.
    static let hotKeyHint = "⌥⌘R"

    @ObservationIgnored private let selector = RegionSelectionController()
    @ObservationIgnored private let border = RecordingBorderController()
    @ObservationIgnored private var recorder: RegionRecorder?
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var hotKey: GlobalHotKey?

    private enum Keys {
        static let lastRegion = "lastCaptureRegion"
        static let aspect = "selectionAspect"
    }

    init() {
        lastRegion = Self.load(CaptureRegion.self, forKey: Keys.lastRegion)
        aspect = AspectPreset(rawValue: UserDefaults.standard.string(forKey: Keys.aspect) ?? "") ?? .widescreen
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.info("Cocut \(version) launched; screen permission: \(hasScreenPermission)")

        // ⌥⌘R anywhere: start recording (same region if there is one), or stop and save.
        hotKey = GlobalHotKey(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey, id: 1) { [weak self] in
            Task { @MainActor in await self?.toggleRecording() }
        }
        updater.checkInBackgroundIfDue()
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

    func toggleRecording() async {
        switch phase {
        case .recording:
            await stopRecording()
        case .idle:
            if canRecordLastRegion {
                await recordLastRegion()
            } else {
                await recordNewRegion()
            }
        default:
            break
        }
    }

    func recordNewRegion() async {
        guard !isBusy, ensurePermission() else { return }
        phase = .selecting
        hideAppWindows()

        let region = await selector.selectRegion(initial: lastRegion, aspect: aspect)
        aspect = selector.currentAspect

        guard let region else {
            Log.info("Region selection cancelled")
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
        guard isRecording, let recorder else { return }
        stopTicking()
        border.hide()
        restoreAppWindows()
        phase = .saving
        do {
            let url = try await recorder.stop()
            await library.addClip(at: url)
            Log.info("Saved \(url.lastPathComponent) (\(elapsedText))")
        } catch {
            Log.error("Stop failed: \(error.localizedDescription)")
            presentError(error.localizedDescription)
        }
        self.recorder = nil
        phase = .idle
    }

    func discardRecording() async {
        guard isRecording, let recorder else { return }
        stopTicking()
        border.hide()
        await recorder.discard()
        self.recorder = nil
        restoreAppWindows()
        phase = .idle
        Log.info("Recording discarded")
    }

    private func startRecording(_ region: CaptureRegion) async {
        phase = .starting
        let recorder = RegionRecorder()
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in await self?.handleUnexpectedStop(error) }
        }
        let outputURL = library.makeNewClipURL()

        do {
            // ScreenCaptureKit can stall (e.g. behind a permission prompt); don't hang forever.
            try await withTimeout(seconds: 12) {
                try await recorder.start(region: region, outputURL: outputURL)
            }
        } catch {
            Log.error("Start failed: \(error.localizedDescription)")
            await recorder.discard()
            phase = .idle
            refreshPermission()
            presentError(hasScreenPermission
                ? error.localizedDescription
                : "Cocut needs Screen Recording permission. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Cocut.")
            return
        }

        self.recorder = recorder
        let startedAt = Date()
        phase = .recording(startedAt: startedAt)
        startTicking(from: startedAt)
        border.show(around: region)
        Log.info("Recording started")
    }

    private func handleUnexpectedStop(_ error: Error) async {
        guard isRecording else { return }
        // Keep whatever was captured before the interruption.
        await stopRecording()
        presentError("Recording stopped unexpectedly: \(error.localizedDescription)")
    }

    private func ensurePermission() -> Bool {
        refreshPermission()
        if hasScreenPermission { return true }
        Log.info("Screen permission missing; requesting")
        requestPermission()
        return false
    }

    // MARK: Timer

    private func startTicking(from start: Date) {
        elapsed = 0
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = Date().timeIntervalSince(start) }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Windows & alerts

    /// Gets the app's own windows out of the way while picking a region and recording.
    private func hideAppWindows() {
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is OverlayWindow) }
        hiddenWindows.forEach { $0.orderOut(nil) }
    }

    func restoreAppWindows() {
        hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        hiddenWindows.removeAll()
        NSApp.activate()
    }

    func presentError(_ message: String) {
        restoreAppWindows()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording Problem"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Log")
        if alert.runModal() == .alertSecondButtonReturn {
            Log.reveal()
        }
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

// MARK: - Timeout helper

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Runs `operation`, failing with `RecorderError.startTimedOut` if it hasn't finished in time.
/// The operation isn't cancelled (ScreenCaptureKit calls can't be), it's just no longer awaited.
func withTimeout(seconds: Double, _ operation: @escaping @Sendable () async throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let once = OnceFlag()
        Task {
            do {
                try await operation()
                if once.claim() { continuation.resume() }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() { continuation.resume(throwing: RecorderError.startTimedOut) }
        }
    }
}
