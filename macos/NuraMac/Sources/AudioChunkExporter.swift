import AVFoundation
import Foundation

enum AudioChunkExportError: LocalizedError, Equatable {
    case remoteMedia
    case unreadableMedia
    case noAudio
    case noDuration
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
        case .exportFailed(let message):
            return message
        }
    }
}

struct AudioAssetInfo: Equatable, Sendable {
    let durationMs: Int64
}

struct ExportedAudioChunk: Sendable {
    let chunk: AudioChunk
    let temporaryDirectory: URL

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

enum AudioChunkExporter {
    static func inspect(_ mediaURL: URL) async throws -> AudioAssetInfo {
        guard mediaURL.isFileURL else { throw AudioChunkExportError.remoteMedia }
        do {
            let asset = AVURLAsset(url: mediaURL)
            guard try await asset.load(.isReadable) else { throw AudioChunkExportError.unreadableMedia }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { throw AudioChunkExportError.noAudio }
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
                throw AudioChunkExportError.noDuration
            }
            return AudioAssetInfo(durationMs: Int64((duration.seconds * 1_000).rounded(.up)))
        } catch let error as AudioChunkExportError {
            throw error
        } catch {
            throw AudioChunkExportError.unreadableMedia
        }
    }

    static func export(
        mediaURL: URL,
        plannedChunk: AudioChunkPlan.Chunk
    ) async throws -> ExportedAudioChunk {
        guard mediaURL.isFileURL else { throw AudioChunkExportError.remoteMedia }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuraTranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory.appendingPathComponent("chunk-\(plannedChunk.index).m4a")
        do {
            let asset = AVURLAsset(url: mediaURL)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw AudioChunkExportError.exportFailed("AVFoundation could not prepare this audio for analysis.")
            }
            session.outputURL = fileURL
            session.outputFileType = .m4a
            session.timeRange = CMTimeRange(
                start: CMTime(value: plannedChunk.startMs, timescale: 1_000),
                duration: CMTime(value: plannedChunk.durationMs, timescale: 1_000)
            )
            try await session.export(to: fileURL, as: .m4a)
            try Task.checkCancellation()
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

}
