import XCTest

@testable import Nura

final class SubtitleParserTests: XCTestCase {
    func testSRTParserProducesMillisecondsAndPlainText() throws {
        let input = "1\n00:00:01,250 --> 00:00:03,500\nHello <i>Nura</i>\n"

        XCTAssertEqual(
            try SubtitleParser.parse(input, fileExtension: "srt"),
            [TranscriptSegment(startMs: 1_250, endMs: 3_500, text: "Hello Nura")]
        )
    }

    func testVTTParserRejectsInvalidTiming() {
        XCTAssertThrowsError(
            try SubtitleParser.parse(
                "WEBVTT\n\n00:bad --> 00:00:02.000\ntext",
                fileExtension: "vtt"
            )
        )
    }

    func testTimedTextSamplesBecomeAbsoluteSegments() throws {
        XCTAssertEqual(
            try EmbeddedSubtitleExtractor.normalize([
                .init(startMs: 2_000, endMs: 4_000, payload: "Hello")
            ]),
            [TranscriptSegment(startMs: 2_000, endMs: 4_000, text: "Hello")]
        )
    }

    func testSourceFingerprintChangesWhenSubtitlePayloadChanges() {
        let first = SubtitleParser.sourceFingerprint(data: Data("first".utf8), trackIdentifier: "external")
        let second = SubtitleParser.sourceFingerprint(data: Data("second".utf8), trackIdentifier: "external")

        XCTAssertNotEqual(first, second)
    }
}
