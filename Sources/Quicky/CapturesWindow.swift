import AppKit
import QuickLookThumbnailing
import QuickyCore
import SwiftUI

@MainActor
final class CapturesModel: ObservableObject {
    private static let visibleCount = 20

    @Published var captures: [Capture] = []
    /// The capture currently on the clipboard, if we put it there.
    @Published var copiedURL: URL?
    let store: CaptureStore

    init(store: CaptureStore) {
        self.store = store
    }

    func reload() {
        captures = Array(store.list().prefix(Self.visibleCount))
    }

    func copy(_ capture: Capture) {
        Clipboard.copy(capture.url)
        copiedURL = capture.url
    }

    func reveal(_ capture: Capture) {
        NSWorkspace.shared.activateFileViewerSelecting([capture.url])
    }

    func delete(_ capture: Capture) {
        do {
            try store.delete(capture)
        } catch {
            NSAlert(error: error).runModal()
        }
        reload()
    }
}

/// The small floating panel listing recent captures.
@MainActor
final class CapturesWindowController {
    private let model: CapturesModel
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quicky"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CapturesView(model: model))
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(CGPoint(x: visible.maxX - 380, y: visible.maxY - 20))
        }
        return panel
    }()

    init(store: CaptureStore) {
        model = CapturesModel(store: store)
    }

    func show(copied url: URL? = nil) {
        if let url { model.copiedURL = url }
        model.reload()
        panel.orderFrontRegardless()
    }
}

private struct CapturesView: View {
    @ObservedObject var model: CapturesModel

    var body: some View {
        if model.captures.isEmpty {
            Text("No captures yet.\nPress ⌥⇧R to record.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.captures) { capture in
                        CaptureRow(capture: capture, model: model)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct CaptureRow: View {
    let capture: Capture
    @ObservedObject var model: CapturesModel
    @State private var thumbnail: NSImage?
    @State private var duration: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 72, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.system(size: 12, weight: .medium))
                if model.copiedURL == capture.url {
                    Text("Copied to clipboard").font(.system(size: 11)).foregroundStyle(.green)
                } else {
                    Text(capture.date, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            button("doc.on.doc", help: "Copy") { model.copy(capture) }
            button("magnifyingglass", help: "Reveal in Finder") { model.reveal(capture) }
            button("trash", help: "Move to Trash") { model.delete(capture) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(capture.url) }
        .onDrag { NSItemProvider(contentsOf: capture.url) ?? NSItemProvider() }
        .task(id: capture.url) {
            duration = await CaptureStore.duration(of: capture)
            let request = QLThumbnailGenerator.Request(fileAt: capture.url, size: CGSize(width: 144, height: 96), scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }

    private var summary: String {
        var parts = [capture.format.title]
        if let duration { parts.append(String(format: "%.0fs", duration.rounded(.up))) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(capture.byteCount), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
