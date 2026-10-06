import XCTest
import CoreGraphics
@testable import Snaplet

final class PinTests: XCTestCase {
    func testLargePinFitsScreenAndPreservesAspectRatio() {
        let bounds = CGRect(x: -1200, y: 100, width: 1000, height: 600)
        let rect = PinGeometry.fit(size: CGSize(width: 2000, height: 1000), centeredAt: CGPoint(x: -700, y: 400), within: bounds)
        XCTAssertEqual(rect.size, CGSize(width: 1000, height: 500))
        XCTAssertTrue(bounds.contains(rect))
    }
    func testPinAtScreenEdgeIsMovedInsideWithoutChangingSize() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rect = PinGeometry.fit(size: CGSize(width: 200, height: 100), centeredAt: CGPoint(x: 799, y: 599), within: bounds)
        XCTAssertEqual(rect, CGRect(x: 600, y: 500, width: 200, height: 100))
    }
    func testThinPinKeepsItsAspectRatio() {
        let rect = PinGeometry.fit(size: CGSize(width: 10000, height: 20), centeredAt: .zero,
                                  within: CGRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(rect.width / rect.height, 500, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1000)
    }
}
