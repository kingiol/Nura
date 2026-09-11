import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @Bindable var model: PlayerViewModel
    private let keepControlsVisible: Bool
    private let onOpenInNewWindow: (MediaItem) -> Void
    private let onWindowAvailable: (NSWindow) -> Void
    @State private var isDropTargeted = false
    @State private var controlsVisible = true
    @State private var controlBarHovered = false
    @State private var sidebarHovered = false
    @State private var sidebar: SidebarTab?
    @State private var hideControlsTask: Task<Void, Never>?

    init(
        model: PlayerViewModel,
        keepControlsVisible: Bool,
        onOpenInNewWindow: @escaping (MediaItem) -> Void = { _ in },
        onWindowAvailable: @escaping (NSWindow) -> Void = { _ in }
    ) {
        self.model = model
        self.keepControlsVisible = keepControlsVisible
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onWindowAvailable = onWindowAvailable
    }

    var body: some View {
        GeometryReader { container in
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
                        Button("Picture in Picture", action: model.togglePiP)
                        Button("Toggle Fullscreen", action: model.toggleFullscreen)
                    }

                if model.isPictureInPictureActive {
                    PiPPlaceholderView()
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    if controlsVisible {
                        Spacer()
                        controlBar
                            .frame(width: controlBarWidth(in: container.size))
                            .transition(.opacity)
                    } else {
                        Spacer()
                    }
                }

                if let sidebar {
                    Group {
                        if sidebar == .settings {
                            SettingsSidebarView(
                                model: model,
                                onClose: { self.sidebar = nil },
                                onTogglePiP: togglePiP
                            )
                        } else {
                            SidebarView(
                                tab: sidebar,
                                snapshot: model.snapshot,
                                onClose: { self.sidebar = nil },
                                onPlayIndex: model.playPlaylistIndex,
                                onRemovePlaylistIndex: model.removePlaylistIndex,
                                onMovePlaylistItem: model.movePlaylistItem,
                                onSeek: { position in model.seek(to: position) },
                                onSelectVideoTrack: model.selectVideoTrack,
                                onAddExternalSubtitle: model.openExternalSubtitle,
                                onOpenInNewWindow: onOpenInNewWindow,
                                onAddFile: model.addPlaylistPanel,
                                onAddURL: model.addPlaylistURLPrompt,
                                onClearPlaylist: model.clearPlaylist,
                                onShufflePlaylist: model.shufflePlaylist,
                                onToggleLoop: model.cyclePlaylistLoopMode,
                                onSortPlaylist: model.sortPlaylist,
                                onPlayNext: model.playPlaylistItemNext,
                                loopLabel: model.playlistLoopLabel,
                                loopSymbol: model.playlistLoopSymbol
                            )
                        }
                    }
                    .onHover { hovering in
                        sidebarHovered = hovering
                        updateControlsVisibility()
                    }
                        .frame(width: sidebar == .settings ? 360 : 300)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
            .background(Color.black)
            .background(WindowButtonVisibility(isVisible: controlsVisible, onWindowAvailable: onWindowAvailable))
            .animation(.easeOut(duration: 0.18), value: controlsVisible)
            .animation(.easeOut(duration: 0.18), value: sidebar)
            .onHover { hovering in
                if hovering, !controlBarHovered, !sidebarHovered { revealControls() }
            }
            .onAppear {
                model.updateWindowGeometryIfNeeded()
                revealControls()
            }
            .onChange(of: model.isPictureInPictureActive) { _, active in
                if active {
                    revealControls()
                }
            }
            .onDisappear {
                hideControlsTask?.cancel()
                model.stopPiP()
            }
        }
    }

    private func controlBarWidth(in containerSize: CGSize) -> CGFloat {
        let outerHorizontalPadding: CGFloat = 20
        guard let aspectRatio = videoAspectRatio, containerSize.width > 0, containerSize.height > 0 else {
            return containerSize.width
        }

        let displayedVideoWidth = min(containerSize.width, containerSize.height * aspectRatio)
        return min(containerSize.width, displayedVideoWidth + outerHorizontalPadding)
    }

    private var videoAspectRatio: CGFloat? {
        guard let width = model.snapshot.videoWidth,
              let height = model.snapshot.videoHeight,
              width > 0,
              height > 0 else {
            return nil
        }

        let rotated = model.snapshot.videoRotationDegrees % 180 != 0
        let sourceWidth = CGFloat(rotated ? height : width)
        let sourceHeight = CGFloat(rotated ? width : height)

        switch model.snapshot.videoAspect {
        case "16:9": return 16 / 9
        case "4:3": return 4 / 3
        case "1.85:1": return 1.85
        case "2.35:1": return 2.35
        default: return sourceWidth / sourceHeight
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            if let title = model.snapshot.item?.title {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("player.title")
                    .accessibilityLabel(title)
                    .accessibilityValue(title)
            }

            HStack(spacing: 8) {
                Text(currentTimeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier("player.current-time")
                    .accessibilityLabel("Current time")
                    .accessibilityValue(currentTimeText)

                SeekPreviewSlider(
                    value: $model.seekPosition,
                    duration: model.duration,
                    previewImage: model.seekPreviewImage,
                    previewPosition: model.seekPreviewPosition,
                    previewVisible: model.isSeekPreviewVisible,
                    onEditingChanged: model.seekEditingChanged,
                    onPreviewPositionChanged: model.updateSeekPreview,
                    onPreviewEnded: model.hideSeekPreview
                )
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier("player.duration")
                    .accessibilityLabel("Duration")
                    .accessibilityValue(durationText)
            }

            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        model.toggleMute()
                    }
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(ControlButtonStyle())
                .help(model.isMuted ? "Unmute" : "Mute")
                .accessibilityIdentifier("player.mute-toggle")
                .accessibilityLabel("Mute")
                .accessibilityValue(model.isMuted ? "muted" : "unmuted")

                Slider(value: Binding(get: { model.isMuted ? 0 : model.volume }, set: { value in
                    model.setVolume(value)
                }), in: 0...100)
                    .frame(width: 110)
                    .controlSize(.small)
                    .animation(.easeInOut(duration: 0.22), value: model.isMuted)

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    if model.snapshot.playlist.count > 1 {
                        Button(action: model.previous) {
                            Image(systemName: "backward.end.fill")
                        }
                        .buttonStyle(ControlButtonStyle())
                        .help("Previous item")
                    }

                    SeekButton(model: model, direction: -1)

                    Button(action: { model.togglePlayback() }) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(ControlButtonStyle())
                    .help(model.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("player.playback-toggle")
                    .accessibilityLabel("Playback")
                    .accessibilityValue(model.isPlaying ? "playing" : "paused")
                    .keyboardShortcut(.space, modifiers: [])

                    SeekButton(model: model, direction: 1)

                    if model.snapshot.playlist.count > 1 {
                        Button(action: model.next) {
                            Image(systemName: "forward.end.fill")
                        }
                        .buttonStyle(ControlButtonStyle())
                        .help("Next item")
                    }

                }

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    Button(action: model.togglePiP) {
                        Image(systemName: "pip")
                    }
                    .buttonStyle(ControlButtonStyle())
                    .help("Picture in Picture")

                    Button {
                        sidebar = sidebar == .settings ? nil : .settings
                        revealControls()
                    } label: { Image(systemName: "gearshape") }
                        .buttonStyle(ControlButtonStyle())
                        .help("Settings")
                        .accessibilityIdentifier("player.settings-toggle")
                        .accessibilityLabel("Settings")
                        .accessibilityValue(sidebar == .settings ? "open" : "closed")

                    Button {
                        sidebar = sidebar == .playlist ? nil : .playlist
                        revealControls()
                    } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(ControlButtonStyle())
                        .help("Show playlist")
                        .accessibilityIdentifier("player.sidebar-toggle")
                        .accessibilityLabel("Playlist")
                        .accessibilityValue(sidebar == .playlist ? "open" : "closed")

                    Button(action: model.toggleFullscreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(ControlButtonStyle())
                    .help("Enter fullscreen")
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onHover { hovering in
            controlBarHovered = hovering
            updateControlsVisibility()
        }
    }

    private var currentTimeText: String {
        format(model.seekPosition)
    }

    private var durationText: String {
        format(model.snapshot.durationSeconds ?? 0)
    }

    private func revealControls() {
        controlsVisible = true
        hideControlsTask?.cancel()
        guard !keepControlsVisible, !model.isPictureInPictureActive, !controlBarHovered, !sidebarHovered else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            guard !controlBarHovered, !sidebarHovered else { return }
            controlsVisible = false
        }
    }

    private func updateControlsVisibility() {
        if controlBarHovered || sidebarHovered {
            revealControls()
        } else {
            scheduleControlsHide()
        }
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard !keepControlsVisible, !model.isPictureInPictureActive else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !controlBarHovered, !sidebarHovered else { return }
            controlsVisible = false
        }
    }

    private func togglePiP() {
        model.togglePiP()
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

private struct ControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .modifier(HoverBackgroundModifier())
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct HoverBackgroundModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.14 : 0))
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}

