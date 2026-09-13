import AVFoundation
import CoreMedia
import Foundation

enum EmbeddedSubtitleExtractionError: LocalizedError, Equatable {
    case unavailable(String)
    case unreadablePayload
    case noContent

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .unreadablePayload:
            return "The selected subtitle track uses an unsupported text encoding."
        case .noContent:
            return "The selected subtitle track does not contain readable timed text."
        }
    }
}

enum EmbeddedSubtitleExtractor {
    struct TimedTextSample: Equatable {
        let startMs: Int64
        let endMs: Int64
        let payload: String
    }

    static func discover(in url: URL) async throws -> [EmbeddedSubtitleTrack] {
        guard url.isFileURL else {
            throw EmbeddedSubtitleExtractionError.unavailable("Embedded subtitle extraction is available for local media only.")
        }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable) else {
            throw EmbeddedSubtitleExtractionError.unavailable("This media file is not readable by AVFoundation.")
        }
        let tracks = try await subtitleTracks(in: asset)
        var available: [EmbeddedSubtitleTrack] = []
        for track in tracks {
            guard try await canReadMetadata(for: track, asset: asset) else { continue }
            available.append(
                EmbeddedSubtitleTrack(
                    identifier: String(track.trackID),
                    displayName: "Subtitle track \(track.trackID)"
                )
            )
        }
        return available
    }

    static func extract(from url: URL, trackIdentifier: String) async throws -> TranscriptDocument {
        guard url.isFileURL else {
            throw EmbeddedSubtitleExtractionError.unavailable("Embedded subtitle extraction is available for local media only.")
        }
        guard let trackID = Int32(trackIdentifier) else {
            throw EmbeddedSubtitleExtractionError.unavailable("The selected subtitle track is unavailable.")
        }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable) else {
            throw EmbeddedSubtitleExtractionError.unavailable("This media file is not readable by AVFoundation.")
        }
        guard let track = try await subtitleTracks(in: asset).first(where: { $0.trackID == trackID }) else {
            throw EmbeddedSubtitleExtractionError.unavailable("The selected subtitle track cannot be read as timed text.")
        }
        guard try await canReadMetadata(for: track, asset: asset) else {
            throw EmbeddedSubtitleExtractionError.unavailable("The selected subtitle track cannot be read as timed text.")
        }

        let samples = try readSamples(from: track, asset: asset)
        let segments = try normalize(samples)
        let normalizedPayload = segments.map { "\($0.startMs)-\($0.endMs):\($0.text)" }.joined(separator: "\n")
        let sourceFingerprint = SubtitleParser.sourceFingerprint(
            data: Data(normalizedPayload.utf8),
            trackIdentifier: "embedded:\(trackIdentifier)"
        )
        let key = AnalysisKey(
            mediaFingerprint: MediaFingerprint.forLocalMedia(url),
            sourceFingerprint: sourceFingerprint,
            analysisProfile: "embedded/avfoundation-v1"
        )
        return TranscriptDocument(
            key: key,
            source: "embedded_subtitle",
            providerID: nil,
            modelRevision: nil,
            segments: segments
        )
    }

    static func normalize(_ samples: [TimedTextSample]) throws -> [TranscriptSegment] {
        let segments = samples.compactMap { sample -> TranscriptSegment? in
            guard sample.startMs >= 0, sample.endMs > sample.startMs else { return nil }
            let text = SubtitleParser.normalizedText(sample.payload)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(startMs: sample.startMs, endMs: sample.endMs, text: text)
        }
        guard !segments.isEmpty else { throw EmbeddedSubtitleExtractionError.noContent }
        return segments
    }

    private static func subtitleTracks(in asset: AVAsset) async throws -> [AVAssetTrack] {
        let textTracks = try await asset.loadTracks(withMediaType: .text)
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        return textTracks + subtitleTracks
    }

    private static func canReadMetadata(for track: AVAssetTrack, asset: AVAsset) async throws -> Bool {
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.contains(where: isSupportedTextFormat) else { return false }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        return reader.canAdd(output)
    }

    private static func isSupportedTextFormat(_ description: CMFormatDescription) -> Bool {
        let mediaType = CMFormatDescriptionGetMediaType(description)
        guard mediaType == kCMMediaType_Text || mediaType == kCMMediaType_Subtitle else { return false }
        switch CMFormatDescriptionGetMediaSubType(description) {
        case 0x7478_3367, 0x7465_7874, 0x7776_7474: // tx3g, text, wvtt
            return true
        default:
            return false
        }
    }

    private static func readSamples(from track: AVAssetTrack, asset: AVAsset) throws -> [TimedTextSample] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw EmbeddedSubtitleExtractionError.unavailable("The selected subtitle track cannot be read as timed text.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw EmbeddedSubtitleExtractionError.unavailable(reader.error?.localizedDescription ?? "AVFoundation could not start reading this subtitle track.")
        }

        var samples: [TimedTextSample] = []
        while let sample = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            guard start.isValid, duration.isValid,
                  start.seconds.isFinite, duration.seconds.isFinite,
                  start.seconds >= 0, duration.seconds > 0 else {
                continue
            }
            let payload = try payloadString(from: sample)
            let startMs = Int64((start.seconds * 1_000).rounded())
            let endMs = Int64(((start.seconds + duration.seconds) * 1_000).rounded())
            samples.append(TimedTextSample(startMs: startMs, endMs: endMs, payload: payload))
        }
        if reader.status == .failed {
            throw EmbeddedSubtitleExtractionError.unavailable(reader.error?.localizedDescription ?? "AVFoundation could not read this subtitle track.")
        }
        return samples
    }

    private static func payloadString(from sample: CMSampleBuffer) throws -> String {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else {
            throw EmbeddedSubtitleExtractionError.unreadablePayload
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return "" }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard result == kCMBlockBufferNoErr else {
            throw EmbeddedSubtitleExtractionError.unreadablePayload
        }
        if data.count >= 3, data[0] == 0 {
            let textLength = Int(data[1])
            let textEnd = 2 + textLength
            if textLength > 0, textEnd <= data.count,
               let value = String(data: data[2..<textEnd], encoding: .utf8) {
                return value
            }
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw EmbeddedSubtitleExtractionError.unreadablePayload
        }
        return value
    }
}

enum MediaFingerprint {
    static func forLocalMedia(_ url: URL) -> String {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues = try? canonicalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = resourceValues?.fileSize ?? 0
        let modificationTime = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let identity = "local-v1|\(canonicalURL.path)|\(size)|\(modificationTime)"
        return SubtitleParser.sourceFingerprint(data: Data(identity.utf8), trackIdentifier: "media")
    }
}
