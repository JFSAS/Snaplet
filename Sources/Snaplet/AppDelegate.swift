import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindowController: MainWindowController?
    private let captureCoordinator = CaptureCoordinator()
    private lazy var globalShortcut = GlobalShortcut { [weak self] in
        self?.captureCoordinator.start()
    }

    private lazy var recordShortcut = GlobalShortcut(defaultsKey: "recordingShortcut",
        defaultShortcut: ScreenshotShortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey), keyLabel: "W"),
        identifier: 2) { [weak self] in self?.captureCoordinator.startRecording() }
    private lazy var pauseShortcut = GlobalShortcut(defaultsKey: "recordingPauseShortcut",
        defaultShortcut: ScreenshotShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey), keyLabel: "P"),
        identifier: 3) { [weak self] in self?.captureCoordinator.recording.togglePause() }
    private var stopRecordingItem: NSMenuItem?
    private var pauseRecordingItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        globalShortcut.start()
        recordShortcut.start()
        pauseShortcut.start()
        captureCoordinator.recording.onStateChange = { [weak self] in self?.updateRecordingMenu() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: "Snaplet"
        )
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Snaplet"

        let menu = NSMenu()
        let captureItem = NSMenuItem(title: "区域截图…", action: #selector(startCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        let recordItem = NSMenuItem(title: "区域录屏…", action: #selector(startRecording), keyEquivalent: "")
        recordItem.target = self; menu.addItem(recordItem)
        let fullScreenItem = NSMenuItem(title: "全屏录制（鼠标所在屏幕）", action: #selector(recordFullScreen), keyEquivalent: "")
        fullScreenItem.target = self; menu.addItem(fullScreenItem)
        let pauseItem = NSMenuItem(title: "暂停录屏", action: #selector(pauseRecording), keyEquivalent: "")
        pauseItem.target = self; menu.addItem(pauseItem); pauseRecordingItem = pauseItem
        let stopItem = NSMenuItem(title: "停止录屏并保存", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.target = self; menu.addItem(stopItem); stopRecordingItem = stopItem
        menu.addItem(.separator())
        let clipboardItem = NSMenuItem(title: "剪贴板贴图", action: #selector(pinClipboard), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)
        let toggleItem = NSMenuItem(title: "隐藏 / 显示全部贴图", action: #selector(togglePins), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let openItem = NSMenuItem(
            title: "打开 Snaplet",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 Snaplet",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        updateRecordingMenu()
        showMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(shortcut: globalShortcut, recording: captureCoordinator.recording,
                recordShortcut: recordShortcut, pauseShortcut: pauseShortcut,
                onRecord: { [weak self] fullScreen in self?.captureCoordinator.startRecording(fullScreen: fullScreen) }, onCapture: { [weak self] in
                self?.captureCoordinator.start()
            })
        }
        mainWindowController?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func pinClipboard() { captureCoordinator.pinClipboard() }
    @objc private func togglePins() { captureCoordinator.togglePins() }

    @objc private func startCapture() {
        captureCoordinator.start()
    }

    @objc private func startRecording() { captureCoordinator.startRecording() }
    @objc private func recordFullScreen() { captureCoordinator.startRecording(fullScreen: true) }
    @objc private func pauseRecording() { captureCoordinator.recording.togglePause() }
    @objc private func stopRecording() { captureCoordinator.recording.stop() }
    private func updateRecordingMenu() {
        let state = captureCoordinator.recording.state
        pauseRecordingItem?.isHidden = state != .recording && state != .paused
        pauseRecordingItem?.title = state == .paused ? "继续录屏" : "暂停录屏"
        stopRecordingItem?.isHidden = state != .recording && state != .paused && state != .countdown && state != .selecting
        stopRecordingItem?.title = state == .countdown || state == .selecting ? "取消录屏" : "停止录屏并保存"
        statusItem?.button?.image = NSImage(systemSymbolName: captureCoordinator.recording.busy ? "record.circle" : "viewfinder", accessibilityDescription: "Snaplet")
        statusItem?.button?.image?.isTemplate = true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        captureCoordinator.recording.requestTermination()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalShortcut.stop()
        recordShortcut.stop()
        pauseShortcut.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
