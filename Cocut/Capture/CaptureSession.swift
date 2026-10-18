import AVFoundation
import CoreMedia
import QuartzCore
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case displayNotFound
    case writerFailed(String)
    case noFrames
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "The display for this region is no longer connected."
        case .writerFailed(let reason):
            return "The clip couldn't be saved. \(reason)"
        case .noFrames:
            return "No video was captured. If the video was paused the whole time, press play and try again."
        case .startTimedOut:
            return "macOS didn't start the screen capture. Check System Settings › Privacy & Security › Screen & System Audio Recording, make sure Cocut is on, then quit and reopen Cocut."
        }
    }
}

/// Auto-mode timing the user can adjust in Settings.
/// The clip always ends at the last change, so a longer stillSeconds only delays the save;
/// it doesn't add dead time to the clip.
struct CaptureTuning: Sendable {
    /// No change in the region for this long means the video was paused.
    var stillSeconds: Double = 3.0
    /// Shorter bursts (hover controls, scrubbing, page flicker) are dropped.
    var minimumClipSeconds: Double = 2.0
}

enum CaptureMode: String, Codable {
    /// Recording starts right away and runs until Stop.
    case manual
    /// The region is watched; playback (motion) starts a clip and a pause (stillness) ends it.
    case auto
}

/// Watches one screen region with ScreenCaptureKit and writes clips ("segments") with AVAssetWriter.
/// Cocut's own windows are excluded from the capture.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Segment {
        let url: URL
        let duration: Double
    }

    // Fixed tuning for auto mode (the user-adjustable parts live in CaptureTuning).
    static let tailSeconds: Double = 0.15       // keep a moment after the last change
    static let armingGraceSeconds: Double = 1.0 // ignore the repaint when focus returns to the browser
    static let frameRate: Int32 = 60

    let mode: CaptureMode
    let captureAudio: Bool
    let tuning: CaptureTuning

    /// All callbacks arrive on the main queue.
    var onSegmentStarted: (() -> Void)?
    var onSegmentFinished: ((Result<Segment, Error>) -> Void)?
    var onUnexpectedStop: ((Error) -> Void)?

    private let clipsDirectory: URL
    private let queue = DispatchQueue(label: "com.mjcocat.Cocut.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var stillTimer: DispatchSourceTimer?
    private var pixelWidth = 0
    private var pixelHeight = 0

    // Everything below is touched only on `queue`.
    private var writer: SegmentWriter?
    private var previousPrint: [UInt8] = []
    private var lastChangePTS: CMTime = .zero
    private var lastChangeHost: CFTimeInterval = 0
    private var stopping = false

    /// Last time the picture changed, readable from the main thread for the on-screen clock.
    private let activityLock = NSLock()
    private var activityHost: CFTimeInterval = 0

    /// Seconds since the captured picture last changed (0 while it's changing).
    func secondsSinceActivity() -> Double {
        activityLock.lock()
        defer { activityLock.unlock() }
        guard activityHost > 0 else { return 0 }
        return max(0, CACurrentMediaTime() - activityHost)
    }

    private func markActivity(_ host: CFTimeInterval) {
        activityLock.lock()
        activityHost = host
        activityLock.unlock()
    }
    private var armedAtHost: CFTimeInterval = 0

    init(mode: CaptureMode, captureAudio: Bool, tuning: CaptureTuning, clipsDirectory: URL) {
        self.mode = mode
        self.captureAudio = captureAudio
        self.tuning = tuning
        self.clipsDirectory = clipsDirectory
    }

    // MARK: Lifecycle

    func start(region: CaptureRegion) async throws {
        Log.info("Starting \(mode.rawValue) capture: display \(region.displayID), rect \(region.rect)")
        // All windows, not just on-screen ones: with a browser in fullscreen, Cocut's own windows are
        // on another Space, and an on-screen-only query would leave Cocut out of the list — and
        // then its floating control and outline would end up in the recording.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        if ownApps.isEmpty {
            Log.error("Cocut wasn't in the shareable app list; its windows may appear in the recording")
        }

        let scale = CGFloat(filter.pointPixelScale)
        let rect = region.rect.intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))
        pixelWidth = max(2, Int((rect.width * scale).rounded()) & ~1)   // H.264 wants even sizes
        pixelHeight = max(2, Int((rect.height * scale).rounded()) & ~1)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.frameRate)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 6
        if captureAudio {
            // System audio (the browser's sound); Cocut's own sounds are left out.
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream

        if mode == .auto {
            queue.sync { armedAtHost = CACurrentMediaTime() }
            startStillTimer()
        }
        Log.info("Capture running at \(pixelWidth)x\(pixelHeight), audio \(captureAudio ? "on" : "off")")
    }

    /// Ends the session, finishing any clip in progress (delivered through `onSegmentFinished`).
    func stop() async {
        await stopStream()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stopping = true
                guard let writer else { done.resume(); return }
                let end: CMTime
                if mode == .manual {
                    // Frames only arrive when pixels change, so extend to the moment Stop was pressed.
                    end = writer.sourceTime(forHostTime: CACurrentMediaTime())
                } else {
                    end = CMTimeAdd(lastChangePTS, CMTime(seconds: Self.tailSeconds, preferredTimescale: 600))
                }
                finishCurrent(endingAt: end) { done.resume() }
            }
        }
    }

    /// Throws away the clip in progress. Auto mode keeps watching; manual mode ends the session.
    func discardCurrent() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                writer?.cancel()
                writer = nil
                previousPrint = []
                done.resume()
            }
        }
        if mode == .manual { await stopStream() }
        Log.info("Clip discarded")
    }

    private func stopStream() async {
        stillTimer?.cancel()
        stillTimer = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, !stopping else { return }
        if type == .audio {
            // Sound rides along with whatever clip is being written; motion alone starts and ends clips.
            writer?.appendAudio(sampleBuffer)
            return
        }
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let pts = sampleBuffer.presentationTimeStamp

        switch mode {
        case .manual:
            if writer == nil { beginSegment() }
            markActivity(CACurrentMediaTime())
        case .auto:
            let print = Self.fingerprint(pixelBuffer)
            let changed = Self.differs(print, previousPrint)
            previousPrint = print
            if changed, CACurrentMediaTime() - armedAtHost > Self.armingGraceSeconds {
                lastChangePTS = pts
                lastChangeHost = CACurrentMediaTime()
                markActivity(lastChangeHost)
                if writer == nil { beginSegment() }
            }
        }

        writer?.append(pixelBuffer, at: pts)
    }

    private func beginSegment() {
        do {
            writer = try SegmentWriter(url: Self.makeClipURL(in: clipsDirectory),
                                       width: pixelWidth, height: pixelHeight, audio: captureAudio)
            Log.info("Clip started")
            DispatchQueue.main.async { [weak self] in self?.onSegmentStarted?() }
        } catch {
            Log.error("Couldn't start clip: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in self?.onSegmentFinished?(.failure(error)) }
        }
    }

    private func finishCurrent(endingAt end: CMTime, then completion: (() -> Void)? = nil) {
        guard let current = writer else { completion?(); return }
        writer = nil
        previousPrint = []

        if mode == .auto, current.duration(endingAt: end) < self.tuning.minimumClipSeconds {
            Log.info("Dropped a \(String(format: "%.2f", current.duration(endingAt: end)))s burst")
            current.cancel()
            completion?()
            return
        }

        current.finish(endingAt: end) { [weak self] result in
            let mapped = result.map { Segment(url: $0, duration: current.duration(endingAt: end)) }
            if case .failure(let error) = result { Log.error("Clip failed: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                self?.onSegmentFinished?(mapped)
                completion?()
            }
        }
    }

    private func startStillTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping, self.writer != nil else { return }
            if CACurrentMediaTime() - self.lastChangeHost > self.tuning.stillSeconds {
                let end = CMTimeAdd(self.lastChangePTS, CMTime(seconds: Self.tailSeconds, preferredTimescale: 600))
                self.finishCurrent(endingAt: end)
            }
        }
        timer.resume()
        stillTimer = timer
    }

    // MARK: Motion detection

    /// A 40×24 grid of luminance samples — cheap enough to run on every frame.
    private static func fingerprint(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let cols = 40, rows = 24
        var out = [UInt8](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            let y = (2 * r + 1) * height / (2 * rows)
            for c in 0..<cols {
                let x = (2 * c + 1) * width / (2 * cols)
                let o = y * rowBytes + x * 4 // BGRA
                let luma = (Int(bytes[o + 2]) * 77 + Int(bytes[o + 1]) * 150 + Int(bytes[o]) * 29) >> 8
                out[r * cols + c] = UInt8(luma)
            }
        }
        return out
    }

    private static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        // An empty previous print means "no baseline yet": this frame only sets one.
        guard !a.isEmpty, a.count == b.count else { return false }
        var changed = 0
        // Sensitive on purpose: a paused video is pixel-identical, so any real difference
        // means it's playing — even a slow stretch of fixed-camera game film.
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 4 { changed += 1 }
        return changed >= 3
    }

    static func makeClipURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: .now)
        var url = directory.appending(path: "Clip \(stamp).mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = directory.appending(path: "Clip \(stamp) \(n).mov")
            n += 1
        }
        return url
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Stream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.onUnexpectedStop?(error)
        }
    }
}

