import AppKit
import XCTest

@testable import Nura

@MainActor
final class PlayerViewModelTests: XCTestCase {
    func testPiPRenderSizeKeepsSystemRenderDimensions() {
        XCTAssertEqual(
            PictureInPictureRenderSize.validated(width: 1280, height: 720),
            PictureInPictureRenderSize(width: 1280, height: 720)
        )
        XCTAssertEqual(
            PictureInPictureRenderSize.validated(width: 160, height: 90),
            PictureInPictureRenderSize(width: 160, height: 90)
        )
    }

    func testPiPRenderSizeClampsInvalidDimensions() {
        XCTAssertEqual(
            PictureInPictureRenderSize.validated(width: 0, height: -1),
            PictureInPictureRenderSize(width: 2, height: 2)
        )
    }

    func testPiPRenderSizeFitsVideoAspectInsideSystemRenderDimensions() {
        XCTAssertEqual(
            PictureInPictureRenderSize.aspectFit(
                sourceWidth: 1440,
                sourceHeight: 1080,
                targetWidth: 1280,
                targetHeight: 720
            ),
            PictureInPictureRenderSize(width: 960, height: 720)
        )

        XCTAssertEqual(
            PictureInPictureRenderSize.aspectFit(
                sourceWidth: 2560,
                sourceHeight: 1080,
                targetWidth: 1280,
                targetHeight: 720
            ),
            PictureInPictureRenderSize(width: 1280, height: 540)
        )
    }

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

