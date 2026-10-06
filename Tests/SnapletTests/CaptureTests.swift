import XCTest
import CoreGraphics
import ImageIO
import AppKit
@testable import Snaplet

final class CaptureTests: XCTestCase {
    func testShortcutRequiresModifierAndSurvivesSerialization() throws {
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        XCTAssertNil(ScreenshotShortcut.from(event: plain))
        let modified = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "@", charactersIgnoringModifiers: "@", isARepeat: false, keyCode: 19))
        let shortcut = try XCTUnwrap(ScreenshotShortcut.from(event: modified))
        XCTAssertEqual(shortcut.keyCode, 19)
        XCTAssertEqual(shortcut.modifiers, 768)
        XCTAssertEqual(ScreenshotShortcut.defaultShortcut.displayName, "⌥A")
        let restored = try JSONDecoder().decode(ScreenshotShortcut.self,
            from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(restored, shortcut)
        XCTAssertEqual(restored.displayName, "⇧⌘2")
    }

    func testConvertsBottomLeftSelectionToTopLeftCaptureCoordinates() {
        let rect = CaptureGeometry.sourceRect(
            selection: CGRect(x: 100, y: 200, width: 320, height: 180),
            screenSize: CGSize(width: 1440, height: 900)
        )
        XCTAssertEqual(rect, CGRect(x: 100, y: 520, width: 320, height: 180))
    }

    func testFullScreenAndTopEdgeCoordinates() {
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(CaptureGeometry.sourceRect(selection: CGRect(origin: .zero, size: size),
                                                  screenSize: size), CGRect(origin: .zero, size: size))
        XCTAssertEqual(CaptureGeometry.sourceRect(
            selection: CGRect(x: 0, y: 980, width: 100, height: 100), screenSize: size).minY, 0)
    }

    @MainActor
    func testPNGPreservesPixelDimensionsAndColor() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
            bytesPerRow: 32, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let originalPixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let originalColor = Array(UnsafeBufferPointer(start: originalPixels, count: 4))
        let image = try XCTUnwrap(context.makeImage())
        let data = try CaptureService.pngData(for: image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 6)
        context.clear(CGRect(x: 0, y: 0, width: 8, height: 6))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 8, height: 6))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels, count: 4)), originalColor)
    }
}
