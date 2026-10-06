import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let onCapture: () -> Void
    private let shortcut: GlobalShortcut

    init(shortcut: GlobalShortcut, onCapture: @escaping () -> Void) {
        self.shortcut = shortcut
        self.onCapture = onCapture
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Snaplet"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        configureContent(in: window)
    }

    required init?(coder: NSCoder) {
        fatalError("Snaplet uses programmatic AppKit windows.")
    }

    private func configureContent(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Snaplet")
        title.font = .systemFont(ofSize: 30, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "轻巧的 macOS 截图工具")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor

        let description = NSTextField(wrappingLabelWithString:
            "拖动框选，预览后复制或保存 PNG。\n按 Esc 或右键取消；关闭窗口后可从菜单栏截图。"
        )
        description.alignment = .center
        description.textColor = .secondaryLabelColor

        let closeButton = NSButton(
            title: "返回菜单栏",
            target: self,
            action: #selector(closeWindow)
        )
        closeButton.bezelStyle = .rounded

        let captureButton = NSButton(title: "开始区域截图", target: self, action: #selector(startCapture))
        captureButton.bezelStyle = .rounded
        captureButton.keyEquivalent = "\r"

        let shortcutButton = ShortcutRecorderButton()
        shortcutButton.title = "截图快捷键：\(shortcut.shortcut.displayName) · 点击修改"
        shortcutButton.onBeginRecording = { [weak self] in self?.shortcut.suspend() }
        shortcutButton.onEndRecording = { [weak self] in self?.shortcut.resume() }
        shortcutButton.onShortcut = { [weak self, weak shortcutButton] candidate in
            guard let self else { return }
            if self.shortcut.update(candidate) {
                shortcutButton?.title = "截图快捷键：\(candidate.displayName) · 点击修改"
            } else {
                let alert = NSAlert()
                alert.messageText = "无法使用该快捷键"
                alert.informativeText = self.shortcut.registrationError ?? "请重试。"
                alert.runModal()
            }
        }
        let shortcutHint = NSTextField(wrappingLabelWithString:
            shortcut.registrationError ?? "全局生效 · 组合键需包含 ⌘、⌃ 或 ⌥"
        )
        shortcutHint.font = .systemFont(ofSize: 12)
        shortcutHint.alignment = .center
        shortcutHint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, title, subtitle, description, captureButton,
                                     shortcutButton, shortcutHint, closeButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -64),
            icon.heightAnchor.constraint(equalToConstant: 56),
            icon.widthAnchor.constraint(equalToConstant: 56)
        ])
    }

    @objc private func startCapture() { onCapture() }

    @objc private func closeWindow() {
        window?.close()
    }
}
