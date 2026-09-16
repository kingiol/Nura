import AppKit
import XCTest

@testable import Nura

final class PlayerViewModelTests: XCTestCase {
    func testVideoMinimumSizePreservesAspectForWideVideo() {
        let geometry = VideoGeometry(width: 960, height: 400)
        let minimumSize = geometry.minimumSize

        XCTAssertEqual(minimumSize.width, 864)
        XCTAssertEqual(minimumSize.height, 360)
        XCTAssertEqual(minimumSize.width / minimumSize.height, 2.4, accuracy: 0.001)
    }

    func testVideoMinimumSizePreservesAspectForTallVideo() {
        let geometry = VideoGeometry(width: 400, height: 960)
        let minimumSize = geometry.minimumSize

        XCTAssertEqual(minimumSize.width, 360)
        XCTAssertEqual(minimumSize.height, 864)
        XCTAssertEqual(minimumSize.width / minimumSize.height, 400 / 960, accuracy: 0.001)
    }

    func testVideoMinimumSizeKeepsAbsoluteFloorForWideVideo() {
        let geometry = VideoGeometry(width: 1920, height: 1080)
        let minimumSize = geometry.minimumSize

        XCTAssertGreaterThanOrEqual(minimumSize.width, 600)
        XCTAssertGreaterThanOrEqual(minimumSize.height, 360)
        XCTAssertEqual(minimumSize.width / minimumSize.height, 16 / 9, accuracy: 0.001)
    }
}
