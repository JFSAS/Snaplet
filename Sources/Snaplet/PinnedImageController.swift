import AppKit

struct PinGeometry {
    static func fit(size: CGSize, centeredAt center: CGPoint, within bounds: CGRect) -> CGRect {
        let scale = min(1, bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        let size = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        return CGRect(x: min(max(center.x - size.width / 2, bounds.minX), bounds.maxX - size.width),
                      y: min(max(center.y - size.height / 2, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

@MainActor
final class PinnedImageController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var image: CGImage?
    private let originalSize: CGSize

    init(image: CGImage, rect: CGRect, screen: NSScreen) {
        self.image = image
        originalSize = rect.size
        let frame = PinGeometry.fit(size: rect.size, centeredAt: CGPoint(x: rect.midX, y: rect.midY), within: screen.visibleFrame)
        let panel = PinPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "截图贴图 · \(image.width) × \(image.height) px"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        super.init(window: panel)
        panel.delegate = self
        let view = PinnedImageView(image: image)
        view.onClose = { [weak self] in self?.close() }
        view.onCopy = { [weak self] in self?.copyImage() }
        view.onSave = { [weak self] in self?.saveImage() }
        view.onReset = { [weak self] in self?.resize(to: self?.originalSize ?? .zero) }
        view.onZoom = { [weak self] factor in
            guard let self, let window = self.window else { return }
            self.resize(to: CGSize(width: window.frame.width * factor, height: window.frame.height * factor))
        }
        panel.contentView = view
        panel.makeFirstResponder(view)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic pin") }

    private func resize(to size: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let minimum = 64 / max(1, max(originalSize.width, originalSize.height))
        let scale = max(minimum, size.width / max(1, originalSize.width))
        let rect = PinGeometry.fit(size: CGSize(width: originalSize.width * scale, height: originalSize.height * scale),
                                  centeredAt: CGPoint(x: window.frame.midX, y: window.frame.midY), within: screen.visibleFrame)
        window.setFrame(rect, display: true)
    }
    private func copyImage() {
        guard let image else { return }
        do {
            let data = try CaptureService.pngData(for: image)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setData(data, forType: .png) else { throw CaptureError.encodingFailed }
            CaptureFeedback.success()
        } catch { showError(error) }
    }
    private func saveImage() {
        guard let image, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Snaplet_pin.png"
        panel.directoryURL = CaptureOutput.directory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try CaptureService.pngData(for: image).write(to: url, options: .atomic)
                CaptureFeedback.success()
            } catch { self?.showError(error) }
        }
    }
    private func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
    func windowWillClose(_ notification: Notification) {
        (window?.contentView as? PinnedImageView)?.releaseImage()
        window?.contentView = nil
        image = nil
        onClose?()
        onClose = nil
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PinnedImageView: NSView {
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onReset: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    private var image: NSImage?
    private var resizeStart: (CGPoint, CGRect)?
    private let closeButton = NSButton()
    private var hoverTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage) {
        self.image = NSImage(cgImage: image, size: .zero)
        super.init(frame: .zero)
        setAccessibilityLabel("截图贴图，拖动移动，滚轮缩放，右键查看操作")
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭贴图")
        closeButton.contentTintColor = .white
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.toolTip = "关闭贴图 · Esc"
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        closeButton.layer?.cornerRadius = 10
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic pin view") }
    func releaseImage() { image = nil }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(CGRect(x: bounds.maxX - 18, y: 0, width: 18, height: 18), cursor: .crosshair)
        addCursorRect(closeButton.frame, cursor: .arrow)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.maxX - 18 && point.y <= 18, let window {
            resizeStart = (NSEvent.mouseLocation, window.frame)
        } else {
            window?.performDrag(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (start, frame) = resizeStart, let window else { return }
        let ratio = frame.height / frame.width
        let delta = NSEvent.mouseLocation.x - start.x
        let maxWidth = min((window.screen?.visibleFrame.width ?? 3000), (window.screen?.visibleFrame.height ?? 2000) / ratio)
        let minimumWidth = 64 / max(1, ratio)
        let width = min(max(minimumWidth, frame.width + delta), maxWidth)
        let height = width * ratio
        window.setFrame(CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
    }
    override func mouseUp(with event: NSEvent) { resizeStart = nil }
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        onZoom?(exp(min(max(event.scrollingDeltaY * 0.01, -0.2), 0.2)))
    }
    override func magnify(with event: NSEvent) { onZoom?(max(0.5, 1 + event.magnification)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 8: copyPin(); return true
        case 1: savePin(); return true
        case 13: closePin(); return true
        case 29: resetPin(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("复制图片 · ⌘C", #selector(copyPin)), ("保存 PNG… · ⌘S", #selector(savePin)),
                                ("恢复原始大小 · ⌘0", #selector(resetPin)), ("关闭贴图 · Esc", #selector(closePin))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    @objc private func closePin() { onClose?() }
    @objc private func copyPin() { onCopy?() }
    @objc private func savePin() { onSave?() }
    @objc private func resetPin() { onReset?() }
}
