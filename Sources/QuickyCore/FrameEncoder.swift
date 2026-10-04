import CoreVideo
import Foundation

public enum EncodingError: LocalizedError {
    case noFrames
    case cannotCreateOutput
    case writeFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noFrames: "No frames were captured."
        case .cannotCreateOutput: "Could not create the output file."
        case .writeFailed(let error): "Could not write the recording. \(error?.localizedDescription ?? "")"
        }
    }
}

/// Turns timestamped frames into a file. Calls must be serialized by the caller.
public protocol FrameEncoder: AnyObject {
    /// `time` is seconds since the first frame.
    func append(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) throws
    /// `endTime` is when recording stopped, so the last frame gets its real duration.
    func finish(endTime: TimeInterval) async throws -> URL
    /// Abandon the recording and remove any partial file.
    func cancel()
}
