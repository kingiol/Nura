import Foundation

struct EmbeddedSubtitleTrack: Identifiable, Equatable {
    let identifier: String
    let displayName: String

    var id: String { identifier }
}

struct NoteDraft: Equatable {
    var note: InstantNote?
    var positionMs: Int64
    var mediaTitle: String
    var transcriptQuote: String?
    var body: String

    init(note: InstantNote? = nil, positionMs: Int64, mediaTitle: String, transcriptQuote: String?, body: String = "") {
        self.note = note
        self.positionMs = positionMs
        self.mediaTitle = mediaTitle
        self.transcriptQuote = transcriptQuote
        self.body = body
    }
}

enum LocalTranscriptState: Equatable {
    case unavailable
    case loading
    case transcript
    case noContent(String?)

    var message: String {
        switch self {
        case .unavailable:
            return "No transcript available"
        case .loading:
            return "Loading local transcript…"
        case .transcript:
            return "Transcript saved locally"
        case .noContent:
            return "No searchable speech or subtitles found"
        }
    }
}

enum CloudAnalysisProgress: Equatable {
    case idle
    case processing(completedChunks: Int, totalChunks: Int)
    case failed(String)
    case cancelled

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .processing(let completedChunks, let totalChunks):
            return "Analyzing audio \(completedChunks) of \(totalChunks)…"
        case .failed(let message):
            return message
        case .cancelled:
            return "Audio analysis was cancelled."
        }
    }
}
