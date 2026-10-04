import AVFoundation
import CoreVideo
import Foundation

public final class VideoEncoder: FrameEncoder {
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var frameCount = 0

    /// `width` and `height` are in pixels and must be even.
    public init(url: URL, width: Int, height: Int, quality: CaptureQuality = .medium) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // H.264 rather than HEVC so the file plays wherever it is sent.
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: quality.videoBitRate(width: width, height: height)],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw EncodingError.cannotCreateOutput }
        writer.add(input)
        guard writer.startWriting() else { throw EncodingError.writeFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)
    }

    public func append(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) throws {
        // Dropping a frame is better than blocking the capture queue.
        guard input.isReadyForMoreMediaData else { return }
        guard adaptor.append(pixelBuffer, withPresentationTime: Self.time(time)) else {
            throw EncodingError.writeFailed(writer.error)
        }
        frameCount += 1
    }

    public func finish(endTime: TimeInterval) async throws -> URL {
        guard frameCount > 0 else {
            cancel()
            throw EncodingError.noFrames
        }
        writer.endSession(atSourceTime: Self.time(endTime))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            let error = writer.error
            try? FileManager.default.removeItem(at: url)
            throw EncodingError.writeFailed(error)
        }
        return url
    }

    public func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    private static func time(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
