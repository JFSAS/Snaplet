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
    func testMoveAndDeleteEachUndoAsOneAction() {
        var document = AnnotationDocument()
        let text = Annotation(tool: .text, points: [CGPoint(x: 20, y: 20)], color: .red, width: 4, text: "Text")
        document.append(text)
        document.replace(at: 0, with: text.translated(by: CGPoint(x: 30, y: 10)))
        document.remove(at: 0)
        XCTAssertTrue(document.items.isEmpty)
        document.undo()
        XCTAssertEqual(document.items.first?.points.first, CGPoint(x: 50, y: 30))
        document.undo()
        XCTAssertEqual(document.items.first?.points.first, CGPoint(x: 20, y: 20))
        document.redo()
        document.redo()
        XCTAssertTrue(document.items.isEmpty)
    }

    @MainActor
    func testShapeHitTestingUsesVisibleStrokesAndArrowheads() {
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)]
        let rectangle = Annotation(tool: .rectangle, points: points, color: .red, width: 4)
        XCTAssertTrue(rectangle.contains(CGPoint(x: 200, y: 202)))
        XCTAssertFalse(rectangle.contains(CGPoint(x: 200, y: 150)))
        let ellipse = Annotation(tool: .ellipse, points: points, color: .red, width: 4)
        XCTAssertTrue(ellipse.contains(CGPoint(x: 200, y: 200)))
        XCTAssertFalse(ellipse.contains(CGPoint(x: 200, y: 150)))
        XCTAssertFalse(ellipse.contains(CGPoint(x: 100, y: 100)))
        let arrow = Annotation(tool: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)], color: .red, width: 12)
        XCTAssertTrue(arrow.contains(CGPoint(x: 164, y: 122)), "Arrowhead is draggable too")
        XCTAssertTrue(arrow.bounds.contains(CGPoint(x: 164, y: 122)))
        let pen = Annotation(tool: .pen, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 100)], color: .red, width: 4)
        XCTAssertTrue(pen.contains(CGPoint(x: 150, y: 150)))
        XCTAssertFalse(pen.contains(CGPoint(x: 200, y: 100)))
        var document = AnnotationDocument()
        document.append(rectangle)
        document.append(ellipse)
        XCTAssertEqual(document.index(at: CGPoint(x: 200, y: 200)), 1)
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
