import XCTest

@MainActor
final class NuraMacUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDirectory: URL!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixturePath = ProcessInfo.processInfo.environment["NURA_E2E_MEDIA_PATH"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("test-fixtures/media/oceans.mp4")
                .path
        guard FileManager.default.fileExists(atPath: fixturePath) else {
            throw XCTSkip("E2E fixture does not exist: \(fixturePath)")
        }

        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuraMacUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "com.nura.player.uitests.\(UUID().uuidString)"

        app = XCUIApplication()
        app.launchArguments = [
            "-e2e-media-path", fixturePath,
            "-e2e-state-dir", stateDirectory.path,
            "-e2e-defaults-suite", defaultsSuiteName,
            "-e2e-keep-controls-visible",
            "-e2e-disable-window-resize",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        app.activate()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let stateDirectory, FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.removeItem(at: stateDirectory)
        }
        if let defaultsSuiteName {
            UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    func testLoadsTheConfiguredMediaFixture() {
        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "oceans.mp4")
    }

    func testCanPauseAndResumePlayback() {
        let playback = app.buttons["player.playback-toggle"]
        XCTAssertTrue(playback.waitForExistence(timeout: 15))
        assertValue(playback, becomes: "playing", timeout: 15)
        playback.click()
        assertValue(playback, becomes: "paused")
        playback.click()
        assertValue(playback, becomes: "playing")
    }

    func testCanMuteAndUnmute() {
        let mute = app.buttons["player.mute-toggle"]
        XCTAssertTrue(mute.waitForExistence(timeout: 15))
        assertValue(mute, becomes: "unmuted", timeout: 15)
        mute.click()
        assertValue(mute, becomes: "muted")
        mute.click()
        assertValue(mute, becomes: "unmuted")
    }

    func testCanOpenAndClosePlaylistSidebar() {
        let toggle = app.buttons["player.sidebar-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        assertValue(toggle, becomes: "closed", timeout: 5)
        toggle.click()
        assertValue(toggle, becomes: "open", timeout: 5)

        let close = app.buttons["player.sidebar-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        let closedToggle = app.buttons["player.sidebar-toggle"]
        assertValue(closedToggle, becomes: "closed", timeout: 5)
    }

    private func assertValue(_ element: XCUIElement, becomes expected: String, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: "value == %@", expected)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
}
