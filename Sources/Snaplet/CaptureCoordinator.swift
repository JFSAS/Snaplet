import AppKit

@MainActor
final class CaptureCoordinator {
    private let overlay = SelectionOverlay()
    private var isCapturing = false
    private var hiddenWindows: [NSWindow] = []
    private var preview: CapturePreviewController?

    func start() {
        guard !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermissionHelp()
            return
        }
        isCapturing = true
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        hiddenWindows.forEach { $0.orderOut(nil) }
        overlay.begin(onSelection: { [weak self] screen, rect in
            guard let self else { return }
            Task {
                do {
                    let image = try await CaptureService.capture(screen: screen, selection: rect)
                    self.restoreWindows()
                    let controller = CapturePreviewController(image: image)
                    self.preview?.close()
                    self.preview = controller
                    controller.onClose = { [weak self] in self?.preview = nil }
                    controller.showWindow(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } catch {
                    self.restoreWindows()
                    let alert = NSAlert()
                    alert.messageText = "截图失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
                self.isCapturing = false
            }
        }, onCancel: { [weak self] in
            self?.restoreWindows()
            self?.isCapturing = false
        })
    }

    private func restoreWindows() {
        hiddenWindows.forEach { $0.orderFront(nil) }
        hiddenWindows.removeAll()
    }

    private func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "Snaplet 需要屏幕录制权限"
        alert.informativeText = "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Snaplet。\n授权后如系统要求，请退出并重新打开 Snaplet，再开始截图。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
