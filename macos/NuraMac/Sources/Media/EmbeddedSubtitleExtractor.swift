import Foundation

enum EmbeddedSubtitleExtractionError: LocalizedError, Equatable {
    case remoteMedia
    case ffprobeUnavailable
    case ffmpegUnavailable
    case probeFailed(String)
    case exportFailed(String)
    case noContent
    case unsupportedGraphicSubtitle

    var errorDescription: String? {
        switch self {
        case .remoteMedia:
            return "Embedded subtitle extraction is available for local media only."
        case .ffprobeUnavailable:
            return "FFprobe is unavailable for subtitle extraction."
        case .ffmpegUnavailable:
            return "FFmpeg is unavailable for subtitle extraction."
        case .probeFailed(let message), .exportFailed(let message):
            return message
        case .noContent:
            return "The selected subtitle track does not contain readable timed text."
        case .unsupportedGraphicSubtitle:
            return "This subtitle track is a bitmap subtitle and would require OCR."
        }
    }
}

enum EmbeddedSubtitleExtractor {
    static func discover(in url: URL) async throws -> [EmbeddedSubtitleTrack] {
        let probe = try await inspect(url: url)
        return probe.streams.map { stream in
            EmbeddedSubtitleTrack(
                identifier: String(stream.index),
                displayName: displayName(for: stream),
                kind: stream.kind,
                isSupported: stream.kind.isText
            )
        }
    }

    static func extract(from url: URL, trackIdentifier: String) async throws -> TranscriptDocument {
        guard url.isFileURL else { throw EmbeddedSubtitleExtractionError.remoteMedia }
        guard let streamIndex = Int(trackIdentifier) else {
            throw EmbeddedSubtitleExtractionError.probeFailed("The selected subtitle track is unavailable.")
        }
        let probe = try await inspect(url: url)
        guard let stream = probe.streams.first(where: { $0.index == streamIndex }) else {
            throw EmbeddedSubtitleExtractionError.probeFailed("The selected subtitle track cannot be read as timed text.")
        }
        guard stream.kind.isText else {
            throw EmbeddedSubtitleExtractionError.unsupportedGraphicSubtitle
        }

        let srt = try await exportSRT(from: url, streamIndex: streamIndex)
        let segments = try segments(fromSRT: srt)
        let normalizedPayload = segments.map { "\($0.startMs)-\($0.endMs):\($0.text)" }.joined(separator: "\n")
        let sourceFingerprint = SubtitleParser.sourceFingerprint(
            data: Data(normalizedPayload.utf8),
            trackIdentifier: "embedded:\(trackIdentifier)"
        )
        let key = AnalysisKey(
            mediaFingerprint: MediaFingerprint.forLocalMedia(url),
            sourceFingerprint: sourceFingerprint,
            analysisProfile: "embedded/ffmpeg-v1"
        )
        return TranscriptDocument(
            key: key,
            source: "embedded_subtitle",
            providerID: nil,
            modelRevision: nil,
            segments: segments
        )
    }

    static func segments(fromSRT srt: String) throws -> [TranscriptSegment] {
        try SubtitleParser.parse(srt, fileExtension: "srt")
    }

    static func selectDefaultSubtitleStream(from streams: [ProbeSubtitleStream]) -> ProbeSubtitleStream? {
        let orderedStreams = streams.sorted { $0.index < $1.index }
        return orderedStreams.first(where: { $0.disposition?.isDefault == 1 }) ?? orderedStreams.first
    }

    static func inspect(url: URL) async throws -> SubtitleProbeResponse {
        guard url.isFileURL else { throw EmbeddedSubtitleExtractionError.remoteMedia }
        guard let ffprobeURL = executableURL(named: "ffprobe") else {
            throw EmbeddedSubtitleExtractionError.ffprobeUnavailable
        }

        let result: SubtitleProcessResult
        do {
            result = try await runProcess(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-print_format", "json",
                    "-show_entries", "stream=index,codec_name,codec_type,codec_long_name,width,height,disposition:stream_tags=language,title,name",
                    "-select_streams", "s",
                    url.path,
                ]
            )
        } catch {
            throw EmbeddedSubtitleExtractionError.probeFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        guard result.status == 0 else {
            throw EmbeddedSubtitleExtractionError.probeFailed(result.errorMessage)
        }

        do {
            let response = try JSONDecoder().decode(SubtitleProbeResponse.self, from: Data(result.standardOutput.utf8))
            return response
        } catch let error as EmbeddedSubtitleExtractionError {
            throw error
        } catch {
            throw EmbeddedSubtitleExtractionError.probeFailed("FFprobe returned invalid media metadata.")
        }
    }

