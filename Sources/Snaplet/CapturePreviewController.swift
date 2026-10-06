import AppKit
import UniformTypeIdentifiers

@MainActor
final class CapturePreviewController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var capturedImage: CGImage?
    private let feedback = NSTextField(labelWithString: "")

    init(image: CGImage) {
        capturedImage = image
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "截图 · \(image.width) × \(image.height) px"
        window.minSize = CGSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        configureContent(image: image, in: window)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic window") }

    private func configureContent(image: CGImage, in window: NSWindow) {
        guard let content = window.contentView else { return }
        let imageView = NSImageView()
        imageView.image = NSImage(cgImage: image, size: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityLabel("截图预览")
        content.addSubview(imageView)

        let copy = NSButton(title: "复制图片", target: self, action: #selector(copyImage))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        let save = NSButton(title: "保存 PNG…", target: self, action: #selector(saveImage))
        save.bezelStyle = .rounded
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        feedback.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [copy, save, feedback])
        actions.spacing = 12
        actions.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16)
        ])
    }

    @objc private func copyImage() {
        guard let capturedImage else { return }
        do {
            let png = try CaptureService.pngData(for: capturedImage)
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setData(png, forType: .png) {
                feedback.stringValue = "已复制"
            } else {
                feedback.stringValue = "复制失败，请重试"
            }
        } catch { showError(error) }
    }

    @objc private func saveImage() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "Snaplet_\(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url,
                  let image = self.capturedImage else { return }
            do {
                try CaptureService.pngData(for: image).write(to: url, options: .atomic)
                self.feedback.stringValue = "已保存"
            } catch { self.showError(error) }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func windowWillClose(_ notification: Notification) {
        (window?.contentView?.subviews.first { $0 is NSImageView } as? NSImageView)?.image = nil
        capturedImage = nil
        onClose?()
    }
}
