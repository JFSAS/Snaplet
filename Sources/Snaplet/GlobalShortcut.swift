import AppKit
import Carbon

struct ScreenshotShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = ScreenshotShortcut(
        keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey), keyLabel: "A"
    )

    var displayName: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    static func from(event: NSEvent) -> ScreenshotShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require Command, Control or Option to avoid stealing ordinary typing.
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let text = event.charactersIgnoringModifiers, !text.isEmpty,
              event.keyCode != 53 else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        // charactersIgnoringModifiers still includes Shift (e.g. Shift-2 yields @).
        // Show the base physical key for number and punctuation keys.
        let baseLabels: [UInt16: String] = [
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
            28: "8", 25: "9", 29: "0", 24: "=", 27: "-", 30: "]", 33: "[",
            39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return ScreenshotShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                                  keyLabel: baseLabels[event.keyCode] ?? text.uppercased())
    }
}

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void
    private(set) var shortcut: ScreenshotShortcut
    private(set) var registrationError: String?
    private let defaultsKey = "screenshotShortcut"

    init(action: @escaping () -> Void) {
        self.action = action
        shortcut = UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(ScreenshotShortcut.self, from: $0) }
            ?? .defaultShortcut
    }

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                nil, &identifier)
            guard result == noErr, identifier.signature == 0x534E4150, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            // Application event handlers are delivered on the main event loop.
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            registrationError = "无法安装快捷键处理器（\(status)）。"
            return
        }
        if !register(shortcut) {
            registrationError = "快捷键 \(shortcut.displayName) 无法注册，可能已被占用。请更换组合键。"
        }
    }

    func update(_ candidate: ScreenshotShortcut) -> Bool {
        if candidate == shortcut && hotKey != nil { return true }
        let previous = shortcut
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard register(candidate) else {
            _ = register(previous)
            registrationError = "该快捷键无法注册，可能已被系统或其他应用占用。"
            return false
        }
        shortcut = candidate
        registrationError = nil
        if let data = try? JSONEncoder().encode(candidate) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        return true
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    func resume() {
        guard hotKey == nil else { return }
        registrationError = register(shortcut) ? nil : "当前快捷键无法注册，请更换组合键。"
    }

    private func register(_ shortcut: ScreenshotShortcut) -> Bool {
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: 0x534E4150, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKey) == noErr
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onShortcut: ((ScreenshotShortcut) -> Void)?
    var onBeginRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    private var isRecording = false
    private var previousTitle = ""
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic control") }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        previousTitle = title
        title = "按下组合键 · Esc 取消"
        isRecording = true
        onBeginRecording?()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if isRecording { record(event) } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            title = previousTitle
            isRecording = false
            onEndRecording?()
        }
        return super.resignFirstResponder()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 {
            title = previousTitle
            isRecording = false
            onEndRecording?()
        } else if let shortcut = ScreenshotShortcut.from(event: event) {
            title = previousTitle
            isRecording = false
            onShortcut?(shortcut)
            onEndRecording?()
        }
    }
}
