import AppKit
import SwiftUI

/// A single on-screen message shown while the user controls playback.
enum OSDMessage: Equatable {
    case playback(Bool)
    case seekRelative(Double, Double, Double?, Double?)
    case seek(to: Double, duration: Double?)
    case frameStep(Bool)
    case speed(Double)
    case volume(Double)
    case muted(Bool)
    case previous
    case next
    case playing(String)
    case loop(Bool, Bool)
    case shuffle(Bool)
    case abLoop(String, Double?, Double?)
    case stopped
    case track(kind: String, title: String)
    case subtitles(Bool)
    case subtitleDelay(Double)
    case subtitleScale(Double)
    case subtitlePosition(Double)
    case audioDelay(Double)
    case audioDevice(String)
    case aspect(String)
    case rotate(Int)
    case flip(Bool)
    case open(String)
    case playlistAdded(Int)
    case playlistCleared
    case playlistSorted
    case playlistShuffled
    case historyCleared
    case screenshot(String)
    case windowOnTop(Bool)
    case fitWindow
    case searchingSubtitles
    case subtitlesFound(Int)
    case subtitleDownloaded(String)
    case transcriptImport(String)
    case transcriptExtracting
    case transcriptExtracted
    case transcriptAnalysis(String)
    case transcriptReady
    case transcriptCancelled
    case noteSaved
    case noteDeleted
    case noteRestored
    case error(String)

    var title: String {
        switch self {
        case .playback(let playing):
            return playing ? L10n.text("Play") : L10n.text("Pause")
        case .seekRelative(let seconds, _, _, _):
            let value = seconds.rounded()
            return seconds > 0
                ? L10n.format("Seek Forward %d Seconds", Int(value))
                : L10n.format("Seek Backward %d Seconds", Int(abs(value)))
        case .seek:
            return L10n.text("Seek")
        case .frameStep(let backwards):
            return backwards ? L10n.text("Previous Frame") : L10n.text("Next Frame")
        case .speed(let value):
            return L10n.format("Speed: %@x", Self.formatDecimal(value))
        case .volume(let value):
            return L10n.format("Volume: %@", Self.formatDecimal(value))
        case .muted(let muted):
            return muted ? L10n.text("Muted") : L10n.text("Unmuted")
        case .previous:
            return L10n.text("Previous")
        case .next:
            return L10n.text("Next")
        case .playing(let title):
            return L10n.format("Playing: %@", title)
        case .loop(let current, let playlist):
            if current { return L10n.text("Loop Current Item: On") }
            if playlist { return L10n.text("Loop Playlist: On") }
            return L10n.text("Loop: Off")
        case .shuffle(let enabled):
            return enabled ? L10n.text("Shuffle: On") : L10n.text("Shuffle: Off")
        case .abLoop(let label, _, _):
            return L10n.format("A-B Loop: %@", label)
        case .stopped:
            return L10n.text("Stopped")
        case .track(_, let title):
            return title
        case .subtitles(let visible):
            return visible ? L10n.text("Subtitles: Visible") : L10n.text("Subtitles: Hidden")
        case .subtitleDelay(let value):
            return L10n.format("Subtitle Delay: %@s", Self.formatSignedSeconds(value))
        case .subtitleScale(let value):
            return L10n.format("Subtitle Scale: %@x", Self.formatDecimal(value))
        case .subtitlePosition(let value):
            return L10n.format("Subtitle Position: %@%%", Self.formatDecimal(value))
        case .audioDelay(let value):
            return L10n.format("Audio Delay: %@s", Self.formatSignedSeconds(value))
        case .audioDevice(let name):
            return L10n.format("Audio Output: %@", name)
        case .aspect(let value):
            return value == "no" || value == "Auto" ? L10n.text("Aspect: Default") : L10n.format("Aspect: %@", value)
        case .rotate(let degrees):
            return L10n.format("Rotate: %d°", degrees)
        case .flip(let flipped):
            return flipped ? L10n.text("Flip: On") : L10n.text("Flip: Off")
        case .open(let title):
            return L10n.format("Opening: %@", title)
        case .playlistAdded(let count):
            return L10n.format("Added %d Files to Playlist", count)
        case .playlistCleared:
            return L10n.text("Playlist Cleared")
        case .playlistSorted:
            return L10n.text("Playlist Sorted")
        case .playlistShuffled:
            return L10n.text("Playlist Shuffled")
        case .historyCleared:
            return L10n.text("Playback History Cleared")
        case .screenshot(let detail):
            return L10n.format("Screenshot %@", detail)
        case .windowOnTop(let enabled):
            return enabled ? L10n.text("Window on Top: On") : L10n.text("Window on Top: Off")
        case .fitWindow:
            return L10n.text("Fit to Video")
        case .searchingSubtitles:
            return L10n.text("Searching Subtitles…")
        case .subtitlesFound(let count):
            return count == 0
                ? L10n.text("No Subtitles Found")
                : L10n.format("Found %d Subtitles", count)
        case .subtitleDownloaded(let name):
            return L10n.format("Subtitle Downloaded: %@", name)
        case .transcriptImport(let source):
            return L10n.format("Transcript Imported: %@", source)
        case .transcriptExtracting:
            return L10n.text("Extracting Subtitles…")
        case .transcriptExtracted:
            return L10n.text("Transcript Extracted")
        case .transcriptAnalysis(let phase):
            return L10n.format("Audio Analysis: %@", phase)
        case .transcriptReady:
            return L10n.text("Transcript Ready")
        case .transcriptCancelled:
            return L10n.text("Analysis Cancelled")
        case .noteSaved:
            return L10n.text("Note Saved")
        case .noteDeleted:
            return L10n.text("Note Deleted")
        case .noteRestored:
            return L10n.text("Note Restored")
        case .error(let message):
            return message
        }
    }

