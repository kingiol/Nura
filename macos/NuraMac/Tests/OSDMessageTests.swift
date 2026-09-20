import XCTest

@testable import Nura

final class OSDMessageTests: XCTestCase {
    func testPlaybackTitle() {
        XCTAssertEqual(OSDMessage.playback(true).title, "Play")
        XCTAssertEqual(OSDMessage.playback(false).title, "Pause")
    }

    func testSeekTitleUsesConfiguredShortcutLabel() {
        XCTAssertEqual(OSDMessage.seekRelative(5, 105, 120, nil).title, "Seek Forward 5 Seconds")
        XCTAssertEqual(OSDMessage.seekRelative(-5, 95, 120, nil).title, "Seek Backward 5 Seconds")
    }

    func testSeekDetailShowsPositionAndDuration() {
        XCTAssertEqual(OSDMessage.seekRelative(5, 105, 120, nil).detail, "01:45 / 02:00")
        XCTAssertEqual(OSDMessage.seek(to: 125, duration: 300).detail, "02:05 / 05:00")
    }

    func testVolumeProgressClampsToUnitInterval() {
        XCTAssertEqual(OSDMessage.volume(100).progress ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(OSDMessage.volume(50).progress ?? 0, 0.5, accuracy: 0.0001)
    }

    func testErrorUsesErrorStyle() {
        XCTAssertTrue(OSDMessage.error("boom").isError)
        XCTAssertFalse(OSDMessage.speed(1.5).isError)
    }
}
