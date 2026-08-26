import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @StateObject private var model = PlayerViewModel()
    @State private var isDropTargeted = false
    @State private var controlsVisible = true
    @State private var sidebar: SidebarTab?
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var pipPanel: NSPanel?

    var body: some View {
        ZStack {
            RenderSurfaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
                .onTapGesture { revealControls() }

            if model.snapshot.item == nil {
                EmptyPlayerView(isDropTargeted: isDropTargeted)
            }

            VStack(spacing: 0) {
                titlebar
                Spacer()
                if controlsVisible {
                    controlBar.transition(.opacity)
                }
            }

            if let sidebar {
                SidebarView(
                    tab: sidebar,
                    snapshot: model.snapshot,
                    onClose: { self.sidebar = nil },
                    onPlayIndex: model.playPlaylistIndex,
                    onSeek: { position in model.seekPosition = position; model.seekEditingChanged(false) },
                    onSelectVideoTrack: model.selectVideoTrack
                )
                    .frame(width: 300)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Color.black)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .animation(.easeOut(duration: 0.18), value: sidebar)
        .onHover { hovering in
            if hovering { revealControls() }
        }
        .onAppear { revealControls() }
        .onDisappear {
            hideControlsTask?.cancel()
            pipPanel?.close()
            pipPanel = nil
        }
    }

    private var titlebar: some View {
        HStack(spacing: 12) {
            Button(action: model.openPanel) { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Open media")

            Button(action: openURLPanel) { Image(systemName: "link") }
                .buttonStyle(.borderless)
                .help("Open URL")

            Text(model.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(model.hasError ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                sidebar = sidebar == .playlist ? nil : .playlist
                revealControls()
            } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless)
                .help("Show sidebar")

            Button(action: model.toggleAlwaysOnTop) {
                Image(systemName: model.alwaysOnTop ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(model.alwaysOnTop ? "Release window" : "Keep window on top")

            Button(action: togglePiP) {
                Image(systemName: "pip")
            }
            .buttonStyle(.borderless)
            .help("Picture in Picture")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            Slider(value: $model.seekPosition, in: 0...model.duration, onEditingChanged: { editing in
                model.seekEditingChanged(editing)
            })
                .controlSize(.small)

            HStack(spacing: 12) {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(model.isPlaying ? "Pause" : "Play")

                Button(action: model.previous) {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Previous")

                Button(action: model.next) {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Next")

                Text(timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)

                Spacer(minLength: 8)

                TrackMenu(title: "Audio", tracks: model.snapshot.audioTracks, selection: model.selectedAudioTrack, includeOff: false, onSelect: model.selectAudioTrack)
                TrackMenu(title: "Subtitles", tracks: model.snapshot.subtitleTracks, selection: model.selectedSubtitleTrack, includeOff: true, onSelect: model.selectSubtitleTrack)
                SpeedMenu(speed: model.snapshot.speed, onSelect: model.setSpeed)

                Button(action: model.toggleLoop) {
                    Image(systemName: model.loopEnabled ? "repeat.1" : "repeat")
                }
                .buttonStyle(.borderless)
                .help(model.loopEnabled ? "Disable loop" : "Loop current item")

                Button(action: model.toggleMute) {
                    Image(systemName: model.snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .help(model.snapshot.muted ? "Unmute" : "Mute")

                Slider(value: Binding(get: { model.volume }, set: { value in
                    model.setVolume(value)
                }), in: 0...100)
                    .frame(width: 110)
                    .controlSize(.small)

                Button {
                    sidebar = sidebar == .playlist ? nil : .playlist
                    revealControls()
                } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
                    .help("Show playlist")

                Button(action: model.toggleFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Enter fullscreen")

                Button(action: model.screenshot) {
                    Image(systemName: "camera")
                }
                .buttonStyle(.borderless)
                .help("Screenshot")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial.opacity(0.82))
    }

    private var timeText: String {
        "\(format(model.isSeeking ? model.seekPosition : model.snapshot.positionSeconds)) / \(format(model.snapshot.durationSeconds ?? 0))"
    }

    private func revealControls() {
        controlsVisible = true
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func togglePiP() {
        if let pipPanel, pipPanel.isVisible {
            pipPanel.orderOut(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Nura PiP"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MiniPlayerView(model: model))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        pipPanel = panel
    }

    private func openURLPanel() {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Enter a public media URL, YouTube link, or Bilibili link."
        let field = NSTextField(string: "")
        field.placeholderString = "https://..."
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.openURL(field.stringValue)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            loadDroppedFile(from: provider)
        } else {
            loadDroppedText(from: provider)
        }
        revealControls()
        return true
    }

    private func loadDroppedFile(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = droppedFileURL(from: item)
            guard let url else { return }
            DispatchQueue.main.async { model.open(url) }
        }
    }

    private func loadDroppedText(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let text = (item as? String) ?? (item as? NSString).map(String.init)
            guard let text else { return }
            DispatchQueue.main.async { model.openURL(text) }
        }
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

private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }
    if let url = item as? URL {
        return url
    }
    if let url = item as? NSURL {
        return url as URL
    }
    return nil
}

private struct MiniPlayerView: View {
    @ObservedObject var model: PlayerViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            RenderSurfaceView(model: model)
                .background(Color.black)
            HStack(spacing: 10) {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                Text(model.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.ultraThinMaterial.opacity(0.86))
        }
        .frame(minWidth: 300, minHeight: 180)
    }
}

private enum SidebarTab: String, CaseIterable, Identifiable {
    case playlist = "Playlist"
    case chapters = "Chapters"
    case video = "Video"
    case audio = "Audio"
    case subtitles = "Subtitles"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .playlist: return "music.note.list"
        case .chapters: return "list.and.film"
        case .video: return "slider.horizontal.3"
        case .audio: return "waveform"
        case .subtitles: return "captions.bubble"
        }
    }
}

private struct SidebarView: View {
    let tab: SidebarTab
    let snapshot: PlaybackSnapshot
    let onClose: () -> Void
    let onPlayIndex: (Int) -> Void
    let onSeek: (Double) -> Void
    let onSelectVideoTrack: (Int64) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tab.rawValue, systemImage: tab.symbol)
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close sidebar")
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .playlist:
                        if snapshot.playlist.isEmpty {
                            Text("No items in playlist").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(snapshot.playlist.enumerated()), id: \.offset) { index, item in
                                Button {
                                    onPlayIndex(index)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: index == snapshot.playlistIndex ? "play.fill" : "film")
                                            .frame(width: 16)
                                        Text(item.title)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    case .chapters:
                        if snapshot.chapters.isEmpty {
                            Text("No chapters").foregroundStyle(.secondary)
                        } else {
                            ForEach(snapshot.chapters) { chapter in
                                Button {
                                    onSeek(chapter.startSeconds)
                                } label: {
                                    HStack {
                                        Text(chapter.title).lineLimit(1)
                                        Spacer()
                                        Text(format(chapter.startSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    case .video:
                        trackList(snapshot.videoTracks, onSelect: onSelectVideoTrack)
                    case .audio:
                        trackList(snapshot.audioTracks)
                    case .subtitles:
                        trackList(snapshot.subtitleTracks)
                    }
                }
                .padding(14)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) { Divider() }
    }

    @ViewBuilder
    private func trackList(_ tracks: [Track], onSelect: ((Int64) -> Void)? = nil) -> some View {
        if tracks.isEmpty {
            Text("Unavailable").foregroundStyle(.secondary)
        } else {
            ForEach(tracks, id: \.id) { track in
                if let onSelect {
                    Button { onSelect(track.id) } label: {
                        Label(track.title ?? track.language ?? "Track \(track.id)", systemImage: track.selected ? "checkmark.circle.fill" : "circle")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Label(track.title ?? track.language ?? "Track \(track.id)", systemImage: track.selected ? "checkmark.circle.fill" : "circle")
                        .lineLimit(1)
                }
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
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
            if includeOff { Button("Off") { onSelect(-1) } }
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

private struct SpeedMenu: View {
    let speed: Double
    let onSelect: (Double) -> Void

    private let values = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    HStack {
                        Text(label(for: value))
                        if abs(speed - value) < 0.001 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(label(for: speed), systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func label(for value: Double) -> String {
        value == 1.0 ? "1x" : "\(value)x"
    }
}
