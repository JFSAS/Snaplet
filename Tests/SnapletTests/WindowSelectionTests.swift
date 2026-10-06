import XCTest
import CoreGraphics
@testable import Snaplet

final class WindowSelectionTests: XCTestCase {
    func testDesktopCoordinateConversionSupportsAbovePrimaryScreen() {
        XCTAssertEqual(WindowSelection.appKitFrame(CGRect(x: -800, y: -400, width: 500, height: 300), primaryHeight: 900),
                       CGRect(x: -800, y: 1000, width: 500, height: 300))
    }
    func testFrontmostWindowWinsAndSelectionIsLocalToDisplay() {
        let screen = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        let front = WindowCandidate(id: 1, frame: CGRect(x: -900, y: 100, width: 400, height: 300), title: "Front")
        let back = WindowCandidate(id: 2, frame: screen, title: "Back")
        let result = WindowSelection.candidate(at: CGPoint(x: 200, y: 200), screenFrame: screen, windows: [front, back])
        XCTAssertEqual(result?.id, 1)
        XCTAssertEqual(result?.frame, CGRect(x: 100, y: 100, width: 400, height: 300))
    }
    func testWindowSpanningDisplaysIsClippedToCurrentDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = WindowCandidate(id: 1, frame: CGRect(x: 700, y: 100, width: 400, height: 300), title: "Window")
        XCTAssertEqual(WindowSelection.candidate(at: CGPoint(x: 750, y: 200), screenFrame: screen, windows: [window])?.frame,
                       CGRect(x: 700, y: 100, width: 100, height: 300))
        XCTAssertNil(WindowSelection.candidate(at: CGPoint(x: 200, y: 200), screenFrame: screen, windows: [window]))
    }
}
