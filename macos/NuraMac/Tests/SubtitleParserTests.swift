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

    func testVTTParserSkipsHeaderMetadataBeforeCues() throws {
        let input = """
        WEBVTT - Nura captions
        Kind: captions
        Language: en

        00:00:01.000 --> 00:00:02.500
        Hello
        """

        XCTAssertEqual(
            try SubtitleParser.parse(input, fileExtension: "vtt"),
            [TranscriptSegment(startMs: 1_000, endMs: 2_500, text: "Hello")]
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

    func testEmbeddedSubtitleDecodesTx3GPayloadWithoutTrailingStyles() throws {
        let payload = Data([0x00, 0x05] + Array("Hello".utf8) + [0x00, 0x00, 0x00, 0x00])

        XCTAssertEqual(
            try EmbeddedSubtitleExtractor.payloadString(data: payload, mediaSubType: 0x7478_3367),
            "Hello"
        )
    }

    func testEmbeddedSubtitleDecodesWVTTVttcPaylPayload() throws {
        let payload = wvttBox(type: "vttc", payload: wvttBox(type: "payl", payload: Data("Hello".utf8)))

        XCTAssertEqual(
            try EmbeddedSubtitleExtractor.payloadString(data: payload, mediaSubType: 0x7776_7474),
            "Hello"
        )
    }

    func testEmbeddedSubtitleRejectsUnsupportedTextFormat() {
        XCTAssertThrowsError(
            try EmbeddedSubtitleExtractor.payloadString(data: Data("plain text".utf8), mediaSubType: 0x7465_7874)
        )
    }

    func testSourceFingerprintChangesWhenSubtitlePayloadChanges() {
        let first = SubtitleParser.sourceFingerprint(data: Data("first".utf8), trackIdentifier: "external")
        let second = SubtitleParser.sourceFingerprint(data: Data("second".utf8), trackIdentifier: "external")

        XCTAssertNotEqual(first, second)
    }

    private func wvttBox(type: String, payload: Data) -> Data {
        let size = UInt32(payload.count + 8)
        return Data([
            UInt8((size >> 24) & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ]) + Data(type.utf8) + payload
    }
}