private struct SeekButton: View {
    let model: PlayerViewModel
    let direction: Double

    @State private var holdTask: Task<Void, Never>?
    @State private var longPressActivationTask: Task<Void, Never>?
    @State private var didLongPress = false
    @State private var isLongPressActive = false
    @State private var heldPosition: Double?

    private var shortSeekSeconds: Double { model.settings.shortSeekSeconds }
    private var longSeekSeconds: Double { model.settings.longSeekSeconds }

    var body: some View {
        Button {
            if !didLongPress {
                _ = seek(direction * shortSeekSeconds)
            }
            didLongPress = false
            longPressActivationTask?.cancel()
            longPressActivationTask = nil
            isLongPressActive = false
            heldPosition = nil
        } label: {
            ZStack {
                Image(systemName: direction < 0 ? "gobackward" : "goforward")
                    .font(.system(size: 21, weight: .regular))
                Text("\(Int(isLongPressActive ? longSeekSeconds : shortSeekSeconds))")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .allowsHitTesting(false)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(ControlButtonStyle())
        .help(helpText)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onChanged { isPressing in
                    guard isPressing, !isLongPressActive else { return }
                    longPressActivationTask?.cancel()
                    longPressActivationTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard !Task.isCancelled else { return }
                        isLongPressActive = true
                    }
                }
                .onEnded { _ in
                    didLongPress = true
                    heldPosition = model.snapshot.positionSeconds
                    guard seek(direction * longSeekSeconds) else { return }
                    holdTask = Task { @MainActor in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled,
                                  seek(direction * longSeekSeconds) else { return }
                        }
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    holdTask?.cancel()
                    holdTask = nil
                    longPressActivationTask?.cancel()
                    longPressActivationTask = nil
                    isLongPressActive = false
                    heldPosition = nil
                }
        )
        .onDisappear {
            holdTask?.cancel()
            holdTask = nil
            longPressActivationTask?.cancel()
            longPressActivationTask = nil
            isLongPressActive = false
            heldPosition = nil
        }
    }

