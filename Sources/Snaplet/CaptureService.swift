import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureError: LocalizedError {
    case displayUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "显示器已断开，请重新截图。"
        case .encodingFailed: "无法将截图编码为 PNG。"
        }
    }
}

enum CaptureGeometry {
    /// AppKit uses a bottom-left origin; ScreenCaptureKit uses a top-left origin.
    static func sourceRect(selection: CGRect, screenSize: CGSize) -> CGRect {
        CGRect(x: selection.minX, y: screenSize.height - selection.maxY,
               width: selection.width, height: selection.height)
    }
}

@MainActor
enum CaptureService {
    static func capture(screen: NSScreen, selection: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CaptureGeometry.sourceRect(
            selection: selection, screenSize: screen.frame.size
        )
        configuration.width = max(1, Int((selection.width * screen.backingScaleFactor).rounded()))
        configuration.height = max(1, Int((selection.height * screen.backingScaleFactor).rounded()))
        configuration.showsCursor = false
        configuration.scalesToFit = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
    }

    static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw CaptureError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }
        return data as Data
    }
}
