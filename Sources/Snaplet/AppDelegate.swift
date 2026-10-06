import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindowController: MainWindowController?
    private let captureCoordinator = CaptureCoordinator()
    private lazy var globalShortcut = GlobalShortcut { [weak self] in
        self?.captureCoordinator.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        globalShortcut.start()
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
            mainWindowController = MainWindowController(shortcut: globalShortcut, onCapture: { [weak self] in
                self?.captureCoordinator.start()
            })
        }
        mainWindowController?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func startCapture() {
        captureCoordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalShortcut.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
