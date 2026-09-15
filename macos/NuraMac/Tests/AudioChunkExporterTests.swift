import XCTest

@testable import Nura

final class AudioChunkExporterTests: XCTestCase {
    func testSelectsTheDefaultAudioStream() {
        let streams = [
            FFmpegAudioStream(index: 3, isDefault: false),
            FFmpegAudioStream(index: 1, isDefault: true),
            FFmpegAudioStream(index: 2, isDefault: false),
        ]

        XCTAssertEqual(
            AudioChunkExporter.selectDefaultAudioStream(from: streams),
            FFmpegAudioStream(index: 1, isDefault: true)
        )
    }

    func testFallsBackToTheFirstAudioStreamWhenNoDefaultIsMarked() {
        let streams = [
            FFmpegAudioStream(index: 7, isDefault: false),
            FFmpegAudioStream(index: 4, isDefault: false),
        ]

        XCTAssertEqual(
            AudioChunkExporter.selectDefaultAudioStream(from: streams),
            FFmpegAudioStream(index: 4, isDefault: false)
        )
    }

    func testUsesTheLowestIndexWhenMultipleDefaultStreamsAreMarked() {
        let streams = [
            FFmpegAudioStream(index: 5, isDefault: true),
            FFmpegAudioStream(index: 2, isDefault: true),
        ]

        XCTAssertEqual(
            AudioChunkExporter.selectDefaultAudioStream(from: streams),
            FFmpegAudioStream(index: 2, isDefault: true)
        )
    }
}
