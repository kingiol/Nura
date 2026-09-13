import CryptoKit
import Foundation

enum SubtitleParserError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case invalidEncoding
    case invalidTiming(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fileExtension):
            return "Only SRT and VTT subtitle files can be imported (received .\(fileExtension))."
        case .invalidEncoding:
            return "The subtitle file is not valid UTF-8 or UTF-16 text."
        case .invalidTiming(let value):
            return "The subtitle timing is invalid: \(value)"
        case .emptyContent:
            return "The subtitle file does not contain readable timed text."
        }
    }
}

enum SubtitleParser {
    static func parse(_ input: String, fileExtension: String) throws -> [TranscriptSegment] {
        let normalizedExtension = fileExtension.lowercased()
        guard ["srt", "vtt"].contains(normalizedExtension) else {
            throw SubtitleParserError.unsupportedFormat(fileExtension)
        }

        let normalizedInput = input
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else { throw SubtitleParserError.emptyContent }

        var lines = normalizedInput.components(separatedBy: "\n")
        if normalizedExtension == "vtt" {
            guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") == true else {
                throw SubtitleParserError.invalidTiming("Missing WEBVTT header")
            }
            lines.removeFirst()
        }

        let blocks = splitBlocks(lines)
        var segments: [TranscriptSegment] = []
        for block in blocks {
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }) else {
                if normalizedExtension == "vtt", isVTTMetadataBlock(block) {
                    continue
                }
                throw SubtitleParserError.invalidTiming(block.first ?? "")
            }

            let (startMs, endMs) = try parseTiming(block[timingIndex])
            let textLines = block[(timingIndex + 1)...]
            let text = normalizedText(textLines.joined(separator: " "))
            guard !text.isEmpty else { continue }
            segments.append(TranscriptSegment(startMs: startMs, endMs: endMs, text: text))
        }

        guard !segments.isEmpty else { throw SubtitleParserError.emptyContent }
        return segments
    }

    static func parse(data: Data, fileExtension: String) throws -> [TranscriptSegment] {
        let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)
        guard let content else { throw SubtitleParserError.invalidEncoding }
        return try parse(content, fileExtension: fileExtension)
    }

    static func sourceFingerprint(data: Data, trackIdentifier: String) -> String {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(trackIdentifier):\(digest)"
    }

    static func normalizedText(_ input: String) -> String {
        var value = input
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]+\}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitBlocks(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current)
        }
        return blocks
    }

    private static func isVTTMetadataBlock(_ block: [String]) -> Bool {
        guard let first = block.first?.uppercased() else { return false }
        return first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION")
    }

    private static func parseTiming(_ line: String) throws -> (Int64, Int64) {
        let components = line.components(separatedBy: "-->")
        guard components.count == 2 else { throw SubtitleParserError.invalidTiming(line) }
        let start = try milliseconds(from: components[0].trimmingCharacters(in: .whitespacesAndNewlines))
        let endToken = components[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let end = try milliseconds(from: endToken)
        guard end > start else { throw SubtitleParserError.invalidTiming(line) }
        return (start, end)
    }

    private static func milliseconds(from value: String) throws -> Int64 {
        let components = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard components.count == 2 || components.count == 3 else {
            throw SubtitleParserError.invalidTiming(value)
        }
        let secondsAndMilliseconds = components[components.count - 1].split(separator: ".", omittingEmptySubsequences: false)
        guard secondsAndMilliseconds.count == 2,
              let seconds = Int64(secondsAndMilliseconds[0]),
              seconds >= 0,
              seconds < 60,
              secondsAndMilliseconds[1].count == 3,
              let milliseconds = Int64(secondsAndMilliseconds[1]),
              milliseconds >= 0,
              milliseconds < 1_000,
              let minutes = Int64(components[components.count - 2]),
              minutes >= 0,
              (components.count == 2 || minutes < 60) else {
            throw SubtitleParserError.invalidTiming(value)
        }
        let hours: Int64
        if components.count == 3 {
            guard let parsedHours = Int64(components[0]), parsedHours >= 0 else {
                throw SubtitleParserError.invalidTiming(value)
            }
            hours = parsedHours
        } else {
            hours = 0
        }
        return (((hours * 60) + minutes) * 60 + seconds) * 1_000 + milliseconds
    }
}
