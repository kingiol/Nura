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

    func testEmbeddedSubtitleSRTBecomesAbsoluteSegments() throws {
        let srt = """
        1
        00:00:01,250 --> 00:00:03,500
        Hello <i>Nura</i>

        2
        00:00:04,000 --> 00:00:05,500
        Second cue
        """

        XCTAssertEqual(
            try EmbeddedSubtitleExtractor.segments(fromSRT: srt),
            [
                TranscriptSegment(startMs: 1_250, endMs: 3_500, text: "Hello Nura"),
                TranscriptSegment(startMs: 4_000, endMs: 5_500, text: "Second cue"),
            ]
        )
    }

    func testEmbeddedSubtitleClassifiesTextAndGraphicStreams() throws {
        let textStream = try makeStream(
            index: 2,
            codecName: "ass",
            codecLongName: "ASS (Advanced SubStation Alpha)",
            width: nil,
            height: nil,
            isDefault: 1,
            language: "eng",
            title: "Commentary"
        )
        let graphicStream = try makeStream(
            index: 3,
            codecName: "hdmv_pgs_subtitle",
            codecLongName: "HDMV PGS subtitle",
            width: 1920,
            height: 1080,
            isDefault: 0,
            language: nil,
            title: nil
        )

        XCTAssertEqual(textStream.kind, .text)
        XCTAssertTrue(textStream.kind.isText)
        XCTAssertEqual(graphicStream.kind, .graphic)
        XCTAssertFalse(graphicStream.kind.isText)
        XCTAssertEqual(
            EmbeddedSubtitleExtractor.displayName(for: textStream),
            "Commentary | eng | text"
        )
        XCTAssertEqual(
            EmbeddedSubtitleExtractor.displayName(for: graphicStream),
            "Subtitle track 3 | requires OCR"
        )
    }

    func testEmbeddedSubtitleSelectsDefaultStream() throws {
        let streams = [
            try makeStream(
                index: 0,
                codecName: "subrip",
                codecLongName: nil,
                width: nil,
                height: nil,
                isDefault: 0,
                language: "eng",
                title: nil
            ),
            try makeStream(
                index: 1,
                codecName: "subrip",
                codecLongName: nil,
                width: nil,
                height: nil,
                isDefault: 1,
                language: "chi",
                title: nil
            ),
        ]

        XCTAssertEqual(
            EmbeddedSubtitleExtractor.selectDefaultSubtitleStream(from: streams)?.index,
            1
        )
    }

    func testEmbeddedSubtitleProbeDecodesLanguageAndTitle() throws {
        let json = """
        {
            "streams": [
                {
                    "index": 1,
                    "codec_name": "mov_text",
                    "codec_type": "subtitle",
                    "codec_long_name": "MOV text",
                    "width": null,
                    "height": null,
                    "disposition": { "default": 1 },
                    "tags": { "language": "eng", "name": "English" }
                }
            ]
        }
        """

        let response = try JSONDecoder().decode(SubtitleProbeResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.streams.count, 1)
        XCTAssertEqual(response.streams[0].language, "eng")
        XCTAssertEqual(response.streams[0].title, "English")
        XCTAssertEqual(response.streams[0].kind, .text)
    }

    private func makeStream(
        index: Int,
        codecName: String?,
        codecLongName: String?,
        width: Int?,
        height: Int?,
        isDefault: Int,
        language: String?,
        title: String?
    ) throws -> ProbeSubtitleStream {
        var tags = "{ "
        if let language {
            tags += "\"language\": \"\(language)\", "
        }
        if let title {
            tags += "\"name\": \"\(title)\", "
        }
        tags += "\"default_placeholder\": \"true\" }"
        let json = """
        {
            "index": \(index),
            "codec_name": \(codecName.map { "\"\($0)\"" } ?? "null"),
            "codec_type": "subtitle",
            "codec_long_name": \(codecLongName.map { "\"\($0)\"" } ?? "null"),
            "width": \(width.map(String.init) ?? "null"),
            "height": \(height.map(String.init) ?? "null"),
            "disposition": { "default": \(isDefault) },
            "tags": \(tags)
        }
        """
        return try JSONDecoder().decode(ProbeSubtitleStream.self, from: Data(json.utf8))
    }

    func testSourceFingerprintChangesWhenSubtitlePayloadChanges() {
        let first = SubtitleParser.sourceFingerprint(data: Data("first".utf8), trackIdentifier: "external")
        let second = SubtitleParser.sourceFingerprint(data: Data("second".utf8), trackIdentifier: "external")

        XCTAssertNotEqual(first, second)
    }

}
