import AppKit

@MainActor
enum CaptureOutput {
    static var directory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "captureSaveDirectory") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return pictures.appendingPathComponent("Snaplet", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "captureSaveDirectory") }
    }

    @discardableResult
    static func save(_ image: CGImage, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let name = "Snaplet_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).png"
        let url = directory.appendingPathComponent(name)
        try CaptureService.pngData(for: image).write(to: url, options: .atomic)
        return url
    }
}
