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

/// Records one screen region to a .mov using ScreenCaptureKit + AVAssetWriter.
/// Our own windows (selection overlay, HUD, border) are excluded from the capture.
final class RegionRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on the main queue if capture stops unexpectedly (display unplugged, permission revoked).
    var onUnexpectedStop: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.mjcocat.Cocut.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Touched only on `queue` once capture is running.
    private var sessionStarted = false
    private var firstPTS: CMTime = .zero
    private var firstHostTime: CFTimeInterval = 0
    private var lastPTS: CMTime = .zero

    static let frameRate: Int32 = 60

    func start(region: CaptureRegion, outputURL: URL) async throws {
        Log.info("Starting capture: display \(region.displayID), rect \(region.rect)")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Log.info("Shareable content: \(content.displays.count) displays, \(content.applications.count) apps")
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = CGFloat(filter.pointPixelScale)
        let rect = region.rect.intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))
        let pixelWidth = max(2, Int((rect.width * scale).rounded()) & ~1)    // H.264 wants even sizes
        let pixelHeight = max(2, Int((rect.height * scale).rounded()) & ~1)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.frameRate)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 6

        // Writer
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitRate = Int(Double(pixelWidth * pixelHeight) * Double(Self.frameRate) * 0.12)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.frameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("Unsupported video settings.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "Couldn't start writing.")
        }

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.sessionStarted = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("Capture running at \(pixelWidth)x\(pixelHeight) -> \(outputURL.lastPathComponent)")
    }

    /// Stops capture and finalizes the file. Returns the finished clip URL.
    func stop() async throws -> URL {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let writer, let input else {
                    continuation.resume(throwing: RecorderError.noFrames)
                    return
                }
                guard sessionStarted else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: writer.outputURL)
                    continuation.resume(throwing: RecorderError.noFrames)
                    return
                }
                // ScreenCaptureKit only delivers frames when pixels change, so extend the clip
                // to the moment Stop was pressed (e.g. if the video was paused at the end).
                let elapsed = CACurrentMediaTime() - firstHostTime
                let endTime = CMTimeMaximum(lastPTS, CMTimeAdd(firstPTS, CMTime(seconds: elapsed, preferredTimescale: 600)))
                input.markAsFinished()
                writer.endSession(atSourceTime: endTime)
                writer.finishWriting {
                    Log.info("Writer finished with status \(writer.status.rawValue)")
                    if writer.status == .completed {
                        continuation.resume(returning: writer.outputURL)
                    } else {
                        continuation.resume(throwing: RecorderError.writerFailed(writer.error?.localizedDescription ?? "Unknown error."))
                    }
                }
            }
        }
    }

    /// Stops capture and deletes whatever was written.
    func discard() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let writer {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: writer.outputURL)
                }
                continuation.resume()
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Skip idle/blank frames; only append frames that carry new pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        guard let writer, let input, let adaptor, writer.status == .writing else { return }

        let pts = sampleBuffer.presentationTimeStamp
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstPTS = pts
            firstHostTime = CACurrentMediaTime()
        }
        guard pts > lastPTS || lastPTS == .zero else { return }
        if input.isReadyForMoreMediaData, adaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastPTS = pts
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Stream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.onUnexpectedStop?(error)
        }
    }
}