    func testABLoopIgnoresRepeatedCommandUntilMatchingSnapshotArrives() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)
        runtime.queuedEvents = [.state(snapshot(position: 10, start: nil, end: nil))]
        model.processPlaybackEvents()

        model.advanceABLoop()
        model.advanceABLoop()

        XCTAssertEqual(runtime.commands, [.setABLoop(10, nil)])

        runtime.queuedEvents = [.state(snapshot(position: 15, start: 10, end: nil))]
        model.processPlaybackEvents()
        model.advanceABLoop()

        XCTAssertEqual(runtime.commands, [.setABLoop(10, nil), .setABLoop(10, 15)])
    }

    func testAbsoluteSeekOutsideCompletedRangeClearsBeforeSeeking() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)
        runtime.queuedEvents = [.state(snapshot(position: 12, start: 10, end: 20))]
        model.processPlaybackEvents()

        model.seek(to: 30)

        XCTAssertEqual(runtime.commands, [.setABLoop(nil, nil), .seek(30)])
    }

    func testRelativeSeekInsideCompletedRangeDoesNotClear() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)
        runtime.queuedEvents = [.state(snapshot(position: 12, start: 10, end: 20))]
        model.processPlaybackEvents()

        XCTAssertTrue(model.seekRelative(3))

        XCTAssertEqual(runtime.commands, [.seekRelative(3)])
    }

    func testRelativeSeekOutsideCompletedRangeClearsBeforeSeeking() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)
        runtime.queuedEvents = [.state(snapshot(position: 12, start: 10, end: 20))]
        model.processPlaybackEvents()

        XCTAssertTrue(model.seekRelative(20))

        XCTAssertEqual(runtime.commands, [.setABLoop(nil, nil), .seekRelative(20)])
    }

    func testSeekToCompletedRangeBoundaryRetainsLoop() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)
        runtime.queuedEvents = [.state(snapshot(position: 12, start: 10, end: 20))]
        model.processPlaybackEvents()

        model.seek(to: 10)
        model.seek(to: 20)

        XCTAssertEqual(runtime.commands, [.seek(10), .seek(20)])
    }

    func testSeekPreservesAOnlySelection() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)
        runtime.queuedEvents = [.state(snapshot(position: 12, start: 10, end: nil))]
        model.processPlaybackEvents()

        model.seek(to: 30)

        XCTAssertEqual(runtime.commands, [.seek(30)])
    }

    func testNativeErrorReenablesABLoopCommand() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)
        runtime.queuedEvents = [.state(snapshot(position: 10, start: nil, end: nil))]
        model.processPlaybackEvents()

        model.advanceABLoop()
        runtime.queuedEvents = [.error("A-B loop end must be after its start")]
        model.processPlaybackEvents()
        model.advanceABLoop()

        XCTAssertEqual(runtime.commands, [.setABLoop(10, nil), .setABLoop(10, nil)])
    }

    func testABLoopProgressGeometryReturnsNilWithoutFiniteDuration() {
        XCTAssertNil(ABLoopProgressGeometry.resolve(duration: nil, start: 5, end: 10))
        XCTAssertNil(ABLoopProgressGeometry.resolve(duration: .infinity, start: 5, end: 10))
    }

    func testABLoopProgressGeometryNormalizesAndClampsMarkers() {
        let geometry = ABLoopProgressGeometry.resolve(duration: 100, start: -5, end: 120)

        XCTAssertEqual(geometry?.start, 0)
        XCTAssertEqual(geometry?.end, 1)
    }

    func testABLoopProgressGeometrySupportsStartOnlyMarker() {
        let geometry = ABLoopProgressGeometry.resolve(duration: 100, start: 25, end: nil)

        XCTAssertEqual(geometry?.start, 0.25)
        XCTAssertNil(geometry?.end)
    }

    func testABLoopLabelReflectsCurrentNativeState() {
        let runtime = FakePlaybackRuntime()
        let model = PlayerViewModel(testingRuntime: runtime)

        runtime.queuedEvents = [.state(snapshot(position: 10, start: nil, end: nil))]
        model.processPlaybackEvents()
        XCTAssertEqual(model.abLoopLabel, "Set Loop Start")

        runtime.queuedEvents = [.state(snapshot(position: 10, start: 10, end: nil))]
        model.processPlaybackEvents()
        XCTAssertEqual(model.abLoopLabel, "Set Loop End")

        runtime.queuedEvents = [.state(snapshot(position: 10, start: 10, end: 20))]
        model.processPlaybackEvents()
        XCTAssertEqual(model.abLoopLabel, "Clear Loop")
    }

    private func snapshot(position: Double, start: Double?, end: Double?) -> PlaybackSnapshot {
        PlaybackSnapshot(
            item: MediaItem(source: .publicURL("https://example.com/video.mp4"), title: "video.mp4"),
            playlist: [],
            recentItems: [],
            historyItems: [],
            playlistIndex: nil,
            chapters: [],
            playlistLoop: false,
            abLoopStartSeconds: start,
            abLoopEndSeconds: end,
            status: "paused",
            positionSeconds: position,
            durationSeconds: 120,
            videoWidth: 1920,
            videoHeight: 1080,
            speed: 1,
            audioDelaySeconds: 0,
            subtitleDelaySeconds: 0,
            subtitlesVisible: true,
            subtitleScale: 1,
            subtitlePosition: 100,
            videoAspect: "Auto",
            videoRotationDegrees: 0,
            videoFlipped: false,
            bufferingPercent: nil,
            volume: 100,
            muted: false,
            videoTracks: [],
            audioTracks: [],
            audioDevices: [],
            subtitleTracks: [],
            error: nil
        )
    }
}

private final class FakePlaybackRuntime: PlaybackRuntime {
    enum Command: Equatable {
        case setABLoop(Double?, Double?)
        case seek(Double)
        case seekRelative(Double)
    }

    var commands: [Command] = []
    var queuedEvents: [PlayerEvent] = []

    func events() -> [PlayerEvent] {
        defer { queuedEvents = [] }
        return queuedEvents
    }

    func setABLoop(start: Double?, end: Double?) throws {
        commands.append(.setABLoop(start, end))
    }

    func seek(_ position: Double) throws {
        commands.append(.seek(position))
    }

    func seekRelative(_ offset: Double) throws {
        commands.append(.seekRelative(offset))
    }
}
