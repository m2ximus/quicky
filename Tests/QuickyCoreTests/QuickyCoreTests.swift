import AVFoundation
import AppKit
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import QuickyCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("quicky-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFrame(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    memset(CVPixelBufferGetBaseAddress(buffer!), Int32(shade), CVPixelBufferGetDataSize(buffer!))
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    return buffer!
}

@Suite struct SettingsTests {
    let defaults = UserDefaults(suiteName: "quicky-tests-\(UUID().uuidString)")!

    @Test func defaultsMatchTheSpec() {
        let settings = Settings(defaults: defaults)
        #expect(settings.format == .gif)
        #expect(settings.duration == .ten)
        #expect(settings.reuseLastRegion == false)
        #expect(settings.lastRegion == nil)
        #expect(settings.retention == .forever)
        #expect(settings.quality == .medium)
        #expect(settings.retention.days == nil)
    }

    @Test func valuesPersistAcrossInstances() {
        let region = StoredRegion(displayID: 7, rect: CGRect(x: 10, y: 20, width: 300, height: 200))
        let settings = Settings(defaults: defaults)
        settings.format = .video
        settings.duration = .untilStopped
        settings.reuseLastRegion = true
        settings.lastRegion = region
        settings.retention = .week
        settings.quality = .high

        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.format == .video)
        #expect(reloaded.duration == .untilStopped)
        #expect(reloaded.duration.seconds == nil)
        #expect(reloaded.reuseLastRegion)
        #expect(reloaded.lastRegion == region)
        #expect(reloaded.retention.days == 7)
        #expect(reloaded.quality == .high)
        #expect(reloaded.lastRegion?.rect == CGRect(x: 10, y: 20, width: 300, height: 200))
    }
}

@Suite struct QualityTests {
    let region = CGSize(width: 1000, height: 601)

    @Test func gifWidthIsCappedPerQualityAndKeepsAspectRatio() {
        #expect(CaptureQuality.low.outputSize(for: region, scale: 2, format: .gif) == (480, 288))
        #expect(CaptureQuality.medium.outputSize(for: region, scale: 2, format: .gif) == (800, 480))
        #expect(CaptureQuality.high.outputSize(for: region, scale: 2, format: .gif) == (1200, 720))
    }

    @Test func smallRegionsAreNeverScaledUp() {
        #expect(CaptureQuality.high.outputSize(for: CGSize(width: 200, height: 100), scale: 2, format: .gif) == (400, 200))
    }

    @Test func videoIsRetinaExceptAtLowQualityAndAlwaysEven() {
        #expect(CaptureQuality.low.outputSize(for: region, scale: 2, format: .video) == (1000, 600))
        #expect(CaptureQuality.medium.outputSize(for: region, scale: 2, format: .video) == (2000, 1202))
        #expect(CaptureQuality.high.outputSize(for: CGSize(width: 1, height: 1), scale: 1, format: .video) == (2, 2))
    }

    @Test func higherQualityMeansMoreBitsAndFrames() {
        let rates = CaptureQuality.allCases.map { $0.videoBitRate(width: 1280, height: 720) }
        #expect(rates == rates.sorted() && Set(rates).count == 3)
        #expect(CaptureQuality.low.framesPerSecond(for: .gif) < CaptureQuality.high.framesPerSecond(for: .gif))
        #expect(CaptureQuality.high.gifMaxSeconds < CaptureQuality.medium.gifMaxSeconds)
    }
}

@Suite struct CaptureStoreTests {
    @Test func newURLsAreUniqueAndCreateTheFolder() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Captures")
        let store = CaptureStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try store.newURL(format: .gif, date: date)
        try Data("a".utf8).write(to: first)
        let second = try store.newURL(format: .gif, date: date)

