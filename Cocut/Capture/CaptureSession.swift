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

    // Tuning for auto mode.
    static let stillSeconds: Double = 1.2      // no change this long = paused
    static let minimumClipSeconds: Double = 1.0 // shorter bursts (hover controls, scrubbing) are dropped
    static let tailSeconds: Double = 0.15       // keep a moment after the last change
    static let frameRate: Int32 = 60

    let mode: CaptureMode

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

    init(mode: CaptureMode, clipsDirectory: URL) {
        self.mode = mode
        self.clipsDirectory = clipsDirectory
    }

    // MARK: Lifecycle

    func start(region: CaptureRegion) async throws {
        Log.info("Starting \(mode.rawValue) capture: display \(region.displayID), rect \(region.rect)")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        if mode == .auto { startStillTimer() }
        Log.info("Capture running at \(pixelWidth)x\(pixelHeight)")
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
        guard type == .screen, sampleBuffer.isValid, !stopping else { return }
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
        case .auto:
            let print = Self.fingerprint(pixelBuffer)
            let changed = Self.differs(print, previousPrint)
            previousPrint = print
            if changed {
                lastChangePTS = pts
                lastChangeHost = CACurrentMediaTime()
                if writer == nil { beginSegment() }
            }
        }

        writer?.append(pixelBuffer, at: pts)
    }

    private func beginSegment() {
        do {
            writer = try SegmentWriter(url: Self.makeClipURL(in: clipsDirectory), width: pixelWidth, height: pixelHeight)
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

        if mode == .auto, current.duration(endingAt: end) < Self.minimumClipSeconds {
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
            if CACurrentMediaTime() - self.lastChangeHost > Self.stillSeconds {
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
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 12 { changed += 1 }
        return changed >= max(4, a.count / 100)
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
    private var startPTS: CMTime?
    private var startHost: CFTimeInterval = 0
    private var lastPTS: CMTime = .zero

    init(url: URL, width: Int, height: Int) throws {
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