    static func exportSRT(from url: URL, streamIndex: Int) async throws -> String {
        guard url.isFileURL else { throw EmbeddedSubtitleExtractionError.remoteMedia }
        guard let ffmpegURL = executableURL(named: "ffmpeg") else {
            throw EmbeddedSubtitleExtractionError.ffmpegUnavailable
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NuraEmbeddedSubtitle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let srtURL = temporaryDirectory.appendingPathComponent("subtitle.srt")
        do {
            let result = try await runProcess(
                executableURL: ffmpegURL,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", url.path,
                    "-map", "0:\(streamIndex)",
                    "-vn", "-an", "-dn",
                    "-c:s", "srt",
                    "-f", "srt",
                    srtURL.path,
                ]
            )
            try Task.checkCancellation()
            guard result.status == 0 else {
                throw EmbeddedSubtitleExtractionError.exportFailed(result.errorMessage)
            }
            let data = try Data(contentsOf: srtURL)
            guard let srt = String(data: data, encoding: .utf8) else {
                throw EmbeddedSubtitleExtractionError.noContent
            }
            return srt
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    static func displayName(for stream: ProbeSubtitleStream) -> String {
        let title = stream.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let language = stream.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var components = [String]()
        if let title {
            components.append(title)
        }
        if let language {
            components.append(language)
        }
        if components.isEmpty {
            components.append("Subtitle track \(stream.index)")
        }
        components.append(stream.kind.displayLabel)
        return components.joined(separator: " | ")
    }

    static func executableURL(named name: String) -> URL? {
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

    static func runProcess(executableURL: URL, arguments: [String]) async throws -> SubtitleProcessResult {
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
                    continuation.resume(returning: SubtitleProcessResult(
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

struct SubtitleProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let errorMessage: String
}

struct SubtitleProbeResponse: Decodable, Equatable {
    let streams: [ProbeSubtitleStream]
}

struct ProbeSubtitleStream: Decodable, Equatable {
    let index: Int
    let codecName: String?
    let codecType: String?
    let codecLongName: String?
    let width: Int?
    let height: Int?
    let disposition: SubtitleProbeDisposition?
    let language: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecType = "codec_type"
        case codecLongName = "codec_long_name"
        case width
        case height
        case disposition
        case tags
        case tagLanguage = "language"
        case tagTitle = "title"
        case tagName = "name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        codecName = try container.decodeIfPresent(String.self, forKey: .codecName)
        codecType = try container.decodeIfPresent(String.self, forKey: .codecType)
        codecLongName = try container.decodeIfPresent(String.self, forKey: .codecLongName)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        disposition = try container.decodeIfPresent(SubtitleProbeDisposition.self, forKey: .disposition)
        if let tags = try container.decodeIfPresent([String: String].self, forKey: .tags) {
            language = tags["language"]
            title = tags["name"] ?? tags["title"]
        } else {
            language = nil
            title = nil
        }
    }

    var kind: EmbeddedSubtitleKind {
        guard codecType == "subtitle" else { return .unknown }
        if let codecName = codecName?.lowercased() {
            switch codecName {
            case "subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "tx3g", "text",
                 "eia_608", "eia_708", "cc_dec", "microdvd", "mpl2", "pjs", "subviewer",
                 "subviewer1", "stl", "vplayer", "jacosub", "sami", "realtext", "dvb_teletext":
                return .text
            case "hdmv_pgs_subtitle", "pgs", "dvd_subtitle", "dvdsub", "dvb_subtitle",
                 "dvbsub", "xsub", "dvd_vobsub", "vobsub":
                return .graphic
            default:
                break
            }
        }
        if let width = width, width > 0, let height = height, height > 0 {
            return .graphic
        }
        return .unknown
    }
}

enum EmbeddedSubtitleKind: Equatable {
    case text
    case graphic
    case unknown

    var isText: Bool { self == .text }
    var displayLabel: String {
        switch self {
        case .text: return "text"
        case .graphic: return "requires OCR"
        case .unknown: return "unknown"
        }
    }
}

struct SubtitleProbeDisposition: Decodable, Equatable {
    let isDefault: Int?

    enum CodingKeys: String, CodingKey {
        case isDefault = "default"
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
