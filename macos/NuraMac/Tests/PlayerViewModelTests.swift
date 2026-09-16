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

final class PlayerWindowResizeDelegateTests: XCTestCase {
    func testWindowWillResizeClampsToMinimumContentSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 600, height: 360)
        let delegate = PlayerWindowResizeDelegate()

        let clamped = delegate.windowWillResize(window, to: NSSize(width: 80, height: 80))
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: 600, height: 360))
        ).size

        XCTAssertGreaterThanOrEqual(clamped.width, minimumFrameSize.width)
        XCTAssertGreaterThanOrEqual(clamped.height, minimumFrameSize.height)
    }

    func testWindowWillResizeAllowsLargerFrames() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 600, height: 360)
        let delegate = PlayerWindowResizeDelegate()

        let result = delegate.windowWillResize(window, to: NSSize(width: 1200, height: 800))
        XCTAssertEqual(result, NSSize(width: 1200, height: 800))
    }
}
