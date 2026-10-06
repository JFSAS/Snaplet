import AppKit

@MainActor
enum CaptureFeedback {
    static var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "captureSoundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "captureSoundEnabled") }
    }
    private static let sound = NSSound(contentsOfFile:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true) ?? NSSound(named: "Pop")

    static func success() {
        guard soundEnabled else { return }
        sound?.stop()
        sound?.play()
    }
}
