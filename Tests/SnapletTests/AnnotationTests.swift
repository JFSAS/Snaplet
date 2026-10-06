import XCTest
import AppKit
@testable import Snaplet

final class AnnotationTests: XCTestCase {
    @MainActor
    func testUndoRedoAndNewEditDiscardRedoHistory() {
        var document = AnnotationDocument()
        let annotation = Annotation(tool: .number, points: [CGPoint(x: 20, y: 20)],
                                    color: .red, width: 4, text: "1")
        document.append(annotation)
        XCTAssertEqual(document.nextNumber, 2)
        document.undo()
        XCTAssertTrue(document.items.isEmpty)
        XCTAssertEqual(document.nextNumber, 1)
        document.redo()
        XCTAssertEqual(document.items.count, 1)
        document.undo()
        document.append(annotation)
        document.redo()
        XCTAssertEqual(document.items.count, 1)
        document.reset()
        XCTAssertTrue(document.undone.isEmpty)
        XCTAssertTrue(document.items.isEmpty)
    }

    @MainActor
    func testAnnotationExportMatchesRetinaCropAndBottomLeftCoordinates() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 160,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let source = try XCTUnwrap(context.makeImage())
        let selection = CGRect(x: 10.25, y: 20.25, width: 50, height: 40)
        let screenSize = CGSize(width: 100, height: 80)
        let cropped = try CaptureService.crop(image: source, selection: selection, screenSize: screenSize)
        var document = AnnotationDocument()
        document.append(Annotation(tool: .line, points: [CGPoint(x: 20, y: 30), CGPoint(x: 40, y: 30)],
                                   color: .red, width: 4))
        let result = try document.render(on: cropped, selection: selection, screenSize: screenSize,
                                        sourceSize: CGSize(width: 200, height: 160))
        XCTAssertEqual(result.width, 101)
        XCTAssertEqual(result.height, 81)
        let readback = try XCTUnwrap(CGContext(data: nil, width: result.width, height: result.height,
            bitsPerComponent: 8, bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        readback.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let pixels = try XCTUnwrap(readback.data).assumingMemoryBound(to: UInt8.self)
        // Memory rows start at the top; y=30 is 20 pixels above the crop bottom.
        let red = (61 * result.width + 40) * 4
        XCTAssertGreaterThan(pixels[red], 240)
        XCTAssertLessThan(pixels[red + 1], 20)
        let untouched = (20 * result.width + 40) * 4
        XCTAssertGreaterThan(pixels[untouched + 1], 240)
    }
}
