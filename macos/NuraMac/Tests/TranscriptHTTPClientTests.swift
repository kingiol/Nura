import Foundation
import XCTest

@testable import Nura

final class TranscriptHTTPClientTests: XCTestCase {
    func testTranscriptionRequestUsesBearerToken() throws {
        let fileURL = try makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let request = try TranscriptHTTPClient.makeRequest(
            chunk: AudioChunk(index: 0, count: 1, startMs: 0, durationMs: 600_000, fileURL: fileURL),
            configuration: try TranscriptHTTPConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "test-token"
            )
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.url?.path, "/api/v1/ai/transcriptions")
        XCTAssertTrue(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains("chunk_duration_ms") == true)
    }

    func testChunkPlanCoversDurationWithoutOverlap() {
        let plan = AudioChunkPlan(durationMs: 1_201_000, chunkDurationMs: 600_000)

        XCTAssertEqual(plan.chunks.map(\.startMs), [0, 600_000, 1_200_000])
        XCTAssertEqual(plan.chunks.map(\.durationMs), [600_000, 600_000, 1_000])
        for (previous, next) in zip(plan.chunks, plan.chunks.dropFirst()) {
            XCTAssertEqual(previous.startMs + previous.durationMs, next.startMs)
        }
    }

    func testConfigurationRejectsMissingBearerToken() {
        XCTAssertThrowsError(
            try TranscriptHTTPConfiguration(baseURL: URL(string: "https://api.example.test")!, bearerToken: " ")
        )
    }

    func testTranscribeDecodesTheNuraEnvelope() async throws {
        let fileURL = try makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let client = TranscriptHTTPClient(session: makeSession(protocolClass: SuccessfulTranscriptionURLProtocol.self))

        let result = try await client.transcribe(
            chunk: AudioChunk(index: 0, count: 1, startMs: 0, durationMs: 1_000, fileURL: fileURL),
            configuration: try TranscriptHTTPConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "test-token"
            )
        )

        XCTAssertEqual(result.providerID, "groq")
        XCTAssertEqual(result.modelRevision, "whisper-large-v3-turbo")
        XCTAssertEqual(result.segments, [TranscriptSegment(startMs: 1_250, endMs: 3_500, text: "Hello")])
    }

    func testTranscribeSurfacesNuraErrorEnvelope() async throws {
        let fileURL = try makeAudioFixture()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let client = TranscriptHTTPClient(session: makeSession(protocolClass: FailingTranscriptionURLProtocol.self))

        do {
            _ = try await client.transcribe(
                chunk: AudioChunk(index: 0, count: 1, startMs: 0, durationMs: 1_000, fileURL: fileURL),
                configuration: try TranscriptHTTPConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "test-token"
                )
            )
            XCTFail("Expected a transcription error")
        } catch let error as TranscriptHTTPClientError {
            XCTAssertEqual(error, .server(status: 422, message: "The chunk metadata is invalid."))
        }
    }

    func testInitialCloudAnalysisGuardRejectsAnyActiveTranscript() {
        XCTAssertFalse(
            CloudAnalysisWorkflowRules.canStartInitialAnalysis(
                hasActiveTranscript: true,
                isProcessing: false,
                canResume: false,
                canReTranscribe: false
            )
        )
        XCTAssertTrue(
            CloudAnalysisWorkflowRules.canStartInitialAnalysis(
                hasActiveTranscript: false,
                isProcessing: false,
                canResume: false,
                canReTranscribe: false
            )
        )
    }

    func testUnreadableMediaUsesTerminalNoContentRunBeforeCloudConfiguration() {
        let key = AnalysisKey(
            mediaFingerprint: "media",
            sourceFingerprint: "audio-v1",
            analysisProfile: "groq/whisper-large-v3-turbo/segment"
        )

        let run = CloudAnalysisWorkflowRules.noContentRun(
            key: key,
            reason: AudioChunkExportError.unreadableMedia.localizedDescription
        )

        XCTAssertEqual(run.status, .noContent)
        XCTAssertEqual(run.key, key)
        XCTAssertEqual(run.completedChunkIndexes, [])
    }

    func testCancelledRunKeepsTheOriginalAnalysisKey() {
        let original = AnalysisKey(
            mediaFingerprint: "media-a",
            sourceFingerprint: "audio-v1",
            analysisProfile: "groq/whisper-large-v3-turbo/segment"
        )
        let replacement = AnalysisKey(
            mediaFingerprint: "media-b",
            sourceFingerprint: "audio-v1",
            analysisProfile: "groq/whisper-large-v3-turbo/segment"
        )
        let existing = AnalysisRun(
            key: original,
            totalChunks: 3,
            completedChunkIndexes: [0],
            status: .processing,
            lastError: nil
        )

        let cancelled = CloudAnalysisWorkflowRules.interruptedRun(
            key: original,
            existing: existing,
            status: .cancelled,
            message: nil
        )

        XCTAssertEqual(cancelled.key, original)
        XCTAssertNotEqual(cancelled.key, replacement)
        XCTAssertEqual(cancelled.completedChunkIndexes, [0])
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    private func makeAudioFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptHTTPClientTests-\(UUID().uuidString).m4a")
        try Data([0, 1, 2]).write(to: url)
        return url
    }

    private func makeSession(protocolClass: URLProtocol.Type) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }
}

private class TranscriptionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    func respond(status: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SuccessfulTranscriptionURLProtocol: TranscriptionURLProtocol {
    override func startLoading() {
        respond(
            status: 200,
            body: """
            {"code":0,"message":"ok","data":{"provider_id":"groq","model_revision":"whisper-large-v3-turbo","language":"en","segments":[{"start_ms":1250,"end_ms":3500,"text":"Hello"}]}}
            """
        )
    }

    override func stopLoading() {}
}

private final class FailingTranscriptionURLProtocol: TranscriptionURLProtocol {
    override func startLoading() {
        respond(status: 422, body: #"{"code":42200,"message":"The chunk metadata is invalid.","data":null}"#)
    }

    override func stopLoading() {}
}
