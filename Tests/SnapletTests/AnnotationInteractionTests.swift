import XCTest
import AppKit
@testable import Snaplet

@MainActor
final class AnnotationInteractionTests: XCTestCase {
    private func overlay(annotations: AnnotationDocument = AnnotationDocument()) throws -> (SelectionView, NSWindow) {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 800,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            image: try XCTUnwrap(context.makeImage()), screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), candidates: [])
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.restoreSelection(CGRect(x: 50, y: 100, width: 900, height: 650), annotations: annotations)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == title })
    }
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow, clickCount: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
    }
    private func key(_ code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    func testLargeTextEditorFitsItsFont() throws {
        let (view, window) = try overlay()
        defer { window.close() }
        let picker = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first)
        picker.selectItem(withTitle: "12")
        try button("文字", in: view).performClick(nil)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 200, y: 400), window: window))
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let font = try XCTUnwrap(field.font)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        XCTAssertGreaterThanOrEqual(field.frame.height, lineHeight + 6, "72 pt text must fit inside its editor")
    }

    func testCommittedTextCanBeDraggedAndDeleted() throws {
        var document = AnnotationDocument()
        document.append(Annotation(tool: .text, points: [CGPoint(x: 200, y: 400)], color: .red, width: 4, text: "Drag me"))
        let (view, window) = try overlay(annotations: document)
        defer { window.close() }
        try button("文字", in: view).performClick(nil)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 220, y: 410), window: window))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 320, y: 460), window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 320, y: 460), window: window))
        var exported = AnnotationDocument()
        view.onAction = { _, _, document in exported = document }
        try button("完成 ✓", in: view).performClick(nil)
        XCTAssertEqual(exported.items.count, 1, "Dragging existing text must not create another text item")
        XCTAssertEqual(exported.items.first?.points.first, CGPoint(x: 300, y: 450))
        view.keyDown(with: try key(51, window: window))
        try button("完成 ✓", in: view).performClick(nil)
        XCTAssertTrue(exported.items.isEmpty, "Delete must remove the selected text")
    }

    func testEveryDrawingToolCanDragAndDeleteItsExistingAnnotation() throws {
        let cases: [(AnnotationTool, [CGPoint], CGPoint)] = [
            (.rectangle, [CGPoint(x: 200, y: 400), CGPoint(x: 400, y: 500)], CGPoint(x: 300, y: 500)),
            (.ellipse, [CGPoint(x: 200, y: 400), CGPoint(x: 400, y: 500)], CGPoint(x: 300, y: 500)),
            (.line, [CGPoint(x: 200, y: 400), CGPoint(x: 400, y: 500)], CGPoint(x: 300, y: 450)),
            (.arrow, [CGPoint(x: 200, y: 400), CGPoint(x: 400, y: 500)], CGPoint(x: 300, y: 450)),
            (.pen, [CGPoint(x: 200, y: 400), CGPoint(x: 300, y: 500), CGPoint(x: 400, y: 400)], CGPoint(x: 250, y: 450)),
            (.number, [CGPoint(x: 200, y: 400)], CGPoint(x: 200, y: 400))
        ]
        for (tool, points, hit) in cases {
            var document = AnnotationDocument()
            document.append(Annotation(tool: tool, points: points, color: .red, width: 4, text: "1"))
            let (view, window) = try overlay(annotations: document)
            defer { window.close() }
            try button(tool.title, in: view).performClick(nil)
            let end = CGPoint(x: hit.x + 100, y: hit.y + 50)
            view.mouseDown(with: try mouse(.leftMouseDown, at: hit, window: window))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, window: window))
            view.mouseUp(with: try mouse(.leftMouseUp, at: end, window: window))
            var exported = AnnotationDocument()
            view.onAction = { _, _, document in exported = document }
            try button("完成 ✓", in: view).performClick(nil)
            XCTAssertEqual(exported.items.count, 1, tool.title)
            XCTAssertEqual(exported.items.first?.points, points.map { CGPoint(x: $0.x + 100, y: $0.y + 50) }, tool.title)
            var history = exported
            history.undo()
            XCTAssertEqual(history.items.first?.points, points, tool.title)
            view.keyDown(with: try key(51, window: window))
            try button("完成 ✓", in: view).performClick(nil)
            XCTAssertTrue(exported.items.isEmpty, tool.title)
        }
    }

    func testTextDeleteButtonAndTopmostHit() throws {
        var document = AnnotationDocument()
        for text in ["Behind", "Front"] {
            document.append(Annotation(tool: .text, points: [CGPoint(x: 200, y: 400)], color: .red, width: 4, text: text))
        }
        let (view, window) = try overlay(annotations: document)
        defer { window.close() }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 220, y: 410), window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 220, y: 410), window: window))
        let delete = try button("删除文字", in: view)
        XCTAssertFalse(delete.isHidden)
        delete.performClick(nil)
        var exported = AnnotationDocument()
        view.onAction = { _, _, document in exported = document }
        try button("完成 ✓", in: view).performClick(nil)
        XCTAssertEqual(exported.items.map(\.text), ["Behind"])
        exported.undo()
        XCTAssertEqual(exported.items.map(\.text), ["Behind", "Front"])
    }

    func testExistingTextCanBeEditedAndLongInputGrows() throws {
        var document = AnnotationDocument()
        document.append(Annotation(tool: .text, points: [CGPoint(x: 200, y: 400)], color: .red, width: 12, text: "Before"))
        let (view, window) = try overlay(annotations: document)
        defer { window.close() }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 220, y: 410), window: window, clickCount: 2))
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertEqual(field.stringValue, "Before")
        let oldWidth = field.frame.width
        field.stringValue = "After editing a much longer text"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertGreaterThan(field.frame.width, oldWidth)
        XCTAssertTrue(view.bounds.contains(field.frame))
        var exported = AnnotationDocument()
        view.onAction = { _, _, document in exported = document }
        try button("完成 ✓", in: view).performClick(nil)
        XCTAssertEqual(exported.items.count, 1)
        XCTAssertEqual(exported.items.first?.text, "After editing a much longer text")
        exported.undo()
        XCTAssertEqual(exported.items.first?.text, "Before")
    }

    func testEditToolHoverShowsAnOverlayHint() throws {
        let (view, window) = try overlay()
        defer { window.close() }
        let arrow = try button("箭头", in: view)
        arrow.mouseEntered(with: try mouse(.mouseMoved, at: .zero, window: window))
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue.contains("箭头")
        }, "Tooltips must be drawn in the overlay, above the screenSaver-level window")
    }
}