// MARK: - Segment writer

/// One clip file. Not thread-safe; used only on the capture queue.
final class SegmentWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private var startPTS: CMTime?
    private var startHost: CFTimeInterval = 0
    private var lastPTS: CMTime = .zero

    init(url: URL, width: Int, height: Int, audio: Bool) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let fps = Int(CaptureSession.frameRate)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(width * height) * Double(fps) * 0.12),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("Unsupported video settings.") }
        writer.add(input)

        if audio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            } else {
                self.audioInput = nil
            }
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "Couldn't start writing.")
        }
    }

    func append(_ buffer: CVPixelBuffer, at pts: CMTime) {
        guard writer.status == .writing else { return }
        if startPTS == nil {
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            startHost = CACurrentMediaTime()
        } else if pts <= lastPTS {
            return
        }
        if input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: pts) {
            lastPTS = pts
        }
    }

    /// Audio is kept only once the video has started the clip, so the two stay in sync.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput, writer.status == .writing, let startPTS,
              sampleBuffer.presentationTimeStamp >= startPTS,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Maps "now" onto the capture timeline, for ending a clip at the moment Stop was pressed.
    func sourceTime(forHostTime host: CFTimeInterval) -> CMTime {
        guard let startPTS else { return .zero }
        return CMTimeAdd(startPTS, CMTime(seconds: host - startHost, preferredTimescale: 600))
    }

    func duration(endingAt end: CMTime) -> Double {
        guard let startPTS else { return 0 }
        return max(0, CMTimeMaximum(end, lastPTS).seconds - startPTS.seconds)
    }

    func finish(endingAt end: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
        guard startPTS != nil else {
            cancel()
            completion(.failure(RecorderError.noFrames))
            return
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(end, lastPTS))
        let assetWriter = writer
        let fileURL = url
        assetWriter.finishWriting {
            if assetWriter.status == .completed {
                completion(.success(fileURL))
            } else {
                completion(.failure(RecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "Unknown error.")))
            }
        }
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
