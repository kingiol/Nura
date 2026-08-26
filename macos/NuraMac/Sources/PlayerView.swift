import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @StateObject private var model = PlayerViewModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                RenderSurfaceView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)

                if model.snapshot.item == nil {
                    EmptyPlayerView(isDropTargeted: isDropTargeted)
                }
            }
            controls
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: model.openPanel) {
                Label("Open", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .help("Open media")
            .buttonStyle(.borderless)

            Text(model.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(model.hasError ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(value: $model.seekPosition, in: 0...model.duration, onEditingChanged: model.seekEditingChanged)
                .controlSize(.small)

            HStack(spacing: 10) {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .help(model.isPlaying ? "Pause" : "Play")
                .buttonStyle(.borderless)

                Text(timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)

                Spacer(minLength: 8)

                TrackMenu(title: "Audio", tracks: model.snapshot.audioTracks, selection: model.selectedAudioTrack, includeOff: false, onSelect: model.selectAudioTrack)
                TrackMenu(title: "Subtitles", tracks: model.snapshot.subtitleTracks, selection: model.selectedSubtitleTrack, includeOff: true, onSelect: model.selectSubtitleTrack)

                Button(action: model.toggleMute) {
                    Image(systemName: model.snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help(model.snapshot.muted ? "Unmute" : "Mute")
                .buttonStyle(.borderless)

                Slider(value: Binding(get: { model.volume }, set: { value in model.setVolume(value) }), in: 0...100)
                    .frame(width: 110)
                    .controlSize(.small)

                Button(action: model.toggleFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Enter fullscreen")
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var timeText: String {
        "\(format(model.isSeeking ? model.seekPosition : model.snapshot.positionSeconds)) / \(format(model.snapshot.durationSeconds ?? 0))"
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let itemURL = item as? URL {
                url = itemURL
            } else if let itemURL = item as? NSURL {
                url = itemURL as URL
            }
            guard let url else { return }
            DispatchQueue.main.async {
                model.open(url)
            }
        }
        return true
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let remaining = total % 60
        return hours > 0 ? String(format: "%02d:%02d:%02d", hours, minutes, remaining) : String(format: "%02d:%02d", minutes, remaining)
    }
}

private struct EmptyPlayerView: View {
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "film")
                .font(.system(size: 34))
                .foregroundStyle(isDropTargeted ? .blue : .secondary)
            Text(isDropTargeted ? "Release to open" : "Open a media file to begin")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }
}

private struct TrackMenu: View {
    let title: String
    let tracks: [Track]
    let selection: Int64
    let includeOff: Bool
    let onSelect: (Int64) -> Void

    var body: some View {
        Menu {
            if includeOff {
                Button("Off") { onSelect(-1) }
            }
            if tracks.isEmpty {
                Text("Unavailable")
            } else {
                ForEach(tracks, id: \.id) { track in
                    Button {
                        onSelect(track.id)
                    } label: {
                        HStack {
                            Text(trackLabel(track))
                            if track.id == selection { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            Label(title, systemImage: title == "Audio" ? "waveform" : "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func trackLabel(_ track: Track) -> String {
        let label = track.title ?? track.language ?? "Track \(track.id)"
        return track.external ? "\(label) (external)" : label
    }
}
