import CoreMedia
import Foundation
import ScreenCaptureKit

public enum RecorderError: LocalizedError {
    case displayNotFound

    public var errorDescription: String? { "The display to record is no longer available." }
}

/// Captures one region of one display and feeds the frames to an encoder.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    public struct Target {
        public var displayID: CGDirectDisplayID
        /// Points, origin at the display's top-left.
        public var rect: CGRect
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var framesPerSecond: Int

        public init(displayID: CGDirectDisplayID, rect: CGRect, pixelWidth: Int, pixelHeight: Int, framesPerSecond: Int) {
            self.displayID = displayID
            self.rect = rect
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.framesPerSecond = framesPerSecond
        }
    }

    /// Called on an arbitrary queue if the stream stops by itself or a frame cannot be encoded.
    public var onFailure: ((Error) -> Void)?

    private let target: Target
    private let encoder: FrameEncoder
    private let queue = DispatchQueue(label: "quicky.recorder")
    private var stream: SCStream?
    private var firstFrameTime: TimeInterval?
    private var failed = false

    public init(target: Target, encoder: FrameEncoder) {
        self.target = target
        self.encoder = encoder
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw RecorderError.displayNotFound
        }
        // Leave our own windows (region border, captures panel) out of the recording.
        let ownApp = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = target.rect
        configuration.width = target.pixelWidth
        configuration.height = target.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(target.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async throws -> URL {
        try? await stream?.stopCapture()
        stream = nil
        let endTime = queue.sync { firstFrameTime.map { Self.now() - $0 } ?? 0 }
        return try await encoder.finish(endTime: endTime)
    }

    public func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync { encoder.cancel() }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !failed, Self.isComplete(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let time = sampleBuffer.presentationTimeStamp.seconds
        if firstFrameTime == nil { firstFrameTime = time }
        do {
            try encoder.append(pixelBuffer, at: time - firstFrameTime!)
        } catch {
            failed = true
            onFailure?(error)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }

    /// The stream also delivers idle frames with no new image; only complete ones carry pixels.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: rawStatus) == .complete
    }

    /// Frame timestamps are on the host clock.
    private static func now() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}
