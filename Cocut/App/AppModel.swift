import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum RecordingPhase: Equatable {
    case idle
    case selecting
    case starting
    /// Auto mode: watching the region, waiting for the video to play.
    case armed
    /// A clip is being written.
    case recording(startedAt: Date)
    case stopping
}

@MainActor
@Observable
final class AppModel {
    let library = ClipLibrary()
    let updater = Updater()
    let profile = ProfileStore()
    let exporter = ReelExporter()
    let settings = AppSettings()

    /// Lets menu commands switch the main window's sidebar section.
    var requestedSection: SidebarItem?

    private(set) var phase: RecordingPhase = .idle
    private(set) var elapsed: TimeInterval = 0
    /// The video stopped changing while a clip records (auto mode): the clip will save shortly.
    private(set) var isPausedInClip = false
    private(set) var clipsThisSession = 0
    private(set) var sessionMode: CaptureMode = .auto
    private(set) var lastRegion: CaptureRegion? {
        didSet { Self.store(lastRegion, forKey: Keys.lastRegion) }
    }
    private(set) var aspect: AspectPreset {
        didSet { UserDefaults.standard.set(aspect.rawValue, forKey: Keys.aspect) }
    }
    private(set) var captureMode: CaptureMode {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: Keys.mode) }
    }
    private(set) var captureAudio: Bool {
        didSet { UserDefaults.standard.set(captureAudio, forKey: Keys.audio) }
    }
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()

    var isBusy: Bool { phase != .idle }
    var isSessionActive: Bool {
        switch phase {
        case .armed, .recording: return true
        default: return false
        }
    }
    var isRecording: Bool { if case .recording = phase { return true } else { return false } }
    var canRecordLastRegion: Bool { !isBusy && lastRegion?.screen != nil }
    var elapsedText: String { Self.formatElapsed(elapsed) }
    /// "Recording · 0:12" or, once the video pauses, "Paused · saving…".
    var recordingStatusText: String {
        isPausedInClip ? "Paused · saving \(elapsedText)…" : "Recording · \(elapsedText)"
    }

    /// System-wide shortcuts, shown in menus and hints.
    static let hotKeyHint = "⌥⌘R"
    static let fullScreenHotKeyHint = "⌥⌘F"
    static let newRegionHotKeyHint = "⌥⌘N"

    @ObservationIgnored private let selector = RegionSelectionController()
    @ObservationIgnored private let border = RecordingBorderController()
    @ObservationIgnored private let hud = SessionHUDController()
    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var hotKeys: [GlobalHotKey] = []
    /// Keeps the display from dimming or sleeping while a session runs (nobody touches the mouse).
    @ObservationIgnored private var awakeActivity: NSObjectProtocol?
    @ObservationIgnored private var userActivityTimer: Timer?
    @ObservationIgnored private var userActivityAssertion: IOPMAssertionID = 0

    private enum Keys {
        static let lastRegion = "lastCaptureRegion"
        static let aspect = "selectionAspect"
        static let mode = "captureMode"
        static let audio = "captureAudio"
    }

    init() {
        lastRegion = Self.load(CaptureRegion.self, forKey: Keys.lastRegion)
        aspect = AspectPreset(rawValue: UserDefaults.standard.string(forKey: Keys.aspect) ?? "") ?? .widescreen
        captureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .auto
        captureAudio = UserDefaults.standard.object(forKey: Keys.audio) as? Bool ?? true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.info("Cocut \(version) launched; screen permission: \(hasScreenPermission)")

        // System-wide shortcuts, so recording works even with the browser in fullscreen:
        // ⌥⌘R same region (or finish), ⌥⌘F full screen (or finish), ⌥⌘N pick a new region.
        let mods = cmdKey | optionKey
        let bindings: [(Int, UInt32, @MainActor (AppModel) async -> Void)] = [
            (kVK_ANSI_R, 1, { await $0.toggleRecording() }),
            (kVK_ANSI_F, 2, { await $0.toggleFullScreenRecording() }),
            (kVK_ANSI_N, 3, { await $0.toggleNewRegionRecording() }),
        ]
        for (key, id, action) in bindings {
            if let hotKey = GlobalHotKey(keyCode: key, modifiers: mods, id: id, handler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    await action(self)
                }
            }) {
                hotKeys.append(hotKey)
            }
        }
        // Older full-screen recordings: find the video in them once, in the background.
        Task { [library] in
            for clip in library.clips where clip.cropChecked == nil && clip.pixelWidth >= 2000 {
                _ = await library.autoCrop(clip.id)
            }
        }
        updater.checkForFailedInstall()
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

    // MARK: Session control

    func toggleRecording() async {
        switch phase {
        case .armed, .recording:
            await stopSession()
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

    func toggleFullScreenRecording() async {
        switch phase {
        case .armed, .recording: await stopSession()
        case .idle: await recordFullScreen()
        default: break
        }
    }

    func toggleNewRegionRecording() async {
        switch phase {
        case .armed, .recording: await stopSession()
        case .idle: await recordNewRegion()
        default: break
        }
    }

    // MARK: Import

    func importVideosWithPanel() async {
        let panel = NSOpenPanel()
        panel.title = "Import Videos"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        await importVideos(panel.urls)
    }

    func importVideos(_ urls: [URL]) async {
        let count = await library.importFiles(urls)
        Log.info("Imported \(count) of \(urls.count) video(s)")
        if count < urls.count {
            presentError("\(urls.count - count) file(s) couldn't be imported. Cocut can import videos macOS can play, such as .mp4 and .mov.",
                         title: "Import Problem")
        }
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard !isBusy else { return }
        captureMode = mode
    }

    func setCaptureAudio(_ on: Bool) {
        guard !isBusy else { return }
        captureAudio = on
    }

    func recordNewRegion() async {
        guard !isBusy, ensurePermission() else { return }
        phase = .selecting
        hideAppWindows()

        let region = await selector.selectRegion(initial: lastRegion, aspect: aspect, mode: captureMode,
                                                 captureAudio: captureAudio)
        aspect = selector.currentAspect
        captureMode = selector.currentMode
        captureAudio = selector.currentCaptureAudio

        guard let region else {
            Log.info("Region selection cancelled")
            restoreAppWindows()
            phase = .idle
            return
        }
        lastRegion = region
        await startSession(region)
    }

    /// Records the whole display the mouse is on, skipping region selection.
    func recordFullScreen() async {
        guard !isBusy, ensurePermission() else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let id = screen.displayID else { return }
        let region = CaptureRegion(displayID: id, rect: CGRect(origin: .zero, size: screen.frame.size))
        lastRegion = region
        hideAppWindows()
        await startSession(region)
    }

    func recordLastRegion() async {
        guard !isBusy, ensurePermission() else { return }
        guard let region = lastRegion, region.screen != nil else {
            await recordNewRegion()
            return
        }
        hideAppWindows()
        await startSession(region)
    }

    /// Ends the session; a clip in progress is finished and saved.
    func stopSession() async {
        guard isSessionActive, let session else { return }
        phase = .stopping
        stopTicking()
        border.hide()
        hud.hide()
        await session.stop()
        self.session = nil
        keepDisplayAwake(false)
        restoreAppWindows()
        phase = .idle
        Log.info("Session ended with \(clipsThisSession) clip(s)")
    }

    /// Throws away the clip being recorded. In auto mode Cocut keeps waiting for the next play.
    func discardCurrentClip() async {
        guard isRecording, let session else { return }
        stopTicking()
        await session.discardCurrent()
        if session.mode == .auto {
            phase = .armed
            border.setStyle(.armed)
        } else {
            self.session = nil
            keepDisplayAwake(false)
            border.hide()
            hud.hide()
            restoreAppWindows()
            phase = .idle
        }
    }

    private func startSession(_ region: CaptureRegion) async {
        phase = .starting
        clipsThisSession = 0
        sessionMode = captureMode
        let session = CaptureSession(mode: captureMode, captureAudio: captureAudio,
                                     tuning: settings.tuning,
                                     clipsDirectory: library.clipsDirectory)

        session.onSegmentStarted = { [weak self] in
            MainActor.assumeIsolated { self?.segmentStarted() }
        }
        session.onSegmentFinished = { [weak self] result in
            MainActor.assumeIsolated { self?.segmentFinished(result) }
        }
        session.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in await self?.handleUnexpectedStop(error) }
        }

        do {
            // ScreenCaptureKit can stall (e.g. behind a permission prompt); don't hang forever.
            try await withTimeout(seconds: 12) {
                try await session.start(region: region)
            }
        } catch {
            Log.error("Start failed: \(error.localizedDescription)")
            await session.stop()
            phase = .idle
            refreshPermission()
            presentError(hasScreenPermission
                ? error.localizedDescription
                : "Cocut needs Screen Recording permission. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Cocut.")
            return
        }

        self.session = session
        keepDisplayAwake(true)
        hud.show(near: region, model: self)
        if captureMode == .auto {
            phase = .armed
            border.show(around: region, style: .armed)
            returnFocusToVideo()
            Log.info("Armed; waiting for playback")
        } else {
            // Manual: the first frame starts the clip; show recording state right away.
            phase = .recording(startedAt: .now)
            startTicking(from: .now)
            border.show(around: region, style: .recording)
            returnFocusToVideo()
            Log.info("Recording started")
        }
    }

    private func segmentStarted() {
        guard session != nil else { return }
        if case .recording = phase { return }
        phase = .recording(startedAt: .now)
        startTicking(from: .now)
        border.setStyle(.recording)
    }

    private func segmentFinished(_ result: Result<CaptureSession.Segment, Error>) {
        switch result {
        case .success(let segment):
            clipsThisSession += 1
            Log.info("Saved \(segment.url.lastPathComponent) (\(Self.formatElapsed(segment.duration)))")
            if settings.playSoundOnSave { NSSound(named: "Pop")?.play() }
            Task {
                if let clip = await library.addClip(at: segment.url) {
                    // Full-screen and large recordings: find the video and crop to it.
                    _ = await library.autoCrop(clip.id)
                }
            }
        case .failure(let error):
            Log.error("Clip failed: \(error.localizedDescription)")
        }
        // Auto mode goes back to waiting for the next play.
        if session?.mode == .auto, isRecording {
            stopTicking()
            phase = .armed
            border.setStyle(.armed)
        }
    }

    private func handleUnexpectedStop(_ error: Error) async {
        guard isSessionActive else { return }
        // Keep whatever was captured before the interruption.
        await stopSession()
        // Stopping from macOS's own screen-recording menu bar indicator is a normal stop.
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userStopped.rawValue {
            return
        }
        presentError("Recording stopped unexpectedly: \(error.localizedDescription)")
    }

    private func ensurePermission() -> Bool {
        refreshPermission()
        if hasScreenPermission { return true }
        Log.info("Screen permission missing; requesting")
        requestPermission()
        return false
    }

    /// Blocking display sleep isn't always enough to stop the pre-sleep dim (notably on battery),
    /// so also tell macOS the user is active every few seconds, like video players do.
    private func keepDisplayAwake(_ awake: Bool) {
        if awake, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Recording game film")
            declareUserActivity()
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.declareUserActivity() }
            }
            RunLoop.main.add(timer, forMode: .common)
            userActivityTimer = timer
        } else if !awake {
            if let activity = awakeActivity {
                ProcessInfo.processInfo.endActivity(activity)
                awakeActivity = nil
            }
            userActivityTimer?.invalidate()
            userActivityTimer = nil
            if userActivityAssertion != 0 {
                IOPMAssertionRelease(userActivityAssertion)
                userActivityAssertion = 0
            }
        }
    }

    private func declareUserActivity() {
        var id = userActivityAssertion
        IOPMAssertionDeclareUserActivity("Cocut recording game film" as CFString, kIOPMUserActiveLocal, &id)
        userActivityAssertion = id
    }

    // MARK: Timer

    private func startTicking(from start: Date) {
        elapsed = 0
        isPausedInClip = false
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date().timeIntervalSince(start)
                // In auto mode, freeze the clock when the picture stops changing: the clip ends
                // where the video paused, even though saving waits a moment to be sure.
                let idle = self.sessionMode == .auto ? (self.session?.secondsSinceActivity() ?? 0) : 0
                let paused = idle > 0.6
                if paused != self.isPausedInClip { self.isPausedInClip = paused }
                self.elapsed = paused ? max(0, now - idle) : now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        elapsed = 0
        isPausedInClip = false
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Windows & alerts

    /// Gets the app's own windows out of the way while picking a region and recording.
    /// Windows are made transparent and click-through rather than ordered out: SwiftUI lists in an
    /// ordered-out window can come back blank. Cocut's windows are excluded from capture either way.
    private func hideAppWindows() {
        hiddenWindows = NSApp.windows.filter {
            $0.isVisible && $0.canBecomeMain && $0.alphaValue > 0 && !($0 is OverlayWindow)
        }
        for window in hiddenWindows {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }

    func restoreAppWindows() {
        for window in hiddenWindows {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)
        }
        hiddenWindows.removeAll()
        NSApp.activate()
    }

    /// Hands keyboard focus back to the browser so Space/K play and pause the video right away.
    private func returnFocusToVideo() {
        NSApp.deactivate()
    }

    /// Quits and reopens Cocut. macOS only applies a new Screen Recording permission after a relaunch.
    func relaunch() {
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "cocut-relaunch",
                          String(ProcessInfo.processInfo.processIdentifier),
                          Bundle.main.bundleURL.path(percentEncoded: false)]
        try? task.run()
        Log.info("Relaunching")
        NSApp.terminate(nil)
    }

    func presentError(_ message: String, title: String = "Recording Problem") {
        restoreAppWindows()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
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