    var symbol: String? {
        switch self {
        case .playback(let playing): return playing ? "play.fill" : "pause.fill"
        case .seekRelative(let seconds, _, _, _): return seconds > 0 ? "forward.fill" : "backward.fill"
        case .seek: return "arrow.left.and.right"
        case .frameStep(let backwards): return backwards ? "backward.frame.fill" : "forward.frame.fill"
        case .speed: return "speedometer"
        case .volume(let value): return value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .muted(let muted): return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .previous: return "backward.end.fill"
        case .next: return "forward.end.fill"
        case .playing: return "play.fill"
        case .loop(let current, _): return current ? "repeat.1" : "repeat"
        case .shuffle: return "shuffle"
        case .abLoop: return "a.circle"
        case .stopped: return "stop.fill"
        case .track(let kind, _):
            switch kind {
            case "video": return "rectangle.on.rectangle"
            case "audio": return "waveform"
            default: return "captions.bubble"
            }
        case .subtitles(let visible): return visible ? "captions.bubble.fill" : "captions.bubble"
        case .subtitleDelay, .audioDelay: return "clock.arrow.circlepath"
        case .subtitleScale, .subtitlePosition: return "textformat.size"
        case .audioDevice: return "hifispeaker"
        case .aspect: return "rectangle.ratio.4.to.3"
        case .rotate: return "rotate.right"
        case .flip: return "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .open: return "arrow.down.circle"
        case .playlistAdded: return "plus"
        case .playlistCleared: return "trash"
        case .playlistSorted: return "arrow.up.arrow.down"
        case .playlistShuffled: return "shuffle"
        case .historyCleared: return "clock.arrow.circlepath"
        case .screenshot: return "camera"
        case .windowOnTop: return "pin"
        case .fitWindow: return "arrow.up.left.and.arrow.down.right"
        case .searchingSubtitles: return "magnifyingglass"
        case .subtitlesFound(let count): return count == 0 ? "exclamationmark" : "checkmark.circle"
        case .subtitleDownloaded: return "arrow.down.circle"
        case .transcriptImport, .transcriptExtracted, .transcriptReady: return "doc.text"
        case .transcriptExtracting: return "doc.text.magnifyingglass"
        case .transcriptAnalysis: return "waveform.badge.magnifyingglass"
        case .transcriptCancelled: return "xmark.circle"
        case .noteSaved: return "note.text"
        case .noteDeleted: return "trash"
        case .noteRestored: return "arrow.uturn.backward"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var detail: String? {
        switch self {
        case .seekRelative(_, let target, let duration, _):
            guard let duration else { return nil }
            return L10n.format("%@ / %@", Self.formatTime(target), Self.formatTime(duration))
        case .seek(let position, let duration):
            guard let duration else { return nil }
            return L10n.format("%@ / %@", Self.formatTime(position), Self.formatTime(duration))
        case .abLoop(_, let start, let end):
            if let start, let end {
                return L10n.format("%@ / %@", Self.formatTime(start), Self.formatTime(end))
            }
            if let start {
                return L10n.format("Start %@", Self.formatTime(start))
            }
            return nil
        default:
            return nil
        }
    }

    var progress: Double? {
        switch self {
        case .seekRelative(_, let target, let duration, _):
            return duration.flatMap { progress(target, duration: $0) }
        case .seek(let position, let duration):
            return duration.flatMap { progress(position, duration: $0) }
        case .volume(let value):
            return value / 100
        default:
            return nil
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    private func progress(_ position: Double, duration: Double) -> Double? {
        guard duration.isFinite, duration > 0, position.isFinite else { return nil }
        return min(max(position / duration, 0), 1)
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
    }

    private static func formatDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func formatSignedSeconds(_ value: Double) -> String {
        if value == 0 { return "0" }
        return value > 0 ? L10n.format("+%@", formatDecimal(value)) : formatDecimal(value)
    }
}

struct OSDView: View {
    let message: OSDMessage

    var body: some View {
        HStack(spacing: 10) {
            if let symbol = message.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(message.isError ? Color.red : Color.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(message.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(message.isError ? Color.red : Color.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = message.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                if let progress = message.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                        .frame(width: 150)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(message.isError ? Color.red.opacity(0.55) : Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.osd")
        .accessibilityLabel(message.title)
    }
}
