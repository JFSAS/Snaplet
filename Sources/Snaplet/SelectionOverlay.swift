import AppKit

@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var completion: ((NSScreen, CGRect) -> Void)?
    private var cancellation: (() -> Void)?

    func begin(onSelection: @escaping (NSScreen, CGRect) -> Void,
               onCancel: @escaping () -> Void) {
        dismiss()
        completion = onSelection
        cancellation = onCancel
        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame,
                                         styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onSelection = { [weak self] rect in
                guard let self else { return }
                let callback = self.completion
                self.dismiss()
                callback?(screen, rect)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
        }
        let mouse = NSEvent.mouseLocation
        windows.first(where: { $0.frame.contains(mouse) })?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        completion = nil
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
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var startPoint: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        startPoint = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(startPoint.x, point.x), y: min(startPoint.y, point.y),
                           width: abs(point.x - startPoint.x), height: abs(point.y - startPoint.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        startPoint = nil
        guard selection.width >= 2, selection.height >= 2 else {
            selection = .zero
            needsDisplay = true
            return
        }
        onSelection?(selection)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.append(NSBezierPath(rect: selection)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.28).setFill()
        shade.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        let text = selection.isEmpty
            ? "拖动选择截图区域 · Esc 或右键取消"
            : "\(Int(selection.width)) × \(Int(selection.height)) pt · 松开鼠标截图"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let label = CGRect(x: (bounds.width - size.width) / 2 - 14,
                           y: bounds.height - 76, width: size.width + 28, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: label, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: CGPoint(x: label.minX + 14, y: label.minY + 10),
                               withAttributes: attributes)
    }
}