    private func seek(_ offset: Double) -> Bool {
        let currentPosition = heldPosition ?? model.snapshot.positionSeconds
        let targetPosition: Double
        if let duration = model.snapshot.durationSeconds, duration.isFinite, duration >= 0 {
            targetPosition = min(max(currentPosition + offset, 0), duration)
        } else {
            targetPosition = max(currentPosition + offset, 0)
        }
        let effectiveOffset = targetPosition - currentPosition
        guard abs(effectiveOffset) > 0.000_001 else { return false }
        guard model.seekRelative(effectiveOffset) else { return false }
        heldPosition = targetPosition
        return true
    }

    private var helpText: String {
        let short = Int(shortSeekSeconds)
        let long = Int(longSeekSeconds)
        let action = direction < 0 ? L10n.text("backward") : L10n.text("forward")
        return L10n.format("Short press %@ %d seconds; long press %@ %d seconds", action, short, action, long)
    }
}

private struct PiPPlaceholderView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.black.opacity(0.12))

            VStack(spacing: 18) {
                Image(systemName: "pip")
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(.secondary)

                Text("This video is playing in picture in picture")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("This video is playing in picture in picture")
    }
}

private struct WindowButtonVisibility: NSViewRepresentable {
    let isVisible: Bool
    let onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowButtonVisibilityView {
        WindowButtonVisibilityView(onWindowAvailable: onWindowAvailable)
    }

    func updateNSView(_ nsView: WindowButtonVisibilityView, context: Context) {
        nsView.setButtonsVisible(isVisible)
    }
}

private final class WindowButtonVisibilityView: NSView {
    private var buttonsVisible = true
    private let onWindowAvailable: (NSWindow) -> Void

