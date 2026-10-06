import AppKit
import UniformTypeIdentifiers

@MainActor
final class CaptureCoordinator {
    private let overlay = SelectionOverlay()
    private var isCapturing = false
    private var hiddenWindows: [NSWindow] = []
    private var windowCandidates: [WindowCandidate] = []
    private var snapshots: [(NSScreen, CGImage)] = []
    private var pins: [UUID: PinnedImageController] = [:]
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
        windowCandidates = WindowSelection.visibleWindows()
        Task {
            do {
                // Freeze the desktop before showing any selection UI.
                for screen in NSScreen.screens {
                    let image = try await CaptureService.capture(screen: screen,
                        selection: CGRect(origin: .zero, size: screen.frame.size))
                    snapshots.append((screen, image))
                }
                guard !snapshots.isEmpty else { throw CaptureError.displayUnavailable }
                showOverlay()
            } catch {
                endSession()
                showError(error)
            }
        }
    }

    private func showOverlay(initialSelection: (NSScreen, CGRect)? = nil) {
        overlay.begin(snapshots: snapshots, candidates: windowCandidates, initialSelection: initialSelection,
            onAction: { [weak self] screen, rect, action in
                self?.finish(screen: screen, rect: rect, action: action)
            }, onCancel: { [weak self] in self?.endSession() })
    }

    private func finish(screen: NSScreen, rect: CGRect, action: CaptureAction) {
        guard let snapshot = snapshots.first(where: { $0.0 === screen })?.1 else { return }
        do {
            let image = try CaptureService.crop(image: snapshot, selection: rect, screenSize: screen.frame.size)
            switch action {
            case .copy:
                let png = try CaptureService.pngData(for: image)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setData(png, forType: .png) else { throw CaptureError.encodingFailed }
                endSession()
                CaptureFeedback.success()
            case .preview:
                endSession()
                let controller = CapturePreviewController(image: image)
                preview?.close()
                preview = controller
                controller.onClose = { [weak self] in self?.preview = nil }
                controller.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                CaptureFeedback.success()
            case .pin:
                let globalRect = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                endSession()
                showPin(image: image, rect: globalRect, screen: screen)
                CaptureFeedback.success()
            case .save:
                save(image: image, screen: screen, rect: rect)
            case .quickSave:
                try CaptureOutput.save(image, to: CaptureOutput.directory)
                endSession()
                CaptureFeedback.success()
            }
        } catch {
            overlay.dismiss()
            showError(error)
            showOverlay(initialSelection: (screen, rect))
        }
    }

    private func save(image: CGImage, screen: NSScreen, rect: CGRect) {
        overlay.dismiss()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "Snaplet_\(formatter.string(from: Date())).png"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.showOverlay(initialSelection: (screen, rect))
                return
            }
            do {
                try CaptureService.pngData(for: image).write(to: url, options: .atomic)
                self.endSession()
                CaptureFeedback.success()
            } catch {
                self.showError(error)
                self.showOverlay(initialSelection: (screen, rect))
            }
        }
    }

    private func endSession() {
        overlay.dismiss()
        snapshots.removeAll()
        windowCandidates.removeAll()
        hiddenWindows.forEach { $0.orderFront(nil) }
        hiddenWindows.removeAll()
        isCapturing = false
    }

    func pinClipboard() {
        guard !isCapturing else { return }
        guard let source = NSImage(pasteboard: .general),
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.main else {
            let alert = NSAlert()
            alert.messageText = "剪贴板中没有图片"
            alert.informativeText = "请先复制一张图片，再使用剪贴板贴图。"
            alert.runModal()
            return
        }
        let size = CGSize(width: CGFloat(image.width) / screen.backingScaleFactor,
                          height: CGFloat(image.height) / screen.backingScaleFactor)
        let rect = PinGeometry.fit(size: size, centeredAt: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY), within: screen.visibleFrame)
        showPin(image: image, rect: rect, screen: screen)
        CaptureFeedback.success()
    }

    func togglePins() {
        let hide = pins.values.contains { $0.window?.isVisible == true }
        for controller in pins.values {
            if hide { controller.window?.orderOut(nil) }
            else { controller.window?.orderFrontRegardless() }
        }
    }

    private func showPin(image: CGImage, rect: CGRect, screen: NSScreen) {
        let id = UUID()
        let controller = PinnedImageController(image: image, rect: rect, screen: screen)
        pins[id] = controller
        controller.onClose = { [weak self] in self?.pins.removeValue(forKey: id) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "截图操作失败"
        alert.runModal()
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