        #expect(first.pathExtension == "gif")
        #expect(first.lastPathComponent.hasPrefix("Quicky "))
        #expect(first != second)
        #expect(try store.newURL(format: .video, date: date).pathExtension == "mp4")
    }

    @Test func listShowsOnlyCapturesNewestFirst() throws {
        let store = CaptureStore(directory: try temporaryDirectory())
        let old = store.directory.appendingPathComponent("old.gif")
        let new = store.directory.appendingPathComponent("new.mp4")
        try Data("12345".utf8).write(to: old)
        try Data("12".utf8).write(to: new)
        try Data("x".utf8).write(to: store.directory.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: old.path)

        let captures = store.list()
        #expect(captures.map(\.url.lastPathComponent) == ["new.mp4", "old.gif"])
        #expect(captures.map(\.format) == [.video, .gif])
        #expect(captures.map(\.byteCount) == [2, 5])
    }

    @Test func listIsEmptyWhenTheFolderIsMissing() throws {
        let store = CaptureStore(directory: try temporaryDirectory().appendingPathComponent("missing"))
        #expect(store.list().isEmpty)
    }

    @Test func pruneRemovesOnlyCapturesOlderThanTheLimit() throws {
        let store = CaptureStore(directory: try temporaryDirectory())
        let now = Date()
        for (name, ageInDays) in [("fresh.gif", 1.0), ("stale.mp4", 8.0), ("notes.txt", 100.0)] {
            let url = store.directory.appendingPathComponent(name)
            try Data("a".utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-ageInDays * 86_400)], ofItemAtPath: url.path)
        }

        #expect(store.prune(olderThan: 7, now: now) == 1)
        #expect(store.list().map(\.url.lastPathComponent) == ["fresh.gif"])
        // Files that are not captures are never touched.
        #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("notes.txt").path))
    }

    @Test func deleteRemovesTheFile() throws {
        let store = CaptureStore(directory: try temporaryDirectory())
        let url = try store.newURL(format: .gif)
        try Data("a".utf8).write(to: url)

        try store.delete(store.list()[0])
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct EncoderTests {
    @Test func gifHasEveryFrameAndTheRecordedDuration() async throws {
        let url = try temporaryDirectory().appendingPathComponent("out.gif")
        let encoder = try GIFEncoder(url: url)
        for i in 0..<5 {
            try encoder.append(makeFrame(width: 120, height: 80, shade: UInt8(i * 50)), at: Double(i) * 0.2)
        }
        let result = try await encoder.finish(endTime: 1.5)

        let source = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 5)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 120)
        #expect(image.height == 80)
        // Four 0.2 s frames, then the last one held until the 1.5 s stop.
        let capture = Capture(url: result, format: .gif, byteCount: 0, date: Date())
        let duration = try #require(await CaptureStore.duration(of: capture))
        #expect(abs(duration - 1.5) < 0.05)
    }

    @Test func videoHasTheRequestedSizeAndDuration() async throws {
        let url = try temporaryDirectory().appendingPathComponent("out.mp4")
        let encoder = try VideoEncoder(url: url, width: 320, height: 240)
        for i in 0..<10 {
            try encoder.append(makeFrame(width: 320, height: 240, shade: UInt8(i * 25)), at: Double(i) * 0.1)
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try await encoder.finish(endTime: 1.0)

        let asset = AVURLAsset(url: result)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 240))
        #expect(abs(try await asset.load(.duration).seconds - 1.0) < 0.05)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(description.mediaSubType == .h264)
    }

    @Test func finishingWithNoFramesFailsAndLeavesNoFile() async throws {
        let directory = try temporaryDirectory()
        let gifURL = directory.appendingPathComponent("empty.gif")
        let videoURL = directory.appendingPathComponent("empty.mp4")
        let encoders: [FrameEncoder] = [try GIFEncoder(url: gifURL), try VideoEncoder(url: videoURL, width: 320, height: 240)]

        for encoder in encoders {
            await #expect(throws: EncodingError.self) { try await encoder.finish(endTime: 1) }
        }
        #expect(!FileManager.default.fileExists(atPath: gifURL.path))
        #expect(!FileManager.default.fileExists(atPath: videoURL.path))
    }

    @Test func cancelRemovesThePartialFile() async throws {
        let url = try temporaryDirectory().appendingPathComponent("partial.mp4")
        let encoder = try VideoEncoder(url: url, width: 320, height: 240)
        try encoder.append(makeFrame(width: 320, height: 240, shade: 10), at: 0)
        encoder.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct ClipboardTests {
    @Test func gifIsCopiedAsBothAFileAndImageData() throws {
        let url = try temporaryDirectory().appendingPathComponent("clip.gif")
        try Data("GIF89a".utf8).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quicky-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        Clipboard.copy(url, to: pasteboard)
        #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
        #expect(pasteboard.data(forType: Clipboard.gifType) == Data("GIF89a".utf8))
    }

    @Test func videoIsCopiedAsAFileOnly() throws {
        let url = try temporaryDirectory().appendingPathComponent("clip.mp4")
        try Data("x".utf8).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quicky-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        Clipboard.copy(url, to: pasteboard)
        #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
        #expect(pasteboard.data(forType: Clipboard.gifType) == nil)
    }
}
