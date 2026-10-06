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
    private let toolbar = NSVisualEffectView()
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, image: CGImage) {
        background = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        setAccessibilityLabel("截图框选区域")
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.masksToBounds = true
        toolbar.isHidden = true
        let stack = NSStackView(views: [
            button("重新框选", #selector(reselect)), button("预览", #selector(preview)),
            button("保存…", #selector(save)), button("取消", #selector(cancel)),
            button("完成 ✓", #selector(finish))
        ])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
        addSubview(toolbar)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic overlay") }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
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
        return super.performKeyEquivalent(with: event)
    }
    @objc private func reselect() { resetSelection(); window?.makeFirstResponder(self) }
    @objc private func preview() { confirm(.preview) }
    @objc private func save() { confirm(.save) }
    @objc private func cancel() { onCancel?() }
    @objc private func finish() { confirm(.copy) }
    private func confirm(_ action: CaptureAction) {
        guard model.canConfirm else { return }
        onAction?(model.rect, action)
    }
    private func refresh() {
        toolbar.isHidden = !model.canConfirm
        if model.canConfirm {
            let width: CGFloat = min(430, bounds.width - 16)
            let height: CGFloat = 46
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
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: model.rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        if model.canConfirm {
            for (_, point) in model.handles {
                NSColor.white.setFill()
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                handle.fill()
                NSColor.controlAccentColor.setStroke()
                handle.stroke()
            }
        }
        let text: String
        switch model.phase {
        case .idle: text = "拖动选择截图区域 · Esc 或右键取消"
        case .dragging: text = "\(Int(model.rect.width)) × \(Int(model.rect.height)) pt · 松开后调整选区"
        case .ready: text = "拖动选区或边缘调整 · Enter 复制 · 空格保存 · Esc 取消"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let label = CGRect(x: (bounds.width - size.width) / 2 - 14,
            y: bounds.height - 76, width: size.width + 28, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: label, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: CGPoint(x: label.minX + 14, y: label.minY + 10), withAttributes: attributes)
    }
}