    init(onWindowAvailable: @escaping (NSWindow) -> Void) {
        self.onWindowAvailable = onWindowAvailable
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindowAvailable(window)
            }
        }
        applyButtonVisibility()
    }

    func setButtonsVisible(_ isVisible: Bool) {
        buttonsVisible = isVisible
        applyButtonVisibility()
    }

    private func applyButtonVisibility() {
        guard let window else { return }
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = !buttonsVisible
        }
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
    let model: PlayerViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            RenderSurfaceView(model: model)
                .background(Color.black)
            HStack(spacing: 10) {
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(model.isPlaying ? "Pause" : "Play")
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
    case settings = "Settings"
    case playlist = "Playlist"
    case chapters = "Chapters"
    case video = "Video"
    case audio = "Audio"
    case subtitles = "Subtitles"

    var id: String { rawValue }

    var title: String { L10n.text(rawValue) }
    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .playlist: return "music.note.list"
        case .chapters: return "list.and.film"
        case .video: return "slider.horizontal.3"
        case .audio: return "waveform"
        case .subtitles: return "captions.bubble"
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case video = "Video"
    case audio = "Audio"
    case subtitles = "Subtitles"

    var id: String { rawValue }

    var title: String { L10n.text(rawValue) }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .video: return "rectangle.on.rectangle"
        case .audio: return "waveform"
        case .subtitles: return "captions.bubble"
        }
    }

    var accessibilityIdentifier: String {
        "player.settings-tab-" + rawValue.lowercased()
    }
}

