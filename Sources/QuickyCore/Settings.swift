import Foundation

public enum CaptureFormat: String, CaseIterable, Sendable {
    case gif, video

    public var fileExtension: String { self == .gif ? "gif" : "mp4" }
    public var title: String { self == .gif ? "GIF" : "MP4" }
}

public enum CaptureDuration: Int, CaseIterable, Sendable {
    case five = 5, ten = 10, thirty = 30, untilStopped = 0

    /// nil means record until the user stops.
    public var seconds: TimeInterval? { self == .untilStopped ? nil : TimeInterval(rawValue) }
    public var title: String { self == .untilStopped ? "Until I Stop" : "\(rawValue) Seconds" }
}

/// Trades file size against sharpness and smoothness.
public enum CaptureQuality: String, CaseIterable, Sendable {
    case low, medium, high

    public var title: String { rawValue.capitalized }

    public func framesPerSecond(for format: CaptureFormat) -> Int {
        switch (format, self) {
        case (.gif, .low): 10
        case (.gif, _): 15
        case (.video, _): 30
        }
    }

    /// GIFs are scaled down to at most this many pixels wide.
    var gifMaxWidth: CGFloat {
        switch self {
        case .low: 480
        case .medium: 800
        case .high: 1200
        }
    }

    /// GIF frames are held in memory until the file is written, so open-ended GIFs are capped.
    public var gifMaxSeconds: TimeInterval { self == .high ? 30 : 60 }

    /// Bits per second for a video of the given pixel size.
    public func videoBitRate(width: Int, height: Int) -> Int {
        let (perPixel, cap) = switch self {
        case .low: (1, 4_000_000)
        case .medium: (2, 8_000_000)
        case .high: (4, 16_000_000)
        }
        return min(cap, max(500_000, width * height * perPixel))
    }

    /// Output size in pixels for a region of `pointSize` on a display with the given backing scale.
    /// Dimensions are even, as video encoders require.
    public func outputSize(for pointSize: CGSize, scale: CGFloat, format: CaptureFormat) -> (width: Int, height: Int) {
        // Low-quality video records at 1x rather than Retina resolution.
        let scale = format == .video && self == .low ? 1 : scale
        var size = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        if format == .gif, size.width > gifMaxWidth {
            size = CGSize(width: gifMaxWidth, height: size.height * gifMaxWidth / size.width)
        }
        func even(_ value: CGFloat) -> Int {
            let n = Int(value.rounded())
            return max(2, n - n % 2)
        }
        return (even(size.width), even(size.height))
    }
}

/// How long captures stay in the folder before being moved to the Trash.
public enum CaptureRetention: Int, CaseIterable, Sendable {
    case forever = 0, month = 30, week = 7

    /// nil means never remove anything.
    public var days: Int? { self == .forever ? nil : rawValue }
    public var title: String { self == .forever ? "Forever" : "\(rawValue) Days" }
}

/// A region on one display, in points, origin at the display's top-left.
public struct StoredRegion: Codable, Equatable, Sendable {
    public var displayID: UInt32
    public var x, y, width, height: Double

    public init(displayID: UInt32, rect: CGRect) {
        self.displayID = displayID
        x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public final class Settings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var format: CaptureFormat {
        get { defaults.string(forKey: "format").flatMap(CaptureFormat.init) ?? .gif }
        set { defaults.set(newValue.rawValue, forKey: "format") }
    }

    public var duration: CaptureDuration {
        get { (defaults.object(forKey: "duration") as? Int).flatMap(CaptureDuration.init) ?? .ten }
        set { defaults.set(newValue.rawValue, forKey: "duration") }
    }

    public var reuseLastRegion: Bool {
        get { defaults.bool(forKey: "reuseLastRegion") }
        set { defaults.set(newValue, forKey: "reuseLastRegion") }
    }

    public var quality: CaptureQuality {
        get { defaults.string(forKey: "quality").flatMap(CaptureQuality.init) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    public var retention: CaptureRetention {
        get { (defaults.object(forKey: "retention") as? Int).flatMap(CaptureRetention.init) ?? .forever }
        set { defaults.set(newValue.rawValue, forKey: "retention") }
    }

    public var lastRegion: StoredRegion? {
        get { defaults.data(forKey: "lastRegion").flatMap { try? JSONDecoder().decode(StoredRegion.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastRegion") }
    }
}
