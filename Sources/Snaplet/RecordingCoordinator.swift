import AppKit
import AVFoundation

@MainActor
final class RecordingCoordinator {
    enum State { case idle, selecting, countdown, starting, recording, paused, stopping }
    private(set) var state: State = .idle { didSet { onStateChange?() } }
    var busy: Bool { state != .idle }
    var onStateChange: (() -> Void)?
    var options = RecordingOptions()
    private let overlay = SelectionOverlay()
    private let service = RecordingService()
    private var controls: RecordingControls?
    private var border: NSWindow?
    private var hiddenWindows: [NSWindow] = []
    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var timer: Timer?
    private var pendingURL: URL?
    private var terminating = false
    private var pendingInterruption: Error?

    func start(fullScreen: Bool = false) {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "Snaplet 需要屏幕录制权限"
            alert.informativeText = "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Snaplet。如系统要求，请重新启动应用。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        pendingInterruption = nil
        state = .selecting
        let candidates = WindowSelection.visibleWindows()
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        hiddenWindows.forEach { $0.orderOut(nil) }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        task = Task {
            do {
                // Request microphone permission before selection/countdown, so the prompt is never recorded.
                if options.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    throw RecordingError.microphoneDenied
                }
                guard !Task.isCancelled else { return }
                if fullScreen, let screen {
                    prepare(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
                } else {
                    var snapshots: [(NSScreen, CGImage)] = []
                    for display in NSScreen.screens {
                        snapshots.append((display, try await CaptureService.capture(screen: display,
                            selection: CGRect(origin: .zero, size: display.frame.size))))
                    }
                    guard !Task.isCancelled else { return }
                    guard !snapshots.isEmpty else { throw CaptureError.displayUnavailable }
                    overlay.begin(snapshots: snapshots, candidates: candidates, recording: true,
                        onAction: { [weak self] screen, rect, _, _ in self?.prepare(screen: screen, rect: rect) },
                        onCancel: { [weak self] in self?.cancelPreparation() })
                }
            } catch { if !Task.isCancelled { fail(error) } }
        }
    }

