import CryptoKit
import Foundation

struct AudioChunk: Equatable, Sendable {
    let index: Int
    let count: Int
    let startMs: Int64
    let durationMs: Int64
    let fileURL: URL
}

struct AudioChunkPlan: Equatable, Sendable {
    // Qwen3-ASR synchronous inference accepts recordings up to five minutes.
    static let defaultChunkDurationMs: Int64 = 300_000

    struct Chunk: Equatable, Sendable {
        let index: Int
        let count: Int
        let startMs: Int64
        let durationMs: Int64
    }

    let durationMs: Int64
    let chunkDurationMs: Int64
    let chunks: [Chunk]

    init(durationMs: Int64, chunkDurationMs: Int64 = AudioChunkPlan.defaultChunkDurationMs) {
        self.durationMs = max(0, durationMs)
        self.chunkDurationMs = max(1, chunkDurationMs)
        guard durationMs > 0 else {
            chunks = []
            return
        }

        let count = Int((durationMs + chunkDurationMs - 1) / chunkDurationMs)
        chunks = (0..<count).map { index in
            let startMs = Int64(index) * chunkDurationMs
            return Chunk(
                index: index,
                count: count,
                startMs: startMs,
                durationMs: min(chunkDurationMs, durationMs - startMs)
            )
        }
    }
}

struct TranscriptHTTPConfiguration: Equatable, Sendable {
    let baseURL: URL
    let bearerToken: String

    init(baseURL: URL, bearerToken: String) throws {
        guard (baseURL.scheme == "http" || baseURL.scheme == "https"), baseURL.host != nil else {
            throw TranscriptHTTPClientError.invalidBaseURL
        }
        guard !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptHTTPClientError.missingBearerToken
        }
        self.baseURL = baseURL
        self.bearerToken = bearerToken
    }
}

struct CloudTranscriptResult: Equatable, Sendable {
    let providerID: String
    let modelRevision: String
    let language: String
    let segments: [TranscriptSegment]
}

struct CloudAnalysisCheckpoint: Codable, Equatable {
    let key: AnalysisKey
    var chunks: [Int: [TranscriptSegment]]
    var providerID: String?
    var modelRevision: String?
}

enum CloudAnalysisCheckpointStore {
    static func load(from directory: URL, key: AnalysisKey) throws -> CloudAnalysisCheckpoint? {
        let url = checkpointURL(in: directory, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CloudAnalysisCheckpoint.self, from: Data(contentsOf: url))
    }

    static func save(_ checkpoint: CloudAnalysisCheckpoint, in directory: URL) throws {
        let url = checkpointURL(in: directory, key: checkpoint.key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }

    static func remove(from directory: URL, key: AnalysisKey) {
        try? FileManager.default.removeItem(at: checkpointURL(in: directory, key: key))
    }

    private static func checkpointURL(in directory: URL, key: AnalysisKey) -> URL {
        let data = (try? JSONEncoder().encode(key)) ?? Data()
        let identifier = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return directory
            .appendingPathComponent("analysis-checkpoints", isDirectory: true)
            .appendingPathComponent("\(identifier).json")
    }
}

enum TranscriptHTTPClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case missingBearerToken
    case unreadableAudio
    case invalidResponse(String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid AI API URL."
        case .missingBearerToken:
            return "Add an AI API bearer token in Settings before analyzing audio."
        case .unreadableAudio:
            return "The exported audio chunk could not be read."
        case .invalidResponse(let message):
            return message
        case .server(_, let message):
            return message
        }
    }
}

struct TranscriptHTTPClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func makeRequest(
        chunk: AudioChunk,
        configuration: TranscriptHTTPConfiguration,
        languageHint: String? = nil
    ) throws -> URLRequest {
        let boundary = "NuraTranscript-\(UUID().uuidString)"
        let endpoint = configuration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("ai")
            .appendingPathComponent("transcriptions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try multipartBody(
            boundary: boundary,
            chunk: chunk,
            languageHint: languageHint
        )
        return request
    }

    func transcribe(
        chunk: AudioChunk,
        configuration: TranscriptHTTPConfiguration,
        languageHint: String? = nil
    ) async throws -> CloudTranscriptResult {
        let request = try Self.makeRequest(
            chunk: chunk,
            configuration: configuration,
            languageHint: languageHint
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptHTTPClientError.invalidResponse("The AI API returned an invalid response.")
        }

        let envelope = try decodeEnvelope(data)
        guard (200..<300).contains(httpResponse.statusCode), envelope.code == 0, let result = envelope.data else {
            throw TranscriptHTTPClientError.server(
                status: httpResponse.statusCode,
                message: envelope.message.isEmpty ? "The AI API could not transcribe this audio chunk." : envelope.message
            )
        }
        return CloudTranscriptResult(
            providerID: result.providerID,
            modelRevision: result.modelRevision,
            language: result.language,
            segments: result.segments
        )
    }

    private static func multipartBody(
        boundary: String,
        chunk: AudioChunk,
        languageHint: String?
    ) throws -> Data {
        guard let audioData = try? Data(contentsOf: chunk.fileURL) else {
            throw TranscriptHTTPClientError.unreadableAudio
        }
        var body = Data()
        let lineBreak = "\r\n"

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(value)\(lineBreak)".data(using: .utf8)!)
        }

        appendField("chunk_index", String(chunk.index))
        appendField("chunk_count", String(chunk.count))
        appendField("chunk_start_ms", String(chunk.startMs))
        appendField("chunk_duration_ms", String(chunk.durationMs))
        appendField("timestamp_granularity", "segment")
        if let languageHint = languageHint?.trimmingCharacters(in: .whitespacesAndNewlines), !languageHint.isEmpty {
            appendField("language_hint", languageHint)
        }
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"chunk-\(chunk.index).m4a\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(audioData)
        body.append(lineBreak.data(using: .utf8)!)
        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }

    private func decodeEnvelope(_ data: Data) throws -> TranscriptionEnvelope {
        do {
            return try JSONDecoder().decode(TranscriptionEnvelope.self, from: data)
        } catch {
            throw TranscriptHTTPClientError.invalidResponse("The AI API returned an invalid response.")
        }
    }
}

private struct TranscriptionEnvelope: Decodable {
    let code: Int
    let message: String
    let data: TranscriptionEnvelopeData?
}

private struct TranscriptionEnvelopeData: Decodable {
    let providerID: String
    let modelRevision: String
    let language: String
    let segments: [TranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case language, segments
        case providerID = "provider_id"
        case modelRevision = "model_revision"
    }
}
