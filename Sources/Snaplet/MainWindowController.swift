import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let onCapture: () -> Void
    private let onRecord: (Bool) -> Void
    private let recording: RecordingCoordinator
    private let recordShortcut: GlobalShortcut
    private let pauseShortcut: GlobalShortcut
    private let audioPicker = NSPopUpButton()
    private let qualityPicker = NSPopUpButton()
    private let fpsPicker = NSPopUpButton()
    private let cursorToggle = NSButton(checkboxWithTitle: "显示鼠标光标", target: nil, action: nil)
    private let shortcut: GlobalShortcut
    private let paneHost = NSView()
    private var panes: [NSView] = []
    private var navigation: [NSButton] = []
    private let saveLocation = NSTextField(labelWithString: "")

    init(shortcut: GlobalShortcut, recording: RecordingCoordinator, recordShortcut: GlobalShortcut,
         pauseShortcut: GlobalShortcut, onRecord: @escaping (Bool) -> Void, onCapture: @escaping () -> Void) {
        self.recording = recording
        self.recordShortcut = recordShortcut
        self.pauseShortcut = pauseShortcut
        self.onRecord = onRecord
        self.shortcut = shortcut
        self.onCapture = onCapture
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Snaplet"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
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
        guard let content = window.contentView else { return }
        let logo = SurfaceView(tint: .systemBlue, opacity: 0.12, radius: 10)
        let mark = UI.symbol("viewfinder", size: 23, color: .systemBlue)
        UI.embed(mark, in: logo, inset: 10)
        logo.widthAnchor.constraint(equalToConstant: 44).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let captureButton = NSButton(title: "开始截图", target: self, action: #selector(startCapture))
        captureButton.bezelStyle = .rounded
        captureButton.controlSize = .regular
        captureButton.bezelColor = .systemBlue
        captureButton.font = .systemFont(ofSize: 14, weight: .semibold)
        captureButton.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        captureButton.imagePosition = .imageLeading
        captureButton.keyEquivalent = "\r"
        let captureHeading = UI.horizontal([
            UI.vertical([UI.label("区域截图", size: 15, weight: .semibold),
                         UI.label("框选区域，或单击选择窗口。", size: 12, color: .secondaryLabelColor)], spacing: 5),
            UI.spacer(), captureButton
        ])
        let guide = UI.horizontal([keyHint("↵", text: "复制"), UI.spacer(), keyHint("空格", text: "保存"),
                                  UI.spacer(), keyHint("esc", text: "取消")], spacing: 8)
        let captureBody = UI.vertical([captureHeading, guide], spacing: 18)
        let captureCard = SurfaceView(tint: .systemBlue, opacity: 0.065, radius: 8)
        UI.embed(captureBody, in: captureCard, inset: 14)

        let shortcutButton = ShortcutRecorderButton()
        shortcutButton.title = shortcut.shortcut.displayName
        shortcutButton.bezelStyle = .rounded
        shortcutButton.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        shortcutButton.toolTip = "点击录入新的全局截图快捷键"
        shortcutButton.setAccessibilityLabel("截图快捷键，点击修改")
        shortcutButton.onBeginRecording = { [weak self] in self?.shortcut.suspend() }
        shortcutButton.onEndRecording = { [weak self] in self?.shortcut.resume() }
        shortcutButton.onShortcut = { [weak self, weak shortcutButton] candidate in
            guard let self else { return }
            if self.shortcut.update(candidate) {
                shortcutButton?.title = candidate.displayName
            } else {
                let alert = NSAlert()
                alert.messageText = "无法使用该快捷键"
                alert.informativeText = self.shortcut.registrationError ?? "请重试。"
                alert.runModal()
            }
        }
        let soundToggle = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(toggleSound(_:)))
        soundToggle.setAccessibilityLabel("截图完成时播放音效")
        soundToggle.state = CaptureFeedback.soundEnabled ? .on : .off
        let folderButton = NSButton(title: "更改…", target: self, action: #selector(chooseDirectory))
        folderButton.bezelStyle = .rounded
        updateSaveLocation()
        saveLocation.font = .systemFont(ofSize: 12)
        saveLocation.textColor = .secondaryLabelColor
        saveLocation.lineBreakMode = .byTruncatingMiddle
        saveLocation.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        let shortcutRow = settingRow("keyboard", title: "截图快捷键", detail: UI.label(shortcut.registrationError ?? "全局生效 · 点击右侧修改", size: 11, color: .secondaryLabelColor), control: shortcutButton)
        let settings = UI.vertical([
            settingRow("folder", title: "保存位置", detail: saveLocation, control: folderButton),
            UI.separator(),
            settingRow("speaker.wave.2", title: "完成音效", detail: UI.label("截图成功时播放提示音", size: 11, color: .secondaryLabelColor), control: soundToggle)
        ], spacing: 14)
        let settingsCard = SurfaceView(tint: .controlBackgroundColor, opacity: 1, radius: 8)
        UI.embed(settings, in: settingsCard, inset: 14)
        let shortcutCard = SurfaceView(tint: .controlBackgroundColor, opacity: 1, radius: 8)
        UI.embed(shortcutRow, in: shortcutCard, inset: 14)
        let capturePane = UI.vertical([
            UI.label("截图", size: 20, weight: .semibold), captureCard, shortcutCard,
            UI.label("悬停识别窗口 · 单击选择 · 拖动框选", size: 11, color: .secondaryLabelColor)
        ], spacing: 16)
        let settingsPane = UI.vertical([
            UI.label("保存与声音", size: 20, weight: .semibold),
            UI.label("设置截图和录屏的保存位置与完成反馈。", size: 12, color: .secondaryLabelColor),
            settingsCard,
            UI.label("按空格直接保存 PNG；按 ⌘S 选择保存位置。", size: 11, color: .secondaryLabelColor)
        ], spacing: 16)
        panes = [capturePane, recordingPane(), settingsPane]

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        let brand = UI.horizontal([logo, UI.label("Snaplet", size: 17, weight: .semibold)], spacing: 8)
        let captureNav = navigationButton("截图", symbol: "viewfinder", index: 0)
        let recordNav = navigationButton("录屏", symbol: "record.circle", index: 1)
        let settingsNav = navigationButton("保存与声音", symbol: "slider.horizontal.3", index: 2)
        navigation = [captureNav, recordNav, settingsNav]
        let sidebarBody = UI.vertical([brand, UI.separator(), captureNav, recordNav, settingsNav], spacing: 10)
        sidebarBody.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarBody)
        NSLayoutConstraint.activate([
            sidebarBody.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 20),
            sidebarBody.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarBody.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12)
        ])
        let closeButton = NSButton(title: "返回菜单栏", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .inline
        closeButton.font = .systemFont(ofSize: 11)
        let footer = UI.horizontal([UI.label("关闭窗口后快捷键仍可用", size: 10, color: .secondaryLabelColor), UI.spacer(), closeButton], spacing: 8)
        [sidebar, paneHost, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 160),
            paneHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 22),
            paneHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            paneHost.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            paneHost.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        showPane(0)
    }

    private func recordingPane() -> NSView {
        let region = NSButton(title: "区域 / 窗口录制", target: self, action: #selector(recordRegion))
        let full = NSButton(title: "全屏录制", target: self, action: #selector(recordScreen))
        for button in [region, full] { button.bezelStyle = .rounded }
        region.bezelColor = .systemRed
        audioPicker.addItems(withTitles: ["无声音", "系统声音", "麦克风", "系统声音 + 麦克风"])
        audioPicker.selectItem(at: max(0, min(3, UserDefaults.standard.object(forKey: "recordingAudio") as? Int ?? 1)))
        qualityPicker.addItems(withTitles: ["720p", "1080p", "原始分辨率（最高 4K）"])
        qualityPicker.selectItem(at: max(0, min(2, UserDefaults.standard.object(forKey: "recordingQuality") as? Int ?? 1)))
        fpsPicker.addItems(withTitles: ["15 FPS", "30 FPS", "60 FPS"])
        fpsPicker.selectItem(at: max(0, min(2, UserDefaults.standard.object(forKey: "recordingFPS") as? Int ?? 1)))
        cursorToggle.state = UserDefaults.standard.object(forKey: "recordingCursor") as? Bool == false ? .off : .on
        for picker in [audioPicker, qualityPicker, fpsPicker] {
            picker.target = self; picker.action = #selector(updateRecordingOptions)
        }
        cursorToggle.target = self; cursorToggle.action = #selector(updateRecordingOptions)
        updateRecordingOptions()
        let settings = UI.vertical([
            settingRow("speaker.wave.2", title: "声音", detail: UI.label("讲解时可同时录入麦克风", size: 11, color: .secondaryLabelColor), control: audioPicker),
            settingRow("video", title: "画质", detail: UI.label("保持选区比例，不放大小区域", size: 11, color: .secondaryLabelColor), control: qualityPicker),
            settingRow("speedometer", title: "帧率", detail: cursorToggle, control: fpsPicker)
        ], spacing: 12)
        let card = SurfaceView(tint: .controlBackgroundColor, opacity: 1, radius: 8)
        UI.embed(settings, in: card, inset: 14)
        return UI.vertical([
            UI.label("录屏", size: 20, weight: .semibold),
            UI.label("框选区域或选择窗口范围，倒计时 3 秒后录制。", size: 12, color: .secondaryLabelColor),
            UI.horizontal([region, full, UI.spacer()], spacing: 10), card,
            UI.horizontal([UI.label("开始", size: 12), recordingShortcutButton(recordShortcut),
                           UI.label("暂停 / 继续", size: 12), recordingShortcutButton(pauseShortcut)], spacing: 8),
            UI.label("停止后保存 MP4 并在 Finder 中显示；声音选项需相应权限。", size: 11, color: .secondaryLabelColor)
        ], spacing: 14)
    }
    private func recordingShortcutButton(_ shortcut: GlobalShortcut) -> NSButton {
        let button = ShortcutRecorderButton()
        button.title = shortcut.shortcut.displayName
        button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = shortcut.registrationError ?? "点击修改全局快捷键"
        button.onBeginRecording = { shortcut.suspend() }
        button.onEndRecording = { shortcut.resume() }
        button.onShortcut = { [weak button] candidate in
            if shortcut.update(candidate) { button?.title = candidate.displayName }
            else {
                let alert = NSAlert(); alert.messageText = "无法使用该快捷键"
                alert.informativeText = shortcut.registrationError ?? "请更换组合键。"; alert.runModal()
            }
        }
        return button
    }
    @objc private func updateRecordingOptions() {
        guard !recording.busy else { return }
        let audio = audioPicker.indexOfSelectedItem
        recording.options = RecordingOptions(systemAudio: audio == 1 || audio == 3, microphone: audio == 2 || audio == 3,
            showsCursor: cursorToggle.state == .on, framesPerSecond: [15, 30, 60][fpsPicker.indexOfSelectedItem],
            maximumHeight: [720, 1080, 0][qualityPicker.indexOfSelectedItem])
        UserDefaults.standard.set(audio, forKey: "recordingAudio")
        UserDefaults.standard.set(qualityPicker.indexOfSelectedItem, forKey: "recordingQuality")
        UserDefaults.standard.set(fpsPicker.indexOfSelectedItem, forKey: "recordingFPS")
        UserDefaults.standard.set(cursorToggle.state == .on, forKey: "recordingCursor")
    }
    @objc private func recordRegion() { updateRecordingOptions(); onRecord(false) }
    @objc private func recordScreen() { updateRecordingOptions(); onRecord(true) }

    private func navigationButton(_ title: String, symbol: String, index: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(navigate(_:)))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.tag = index
        return button
    }
    @objc private func navigate(_ sender: NSButton) { showPane(sender.tag) }
    private func showPane(_ index: Int) {
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        let pane = panes[index]
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: paneHost.bottomAnchor)
        ])
        for (offset, button) in navigation.enumerated() { button.state = offset == index ? .on : .off }
    }

    private func keyHint(_ key: String, text: String) -> NSView {
        let badge = SurfaceView(tint: .labelColor, opacity: 0.055, radius: 6)
        UI.embed(UI.label(key, size: 11, weight: .medium, color: .secondaryLabelColor), in: badge, inset: 6)
        let group = UI.horizontal([badge, UI.label(text, size: 12, color: .secondaryLabelColor)], spacing: 7)
        group.setContentHuggingPriority(.required, for: .horizontal)
        return group
    }

    private func settingRow(_ symbol: String, title: String, detail: NSView, control: NSView) -> NSView {
        let icon = UI.symbol(symbol, size: 16, color: .secondaryLabelColor)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return UI.horizontal([icon, UI.vertical([UI.label(title, size: 13, weight: .medium), detail], spacing: 5), UI.spacer(), control], spacing: 10)
    }

    @objc private func startCapture() { onCapture() }
    @objc private func toggleSound(_ sender: NSButton) {
        CaptureFeedback.soundEnabled = sender.state == .on
    }
    private func updateSaveLocation() {
        saveLocation.stringValue =  (CaptureOutput.directory.path as NSString).abbreviatingWithTildeInPath
    }
    @objc private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择保存位置"
        panel.directoryURL = CaptureOutput.directory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            CaptureOutput.directory = url
            self?.updateSaveLocation()
        }
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
