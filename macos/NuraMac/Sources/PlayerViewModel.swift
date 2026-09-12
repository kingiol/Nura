import AppKit
import Observation
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

private enum PendingOpenRequest {
    case media([URL])
    case url(String)
}

enum PlaylistSortKey {
    case title
    case locator

    func value(for item: MediaItem) -> String {
        switch self {
        case .title: return item.title
        case .locator: return item.locator
        }
    }
}

@MainActor
@Observable
final class PlayerViewModel {
    private(set) var snapshot = PlaybackSnapshot(
        item: nil,
        playlist: [],
        recentItems: [],
        historyItems: [],
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
    var seekPosition = 0.0
    private(set) var seekPreviewImage: NSImage? = nil
    private(set) var seekPreviewPosition: Double? = nil
    private(set) var isSeekPreviewVisible = false
    private(set) var volume = 100.0
    var isSeeking = false
    private(set) var lastError: String?
    private(set) var alwaysOnTop = false
    private(set) var loopEnabled = false
    private(set) var isPictureInPictureActive = false
    private var pendingPlaybackState: Bool?
    private var pendingMutedState: Bool?
    private(set) var onlineSubtitleResults: [OnlineSubtitleResult] = []
    private(set) var isSearchingOnlineSubtitles = false

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
    private var requestedMediaIdentity: String?
    private var isOpenGLContextAttached = false
    private var pendingOpenRequest: PendingOpenRequest?
    private weak var playerWindow: NSWindow?
    private var windowVideoGeometry: VideoGeometry?
    private let screenshotDirectoryKey = "screenshotDirectory"
    private let stateDirectory: URL?
    private let defaults: UserDefaults
    private let disableWindowResize: Bool
    let settings: NuraSettings
    @ObservationIgnored
    private lazy var nowPlaying = NowPlayingCoordinator(model: self)
    @ObservationIgnored
    private lazy var pictureInPicture = PictureInPictureCoordinator(
        onPlayingChange: { [weak self] playing in
            guard let self, playing != self.isPlaying else { return }
            self.togglePlayback()
        },
        onSeekRelative: { [weak self] offset in
            self?.seekRelative(offset)
        },
        currentPlaybackState: { [weak self] in
            guard let self else { return (false, 0) }
            return (self.isPlaying, self.snapshot.durationSeconds ?? 0)
        },
        reportError: { [weak self] message in
            self?.showError(message)
        },
        onActiveChange: { [weak self] active in
            self?.isPictureInPictureActive = active
        }
    )

    init(
        launchConfiguration: PlayerLaunchConfiguration = .current,
        settings: NuraSettings? = nil
    ) {
        stateDirectory = launchConfiguration.stateDirectory
        defaults = launchConfiguration.defaults
        disableWindowResize = launchConfiguration.disableWindowResize
        self.settings = settings ?? NuraSettings(defaults: launchConfiguration.defaults)
        startRuntime()
        if let mediaURL = launchConfiguration.mediaURL, bridge != nil {
            DispatchQueue.main.async { [weak self] in
                self?.open(mediaURL)
            }
        }
    }

    var title: String {
        snapshot.item?.title ?? L10n.text("Open a media file to begin")
    }

    var statusText: String {
        if let lastError { return lastError }
        if let error = snapshot.error { return error }
        switch snapshot.status {
        case "buffering": return L10n.text("Buffering…")
        case "loading": return L10n.text("Loading…")
        case "playing": return L10n.text("Playing")
        case "paused": return L10n.text("Paused")
        case "idle": return L10n.text("Idle")
        default: return snapshot.status.capitalized
        }
    }

    var hasError: Bool {
        lastError != nil || snapshot.error != nil
    }

    var showsWelcomeScreen: Bool {
        snapshot.status == "failed" || (snapshot.item == nil && requestedMediaIdentity == nil)
    }

    var welcomeHistoryItems: [HistoryEntry] {
        Array(snapshot.historyItems.prefix(3))
    }

    var welcomeErrorMessage: String? {
        hasError ? statusText : nil
    }

    var duration: Double {
        max(snapshot.durationSeconds ?? 1, 1)
    }

    var isPlaying: Bool {
        pendingPlaybackState ?? (snapshot.status == "playing")
    }

    var canFrameStep: Bool {
        snapshot.status == "paused" && snapshot.videoWidth != nil && snapshot.videoHeight != nil
    }

    var canPlaybackControl: Bool {
        snapshot.item != nil && snapshot.status != "loading" && snapshot.status != "failed"
    }

    var canSeek: Bool {
        snapshot.item != nil && snapshot.status != "loading" && snapshot.status != "failed"
    }

    var canNavigateItems: Bool {
        canPlaybackControl && snapshot.playlist.count > 1
    }

    var canScreenshot: Bool {
        snapshot.item != nil && snapshot.videoWidth != nil && snapshot.videoHeight != nil
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
        requestedMediaIdentity = Self.mediaIdentity(for: url)
        if Self.isSupportedLocalVideoFile(url) {
            openExpandedMediaURLs(Self.expandVideoFileAndSiblings(url))
        } else {
            requestOpen(.media([url]))
        }
    }

    func open(_ urls: [URL]) {
        openExpandedMediaURLs(Self.expandMediaURLs(urls))
    }

    func openExpandedMediaURLs(_ expanded: [URL]) {
        guard !expanded.isEmpty else {
            showError(L10n.text("No supported media files were found"))
            return
        }
        invalidateSeekPreview()
        requestedMediaIdentity = Self.mediaIdentity(for: expanded[0])
        requestOpen(.media(expanded))
    }

    func openURL(_ value: String) {
        invalidateSeekPreview()
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedMediaIdentity = trimmedValue
        requestOpen(.url(trimmedValue))
    }

    private func requestOpen(_ request: PendingOpenRequest) {
        pendingOpenRequest = request
        startPendingOpenIfReady()
    }

    private func startPendingOpenIfReady() {
        guard isOpenGLContextAttached, let request = pendingOpenRequest else { return }
        pendingOpenRequest = nil
        do {
            switch request {
            case .media(let urls):
                guard let first = urls.first else { return }
                try bridge?.open(first)
                for url in urls.dropFirst() {
                    try bridge?.enqueue(url)
                }
            case .url(let value):
                try bridge?.openURL(value)
            }
            lastError = nil
        } catch {
            requestedMediaIdentity = nil
            showError(error.localizedDescription)
        }
    }

    func openRecent(_ item: MediaItem) {
        switch item.source {
        case .localFile(let path): open(URL(fileURLWithPath: path))
        case .publicURL(let value): openURL(value)
        }
    }

    func shouldOpenInNewWindow(for url: URL) -> Bool {
        guard let currentMediaIdentity else { return false }
        return currentMediaIdentity != Self.mediaIdentity(for: url)
    }

    func shouldOpenInNewWindow(forURL value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentMediaIdentity else { return false }
        return currentMediaIdentity != value
    }

    func shouldOpenInNewWindow(for item: MediaItem) -> Bool {
        guard let currentMediaIdentity else { return false }
        return currentMediaIdentity != Self.mediaIdentity(for: item)
    }

    func attach(to window: NSWindow) {
        playerWindow = window
        startRuntime()
        updateWindowGeometryIfNeeded()
    }

    func detachWindow() {
        timer?.invalidate()
        timer = nil
        try? bridge?.detachOpenGLContext()
        bridge = nil
        isOpenGLContextAttached = false
        pendingOpenRequest = nil
        windowVideoGeometry = nil
        playerWindow = nil
    }

    func removeHistoryItem(_ item: HistoryEntry) {
        do {
            try bridge?.removeHistoryItem(item)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func clearHistory() {
        do {
            try bridge?.clearHistory()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func refreshNowPlaying() {
        nowPlaying.update(snapshot: snapshot, enabled: settings.nowPlayingEnabled)
    }

    func enqueueURL(_ value: String) {
        do {
            try bridge?.enqueueURL(value.trimmingCharacters(in: .whitespacesAndNewlines))
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func addPlaylistPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addPlaylistURLs(panel.urls)
    }

    func addPlaylistURLs(_ urls: [URL]) {
        let expanded = Self.expandMediaURLs(urls)
        guard !expanded.isEmpty else {
            showError(L10n.text("No supported media files were found"))
            return
        }
        if snapshot.item == nil {
            openExpandedMediaURLs(expanded)
            return
        }
        do {
            for url in expanded {
                if url.isFileURL {
                    try bridge?.enqueue(url)
                } else {
                    try bridge?.enqueueURL(url.absoluteString)
                }
            }
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func addPlaylistURLPrompt() {
        showOpenURLPanel { [weak self] value in
            guard let self else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if self.snapshot.item == nil {
                self.openURL(trimmed)
            } else {
                self.enqueueURL(trimmed)
            }
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

    func clearPlaylist() {
        do {
            try bridge?.clearPlaylist()
            loopEnabled = false
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func playPlaylistItemNext(_ index: Int) {
        guard let current = snapshot.playlistIndex,
              index != current,
              !snapshot.playlist.isEmpty else { return }
        let destination = index < current ? current : min(current + 1, snapshot.playlist.count - 1)
        movePlaylistItem(from: index, to: destination)
    }

    func sortPlaylist(by key: PlaylistSortKey, ascending: Bool) {
        guard snapshot.playlist.count > 1 else { return }
        let sortedIDs = snapshot.playlist.enumerated().sorted { lhs, rhs in
            let left = key.value(for: lhs.element)
            let right = key.value(for: rhs.element)
            return ascending ? left.localizedStandardCompare(right) == .orderedAscending : left.localizedStandardCompare(right) == .orderedDescending
        }.map(\.offset)
        var currentOrder = Array(snapshot.playlist.indices)
        for target in sortedIDs.indices {
            guard let from = currentOrder.firstIndex(of: sortedIDs[target]), from != target else { continue }
            let itemID = currentOrder.remove(at: from)
            currentOrder.insert(itemID, at: target)
            movePlaylistItem(from: from, to: target)
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
                showError(L10n.text("Unsupported subtitle format"))
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

    func searchOnlineSubtitles() {
        guard let item = snapshot.item else {
            showError(L10n.text("Open media before searching for subtitles"))
            return
        }
        isSearchingOnlineSubtitles = true
        onlineSubtitleResults = []
        let query = URL(fileURLWithPath: item.title).deletingPathExtension().lastPathComponent
        let language = settings.subtitleSearchLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = settings.openSubtitlesAPIKey
        Task { [weak self] in
            do {
                let results = try await OpenSubtitlesClient().search(
                    query: query,
                    language: language.isEmpty ? "en" : language,
                    apiKey: apiKey
                )
                guard let self else { return }
                onlineSubtitleResults = results
                isSearchingOnlineSubtitles = false
            } catch {
                guard let self else { return }
                isSearchingOnlineSubtitles = false
                showError(error.localizedDescription)
            }
        }
    }

    func loadOnlineSubtitle(_ result: OnlineSubtitleResult) {
        let apiKey = settings.openSubtitlesAPIKey
        Task { [weak self] in
            do {
                let url = try await OpenSubtitlesClient().download(result: result, apiKey: apiKey)
                guard let self else { return }
                try bridge?.addExternalSubtitle(url)
                lastError = nil
            } catch {
                guard let self else { return }
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
            showError(L10n.text("Open media before copying a screenshot"))
            return
        }
        guard let bridge else {
            showError(L10n.text("Player is unavailable"))
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

    var playlistLoopLabel: String {
        if loopEnabled { return L10n.text("Loop Current Item") }
        if snapshot.playlistLoop { return L10n.text("Loop Playlist") }
        return L10n.text("Loop Off")
    }

    var playlistLoopSymbol: String {
        if loopEnabled { return "repeat.1" }
        if snapshot.playlistLoop { return "repeat" }
        return "repeat"
    }

    func cyclePlaylistLoopMode() {
        if loopEnabled {
            do {
                try bridge?.setLoop(false)
                try bridge?.setPlaylistLoop(true)
                loopEnabled = false
                lastError = nil
            } catch {
                showError(error.localizedDescription)
            }
        } else if snapshot.playlistLoop {
            do {
                try bridge?.setPlaylistLoop(false)
                lastError = nil
            } catch {
                showError(error.localizedDescription)
            }
        } else {
            do {
                try bridge?.setLoop(true)
                loopEnabled = true
                lastError = nil
            } catch {
                showError(error.localizedDescription)
            }
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
        if snapshot.abLoopStartSeconds == nil { return L10n.text("Set A-B loop start") }
        if snapshot.abLoopEndSeconds == nil { return L10n.text("Set A-B loop end") }
        return L10n.text("Clear A-B loop")
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

    @discardableResult
    func seekRelative(_ seconds: Double) -> Bool {
        guard seconds.isFinite, seconds != 0 else { return false }
        let currentPosition = max(snapshot.positionSeconds, 0)
        let targetPosition: Double
        if let duration = snapshot.durationSeconds, duration.isFinite, duration >= 0 {
            targetPosition = min(max(currentPosition + seconds, 0), duration)
        } else {
            targetPosition = max(currentPosition + seconds, 0)
        }
        let effectiveOffset = targetPosition - currentPosition
        guard abs(effectiveOffset) > 0.000_001 else { return false }
        do {
            try bridge?.seekRelative(effectiveOffset)
            seekPosition = targetPosition
            lastError = nil
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    func frameStep() {
        guard canFrameStep else { return }
        do {
            try bridge?.frameStep()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func frameBackStep() {
        guard canFrameStep else { return }
        do {
            try bridge?.frameBackStep()
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
            isOpenGLContextAttached = true
            lastError = nil
            startPendingOpenIfReady()
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
        playerWindow?.toggleFullScreen(nil)
    }

    func togglePiP() {
        guard snapshot.item != nil, snapshot.videoWidth != nil, snapshot.videoHeight != nil else {
            showError(L10n.text("Open a video before starting Picture in Picture"))
            return
        }
        pictureInPicture.toggle()
    }

    func stopPiP() {
        pictureInPicture.stop()
    }

    func capturePiPFrame(framebuffer: Int32, width: Int32, height: Int32) {
        pictureInPicture.appendFrame(
            framebuffer: framebuffer,
            width: width,
            height: height,
            videoWidth: snapshot.videoWidth.map(Int32.init),
            videoHeight: snapshot.videoHeight.map(Int32.init)
        )
    }

    func fitWindowToVideo() {
        guard let geometry = currentVideoGeometry else {
            showError(L10n.text("Video dimensions are not available yet"))
            return
        }
        guard let window = playerWindow else {
            showError(L10n.text("Player window is unavailable"))
            return
        }
        guard let screen = window.screen ?? NSScreen.main else {
            showError(L10n.text("Display information is unavailable"))
            return
        }

        configure(window, for: geometry, on: screen, resizeToFit: true)
        windowVideoGeometry = geometry
        lastError = nil
    }

    func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        playerWindow?.level = alwaysOnTop ? .floating : .normal
    }

    private func configureBridge(stateDirectory: URL?) {
        do {
            bridge = try PlayerBridge(
                stateDirectory: stateDirectory,
                startupOptionsJSON: settings.startupOptionsJSON
            )
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func startRuntime() {
        guard bridge == nil else { return }
        configureBridge(stateDirectory: stateDirectory)
        guard bridge != nil else { return }

        configureScreenshotDirectory()
        setVolume(settings.defaultVolume)
        setSpeed(settings.defaultPlaybackSpeed)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollEvents()
            }
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
                requestedMediaIdentity = nil
                showError(message)
            }
        }
    }

    private func apply(_ snapshot: PlaybackSnapshot) {
        let incomingIdentity = mediaIdentity(for: snapshot.item)
        if incomingIdentity == requestedMediaIdentity {
            requestedMediaIdentity = nil
        }
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
        nowPlaying.update(snapshot: snapshot, enabled: settings.nowPlayingEnabled)
        pictureInPicture.invalidatePlaybackState()
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

    private var currentMediaIdentity: String? {
        requestedMediaIdentity ?? mediaIdentity(for: snapshot.item)
    }

    private func mediaIdentity(for item: MediaItem?) -> String? {
        guard let item else { return nil }
        return Self.mediaIdentity(for: item)
    }

    private static func mediaIdentity(for item: MediaItem) -> String {
        switch item.source {
        case .localFile(let path): return URL(fileURLWithPath: path).standardizedFileURL.path
        case .publicURL(let value): return value
        }
    }

    private static func mediaIdentity(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
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
              let window = playerWindow,
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
            showError(L10n.text("Unable to fit the video on this display"))
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
        guard let window = playerWindow else { return }
        let minimumLength: CGFloat = snapshot.item == nil ? 600 : 300
        let minimumSize = NSSize(width: minimumLength, height: minimumLength)
        guard window.contentAspectRatio != .zero || window.contentMinSize != minimumSize else { return }
        window.contentAspectRatio = .zero
        window.contentMinSize = minimumSize
    }

    private func showError(_ message: String) {
        lastError = message
    }

    static func expandMediaURLs(_ urls: [URL]) -> [URL] {
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

    static func isSupportedLocalVideoFile(_ url: URL) -> Bool {
        url.isFileURL && !url.hasDirectoryPath && videoExtensions.contains(url.pathExtension.lowercased())
    }

    private static func expandMediaURL(_ url: URL) -> [URL] {
        if url.hasDirectoryPath {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            return enumerator.compactMap { item in
                guard let candidate = item as? URL,
                      (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      mediaExtensions.contains(candidate.pathExtension.lowercased()) else { return nil }
                return candidate
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }

        switch url.pathExtension.lowercased() {
        case "m3u", "m3u8":
            return parsePlaylist(url)
        case let ext where videoExtensions.contains(ext):
            return expandVideoFileAndSiblings(url)
        case let ext where mediaExtensions.contains(ext):
            return [url]
        default:
            return []
        }
    }

    private static func expandVideoFileAndSiblings(_ url: URL) -> [URL] {
        let fileURL = url.standardizedFileURL
        let folderURL = fileURL.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [url]
        }

        let videos = contents.filter { candidate in
            guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            return videoExtensions.contains(candidate.pathExtension.lowercased())
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard !videos.isEmpty else { return [url] }
        return [fileURL] + videos.filter { $0.standardizedFileURL != fileURL }
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm",
        "mpg", "mpeg", "ts", "m2ts", "mts", "flv",
        "wmv", "asf", "3gp", "3g2", "ogv", "vob", "rm", "rmvb"
    ]
    private static let mediaExtensions: Set<String> = videoExtensions.union(["mp3", "m4a", "aac", "flac", "wav", "ogg"])

    private static func parsePlaylist(_ url: URL) -> [URL] {
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
