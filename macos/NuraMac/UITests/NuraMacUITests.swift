import XCTest

@MainActor
final class NuraMacUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDirectory: URL!
    private var defaultsSuiteName: String!
    private var mediaServer: MediaFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuraMacUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "com.nura.player.uitests.\(UUID().uuidString)"

        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        mediaServer?.stop()
        if let stateDirectory, FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.removeItem(at: stateDirectory)
        }
        if let defaultsSuiteName {
            UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    func testLoadsTheConfiguredMediaFixture() throws {
        try launch(loadsFixture: true)

        let title = app.staticTexts["player.title"]
        let slider = app.sliders["player.seek-slider"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "oceans.mp4")
        XCTAssertLessThan(title.frame.maxY, slider.frame.minY)
    }

    func testDoesNotShowTitleOrEmptyStateWithoutMedia() throws {
        try launch(loadsFixture: false)

        XCTAssertFalse(app.staticTexts["player.title"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Open a media file to begin"].exists)
    }

    func testUsesSimplifiedChineseForChineseSystemLanguage() throws {
        try launch(loadsFixture: false, language: "zh-Hans")

        let settingsToggle = app.buttons["player.settings-toggle"]
        XCTAssertTrue(settingsToggle.waitForExistence(timeout: 15))
        settingsToggle.click()

        let general = app.buttons["player.settings-tab-general"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertEqual(general.label, "通用")
    }

    func testUsesEnglishForEnglishSystemLanguage() throws {
        try launch(loadsFixture: false, language: "en")

        let settingsToggle = app.buttons["player.settings-toggle"]
        XCTAssertTrue(settingsToggle.waitForExistence(timeout: 15))
        settingsToggle.click()

        let general = app.buttons["player.settings-tab-general"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertEqual(general.label, "General")
    }

    func testFallsBackToEnglishForUnsupportedSystemLanguage() throws {
        try launch(loadsFixture: false, language: "fr")

        let settingsToggle = app.buttons["player.settings-toggle"]
        XCTAssertTrue(settingsToggle.waitForExistence(timeout: 15))
        settingsToggle.click()

        let general = app.buttons["player.settings-tab-general"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertEqual(general.label, "General")
    }

    func testCanPauseAndResumePlayback() throws {
        try launch(loadsFixture: true)

        let playback = app.buttons["player.playback-toggle"]
        XCTAssertTrue(playback.waitForExistence(timeout: 15))
        assertValue(playback, becomes: "playing", timeout: 15)
        playback.click()
        assertValue(playback, becomes: "paused")
        playback.click()
        assertValue(playback, becomes: "playing")
    }

    func testCanMuteAndUnmute() throws {
        try launch(loadsFixture: true)

        let mute = app.buttons["player.mute-toggle"]
        XCTAssertTrue(mute.waitForExistence(timeout: 15))
        assertValue(mute, becomes: "unmuted", timeout: 15)
        mute.click()
        assertValue(mute, becomes: "muted")
        mute.click()
        assertValue(mute, becomes: "unmuted")
    }

    func testCanOpenAndClosePlaylistSidebar() throws {
        try launch(loadsFixture: true)

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

    func testCanSwitchSettingsCategories() throws {
        try launch(loadsFixture: true)

        let settingsToggle = app.buttons["player.settings-toggle"]
        XCTAssertTrue(settingsToggle.waitForExistence(timeout: 15))
        settingsToggle.click()

        let general = app.buttons["player.settings-tab-general"]
        let video = app.buttons["player.settings-tab-video"]
        let audio = app.buttons["player.settings-tab-audio"]
        let subtitles = app.buttons["player.settings-tab-subtitles"]

        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertTrue(video.exists)
        XCTAssertTrue(audio.exists)
        XCTAssertTrue(subtitles.exists)
        assertValue(general, becomes: "selected")

        for tab in [video, audio, subtitles] {
            tab.click()
            assertValue(tab, becomes: "selected")
            assertValue(general, becomes: "unselected")
        }

        app.buttons["player.sidebar-close"].click()
        assertValue(settingsToggle, becomes: "closed")
    }

    func testOpenURLAfterLastWindowClosedCreatesNewWindowAndLoadsMedia() async throws {
        try launch(loadsFixture: true)

        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "oceans.mp4")
        closeLastPlayerWindow()
        XCTAssertFalse(title.waitForExistence(timeout: 2))

        let openURLItem = app.menuBars.menuItems["Open URL…"]
        XCTAssertTrue(openURLItem.waitForExistence(timeout: 5))
        openURLItem.click()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        let mediaURL = try await startMediaServer().appendingPathComponent("oceans.mp4").absoluteString
        field.typeText(mediaURL)
        app.buttons["Open"].click()

        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "oceans.mp4")
    }

    func testOpenFileAfterLastWindowClosedCreatesNewWindowAndLoadsMedia() throws {
        try launch(loadsFixture: true)

        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        closeLastPlayerWindow()
        XCTAssertFalse(title.waitForExistence(timeout: 2))

        let openItem = app.menuBars.menuItems["Open…"]
        XCTAssertTrue(openItem.waitForExistence(timeout: 5))
        openItem.click()

        chooseFileInOpenPanel(try requiredFixturePath())

        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "oceans.mp4")
    }

    func testOpenRecentAfterLastWindowClosedCreatesNewWindowAndLoadsMedia() throws {
        try launch(loadsFixture: true)

        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        closeLastPlayerWindow()
        XCTAssertFalse(title.waitForExistence(timeout: 2))

        let recentMenu = app.menuBars.menuItems["Open Recent"]
        XCTAssertTrue(recentMenu.waitForExistence(timeout: 5))
        recentMenu.click()
        let recentItem = app.menuBars.menuItems["oceans.mp4"]
        XCTAssertTrue(recentItem.waitForExistence(timeout: 5))
        recentItem.click()

        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "oceans.mp4")
    }

    func testCancelOpenFileAfterLastWindowClosedDoesNotCreateWindow() throws {
        try launch(loadsFixture: false)

        let openItem = app.menuBars.menuItems["Open…"]
        XCTAssertTrue(openItem.waitForExistence(timeout: 5))
        openItem.click()

        dismissOpenPanel()

        XCTAssertFalse(app.windows.firstMatch.waitForExistence(timeout: 2))
    }

    func testUnsupportedOpenFileAfterLastWindowClosedDoesNotCreateWindow() throws {
        try launch(loadsFixture: false)

        let unsupported = stateDirectory.appendingPathComponent("unsupported.txt")
        try Data("not media".utf8).write(to: unsupported)

        let openItem = app.menuBars.menuItems["Open…"]
        XCTAssertTrue(openItem.waitForExistence(timeout: 5))
        openItem.click()

        chooseFileInOpenPanel(unsupported.path)

        XCTAssertFalse(app.windows.firstMatch.waitForExistence(timeout: 2))
    }

    private func assertValue(_ element: XCUIElement, becomes expected: String, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: "value == %@", expected)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func closeLastPlayerWindow() {
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.click()
    }

    private func startMediaServer() async throws -> URL {
        if let mediaServer { return mediaServer.baseURL }
        let server = MediaFixtureServer(fixtureURL: try requiredFixtureURL())
        try await server.start()
        mediaServer = server
        return server.baseURL
    }

    private func requiredFixtureURL() throws -> URL {
        URL(fileURLWithPath: try requiredFixturePath())
    }

    private func chooseFileInOpenPanel(_ path: String) {
        let openPanel = app.sheets.firstMatch
        XCTAssertTrue(openPanel.waitForExistence(timeout: 5))
        openPanel.textFields["Name"].click()
        openPanel.textFields["Name"].typeText(path)
        openPanel.buttons["Open"].click()
    }

    private func dismissOpenPanel() {
        let openPanel = app.sheets.firstMatch
        XCTAssertTrue(openPanel.waitForExistence(timeout: 5))
        openPanel.buttons["Cancel"].click()
    }

    private func launch(loadsFixture: Bool, language: String? = nil) throws {
        let stateDirectory = try XCTUnwrap(stateDirectory)
        let defaultsSuiteName = try XCTUnwrap(defaultsSuiteName)
        var arguments: [String] = [
            "-e2e-state-dir", stateDirectory.path,
            "-e2e-defaults-suite", defaultsSuiteName,
            "-e2e-keep-controls-visible",
            "-e2e-disable-window-resize",
            "-ApplePersistenceIgnoreState", "YES",
        ]

        if loadsFixture {
            arguments.insert(contentsOf: ["-e2e-media-path", try requiredFixturePath()], at: 0)
        }

        if let language {
            arguments.append(contentsOf: ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "zh-Hans" ? "zh_CN" : "\(language)_US"])
        }

        app.launchArguments = arguments
        app.launch()
        app.activate()
    }

    private func requiredFixturePath() throws -> String {
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
        return fixturePath
    }
}