    private func prepare(screen: NSScreen, rect: CGRect) {
        overlay.dismiss()
        state = .countdown
        let controls = RecordingControls(screen: screen, rect: rect)
        self.controls = controls
        controls.onStop = { [weak self] in self?.stop() }
        controls.onPause = { [weak self] in self?.togglePause() }
        controls.showWindow(nil)
        showBorder(screen: screen, rect: rect)
        let options = self.options
        task = Task {
            do {
                for remaining in (1...3).reversed() {
                    controls.update(text: "\(remaining) 秒后开始", paused: false, canPause: false, stopTitle: "取消")
                    try await Task.sleep(for: .seconds(1))
                }
                state = .starting
                controls.update(text: "正在启动…", paused: false, canPause: false, canStop: false)
                try FileManager.default.createDirectory(at: CaptureOutput.directory, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let url = CaptureOutput.directory.appendingPathComponent("Snaplet_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).mp4")
                pendingURL = url
                try await service.start(screen: screen, rect: rect, options: options, url: url,
                    onFailure: { [weak self] error in self?.interrupted(error) })
                startedAt = Date()
                pausedDuration = 0
                state = .recording
                updateElapsed()
                if let pendingInterruption { interrupted(pendingInterruption); return }
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateElapsed() }
                }
            } catch is CancellationError { /* Cancellation already cleaned up the preparation UI. */ }
            catch { fail(error) }
        }
    }

    func togglePause() {
        guard state == .recording || state == .paused else { return }
        let pause = state == .recording
        // Reserve the transition immediately to avoid repeated clicks racing the writer queue.
        state = .starting
        controls?.update(text: pause ? "正在暂停…" : "正在继续…", paused: pause, canPause: false, canStop: false)
        task = Task {
            await service.setPaused(pause)
            if pause { pausedAt = Date() }
            else {
                if let pausedAt { pausedDuration += Date().timeIntervalSince(pausedAt) }
                pausedAt = nil
            }
            state = pause ? .paused : .recording
            updateElapsed()
            if let pendingInterruption { interrupted(pendingInterruption) }
        }
    }

    func stop() {
        if state == .selecting || state == .countdown { cancelPreparation(); return }
        guard state == .recording || state == .paused else { return }
        state = .stopping
        timer?.invalidate(); timer = nil
        border?.orderOut(nil)
        controls?.update(text: "正在保存 MP4…", paused: false, canPause: false, canStop: false)
        task = Task {
            do {
                let url = try await service.stop()
                cleanup()
                if !terminating {
                    CaptureFeedback.success()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch { fail(error) }
            if terminating { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    /// Delay quitting until the MP4 container has been finalized.
    func requestTermination() -> NSApplication.TerminateReply {
        guard busy else { return .terminateNow }
        if state == .selecting || state == .countdown { cancelPreparation(); return .terminateNow }
        if state == .starting { return .terminateCancel }
        terminating = true
        if state != .stopping { stop() }
        return .terminateLater
    }

    private func interrupted(_ error: Error) {
        if state == .starting { pendingInterruption = error; return }
        guard state == .recording || state == .paused else { return }
        stop()
        // Saving takes precedence over displaying a modal interruption alert.
        NSLog("Screen recording interrupted: %@", error.localizedDescription)
    }
    private func cancelPreparation() {
        task?.cancel()
        cleanup()
    }
    private func fail(_ error: Error) {
        let recovery = pendingURL
        cleanup()
        if !terminating {
            let alert = NSAlert(error: error)
            alert.messageText = "录屏操作失败"
            if let recovery, FileManager.default.fileExists(atPath: recovery.path) {
                alert.informativeText += "\n已保留原始录制文件：\(recovery.path)"
            }
            alert.runModal()
        }
    }
    private func cleanup() {
        timer?.invalidate(); timer = nil
        overlay.dismiss()
        controls?.close(); controls = nil
        border?.orderOut(nil); border = nil
        hiddenWindows.forEach { $0.orderFront(nil) }; hiddenWindows.removeAll()
        startedAt = nil; pausedAt = nil; pendingURL = nil
        state = .idle
    }
    private func updateElapsed() {
        guard let startedAt, state == .recording || state == .paused else { return }
        let seconds = max(0, Int((pausedAt ?? Date()).timeIntervalSince(startedAt) - pausedDuration))
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        controls?.update(text: state == .paused ? "已暂停  \(time)" : "●  \(time)", paused: state == .paused, canPause: true)
    }
    private func showBorder(screen: NSScreen, rect: CGRect) {
        let window = NSWindow(contentRect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY).insetBy(dx: -2, dy: -2),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
        window.ignoresMouseEvents = true; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(); view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor; view.layer?.borderWidth = 2
        window.contentView = view
        window.orderFrontRegardless()
        border = window
    }
}

@MainActor
private final class RecordingControls: NSWindowController {
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let pause = NSButton(title: "暂停", target: nil, action: nil)
    private let stop = NSButton(title: "停止", target: nil, action: nil)
    init(screen: NSScreen, rect: CGRect) {
        let frame = screen.visibleFrame
        let region = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let y = region.minY - 70 >= frame.minY ? region.minY - 70 : min(frame.maxY - 64, region.maxY + 8)
        let panel = NSPanel(contentRect: CGRect(x: min(max(frame.minX, region.midX - 180), frame.maxX - 360), y: y, width: 360, height: 56),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        pause.bezelStyle = .rounded; stop.bezelStyle = .rounded
        pause.target = self; pause.action = #selector(toggle)
        stop.target = self; stop.action = #selector(finish)
        stop.bezelColor = .systemRed
        UI.embed(UI.horizontal([label, UI.spacer(), pause, stop], spacing: 10), in: panel.contentView!, inset: 12)
        panel.orderFrontRegardless()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic controls") }
    func update(text: String, paused: Bool, canPause: Bool, canStop: Bool = true, stopTitle: String = "停止") {
        label.stringValue = text
        pause.title = paused ? "继续" : "暂停"
        pause.isEnabled = canPause
        stop.title = stopTitle; stop.isEnabled = canStop
    }
    @objc private func toggle() { onPause?() }
    @objc private func finish() { onStop?() }
}
