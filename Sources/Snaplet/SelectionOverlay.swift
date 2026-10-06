import AppKit

@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var cancellation: (() -> Void)?

    func begin(snapshots: [(NSScreen, CGImage)], candidates: [WindowCandidate],
               initialSelection: (NSScreen, CGRect)? = nil,
               annotations: AnnotationDocument = AnnotationDocument(),
               onAction: @escaping (NSScreen, CGRect, CaptureAction, AnnotationDocument) -> Void,
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
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image, screenFrame: screen.frame, candidates: candidates)
            view.onAction = { rect, action, document in onAction(screen, rect, action, document) }
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
                view.restoreSelection(initialSelection.1, annotations: annotations)
            }
        }
        if let initialSelection {
            windows.first(where: { $0.frame == initialSelection.0.frame })?.makeKey()
        } else {
            windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        }
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
    var onAction: ((CGRect, CaptureAction, AnnotationDocument) -> Void)?
    var onCancel: (() -> Void)?
    var onBegin: (() -> Void)?
    private var model = SelectionModel()
    private let background: NSImage
    private let screenFrame: CGRect
    private let candidates: [WindowCandidate]
    private var hoveredWindow: WindowCandidate?
    private var pendingWindow: WindowCandidate?
    private var dragStart: CGPoint?
    private var hasDragged = false
    private var hoverTracking: NSTrackingArea?
    private let imageSize: CGSize
    private var document = AnnotationDocument()
    private var draft: Annotation?
    private var tool: AnnotationTool = .select
    private var toolButtons: [NSButton] = []
    private let colorPicker = NSColorWell()
    private let widthPicker = NSPopUpButton()
    private let editbar = NSView()
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private let toolbar = NSView()
    private let hoverLabel = NSTextField(labelWithString: "")
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, image: CGImage, screenFrame: CGRect, candidates: [WindowCandidate]) {
        imageSize = CGSize(width: image.width, height: image.height)
        self.screenFrame = screenFrame
        self.candidates = candidates
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
        editbar.appearance = NSAppearance(named: .aqua)
        editbar.wantsLayer = true
        editbar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        editbar.layer?.cornerRadius = 7
        editbar.isHidden = true
        toolButtons = AnnotationTool.allCases.map { tool in
            let button = NSButton(image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)!,
                                  target: self, action: #selector(chooseTool(_:)))
            button.tag = tool.rawValue
            button.bezelStyle = .texturedRounded
            button.setButtonType(.toggle)
            button.toolTip = tool.title
            button.setAccessibilityLabel(tool.title)
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            return button
        }
        colorPicker.color = .systemRed
        colorPicker.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorPicker.setAccessibilityLabel("标注颜色")
        widthPicker.addItems(withTitles: ["2", "4", "6", "8", "12"])
        widthPicker.selectItem(withTitle: "4")
        widthPicker.widthAnchor.constraint(equalToConstant: 48).isActive = true
        widthPicker.toolTip = "线条粗细 / 文字大小"
        widthPicker.setAccessibilityLabel("标注粗细")
        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "撤销")!, target: self, action: #selector(undoAnnotation))
        undo.toolTip = "撤销 · ⌘Z"
        let redo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "重做")!, target: self, action: #selector(redoAnnotation))
        redo.toolTip = "重做 · ⇧⌘Z"
        let edits = NSStackView(views: toolButtons + [colorPicker, widthPicker, undo, redo])
        edits.spacing = 3
        edits.translatesAutoresizingMaskIntoConstraints = false
        editbar.addSubview(edits)
        NSLayoutConstraint.activate([
            edits.leadingAnchor.constraint(equalTo: editbar.leadingAnchor, constant: 8),
            edits.trailingAnchor.constraint(equalTo: editbar.trailingAnchor, constant: -8),
            edits.centerYAnchor.constraint(equalTo: editbar.centerYAnchor)
        ])
        addSubview(editbar)
        updateToolButtons()
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
        updateHoveredWindow(at: CGPoint(x: NSEvent.mouseLocation.x - screenFrame.minX, y: NSEvent.mouseLocation.y - screenFrame.minY))
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
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard model.phase == .idle else { return }
        updateHoveredWindow(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if model.phase == .idle { hoveredWindow = nil; needsDisplay = true }
    }
    private func updateHoveredWindow(at point: CGPoint) {
        hoveredWindow = WindowSelection.candidate(at: point, screenFrame: screenFrame, windows: candidates)
        needsDisplay = true
    }
    func resetSelection() {
        commitText()
        document.reset()
        draft = nil
        tool = .select
        updateToolButtons()
        model.reset()
        updateHoveredWindow(at: CGPoint(x: NSEvent.mouseLocation.x - screenFrame.minX, y: NSEvent.mouseLocation.y - screenFrame.minY))
        refresh()
    }
    func restoreSelection(_ selection: CGRect, annotations: AnnotationDocument) {
        document = annotations; model.restore(selection); refresh()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if model.canConfirm {
            addCursorRect(model.rect, cursor: tool == .select ? .openHand : .crosshair)
            for (handle, point) in model.handles {
                let cursor: NSCursor = handle.x == 1 ? .resizeUpDown
                    : (handle.y == 1 ? .resizeLeftRight : .crosshair)
                addCursorRect(CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14), cursor: cursor)
            }
            addCursorRect(toolbar.frame, cursor: .arrow)
            addCursorRect(editbar.frame, cursor: .arrow)
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if model.canConfirm && tool != .select {
            commitText()
            guard model.rect.contains(point) else { return }
            let width = CGFloat(Double(widthPicker.titleOfSelectedItem ?? "4") ?? 4)
            if tool == .text {
                let field = NSTextField(frame: CGRect(x: point.x, y: point.y,
                    width: max(24, min(240, model.rect.maxX - point.x)), height: 32))
                field.placeholderString = "输入文字，Enter 确认"
                field.font = .systemFont(ofSize: max(16, width * 6), weight: .semibold)
                field.textColor = colorPicker.color
                field.target = self
                field.action = #selector(finishText)
                addSubview(field)
                textField = field
                textOrigin = point
                window?.makeFirstResponder(field)
            } else if tool == .number {
                document.append(Annotation(tool: tool, points: [point], color: colorPicker.color,
                    width: width, text: String(document.nextNumber)))
            } else {
                draft = Annotation(tool: tool, points: [point, point], color: colorPicker.color, width: width)
            }
            needsDisplay = true
            return
        }
        if model.canConfirm && model.rect.contains(point) && event.clickCount == 2 {
            finish(); return
        }
        commitText()
        if !model.canConfirm || (!model.rect.contains(point) && !model.handles.contains(where: {
            abs($0.1.x - point.x) <= 7 && abs($0.1.y - point.y) <= 7
        })) { document.reset() }
        pendingWindow = (model.phase == .idle || (!model.rect.contains(point) && !model.handles.contains(where: {
            abs($0.1.x - point.x) <= 7 && abs($0.1.y - point.y) <= 7
        })))
            ? WindowSelection.candidate(at: point, screenFrame: screenFrame, windows: candidates) : nil
        dragStart = point
        hasDragged = false
        hoveredWindow = nil
        onBegin?()
        model.begin(at: point)
        refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var draft {
            let clamped = CGPoint(x: min(max(point.x, model.rect.minX), model.rect.maxX),
                                  y: min(max(point.y, model.rect.minY), model.rect.maxY))
            if draft.tool == .pen { draft.points.append(clamped) }
            else { draft.points[draft.points.count - 1] = clamped }
            self.draft = draft
            needsDisplay = true
            return
        }
        if tool != .select { return }
        if let dragStart, hypot(point.x - dragStart.x, point.y - dragStart.y) > 3 { hasDragged = true }
        if hasDragged { model.update(to: point, within: bounds) }
        refresh()
    }
    override func mouseUp(with event: NSEvent) {
        if let draft {
            if let first = draft.points.first, let last = draft.points.last,
               draft.tool == .pen || hypot(last.x - first.x, last.y - first.y) >= 2 {
                document.append(draft)
            }
            self.draft = nil
            needsDisplay = true
            return
        }
        guard model.phase == .dragging else { return }
        if !hasDragged, let pendingWindow {
            model.restore(pendingWindow.frame)
        } else {
            model.update(to: convert(event.locationInWindow, from: nil), within: bounds)
            model.end()
        }
        pendingWindow = nil
        dragStart = nil
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
        if textField != nil { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 6 {
            if event.modifierFlags.contains(.shift) { redoAnnotation() } else { undoAnnotation() }
            return true
        }
        if event.keyCode == 8 { finish(); return true }
        if event.keyCode == 1 { save(); return true }
        if event.keyCode == 35 { pin(); return true }
        return super.performKeyEquivalent(with: event)
    }
    private func updateToolButtons() {
        toolButtons.forEach { $0.state = $0.tag == tool.rawValue ? .on : .off }
    }
    @objc private func chooseTool(_ sender: NSButton) {
        commitText()
        tool = AnnotationTool(rawValue: sender.tag) ?? .select
        updateToolButtons()
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }
    @objc private func finishText() { commitText(); window?.makeFirstResponder(self) }
    private func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        if !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.append(Annotation(tool: .text, points: [origin], color: field.textColor ?? .systemRed,
                width: (field.font?.pointSize ?? 24) / 6, text: field.stringValue))
        }
        field.removeFromSuperview()
        textField = nil
        textOrigin = nil
        needsDisplay = true
    }
    @objc private func undoAnnotation() { commitText(); document.undo(); needsDisplay = true }
    @objc private func redoAnnotation() { commitText(); document.redo(); needsDisplay = true }
    @objc private func reselect() { resetSelection(); window?.makeFirstResponder(self) }
    @objc private func pin() { confirm(.pin) }
    @objc private func preview() { confirm(.preview) }
    @objc private func save() { confirm(.save) }
    @objc private func cancel() { onCancel?() }
    @objc private func finish() { confirm(.copy) }
    private func confirm(_ action: CaptureAction) {
        guard model.canConfirm else { return }
        commitText()
        onAction?(model.rect, action, document)
    }
    private func refresh() {
        hoverLabel.isHidden = true
        toolbar.isHidden = !model.canConfirm
        editbar.isHidden = !model.canConfirm
        if model.canConfirm {
            let width: CGFloat = min(288, bounds.width - 16)
            let height: CGFloat = 78
            var y = model.rect.minY - height - 12
            if y < 8 { y = model.rect.maxY + 12 }
            if y + height > bounds.maxY - 8 { y = max(8, model.rect.minY + 12) }
            toolbar.frame = CGRect(x: min(max(8, model.rect.maxX - width), bounds.maxX - width - 8),
                                   y: y, width: width, height: 36)
            let editWidth: CGFloat = min(430, bounds.width - 16)
            editbar.frame = CGRect(x: min(max(8, model.rect.maxX - editWidth), bounds.maxX - editWidth - 8),
                                  y: y + 42, width: editWidth, height: 36)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        background.draw(in: bounds)
        let displayRect = model.rect.isEmpty ? (hoveredWindow?.frame ?? .zero) : model.rect
        let shade = NSBezierPath(rect: bounds)
        if !displayRect.isEmpty { shade.append(NSBezierPath(rect: displayRect)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        shade.fill()
        if !displayRect.isEmpty {
            NSColor.systemBlue.setStroke()
            let border = NSBezierPath(rect: displayRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: model.rect).addClip()
        document.items.forEach { $0.draw() }
        draft?.draw()
        NSGraphicsContext.restoreGraphicsState()
        if model.canConfirm {
            for (_, point) in model.handles {
                NSColor.white.setFill()
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                handle.fill()
                NSColor.systemBlue.setStroke()
                handle.stroke()
            }
        }
        let pixels = CaptureGeometry.pixelRect(selection: displayRect, screenSize: screenFrame.size, imageSize: imageSize)
        let text: String
        switch model.phase {
        case .idle: text = hoveredWindow.map { _ in "\(Int(pixels.width)) × \(Int(pixels.height)) px" } ?? "拖动框选 · 悬停选择窗口 · Esc 取消"
        case .dragging: text = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
        case .ready: text = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let label = CGRect(
            x: displayRect.isEmpty ? (bounds.width - size.width) / 2 - 10 : min(max(8, displayRect.minX), bounds.maxX - size.width - 28),
            y: displayRect.isEmpty ? bounds.height - 65 : max(8, min(bounds.maxY - size.height - 20, displayRect.maxY + 8)),
            width: size.width + 20, height: size.height + 12)
        (displayRect.isEmpty ? NSColor.black.withAlphaComponent(0.7) : NSColor.systemBlue).setFill()
        NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
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