@MainActor
func showOpenURLPanel(open: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = L10n.text("Open URL")
    alert.informativeText = L10n.text("Enter a public media URL, YouTube link, or Bilibili link.")
    let field = NSTextField(string: "")
    field.placeholderString = "https://..."
    field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: L10n.text("Open"))
    alert.addButton(withTitle: L10n.text("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    open(field.stringValue)
}

private struct SettingsSidebarView: View {
    let model: PlayerViewModel
    let onClose: () -> Void
    let onTogglePiP: () -> Void

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close settings")
                    .accessibilityLabel("Close settings")
                    .accessibilityIdentifier("player.sidebar-close")
            }
            .padding(12)

            Divider()

            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.symbol)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedTab == tab ? Color.white : Color.white.opacity(0.55))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(selectedTab == tab ? "selected" : "unselected")
                    .accessibilityIdentifier(tab.accessibilityIdentifier)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .buttonStyle(.borderless)
                .padding(14)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.sidebar")
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general:
            generalContent
        case .video:
            videoContent
        case .audio:
            audioContent
        case .subtitles:
            subtitleContent
        }
    }

    @ViewBuilder
    private var generalContent: some View {
        settingsSection("Playback") {
            Button(action: model.frameStep) { Label("Next Frame", systemImage: "forward.frame") }
            SpeedMenu(speed: model.snapshot.speed, onSelect: model.setSpeed)
        }

        settingsSection("Looping") {
            Button(action: model.toggleLoop) {
                Label(model.loopEnabled ? "Disable Loop" : "Loop Current Item", systemImage: model.loopEnabled ? "repeat.1" : "repeat")
            }
            Button(action: model.togglePlaylistLoop) {
                Label(model.snapshot.playlistLoop ? "Disable Playlist Loop" : "Loop Playlist", systemImage: model.snapshot.playlistLoop ? "repeat.circle.fill" : "repeat.circle")
            }
            Button(action: model.shufflePlaylist) { Label("Shuffle Playlist", systemImage: "shuffle") }
            Button(action: model.advanceABLoop) { Label(model.abLoopLabel, systemImage: model.abLoopSymbol) }
        }

        settingsSection("Window & Tools") {
            Button(action: model.toggleAlwaysOnTop) {
                Label(model.alwaysOnTop ? "Release Window" : "Keep Window on Top", systemImage: model.alwaysOnTop ? "pin.fill" : "pin")
            }
            Button(action: onTogglePiP) { Label("Picture in Picture", systemImage: "pip") }
            Button(action: model.screenshot) { Label("Screenshot", systemImage: "camera") }
            Button(action: model.copyScreenshot) { Label("Copy Screenshot", systemImage: "doc.on.doc") }
            Button(action: model.chooseScreenshotDirectory) { Label("Choose Screenshot Folder", systemImage: "folder.badge.gearshape") }
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        settingsSection("Video track") {
            TrackPicker(
                tracks: model.snapshot.videoTracks,
                selectedTrack: model.snapshot.videoTracks.first(where: \.selected)?.id ?? -1,
                onSelect: model.selectVideoTrack,
                icon: "rectangle.on.rectangle"
            )
        }

        settingsSection("Aspect ratio") {
            SettingSegmentedControl(
                title: "Aspect ratio",
                values: ["Auto", "4:3", "16:9", "1.85:1", "2.35:1"],
                selection: model.snapshot.videoAspect,
                label: { $0 == "Auto" ? "Default" : $0 },
                onSelect: model.setVideoAspect
            )
            Button("Fit to Video", action: model.fitWindowToVideo)
        }

        settingsSection("Transform") {
            HStack(spacing: 8) {
                Text("Rotation")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ValueBadge(text: "\(model.snapshot.videoRotationDegrees)°")
                Button(action: model.rotateVideo) {
                    Label("Rotate 90°", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)
                Button(model.snapshot.videoFlipped ? "Unflip" : "Flip", action: model.toggleVideoFlip)
                    .buttonStyle(.bordered)
            }
        }

        settingsSection("Speed") {
            SettingSlider(
                title: "Speed",
                value: model.snapshot.speed,
                range: 0.25...16,
                step: 0.25,
                leadingLabel: "0.25x",
                trailingLabel: "16x",
                valueLabel: { "\(formatDecimal($0))x" },
                onChange: model.setSpeed
            )
        }
    }

    @ViewBuilder
    private var audioContent: some View {
        settingsSection("Audio track") {
            TrackPicker(
                tracks: model.snapshot.audioTracks,
                selectedTrack: model.selectedAudioTrack,
                onSelect: model.selectAudioTrack,
                icon: "waveform"
            )
        }

        settingsSection("Output") {
            Menu {
                if model.snapshot.audioDevices.isEmpty {
                    Text("Default Output")
                } else {
                    ForEach(model.snapshot.audioDevices) { device in
                        Button {
                            model.setAudioDevice(device.id)
                        } label: {
                            checkedLabel(device.name, selected: device.selected)
                        }
                    }
                }
            } label: {
                Label(model.snapshot.audioDevices.first(where: \.selected)?.name ?? "Default Output", systemImage: "hifispeaker")
            }
            .menuStyle(.borderlessButton)
        }

        settingsSection("Audio delay") {
            SettingSlider(
                title: "Delay",
                value: model.snapshot.audioDelaySeconds,
                range: -5...5,
                step: 0.5,
                leadingLabel: "-5s",
                trailingLabel: "+5s",
                valueLabel: { "\(formatDecimal($0))s" },
                onChange: model.setAudioDelay
            )
        }
    }

    @ViewBuilder
    private var subtitleContent: some View {
        settingsSection("Subtitle") {
            SettingToggleRow(
                title: "Show Subtitles",
                isOn: model.snapshot.subtitlesVisible,
                onChange: model.setSubtitlesVisible
            )
            TrackPicker(
                tracks: model.snapshot.subtitleTracks,
                selectedTrack: model.selectedSubtitleTrack,
                onSelect: model.selectSubtitleTrack,
                icon: "captions.bubble"
            )
        }

        settingsSection("External subtitles") {
            Button(action: model.openExternalSubtitle) {
                Label("Load External Subtitle", systemImage: "text.badge.plus")
            }
        }

        settingsSection("Subtitle delay") {
            SettingSlider(
                title: "Delay",
                value: model.snapshot.subtitleDelaySeconds,
                range: -5...5,
                step: 0.5,
                leadingLabel: "-5s",
                trailingLabel: "+5s",
                valueLabel: { "\(formatDecimal($0))s" },
                onChange: model.setSubtitleDelay
            )
        }

        settingsSection("Appearance") {
            SettingSlider(
                title: "Scale",
                value: model.snapshot.subtitleScale,
                range: 0.8...1.6,
                step: 0.1,
                leadingLabel: "0.8x",
                trailingLabel: "1.6x",
                valueLabel: { "\(formatDecimal($0))x" },
                onChange: model.setSubtitleScale
            )
            SettingSlider(
                title: "Position",
                value: model.snapshot.subtitlePosition,
                range: 0...100,
                step: 1,
                leadingLabel: "0%",
                trailingLabel: "100%",
                valueLabel: { "\(Int($0))%" },
                onChange: model.setSubtitlePosition
            )
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct TrackPicker: View {
    let tracks: [Track]
    let selectedTrack: Int64
    let onSelect: (Int64) -> Void
    let icon: String

    var body: some View {
        Menu {
            if tracks.isEmpty {
                Text("None")
            } else {
                ForEach(tracks, id: \.id) { track in
                    Button {
                        onSelect(track.id)
                    } label: {
                        checkedLabel(track.title ?? track.language ?? "Track \(track.id)", selected: track.id == selectedTrack)
                    }
                }
            }
        } label: {
            Label(currentTitle, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }

    private var currentTitle: String {
        tracks.first(where: { $0.id == selectedTrack })?.title
            ?? tracks.first(where: { $0.id == selectedTrack })?.language
            ?? (tracks.isEmpty ? "None" : "Select Track")
    }
}

private struct SettingSegmentedControl: View {
    let title: String
    let values: [String]
    let selection: String
    let label: (String) -> String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(values, id: \.self) { value in
                    Button {
                        onSelect(value)
                    } label: {
                        Text(label(value))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == value ? Color.white : Color.white.opacity(0.8))
                    .background(selection == value ? Color.accentColor : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }
}

private struct SettingSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let leadingLabel: String
    let trailingLabel: String
    let valueLabel: (Double) -> String
    let onChange: (Double) -> Void

    @State private var draftValue: Double

    init(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        leadingLabel: String,
        trailingLabel: String,
        valueLabel: @escaping (Double) -> String,
        onChange: @escaping (Double) -> Void
    ) {
        self.title = title
        self.value = value
        self.range = range
        self.step = step
        self.leadingLabel = leadingLabel
        self.trailingLabel = trailingLabel
        self.valueLabel = valueLabel
        self.onChange = onChange
        _draftValue = State(initialValue: value)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ValueBadge(text: valueLabel(draftValue))
            }
            Slider(value: $draftValue, in: range, step: step) { editing in
                if !editing {
                    onChange(draftValue)
                }
            }
            .controlSize(.small)
            HStack {
                Text(leadingLabel)
                Spacer()
                Text(trailingLabel)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: value) { _, newValue in
            draftValue = newValue
        }
    }
}

private struct SettingToggleRow: View {
    let title: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 0)
            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { onChange($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

private struct ValueBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private func formatDecimal(_ value: Double) -> String {
    String(format: "%.2f", value)
        .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
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
    let onOpenInNewWindow: (MediaItem) -> Void
    let onAddFile: () -> Void
    let onAddURL: () -> Void
    let onClearPlaylist: () -> Void
    let onShufflePlaylist: () -> Void
    let onToggleLoop: () -> Void
    let onSortPlaylist: (PlaylistSortKey, Bool) -> Void
    let onPlayNext: (Int) -> Void
    let loopLabel: String
    let loopSymbol: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tab.title, systemImage: tab.symbol)
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close sidebar")
                    .accessibilityLabel("Close sidebar")
                    .accessibilityIdentifier("player.sidebar-close")
            }
            .padding(12)
            Divider()
            if tab == .playlist {
                PlaylistSidebarContent(
                    snapshot: snapshot,
                    onPlayIndex: onPlayIndex,
                    onRemovePlaylistIndex: onRemovePlaylistIndex,
                    onMovePlaylistItem: onMovePlaylistItem,
                    onAddFile: onAddFile,
                    onAddURL: onAddURL,
                    onClear: onClearPlaylist,
                    onShuffle: onShufflePlaylist,
                    onToggleLoop: onToggleLoop,
                    onSort: onSortPlaylist,
                    onPlayNext: onPlayNext,
                    loopLabel: loopLabel,
                    loopSymbol: loopSymbol,
                    onOpenInNewWindow: onOpenInNewWindow
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        nonPlaylistContent
                    }
                    .padding(14)
                }
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.sidebar")
    }

    @ViewBuilder
    private var nonPlaylistContent: some View {
        switch tab {
        case .settings:
            EmptyView()
        case .playlist:
            EmptyView()
        case .chapters:
            if snapshot.chapters.isEmpty {
                Text("No chapters").foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.chapters) { chapter in
                    Button { onSeek(chapter.startSeconds) } label: {
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

private struct PlaylistSidebarContent: View {
    let snapshot: PlaybackSnapshot
    let onPlayIndex: (Int) -> Void
    let onRemovePlaylistIndex: (Int) -> Void
    let onMovePlaylistItem: (Int, Int) -> Void
    let onAddFile: () -> Void
    let onAddURL: () -> Void
    let onClear: () -> Void
    let onShuffle: () -> Void
    let onToggleLoop: () -> Void
    let onSort: (PlaylistSortKey, Bool) -> Void
    let onPlayNext: (Int) -> Void
    let loopLabel: String
    let loopSymbol: String
    let onOpenInNewWindow: (MediaItem) -> Void

    @State private var selection: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onToggleLoop) {
                    Label(loopLabel, systemImage: loopSymbol)
                }
                .buttonStyle(.borderless)
                .help(loopLabel)

                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.borderless)
                .help("Shuffle Playlist")

                Menu {
                    Section("Sort by Title") {
                        Button("Ascending") { onSort(.title, true) }
                        Button("Descending") { onSort(.title, false) }
                    }
                    Section("Sort by Location") {
                        Button("Ascending") { onSort(.locator, true) }
                        Button("Descending") { onSort(.locator, false) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .help("Sort Playlist")

                Spacer(minLength: 0)

                Button(action: onAddFile) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add File")
                .accessibilityIdentifier("player.playlist-add-file")

                Button(action: onAddURL) {
                    Image(systemName: "link")
                }
                .buttonStyle(.borderless)
                .help("Add URL")
                .accessibilityIdentifier("player.playlist-add-url")

                Button {
                    for index in selection.sorted(by: >) {
                        onRemovePlaylistIndex(index)
                    }
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Remove Selected")
                .disabled(selection.isEmpty)

                Button(action: onClear) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear Playlist")
                .disabled(snapshot.playlist.isEmpty)
                .accessibilityIdentifier("player.playlist-clear")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if snapshot.playlist.isEmpty {
                ContentUnavailableView("No items in playlist", systemImage: "music.note.list")
            } else {
                List(selection: $selection) {
                    ForEach(Array(snapshot.playlist.enumerated()), id: \.offset) { index, item in
                        Button {
                            onPlayIndex(index)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: index == snapshot.playlistIndex ? "play.fill" : "film")
                                    .frame(width: 16)
                                    .foregroundStyle(index == snapshot.playlistIndex ? Color.accentColor : Color.secondary)
                                Text(item.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(index)
                        .contextMenu {
                            Button("Play Next") { onPlayNext(index) }
                            Button("Play in New Window") { onOpenInNewWindow(item) }
                            Divider()
                            Button("Remove", role: .destructive) { onRemovePlaylistIndex(index) }
                            Divider()
                            Button("Add File…") { onAddFile() }
                            Button("Add URL…") { onAddURL() }
                            Button("Clear Playlist") { onClear() }
                        }
                    }
                    .onMove { offsets, destination in
                        guard offsets.count == 1, let source = offsets.first else { return }
                        let target = destination > source ? destination - 1 : destination
                        guard source != target else { return }
                        onMovePlaylistItem(source, target)
                    }
                }
                .listStyle(.sidebar)
            }
        }
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
        let label = track.title ?? track.language ?? L10n.format("Track %d", track.id)
        return track.external ? L10n.format("%@ (external)", label) : label
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
            Text(L10n.format("Rotation: %d°", rotation))
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
    let localizedPrefix = L10n.text(prefix)
    settingButtons(values: [-1.0, -0.5, 0.0, 0.5, 1.0], current: current, onSelect: onSelect, label: { value in
        value == 0
            ? L10n.format("%@ 0s", localizedPrefix)
            : value > 0
                ? L10n.format("%@ +%gs", localizedPrefix, value)
                : L10n.format("%@ %gs", localizedPrefix, value)
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
        let prefix = L10n.text("Sub")
        if abs(value) < 0.001 { return L10n.format("%@ 0s", prefix) }
        return value > 0 ? L10n.format("%@ +%gs", prefix, value) : L10n.format("%@ %gs", prefix, value)
    }
}
