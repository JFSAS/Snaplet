import XCTest
import CoreGraphics
@testable import Snaplet

final class SelectionTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testMouseReleaseLeavesAdjustableSelectionWithoutFinalizing() {
        var model = SelectionModel()
        model.begin(at: CGPoint(x: 400, y: 300))
        model.update(to: CGPoint(x: 100, y: 100), within: bounds)
        XCTAssertFalse(model.canConfirm)
        model.end()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(model.rect, CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(model.handles.count, 8)
    }

    func testMovingSelectionPreservesSizeAndStaysOnScreen() {
        var model = SelectionModel()
        model.restore(CGRect(x: 100, y: 100, width: 300, height: 200))
        model.begin(at: CGPoint(x: 200, y: 180))
        model.update(to: CGPoint(x: 1000, y: 1000), within: bounds)
        model.end()
        XCTAssertEqual(model.rect, CGRect(x: 500, y: 400, width: 300, height: 200))
    }

    func testCornerResizeCanCrossOppositeCorner() {
        var model = SelectionModel()
        model.restore(CGRect(x: 100, y: 100, width: 300, height: 200))
        model.begin(at: CGPoint(x: 100, y: 100))
        model.update(to: CGPoint(x: 500, y: 400), within: bounds)
        model.end()
        XCTAssertEqual(model.rect, CGRect(x: 400, y: 300, width: 100, height: 100))
        XCTAssertTrue(model.canConfirm)
    }

    func testZeroAreaClickDoesNotEnableCompletionAndResetClearsSelection() {
        var model = SelectionModel()
        model.begin(at: CGPoint(x: 100, y: 100))
        model.update(to: CGPoint(x: 100, y: 100), within: bounds)
        model.end()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.canConfirm)
        model.restore(CGRect(x: 20, y: 20, width: 100, height: 80))
        model.reset()
        XCTAssertFalse(model.canConfirm)
        XCTAssertEqual(model.rect, .zero)
    }

    func testRetinaCropMatchesTopOfFrozenScreen() {
        let pixels = CaptureGeometry.pixelRect(
            selection: CGRect(x: 100, y: 200, width: 320, height: 180),
            screenSize: CGSize(width: 1440, height: 900),
            imageSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(pixels, CGRect(x: 200, y: 1040, width: 640, height: 360))
    }

    @MainActor
    func testFrozenImageCropPreservesTopBandAndDimensions() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6,
            bitsPerComponent: 8, bytesPerRow: 32, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 3, width: 8, height: 3))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0, 0, 1, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 3))
        let image = try XCTUnwrap(context.makeImage())
        let crop = try CaptureService.crop(image: image,
            selection: CGRect(x: 0, y: 1.5, width: 4, height: 1.5),
            screenSize: CGSize(width: 4, height: 3))
        XCTAssertEqual(crop.width, 8)
        XCTAssertEqual(crop.height, 3)
        let result = try XCTUnwrap(CGContext(data: nil, width: 8, height: 3,
            bitsPerComponent: 8, bytesPerRow: 32, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        result.draw(crop, in: CGRect(x: 0, y: 0, width: 8, height: 3))
        let data = try XCTUnwrap(result.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: data, count: 4)), [255, 0, 0, 255])
    }

    @MainActor
    func testRepeatedQuickSaveCreatesDistinctDecodablePNGs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3,
            bitsPerComponent: 8, bytesPerRow: 16, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let first = try CaptureOutput.save(image, to: folder)
        let second = try CaptureOutput.save(image, to: folder)
        XCTAssertNotEqual(first, second)
        for url in [first, second] {
            let data = try Data(contentsOf: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 4)
            XCTAssertEqual(decoded.height, 3)
        }
    }
}
