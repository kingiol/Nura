import AppKit
import Combine
import UniformTypeIdentifiers

private struct VideoGeometry: Equatable {
    let width: CGFloat
    let height: CGFloat

    var size: NSSize {
        NSSize(width: width, height: height)
    }

    var minimumSize: NSSize {
        let scale = 600 / max(width, height)
        return NSSize(width: width * scale, height: height * scale)
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var snapshot = PlaybackSnapshot(
        item: nil,
        playlist: [],
        recentItems: [],
        playlistIndex: nil,
        chapters: [],
        playlistLoop: false,
        abLoopStartSeconds: nil,
        abLoopEndSeconds: nil,
        status: "idle",
        positionSeconds: 0,
        durationSeconds: nil,
        videoWidth: nil,
        videoHeight: nil,
        speed: 1,
        audioDelaySeconds: 0,
        subtitleDelaySeconds: 0,
        subtitlesVisible: true,
        subtitleScale: 1,
        subtitlePosition: 100,
        videoAspect: "Auto",
        videoRotationDegrees: 0,
        videoFlipped: false,
        bufferingPercent: nil,
        volume: 100,
        muted: false,
        videoTracks: [],
        audioTracks: [],
        audioDevices: [],
        subtitleTracks: [],
        error: nil
    )
    @Published var seekPosition = 0.0
    @Published private(set) var seekPreviewImage: NSImage? = nil
    @Published private(set) var seekPreviewPosition: Double? = nil
    @Published private(set) var isSeekPreviewVisible = false
    @Published private(set) var volume = 100.0
    @Published var isSeeking = false
    @Published private(set) var lastError: String?
    @Published private(set) var alwaysOnTop = false
    @Published private(set) var loopEnabled = false
    @Published private var pendingPlaybackState: Bool?
    @Published private var pendingMutedState: Bool?

    private var bridge: PlayerBridge?
    private var timer: Timer?
    private var renderErrorReported = false
    private var pendingVolume: Double?
    private let thumbnailGenerator = SeekThumbnailGenerator()
    private var thumbnailRequest: SeekThumbnailRequest?
    private var thumbnailTask: Task<Void, Never>?
    private var seekPreviewGeneration: UInt64 = 0
    private var seekPreviewRequestID: UInt64 = 0
    private var lastRequestedPreviewPosition: Double?
    private var sliderSeekGeneration: UInt64?
    private var activeMediaIdentity: String?
    private var windowVideoGeometry: VideoGeometry?
    private let screenshotDirectoryKey = "screenshotDirectory"
    private let defaults: UserDefaults
    private let disableWindowResize: Bool

    init(launchConfiguration: PlayerLaunchConfiguration = .current) {
        defaults = launchConfiguration.defaults
        disableWindowResize = launchConfiguration.disableWindowResize
        configureBridge(stateDirectory: launchConfiguration.stateDirectory)
        configureScreenshotDirectory()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollEvents()
            }
        }
        if let mediaURL = launchConfiguration.mediaURL, bridge != nil {
            DispatchQueue.main.async { [weak self] in
                self?.open(mediaURL)
            }
        }
    }

    var title: String {
        snapshot.item?.title ?? "Open a media file to begin"
    }

    var statusText: String {
        if let lastError { return lastError }
        if let error = snapshot.error { return error }
        if snapshot.status == "buffering" { return "Buffering…" }
        if snapshot.status == "loading" { return "Loading…" }
        return snapshot.status.capitalized
    }

    var hasError: Bool {
        lastError != nil || snapshot.error != nil
    }

    var duration: Double {
        max(snapshot.durationSeconds ?? 1, 1)
    }

    var isPlaying: Bool {
        pendingPlaybackState ?? (snapshot.status == "playing")
    }

    var isMuted: Bool {
        pendingMutedState ?? snapshot.muted
    }

    var selectedAudioTrack: Int64 {
        snapshot.audioTracks.first(where: \.selected)?.id ?? -1
    }

    var selectedSubtitleTrack: Int64 {
        snapshot.subtitleTracks.first(where: \.selected)?.id ?? -1
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            open(panel.urls)
        }
    }

    func open(_ url: URL) {
        invalidateSeekPreview()
        do {
            try bridge?.open(url)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func open(_ urls: [URL]) {
        let expanded = expandMediaURLs(urls)
        guard let first = expanded.first else {
            showError("No supported media files were found")
            return
        }
        open(first)
        for url in expanded.dropFirst() {
            do {
                try bridge?.enqueue(url)
            } catch {
                showError(error.localizedDescription)
                break
            }
        }
    }

    func openURL(_ value: String) {
        invalidateSeekPreview()
        do {
            try bridge?.openURL(value.trimmingCharacters(in: .whitespacesAndNewlines))
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func openRecent(_ item: MediaItem) {
        switch item.source {
        case .localFile(let path): open(URL(fileURLWithPath: path))
        case .publicURL(let value): openURL(value)
        }
    }

    func enqueueURL(_ value: String) {
        do {
            try bridge?.enqueueURL(value.trimmingCharacters(in: .whitespacesAndNewlines))
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removePlaylistIndex(_ index: Int) {
        do {
            try bridge?.removePlaylistIndex(index)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func movePlaylistItem(from: Int, to: Int) {
        do {
            try bridge?.movePlaylistItem(from: from, to: to)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func openExternalSubtitle() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let supported = ["srt", "ass", "ssa", "vtt", "sup"].contains(url.pathExtension.lowercased())
            guard supported else {
                showError("Unsupported subtitle format")
                return
            }
            do {
                try bridge?.addExternalSubtitle(url)
                lastError = nil
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func playPlaylistIndex(_ index: Int) {
        invalidateSeekPreview()
        do {
            try bridge?.playPlaylistIndex(index)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func next() {
        invalidateSeekPreview()
        do {
            try bridge?.next()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func previous() {
        invalidateSeekPreview()
        do {
            try bridge?.previous()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func togglePlayback() {
        let target = !isPlaying
        pendingPlaybackState = target
        objectWillChange.send()
        do {
            try bridge?.toggle()
            lastError = nil
        } catch {
            pendingPlaybackState = nil
            showError(error.localizedDescription)
        }
    }

    func toggleMute() {
        let target = !isMuted
        pendingMutedState = target
        objectWillChange.send()
        do {
            try bridge?.setMuted(target)
            lastError = nil
        } catch {
            pendingMutedState = nil
            showError(error.localizedDescription)
        }
    }

    func setSpeed(_ speed: Double) {
        do {
            try bridge?.setSpeed(speed)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func screenshot() {
        do {
            try bridge?.screenshot()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func copyScreenshot() {
        guard snapshot.item != nil else {
            showError("Open media before copying a screenshot")
            return
        }
        guard let bridge else {
            showError("Player is unavailable")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nura", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
        let url = directory.appendingPathComponent("screenshot-\(UUID().uuidString).png")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bridge.screenshotToFile(url)
            guard let image = NSImage(contentsOf: url) else {
                throw PlayerBridgeError.command("Unable to copy the screenshot")
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([image]) else {
                throw PlayerBridgeError.command("Unable to write the screenshot to the clipboard")
            }
            try? FileManager.default.removeItem(at: url)
            lastError = nil
        } catch {
            try? FileManager.default.removeItem(at: url)
            showError(error.localizedDescription)
        }
    }

    func chooseScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            setScreenshotDirectory(url)
        }
    }

    func toggleLoop() {
        let enabled = !loopEnabled
        do {
            try bridge?.setLoop(enabled)
            loopEnabled = enabled
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func togglePlaylistLoop() {
        let enabled = !snapshot.playlistLoop
        do {
            try bridge?.setPlaylistLoop(enabled)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func shufflePlaylist() {
        do {
            try bridge?.shuffle()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func advanceABLoop() {
        let position = max(0, snapshot.positionSeconds)
        do {
            if snapshot.abLoopStartSeconds == nil {
                try bridge?.setABLoop(start: position, end: nil)
            } else if snapshot.abLoopEndSeconds == nil {
                try bridge?.setABLoop(start: snapshot.abLoopStartSeconds, end: position)
            } else {
                try bridge?.setABLoop(start: nil, end: nil)
            }
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    var abLoopLabel: String {
        if snapshot.abLoopStartSeconds == nil { return "Set A-B loop start" }
        if snapshot.abLoopEndSeconds == nil { return "Set A-B loop end" }
        return "Clear A-B loop"
    }

    var abLoopSymbol: String {
        if snapshot.abLoopStartSeconds == nil { return "a.circle" }
        if snapshot.abLoopEndSeconds == nil { return "b.circle" }
        return "a.circle.fill"
    }

    func seekEditingChanged(_ editing: Bool) {
        if editing {
            guard !isSeeking else { return }
            isSeeking = true
            sliderSeekGeneration = seekPreviewGeneration
            return
        }

        guard isSeeking else { return }
        isSeeking = false
        let generation = sliderSeekGeneration
        sliderSeekGeneration = nil
        hideSeekPreview()
        guard generation == seekPreviewGeneration else { return }
        do {
            try bridge?.seek(seekPosition)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func seek(to position: Double) {
        hideSeekPreview()
        let clamped = min(max(position, 0), duration)
        seekPosition = clamped
        do {
            try bridge?.seek(clamped)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func updateSeekPreview(position: Double) {
        guard let source = localMediaURL, let rounded = roundedPreviewPosition(position) else {
            hideSeekPreview()
            return
        }
        if isSeekPreviewVisible,
           lastRequestedPreviewPosition == rounded,
           (thumbnailTask != nil || thumbnailRequest != nil || seekPreviewImage != nil) {
            return
        }
        isSeekPreviewVisible = true
        seekPreviewPosition = rounded
        lastRequestedPreviewPosition = rounded
        thumbnailRequest?.cancel()
        thumbnailTask?.cancel()
        thumbnailRequest = nil
        seekPreviewRequestID &+= 1
        let requestID = seekPreviewRequestID
        let generation = seekPreviewGeneration
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.seekPreviewRequestID == requestID,
                  self.seekPreviewGeneration == generation,
                  self.isSeekPreviewVisible else { return }
            let request = self.thumbnailGenerator.request(source: source, position: rounded) { [weak self] result in
                guard let self,
                      self.seekPreviewGeneration == generation,
                      self.seekPreviewRequestID == requestID,
                      self.isSeekPreviewVisible else { return }
                if let image = result?.image {
                    self.seekPreviewImage = image
                }
                self.seekPreviewPosition = result?.position ?? rounded
            }
            guard self.seekPreviewRequestID == requestID,
                  self.seekPreviewGeneration == generation,
                  self.isSeekPreviewVisible else {
                request.cancel()
                return
            }
            self.thumbnailRequest = request
        }
    }

    func hideSeekPreview() {
        isSeekPreviewVisible = false
        seekPreviewImage = nil
        seekPreviewPosition = nil
        lastRequestedPreviewPosition = nil
        thumbnailTask?.cancel()
        thumbnailRequest?.cancel()
        thumbnailTask = nil
        thumbnailRequest = nil
    }

    func seekRelative(_ seconds: Double) {
        do {
            try bridge?.seekRelative(seconds)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func frameStep() {
        do {
            try bridge?.frameStep()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setVolume(_ volume: Double) {
        self.volume = volume
        pendingVolume = volume
        do {
            try bridge?.setVolume(volume)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func selectAudioTrack(_ id: Int64) {
        do {
            try bridge?.selectAudioTrack(id)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func selectSubtitleTrack(_ id: Int64) {
        do {
            try bridge?.selectSubtitleTrack(id)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setSubtitleDelay(_ delay: Double) {
        do {
            try bridge?.setSubtitleDelay(delay)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setAudioDelay(_ delay: Double) {
        do {
            try bridge?.setAudioDelay(delay)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setAudioDevice(_ deviceID: String) {
        do {
            try bridge?.setAudioDevice(deviceID)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setSubtitlesVisible(_ visible: Bool) {
        do {
            try bridge?.setSubtitlesVisible(visible)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setSubtitleScale(_ scale: Double) {
        do {
            try bridge?.setSubtitleScale(scale)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setSubtitlePosition(_ position: Double) {
        do {
            try bridge?.setSubtitlePosition(position)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setVideoAspect(_ aspect: String) {
        do {
            try bridge?.setVideoAspect(aspect == "Auto" ? "no" : aspect)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func rotateVideo() {
        let degrees = (snapshot.videoRotationDegrees + 90) % 360
        do {
            try bridge?.setVideoRotation(degrees)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func toggleVideoFlip() {
        do {
            try bridge?.setVideoFlipped(!snapshot.videoFlipped)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func selectVideoTrack(_ id: Int64) {
        do {
            try bridge?.selectVideoTrack(id)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func attachOpenGLContext() {
        do {
            try bridge?.attachOpenGLContext()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func render(fbo: Int32, width: Int32, height: Int32) -> Bool {
        guard let bridge else { return false }
        do {
            let rendered = try bridge.render(fbo: fbo, width: width, height: height)
            if rendered {
                renderErrorReported = false
            }
            return rendered
        } catch {
            if !renderErrorReported {
                renderErrorReported = true
                showError(error.localizedDescription)
            }
            return false
        }
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func fitWindowToVideo() {
        guard let geometry = currentVideoGeometry else {
            showError("Video dimensions are not available yet")
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            showError("Player window is unavailable")
            return
        }
        guard let screen = window.screen ?? NSScreen.main else {
            showError("Display information is unavailable")
            return
        }

        configure(window, for: geometry, on: screen, resizeToFit: true)
        windowVideoGeometry = geometry
        lastError = nil
    }

    func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        NSApp.keyWindow?.level = alwaysOnTop ? .floating : .normal
    }

    private func configureBridge(stateDirectory: URL?) {
        do {
            bridge = try PlayerBridge(stateDirectory: stateDirectory)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func configureScreenshotDirectory() {
        let defaultDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = defaults.string(forKey: screenshotDirectoryKey).map(URL.init(fileURLWithPath:)) ?? defaultDirectory
        setScreenshotDirectory(directory)
    }

    private func setScreenshotDirectory(_ url: URL) {
        do {
            try bridge?.setScreenshotDirectory(url)
            defaults.set(url.path, forKey: screenshotDirectoryKey)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func pollEvents() {
        for event in bridge?.events() ?? [] {
            switch event {
            case .state(let snapshot):
                apply(snapshot)
            case .error(let message):
                showError(message)
            }
        }
    }

    private func apply(_ snapshot: PlaybackSnapshot) {
        let incomingIdentity = mediaIdentity(for: snapshot.item)
        if activeMediaIdentity != incomingIdentity {
            invalidateSeekPreview()
            activeMediaIdentity = incomingIdentity
        }
        self.snapshot = snapshot
        if let pendingPlaybackState,
           snapshot.status == "playing" || snapshot.status == "paused",
           pendingPlaybackState == (snapshot.status == "playing") {
            self.pendingPlaybackState = nil
        }
        if let pendingMutedState, pendingMutedState == snapshot.muted {
            self.pendingMutedState = nil
        }
        updateWindowGeometryIfNeeded()
        if let pendingVolume {
            if abs(snapshot.volume - pendingVolume) < 0.001 {
                self.pendingVolume = nil
                volume = snapshot.volume
            }
        } else {
            volume = snapshot.volume
        }
        if !isSeeking {
            seekPosition = min(snapshot.positionSeconds, duration)
        }
    }

    private func invalidateSeekPreview() {
        seekPreviewGeneration &+= 1
        sliderSeekGeneration = nil
        isSeeking = false
        hideSeekPreview()
        thumbnailGenerator.clearCache()
    }

    private var localMediaURL: URL? {
        guard case .localFile(let path) = snapshot.item?.source else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func mediaIdentity(for item: MediaItem?) -> String? {
        guard let item else { return nil }
        switch item.source {
        case .localFile(let path): return URL(fileURLWithPath: path).standardizedFileURL.path
        case .publicURL(let value): return value
        }
    }

    private func roundedPreviewPosition(_ position: Double) -> Double? {
        guard let actualDuration = snapshot.durationSeconds,
              actualDuration.isFinite,
              actualDuration > 0,
              position.isFinite else { return nil }
        let clamped = min(max(position, 0), actualDuration)
        return min((clamped / 0.25).rounded() * 0.25, actualDuration)
    }

    private var currentVideoGeometry: VideoGeometry? {
        guard let width = snapshot.videoWidth, let height = snapshot.videoHeight, width > 0, height > 0 else {
            return nil
        }
        let rotated = snapshot.videoRotationDegrees % 180 != 0
        return VideoGeometry(
            width: CGFloat(rotated ? height : width),
            height: CGFloat(rotated ? width : height)
        )
    }

    func updateWindowGeometryIfNeeded() {
        guard !disableWindowResize else { return }
        guard let geometry = currentVideoGeometry else {
            configureNonVideoWindow()
            windowVideoGeometry = nil
            return
        }
        guard geometry != windowVideoGeometry,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let screen = window.screen ?? NSScreen.main else {
            return
        }
        configure(window, for: geometry, on: screen, resizeToFit: true)
        windowVideoGeometry = geometry
    }

    private func configure(_ window: NSWindow, for geometry: VideoGeometry, on screen: NSScreen, resizeToFit: Bool) {
        let contentSize = geometry.size
        window.contentAspectRatio = contentSize
        window.contentMinSize = geometry.minimumSize
        guard resizeToFit else { return }

        let visibleFrame = screen.visibleFrame
        let maximumSize = NSSize(width: visibleFrame.width * 0.9, height: visibleFrame.height * 0.9)
        let maximumScale = min(maximumSize.width / contentSize.width, maximumSize.height / contentSize.height)
        guard maximumScale > 0 else {
            showError("Unable to fit the video on this display")
            return
        }

        let scale = min(maximumScale, 1)
        let fittedContentSize = NSSize(width: contentSize.width * scale, height: contentSize.height * scale)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: fittedContentSize))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        frame.origin.x = max(visibleFrame.minX, min(frame.origin.x, visibleFrame.maxX - frame.width))
        frame.origin.y = max(visibleFrame.minY, min(frame.origin.y, visibleFrame.maxY - frame.height))
        window.setFrame(frame, display: true, animate: true)
    }

    private func configureNonVideoWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let minimumLength: CGFloat = snapshot.item == nil ? 600 : 300
        let minimumSize = NSSize(width: minimumLength, height: minimumLength)
        guard window.contentAspectRatio != .zero || window.contentMinSize != minimumSize else { return }
        window.contentAspectRatio = .zero
        window.contentMinSize = minimumSize
    }

    private func showError(_ message: String) {
        lastError = message
    }

    private func expandMediaURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for url in urls {
            for candidate in expandMediaURL(url) {
                let key = candidate.standardizedFileURL.path
                if seen.insert(key).inserted {
                    result.append(candidate)
                }
            }
        }
        return result
    }

    private func expandMediaURL(_ url: URL) -> [URL] {
        if url.hasDirectoryPath {
            let keys: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mp3", "m4a", "aac", "flac", "wav", "ogg"]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            return enumerator.compactMap { item in
                guard let candidate = item as? URL,
                      (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      keys.contains(candidate.pathExtension.lowercased()) else { return nil }
                return candidate
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }

        switch url.pathExtension.lowercased() {
        case "m3u", "m3u8":
            return parsePlaylist(url)
        case "mp4", "m4v", "mov", "mkv", "avi", "webm", "mp3", "m4a", "aac", "flac", "wav", "ogg":
            return [url]
        default:
            return []
        }
    }

    private func parsePlaylist(_ url: URL) -> [URL] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if let remote = URL(string: line), let scheme = remote.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return nil
            }
            let candidate = line.hasPrefix("/")
                ? URL(fileURLWithPath: line)
                : URL(fileURLWithPath: line, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
            return candidate.isFileURL && FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }
}
