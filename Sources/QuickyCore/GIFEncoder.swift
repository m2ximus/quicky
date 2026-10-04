import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class GIFEncoder: FrameEncoder {
    private let url: URL
    private let destination: CGImageDestination
    private var pending: (image: CGImage, time: TimeInterval)?

    public init(url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 0, nil) else {
            throw EncodingError.cannotCreateOutput
        }
        self.url = url
        self.destination = destination
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
    }

    public func append(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) throws {
        guard let image = Self.copyImage(from: pixelBuffer) else { throw EncodingError.writeFailed(nil) }
        // A frame's delay is only known once the next frame arrives.
        flushPending(until: time)
        pending = (image, time)
    }

    public func finish(endTime: TimeInterval) async throws -> URL {
        guard pending != nil else {
            cancel()
            throw EncodingError.noFrames
        }
        flushPending(until: endTime)
        guard CGImageDestinationFinalize(destination) else {
            cancel()
            throw EncodingError.writeFailed(nil)
        }
        return url
    }

    public func cancel() {
        pending = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func flushPending(until time: TimeInterval) {
        guard let pending else { return }
        // GIF delays are in hundredths of a second; viewers treat anything under 0.02 as slow.
        let delay = max(0.02, time - pending.time)
        let properties = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFUnclampedDelayTime: delay,
            kCGImagePropertyGIFDelayTime: delay,
        ]]
        CGImageDestinationAddImage(destination, pending.image, properties as CFDictionary)
        self.pending = nil
    }

    /// Copies the pixels, since the capture stream reuses its buffers.
    private static func copyImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return context?.makeImage()
    }
}
