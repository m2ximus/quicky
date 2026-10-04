import AppKit
import Carbon.HIToolbox
import QuickyCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        case idle, selecting, countdown, starting, recording, encoding
    }

    private static let countdownSeconds = 3

    private let settings = Settings()
    private let store = CaptureStore()
    private lazy var capturesWindow = CapturesWindowController(store: store)
    private let selector = RegionSelector()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    private var state = State.idle { didSet { updateStatusItem() } }
    private var frameWindow: RegionFrameWindow?
    private var recorder: Recorder?
    private var timer: Timer?
    private var recordingStart = Date()
    private var limit: TimeInterval?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        pruneOldCaptures()
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: optionKey | shiftKey) { [weak self] in self?.toggle() }
    }

    // MARK: Recording flow

    @objc private func toggle() {
        switch state {
        case .idle: begin()
        case .countdown: cancelCountdown()
        case .recording: stop()
        case .selecting, .starting, .encoding: break
        }
    }

    private func begin() {
        guard CGPreflightScreenCaptureAccess() else {
            if !CGRequestScreenCaptureAccess() { showPermissionAlert() }
            return
        }
        if settings.reuseLastRegion, let stored = settings.lastRegion,
           let screen = NSScreen.screens.first(where: { $0.displayID == stored.displayID }) {
            startCountdown(Selection(screen: screen, rect: stored.rect))
            return
        }
        state = .selecting
        selector.begin { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.state = .idle
                return
            }
            self.settings.lastRegion = StoredRegion(displayID: selection.screen.displayID, rect: selection.rect)
            self.startCountdown(selection)
        }
    }

    private func startCountdown(_ selection: Selection) {
        state = .countdown
        var remaining = Self.countdownSeconds
        let frameWindow = RegionFrameWindow(selection: selection)
        frameWindow.showCountdown(remaining)
        self.frameWindow = frameWindow
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                remaining -= 1
                if remaining > 0 {
                    frameWindow.showCountdown(remaining)
                } else {
                    self?.startRecording(selection)
                }
            }
        }
    }

    private func cancelCountdown() {
        timer?.invalidate()
        frameWindow?.close()
        frameWindow = nil
        state = .idle
    }

    private func startRecording(_ selection: Selection) {
        timer?.invalidate()
        state = .starting
        frameWindow?.showRecording()

        let format = settings.format
        let quality = settings.quality
        let (width, height) = quality.outputSize(for: selection.rect.size, scale: selection.screen.backingScaleFactor, format: format)

        let recorder: Recorder
        do {
            let url = try store.newURL(format: format)
            let encoder: FrameEncoder = format == .gif ? try GIFEncoder(url: url) : try VideoEncoder(url: url, width: width, height: height, quality: quality)
            let target = Recorder.Target(
                displayID: selection.screen.displayID,
                rect: selection.rect,
                pixelWidth: width,
                pixelHeight: height,
                framesPerSecond: quality.framesPerSecond(for: format)
            )
            recorder = Recorder(target: target, encoder: encoder)
        } catch {
            fail(error)
            return
        }
        recorder.onFailure = { [weak self] error in
            Task { @MainActor in self?.fail(error) }
        }
        self.recorder = recorder
        limit = settings.duration.seconds ?? (format == .gif ? quality.gifMaxSeconds : nil)

        Task { @MainActor in
            do {
                try await recorder.start()
            } catch {
                self.fail(error)
                return
            }
            guard self.state == .starting else { return }
            self.recordingStart = Date()
            self.state = .recording
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        if let limit, Date().timeIntervalSince(recordingStart) >= limit {
            stop()
        } else {
            updateStatusItem()
        }
    }

    private func stop() {
        guard state == .recording, let recorder else { return }
        timer?.invalidate()
        frameWindow?.close()
        frameWindow = nil
        state = .encoding
        Task { @MainActor in
            do {
                let url = try await recorder.stop()
                Clipboard.copy(url)
                self.pruneOldCaptures()
                self.capturesWindow.show(copied: url)
            } catch {
                self.showError(error)
            }
            self.recorder = nil
            self.state = .idle
        }
    }

    private func fail(_ error: Error) {
        guard state == .starting || state == .recording else { return }
        timer?.invalidate()
        frameWindow?.close()
        frameWindow = nil
        let recorder = self.recorder
        self.recorder = nil
        state = .idle
        Task { await recorder?.cancel() }
        showError(error)
    }

    private func pruneOldCaptures() {
        if let days = settings.retention.days { store.prune(olderThan: days) }
    }

    // MARK: Alerts

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Quicky couldn't finish the recording"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Quicky needs Screen Recording permission"
        alert.informativeText = "Turn on Quicky in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Quicky."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        var title = ""
        switch state {
        case .idle, .selecting, .countdown, .starting:
            symbol = "record.circle"
        case .recording:
            symbol = "stop.circle.fill"
            let elapsed = Date().timeIntervalSince(recordingStart)
            title = " \(Int((limit.map { $0 - elapsed } ?? elapsed).rounded(.up)))"
        case .encoding:
            symbol = "ellipsis.circle"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Quicky")
        button.imagePosition = .imageLeading
        button.title = title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let record = NSMenuItem(title: state == .recording ? "Stop Recording" : "Record", action: #selector(toggle), keyEquivalent: "r")
        record.keyEquivalentModifierMask = [.option, .shift]
        record.target = self
        record.isEnabled = [.idle, .countdown, .recording].contains(state)
        menu.addItem(record)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Format"))
        for format in CaptureFormat.allCases {
            let item = NSMenuItem(title: format.title, action: #selector(selectFormat), keyEquivalent: "")
            item.target = self
            item.representedObject = format.rawValue
            item.state = settings.format == format ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Quality"))
        for quality in CaptureQuality.allCases {
            let item = NSMenuItem(title: quality.title, action: #selector(selectQuality), keyEquivalent: "")
            item.target = self
            item.representedObject = quality.rawValue
            item.state = settings.quality == quality ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Duration"))
        for duration in CaptureDuration.allCases {
            let item = NSMenuItem(title: duration.title, action: #selector(selectDuration), keyEquivalent: "")
            item.target = self
            item.representedObject = duration.rawValue
            item.state = settings.duration == duration ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let reuse = NSMenuItem(title: "Reuse Last Region", action: #selector(toggleReuse), keyEquivalent: "")
        reuse.target = self
        reuse.state = settings.reuseLastRegion ? .on : .off
        menu.addItem(reuse)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Keep Captures"))
        for retention in CaptureRetention.allCases {
            let item = NSMenuItem(title: retention.title, action: #selector(selectRetention), keyEquivalent: "")
            item.target = self
            item.representedObject = retention.rawValue
            item.state = settings.retention == retention ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show Captures", action: #selector(showCaptures), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let folder = NSMenuItem(title: "Open Captures Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Quicky", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
    }

    @objc private func selectFormat(_ item: NSMenuItem) {
        if let format = (item.representedObject as? String).flatMap(CaptureFormat.init) { settings.format = format }
    }

    @objc private func selectQuality(_ item: NSMenuItem) {
        if let quality = (item.representedObject as? String).flatMap(CaptureQuality.init) { settings.quality = quality }
    }

    @objc private func selectDuration(_ item: NSMenuItem) {
        if let duration = (item.representedObject as? Int).flatMap(CaptureDuration.init) { settings.duration = duration }
    }

    @objc private func selectRetention(_ item: NSMenuItem) {
        guard let retention = (item.representedObject as? Int).flatMap(CaptureRetention.init) else { return }
        settings.retention = retention
        pruneOldCaptures()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func toggleReuse() {
        settings.reuseLastRegion.toggle()
    }

    @objc private func showCaptures() {
        capturesWindow.show()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }
}
