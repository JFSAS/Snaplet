import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureError: LocalizedError {
    case displayUnavailable
    case encodingFailed
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "显示器已断开，请重新截图。"
        case .encodingFailed: "无法将截图编码为 PNG。"
        case .invalidSelection: "选区无效，请重新框选。"
        }
    }
}

enum CaptureGeometry {
    /// AppKit uses a bottom-left origin; ScreenCaptureKit uses a top-left origin.
    static func sourceRect(selection: CGRect, screenSize: CGSize) -> CGRect {
        CGRect(x: selection.minX, y: screenSize.height - selection.maxY,
               width: selection.width, height: selection.height)
    }

    static func pixelRect(selection: CGRect, screenSize: CGSize, imageSize: CGSize) -> CGRect {
        let source = sourceRect(selection: selection, screenSize: screenSize)
        return CGRect(x: source.minX * imageSize.width / screenSize.width,
                      y: source.minY * imageSize.height / screenSize.height,
                      width: source.width * imageSize.width / screenSize.width,
                      height: source.height * imageSize.height / screenSize.height)
            .integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
}

@MainActor
enum CaptureService {
    static func crop(image: CGImage, selection: CGRect, screenSize: CGSize) throws -> CGImage {
        let rect = CaptureGeometry.pixelRect(selection: selection, screenSize: screenSize,
            imageSize: CGSize(width: image.width, height: image.height))
        guard !rect.isEmpty, let cropped = image.cropping(to: rect),
              let colorSpace = image.colorSpace,
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.invalidSelection
        }
        // Detach the result from the full-screen backing storage.
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let result = context.makeImage() else { throw CaptureError.invalidSelection }
        return result
    }

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
