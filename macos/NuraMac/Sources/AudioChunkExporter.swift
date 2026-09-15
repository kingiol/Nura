import Foundation

enum AudioChunkExportError: LocalizedError, Equatable {
    case remoteMedia
    case unreadableMedia
    case noAudio
    case noDuration
    case ffprobeUnavailable
    case ffmpegUnavailable
    case probeFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .remoteMedia:
            return "Cloud audio analysis is available for local media only."
        case .unreadableMedia:
            return "This media file cannot be read for audio analysis."
        case .noAudio:
            return "This media has no audio track to analyze."
        case .noDuration:
            return "This media has no analyzable audio duration."
        case .ffprobeUnavailable:
            return "FFprobe is unavailable for audio analysis."
        case .ffmpegUnavailable:
            return "FFmpeg is unavailable for audio analysis."
        case .probeFailed(let message), .exportFailed(let message):
            return message
        }
    }
}

struct AudioAssetInfo: Equatable, Sendable {
    let durationMs: Int64
    let audioStreamIndex: Int
}

struct ExportedAudioChunk: Sendable {
    let chunk: AudioChunk
    let temporaryDirectory: URL

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

struct FFmpegAudioStream: Equatable, Sendable {
    let index: Int
    let isDefault: Bool
}

enum AudioChunkExporter {
    static func inspect(_ mediaURL: URL) async throws -> AudioAssetInfo {
        guard mediaURL.isFileURL else { throw AudioChunkExportError.remoteMedia }
        guard let ffprobeURL = executableURL(named: "ffprobe") else {
            throw AudioChunkExportError.ffprobeUnavailable
        }

        let result: ProcessResult
        do {
            result = try await runProcess(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-print_format", "json",
                    "-show_entries", "format=duration:stream=index,codec_type,disposition",
                    "-select_streams", "a",
                    mediaURL.path,
                ]
            )
        } catch {
            throw AudioChunkExportError.probeFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        guard result.status == 0 else {
            throw AudioChunkExportError.probeFailed(result.errorMessage)
        }

        let probe: ProbeResponse
        do {
            probe = try JSONDecoder().decode(ProbeResponse.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw AudioChunkExportError.probeFailed("FFprobe returned invalid media metadata.")
        }

        let streams = probe.streams
            .filter { $0.codecType == "audio" }
            .map { FFmpegAudioStream(index: $0.index, isDefault: $0.disposition?.isDefault == 1) }
        guard let selectedStream = selectDefaultAudioStream(from: streams) else {
            throw AudioChunkExportError.noAudio
        }

        guard let durationString = probe.format?.duration,
              let durationSeconds = Double(durationString),
              durationSeconds.isFinite,
              durationSeconds > 0 else {
            throw AudioChunkExportError.noDuration
        }

        return AudioAssetInfo(
            durationMs: Int64((durationSeconds * 1_000).rounded(.up)),
            audioStreamIndex: selectedStream.index
        )
    }

    static func export(
        mediaURL: URL,
        plannedChunk: AudioChunkPlan.Chunk,
        audioStreamIndex: Int
    ) async throws -> ExportedAudioChunk {
        guard mediaURL.isFileURL else { throw AudioChunkExportError.remoteMedia }
        guard let ffmpegURL = executableURL(named: "ffmpeg") else {
            throw AudioChunkExportError.ffmpegUnavailable
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuraTranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory.appendingPathComponent("chunk-\(plannedChunk.index).m4a")
        do {
            let startSeconds = Double(plannedChunk.startMs) / 1_000
            let durationSeconds = Double(plannedChunk.durationMs) / 1_000
            let result = try await runProcess(
                executableURL: ffmpegURL,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", mediaURL.path,
                    "-ss", formatSeconds(startSeconds),
                    "-t", formatSeconds(durationSeconds),
                    "-map", "0:\(audioStreamIndex)",
                    "-vn", "-sn", "-dn",
                    "-ac", "1",
                    "-ar", "16000",
                    "-c:a", "aac",
                    "-b:a", "64k",
                    "-movflags", "+faststart",
                    fileURL.path,
                ]
            )
            try Task.checkCancellation()
            guard result.status == 0 else {
                throw AudioChunkExportError.exportFailed(result.errorMessage)
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw AudioChunkExportError.exportFailed("FFmpeg produced an empty audio chunk.")
            }
            return ExportedAudioChunk(
                chunk: AudioChunk(
                    index: plannedChunk.index,
                    count: plannedChunk.count,
                    startMs: plannedChunk.startMs,
                    durationMs: plannedChunk.durationMs,
                    fileURL: fileURL
                ),
                temporaryDirectory: temporaryDirectory
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    static func selectDefaultAudioStream(from streams: [FFmpegAudioStream]) -> FFmpegAudioStream? {
        let orderedStreams = streams.sorted { $0.index < $1.index }
        return orderedStreams.first(where: { $0.isDefault }) ?? orderedStreams.first
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private static func executableURL(named name: String) -> URL? {
        let environmentKey = "NURA_\(name.uppercased())_PATH"
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("bin").appendingPathComponent(name))
            candidates.append(resourceURL.appendingPathComponent(name))
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)"),
        ])
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let standardOutput = Pipe()
                    let standardError = Pipe()
                    process.executableURL = executableURL
                    process.arguments = arguments
                    process.standardOutput = standardOutput
                    process.standardError = standardError
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(data: standardOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        standardOutput: stdout,
                        errorMessage: stderr.isEmpty ? "FFmpeg process failed." : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let errorMessage: String
}

private struct ProbeResponse: Decodable {
    let streams: [ProbeStream]
    let format: ProbeFormat?
}

private struct ProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let disposition: ProbeDisposition?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case disposition
    }
}

private struct ProbeDisposition: Decodable {
    let isDefault: Int?

    enum CodingKeys: String, CodingKey {
        case isDefault = "default"
    }
}

private struct ProbeFormat: Decodable {
    let duration: String?
}
