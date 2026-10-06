import AppKit

@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var cancellation: (() -> Void)?

    func begin(snapshots: [(NSScreen, CGImage)],
               initialSelection: (NSScreen, CGRect)? = nil,
               onAction: @escaping (NSScreen, CGRect, CaptureAction) -> Void,
               onCancel: @escaping () -> Void) {
        dismiss()
        cancellation = onCancel
        for (screen, image) in snapshots {
            let window = SelectionWindow(contentRect: screen.frame,
                styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image)
            view.onAction = { rect, action in onAction(screen, rect, action) }
            view.onCancel = { [weak self] in self?.cancel() }
            view.onBegin = { [weak self, weak view] in
                for other in self?.windows ?? [] {
                    if let otherView = other.contentView as? SelectionView, otherView !== view {
                        otherView.resetSelection()
                    }
                }
            }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
            if let initialSelection, initialSelection.0 === screen {
                view.restoreSelection(initialSelection.1)
            }
        }
        windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        windows.removeAll()
        cancellation = nil
    }
    private func cancel() {
        let callback = cancellation
        dismiss()
        callback?()
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class SelectionView: NSView {
    var onAction: ((CGRect, CaptureAction) -> Void)?
    var onCancel: (() -> Void)?
    var onBegin: (() -> Void)?
    private var model = SelectionModel()
    private let background: NSImage
    private let toolbar = NSView()
    private let hoverLabel = NSTextField(labelWithString: "")
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, image: CGImage) {
        background = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        setAccessibilityLabel("截图框选区域")
        toolbar.appearance = NSAppearance(named: .aqua)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        toolbar.layer?.cornerRadius = 7
        toolbar.layer?.borderWidth = 0.5
        toolbar.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        toolbar.layer?.masksToBounds = true
        toolbar.isHidden = true
        let divider = UI.separator()
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let stack = NSStackView(views: [
            button("重新框选", #selector(reselect)), button("预览", #selector(preview)),
            button("贴图", #selector(pin)), button("保存…", #selector(save)), divider, button("取消", #selector(cancel)),
            button("完成 ✓", #selector(finish))
        ])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
        addSubview(toolbar)
        hoverLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hoverLabel.textColor = .white
        hoverLabel.alignment = .center
        hoverLabel.drawsBackground = true
        hoverLabel.backgroundColor = .black.withAlphaComponent(0.9)
        hoverLabel.wantsLayer = true
        hoverLabel.layer?.cornerRadius = 6
        hoverLabel.layer?.masksToBounds = true
        hoverLabel.isHidden = true
        addSubview(hoverLabel)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic overlay") }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let symbols = ["重新框选": "selection.pin.in.out", "预览": "eye", "保存…": "square.and.arrow.down",
                       "贴图": "pin.fill", "取消": "xmark", "完成 ✓": "checkmark"]
        let button = HoverActionButton(title: title == "完成 ✓" ? "完成" : "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbols[title] ?? "viewfinder", accessibilityDescription: nil)
        button.imagePosition = title == "完成 ✓" ? .imageLeading : .imageOnly
        button.bezelStyle = title == "完成 ✓" ? .rounded : .texturedRounded
        button.isBordered = title == "完成 ✓"
        button.contentTintColor = title == "完成 ✓" ? .white : .black.withAlphaComponent(0.8)
        if title == "完成 ✓" { button.bezelColor = .systemBlue }
        button.font = .systemFont(ofSize: 12, weight: .medium)
        let hints = ["重新框选": "重新框选", "预览": "预览截图", "保存…": "选择位置保存 · ⌘S",
                     "贴图": "截图贴图 · ⌘P", "取消": "取消截图 · Esc", "完成 ✓": "复制并完成 · Enter / ⌘C"]
        let hint = hints[title] ?? title
        button.setAccessibilityHelp(hint)
        button.onHover = { [weak self, weak button] hovering in
            guard let self, let button else { return }
            self.hoverLabel.isHidden = !hovering
            guard hovering else { return }
            self.hoverLabel.stringValue = hint
            let width = self.hoverLabel.intrinsicContentSize.width + 20
            let buttonRect = button.convert(button.bounds, to: self)
            self.hoverLabel.frame = CGRect(
                x: min(max(8, buttonRect.midX - width / 2), self.bounds.maxX - width - 8),
                y: max(8, self.toolbar.frame.minY - 30), width: width, height: 24)
        }
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: title == "完成 ✓" ? 68 : 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
    func resetSelection() { model.reset(); refresh() }
    func restoreSelection(_ selection: CGRect) { model.restore(selection); refresh() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if model.canConfirm {
            addCursorRect(model.rect, cursor: .openHand)
            for (handle, point) in model.handles {
                let cursor: NSCursor = handle.x == 1 ? .resizeUpDown
                    : (handle.y == 1 ? .resizeLeftRight : .crosshair)
                addCursorRect(CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14), cursor: cursor)
            }
            addCursorRect(toolbar.frame, cursor: .arrow)
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if model.canConfirm && model.rect.contains(point) && event.clickCount == 2 {
            finish(); return
        }
        onBegin?()
        model.begin(at: point)
        refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        model.update(to: convert(event.locationInWindow, from: nil), within: bounds)
        refresh()
    }
    override func mouseUp(with event: NSEvent) {
        guard model.phase == .dragging else { return }
        model.update(to: convert(event.locationInWindow, from: nil), within: bounds)
        model.end()
        refresh()
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: finish()
        case 49: confirm(.quickSave)
        default: super.keyDown(with: event)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), model.canConfirm else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 8 { finish(); return true }
        if event.keyCode == 1 { save(); return true }
        if event.keyCode == 35 { pin(); return true }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func reselect() { resetSelection(); window?.makeFirstResponder(self) }
    @objc private func pin() { confirm(.pin) }
    @objc private func preview() { confirm(.preview) }
    @objc private func save() { confirm(.save) }
    @objc private func cancel() { onCancel?() }
    @objc private func finish() { confirm(.copy) }
    private func confirm(_ action: CaptureAction) {
        guard model.canConfirm else { return }
        onAction?(model.rect, action)
    }
    private func refresh() {
        hoverLabel.isHidden = true
        toolbar.isHidden = !model.canConfirm
        if model.canConfirm {
            let width: CGFloat = min(288, bounds.width - 16)
            let height: CGFloat = 36
            var y = model.rect.minY - height - 12
            if y < 8 { y = model.rect.maxY + 12 }
            if y + height > bounds.maxY - 8 { y = max(8, model.rect.minY + 12) }
            toolbar.frame = CGRect(x: min(max(8, model.rect.maxX - width), bounds.maxX - width - 8),
                                   y: y, width: width, height: height)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        background.draw(in: bounds)
        let shade = NSBezierPath(rect: bounds)
        if !model.rect.isEmpty { shade.append(NSBezierPath(rect: model.rect)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        shade.fill()
        if !model.rect.isEmpty {
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: model.rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        if model.canConfirm {
            for (_, point) in model.handles {
                NSColor.white.setFill()
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                handle.fill()
                NSColor.systemBlue.setStroke()
                handle.stroke()
            }
        }
        let text: String
        switch model.phase {
        case .idle: text = "拖动选择截图区域 · Esc 或右键取消"
        case .dragging: text = "\(Int(model.rect.width)) × \(Int(model.rect.height)) pt · 松开后调整选区"
        case .ready: text = "\(Int(model.rect.width)) × \(Int(model.rect.height)) pt"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let label = CGRect(
            x: model.phase == .idle ? (bounds.width - size.width) / 2 - 10 : min(max(8, model.rect.minX), bounds.maxX - size.width - 28),
            y: model.phase == .idle ? bounds.height - 65 : min(bounds.maxY - size.height - 20, model.rect.maxY + 8),
            width: size.width + 20, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: label, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: CGPoint(x: label.minX + 10, y: label.minY + 6), withAttributes: attributes)
    }
}


/// Immediate, in-overlay hints stay above the frozen screen without another window.
@MainActor
private final class HoverActionButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}
