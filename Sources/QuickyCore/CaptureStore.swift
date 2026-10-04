import AVFoundation
import Foundation
import ImageIO

public struct Capture: Identifiable, Equatable, Sendable {
    public let url: URL
    public let format: CaptureFormat
    public let byteCount: Int
    public let date: Date

    public var id: URL { url }
}

/// The captures folder is the source of truth; there is no separate database.
public final class CaptureStore {
    public let directory: URL
    private let fileManager = FileManager.default

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Quicky")
    }

    public init(directory: URL = CaptureStore.defaultDirectory) {
        self.directory = directory
    }

    /// A unique URL in the captures folder, creating the folder if needed.
    public func newURL(format: CaptureFormat, date: Date = Date()) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Quicky \(formatter.string(from: date))"
        var url = directory.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(format.fileExtension)
            n += 1
        }
        return url
    }

    /// Captures in the folder, newest first.
    public func list() -> [Capture] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return urls.compactMap { url -> Capture? in
            guard let format = CaptureFormat.allCases.first(where: { $0.fileExtension == url.pathExtension.lowercased() }),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Capture(url: url, format: format, byteCount: values.fileSize ?? 0, date: values.creationDate ?? .distantPast)
        }
        .sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }
    }

    public func delete(_ capture: Capture) throws {
        try fileManager.trashItem(at: capture.url, resultingItemURL: nil)
    }

    /// Moves captures older than `days` to the Trash. Returns how many were removed.
    @discardableResult
    public func prune(olderThan days: Int, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return list().filter { $0.date < cutoff }.reduce(0) { count, capture in
            (try? delete(capture)) == nil ? count : count + 1
        }
    }

    public static func duration(of capture: Capture) async -> TimeInterval? {
        switch capture.format {
        case .video:
            return try? await AVURLAsset(url: capture.url).load(.duration).seconds
        case .gif:
            guard let source = CGImageSourceCreateWithURL(capture.url as CFURL, nil) else { return nil }
            return (0..<CGImageSourceGetCount(source)).reduce(0) { total, i in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                return total + (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0)
            }
        }
    }
}
