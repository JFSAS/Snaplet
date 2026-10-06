import XCTest
import AppKit
@testable import Snaplet

@MainActor
final class SelectionToolbarTests: XCTestCase {
    private func primaryButton(recording: Bool) throws -> NSButton {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            image: try XCTUnwrap(context.makeImage()), screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            candidates: [], recording: recording)
        view.restoreSelection(CGRect(x: 50, y: 100, width: 400, height: 300), annotations: AnnotationDocument())
        func descendants(_ node: NSView) -> [NSView] { node.subviews.flatMap { [$0] + descendants($0) } }
        return try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == (recording ? "开始录制" : "完成 ✓")
        })
    }

    func testBothPrimaryActionsKeepDarkContentOnLightBackground() throws {
        for recording in [false, true] {
            let button = try primaryButton(recording: recording)
            let foreground = try XCTUnwrap(button.contentTintColor?.usingColorSpace(.sRGB))
            XCTAssertLessThan(foreground.redComponent, 0.2)
            let background = try XCTUnwrap(button.layer?.backgroundColor,
                "Primary actions need a light neutral fill and readable dark content")
            let rgb = try XCTUnwrap(NSColor(cgColor: background)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722, 0.8)
            XCTAssertTrue(button.imageHugsTitle)
        }
    }
}
