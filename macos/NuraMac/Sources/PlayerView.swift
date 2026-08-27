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
                .contextMenu {
                    Button(model.isPlaying ? "Pause" : "Play", action: model.togglePlayback)
                    Divider()
                    Button("Previous", action: model.previous)
                    Button("Next", action: model.next)
                    Button("Back 5 Seconds") { model.seekRelative(-5) }
                    Button("Forward 5 Seconds") { model.seekRelative(5) }
                    Button("Back 30 Seconds") { model.seekRelative(-30) }
                    Button("Forward 30 Seconds") { model.seekRelative(30) }
                    Button("Next Frame", action: model.frameStep)
                    Button(model.loopEnabled ? "Disable Loop" : "Loop Current Item", action: model.toggleLoop)
                    Button(model.snapshot.playlistLoop ? "Disable Playlist Loop" : "Loop Playlist", action: model.togglePlaylistLoop)
                    Button("Shuffle Playlist", action: model.shufflePlaylist)
                    Button(model.abLoopLabel, action: model.advanceABLoop)
                    Divider()
                    Button("Load External Subtitle", action: model.openExternalSubtitle)
                    Button("Take Screenshot", action: model.screenshot)
                    Button("Copy Screenshot", action: model.copyScreenshot)
                    Button("Choose Screenshot Folder", action: model.chooseScreenshotDirectory)
                    Button("Toggle Fullscreen", action: model.toggleFullscreen)
                }

            if model.snapshot.item == nil {
                EmptyPlayerView(isDropTargeted: isDropTargeted)
            }

            VStack(spacing: 0) {
                if controlsVisible {
                    titlebar
                    Spacer()
                    controlBar.transition(.opacity)
                } else {
                    Spacer()
                }
            }

            if let sidebar {
                SidebarView(
                    tab: sidebar,
                    snapshot: model.snapshot,
                    onClose: { self.sidebar = nil },
                    onPlayIndex: model.playPlaylistIndex,
                    onRemovePlaylistIndex: model.removePlaylistIndex,
                    onMovePlaylistItem: model.movePlaylistItem,
                    onSeek: { position in model.seekPosition = position; model.seekEditingChanged(false) },
                    onSelectVideoTrack: model.selectVideoTrack,
                    onAddExternalSubtitle: model.openExternalSubtitle
                )
                    .frame(width: 300)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
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
                .keyboardShortcut("o", modifiers: [.command])

            Button(action: openURLPanel) { Image(systemName: "link") }
                .buttonStyle(.borderless)
                .help("Open URL")
                .keyboardShortcut("l", modifiers: [.command])

            Menu {
                if model.snapshot.recentItems.isEmpty {
                    Text("No recent media")
                } else {
                    ForEach(Array(model.snapshot.recentItems.enumerated()), id: \.offset) { _, item in
                        Button(item.title) { model.openRecent(item) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .help("Recent media")

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
        .padding(.leading, 82)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 8)
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
                .keyboardShortcut(.space, modifiers: [])

                Button(action: model.previous) {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Previous")

                Button { model.seekRelative(-5) } label: {
                    Image(systemName: "gobackward.5")
                }
                .buttonStyle(.borderless)
                .help("Back 5 seconds")
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button { model.seekRelative(5) } label: {
                    Image(systemName: "goforward.5")
                }
                .buttonStyle(.borderless)
                .help("Forward 5 seconds")
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button(action: model.next) {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Next")

                Button(action: model.frameStep) {
                    Image(systemName: "forward.frame")
                }
                .buttonStyle(.borderless)
                .help("Next frame")
                .keyboardShortcut(".", modifiers: [])

                Button { model.seekRelative(-30) } label: { EmptyView() }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                    .frame(width: 0, height: 0)
                    .opacity(0)

                Button { model.seekRelative(30) } label: { EmptyView() }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
                    .frame(width: 0, height: 0)
                    .opacity(0)

                Text(timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)

                Spacer(minLength: 8)

                AudioMenu(
                    tracks: model.snapshot.audioTracks,
                    selectedTrack: model.selectedAudioTrack,
                    devices: model.snapshot.audioDevices,
                    delay: model.snapshot.audioDelaySeconds,
                    onSelectTrack: model.selectAudioTrack,
                    onSelectDevice: model.setAudioDevice,
                    onSetDelay: model.setAudioDelay
                )
                SubtitleMenu(
                    tracks: model.snapshot.subtitleTracks,
                    selectedTrack: model.selectedSubtitleTrack,
                    visible: model.snapshot.subtitlesVisible,
                    delay: model.snapshot.subtitleDelaySeconds,
                    scale: model.snapshot.subtitleScale,
                    position: model.snapshot.subtitlePosition,
                    onSelectTrack: model.selectSubtitleTrack,
                    onSetVisible: model.setSubtitlesVisible,
                    onSetDelay: model.setSubtitleDelay,
                    onSetScale: model.setSubtitleScale,
                    onSetPosition: model.setSubtitlePosition
                )
                VideoMenu(
                    aspect: model.snapshot.videoAspect,
                    rotation: model.snapshot.videoRotationDegrees,
                    flipped: model.snapshot.videoFlipped,
                    onSetAspect: model.setVideoAspect,
                    onFitToVideo: model.fitWindowToVideo,
                    onRotate: model.rotateVideo,
                    onToggleFlip: model.toggleVideoFlip
                )
                SpeedMenu(speed: model.snapshot.speed, onSelect: model.setSpeed)

                Button(action: model.toggleLoop) {
                    Image(systemName: model.loopEnabled ? "repeat.1" : "repeat")
                }
                .buttonStyle(.borderless)
                .help(model.loopEnabled ? "Disable loop" : "Loop current item")

                Button(action: model.togglePlaylistLoop) {
                    Image(systemName: model.snapshot.playlistLoop ? "repeat.circle.fill" : "repeat.circle")
                }
                .buttonStyle(.borderless)
                .help(model.snapshot.playlistLoop ? "Disable playlist loop" : "Loop playlist")

                Button(action: model.shufflePlaylist) {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.borderless)
                .help("Shuffle playlist")

                Button(action: model.advanceABLoop) {
                    Image(systemName: model.abLoopSymbol)
                }
                .buttonStyle(.borderless)
                .help(model.abLoopLabel)

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
                .keyboardShortcut("f", modifiers: [.command])

                Button(action: model.openExternalSubtitle) {
                    Image(systemName: "text.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Load external subtitle")

                Button(action: model.screenshot) {
                    Image(systemName: "camera")
                }
                .buttonStyle(.borderless)
                .help("Screenshot")
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
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
    let onRemovePlaylistIndex: (Int) -> Void
    let onMovePlaylistItem: (Int, Int) -> Void
    let onSeek: (Double) -> Void
    let onSelectVideoTrack: (Int64) -> Void
    let onAddExternalSubtitle: () -> Void

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
                                HStack(spacing: 6) {
                                    Button { onPlayIndex(index) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: index == snapshot.playlistIndex ? "play.fill" : "film")
                                                .frame(width: 16)
                                            Text(item.title).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    Menu {
                                        if index > 0 {
                                            Button("Move Up") { onMovePlaylistItem(index, index - 1) }
                                        }
                                        if index + 1 < snapshot.playlist.count {
                                            Button("Move Down") { onMovePlaylistItem(index, index + 1) }
                                        }
                                        Divider()
                                        Button("Remove", role: .destructive) { onRemovePlaylistIndex(index) }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                }
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
                        Button("Load External Subtitle", action: onAddExternalSubtitle)
                            .buttonStyle(.borderless)
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

private struct AudioMenu: View {
    let tracks: [Track]
    let selectedTrack: Int64
    let devices: [AudioDevice]
    let delay: Double
    let onSelectTrack: (Int64) -> Void
    let onSelectDevice: (String) -> Void
    let onSetDelay: (Double) -> Void

    var body: some View {
        Menu {
            Section("Track") {
                if tracks.isEmpty {
                    Text("Unavailable")
                } else {
                    ForEach(tracks, id: \.id) { track in
                        Button { onSelectTrack(track.id) } label: {
                            checkedLabel(track.title ?? track.language ?? "Track \(track.id)", selected: track.id == selectedTrack)
                        }
                    }
                }
            }
            Section("Output") {
                if devices.isEmpty {
                    Text("Default Output")
                } else {
                    ForEach(devices) { device in
                        Button { onSelectDevice(device.id) } label: {
                            checkedLabel(device.name, selected: device.selected)
                        }
                    }
                }
            }
            Section("Delay") {
                delayButtons(current: delay, onSelect: onSetDelay, prefix: "Audio")
            }
        } label: {
            Label("Audio", systemImage: "waveform")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct SubtitleMenu: View {
    let tracks: [Track]
    let selectedTrack: Int64
    let visible: Bool
    let delay: Double
    let scale: Double
    let position: Double
    let onSelectTrack: (Int64) -> Void
    let onSetVisible: (Bool) -> Void
    let onSetDelay: (Double) -> Void
    let onSetScale: (Double) -> Void
    let onSetPosition: (Double) -> Void

    var body: some View {
        Menu {
            Button(visible ? "Hide Subtitles" : "Show Subtitles") { onSetVisible(!visible) }
            Section("Track") {
                Button { onSelectTrack(-1) } label: { checkedLabel("Off", selected: selectedTrack < 0) }
                ForEach(tracks, id: \.id) { track in
                    Button { onSelectTrack(track.id) } label: {
                        checkedLabel(track.title ?? track.language ?? "Track \(track.id)", selected: track.id == selectedTrack)
                    }
                }
            }
            Section("Delay") {
                delayButtons(current: delay, onSelect: onSetDelay, prefix: "Subtitle")
            }
            Section("Size") {
                settingButtons(values: [0.8, 1.0, 1.2, 1.4, 1.6], current: scale, onSelect: onSetScale, label: { "\($0)x" })
            }
            Section("Position") {
                settingButtons(values: [70.0, 80.0, 90.0, 100.0], current: position, onSelect: onSetPosition, label: { "\(Int($0))%" })
            }
        } label: {
            Label("Subtitles", systemImage: "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct VideoMenu: View {
    let aspect: String
    let rotation: Int
    let flipped: Bool
    let onSetAspect: (String) -> Void
    let onFitToVideo: () -> Void
    let onRotate: () -> Void
    let onToggleFlip: () -> Void

    private let aspects = ["Auto", "16:9", "4:3", "1.85:1", "2.35:1"]

    var body: some View {
        Menu {
            Section("Aspect Ratio") {
                ForEach(aspects, id: \.self) { value in
                    Button { onSetAspect(value) } label: { checkedLabel(value, selected: value == aspect) }
                }
            }
            Button("Fit to Video", action: onFitToVideo)
            Button("Rotate 90°") { onRotate() }
            Button(flipped ? "Unflip Video" : "Flip Video") { onToggleFlip() }
            Text("Rotation: \(rotation)°")
        } label: {
            Label("Video", systemImage: "rectangle.on.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

@MainActor
@ViewBuilder
private func checkedLabel(_ title: String, selected: Bool) -> some View {
    HStack {
        Text(title)
        if selected { Image(systemName: "checkmark") }
    }
}

@MainActor
@ViewBuilder
private func delayButtons(current: Double, onSelect: @escaping (Double) -> Void, prefix: String) -> some View {
    settingButtons(values: [-1.0, -0.5, 0.0, 0.5, 1.0], current: current, onSelect: onSelect, label: { value in
        value == 0 ? "\(prefix) 0s" : value > 0 ? "\(prefix) +\(value)s" : "\(prefix) \(value)s"
    })
}

@MainActor
@ViewBuilder
private func settingButtons(values: [Double], current: Double, onSelect: @escaping (Double) -> Void, label: @escaping (Double) -> String) -> some View {
    ForEach(values, id: \.self) { value in
        Button { onSelect(value) } label: { checkedLabel(label(value), selected: abs(current - value) < 0.001) }
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

private struct SubtitleDelayMenu: View {
    let delay: Double
    let onSelect: (Double) -> Void

    private let values = [-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0]

    var body: some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    HStack {
                        Text(label(for: value))
                        if abs(delay - value) < 0.001 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(label(for: delay), systemImage: "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func label(for value: Double) -> String {
        if abs(value) < 0.001 { return "Sub 0s" }
        return value > 0 ? "Sub +\(value)s" : "Sub \(value)s"
    }
}
