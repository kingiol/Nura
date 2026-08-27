import AppKit
import Combine
import UniformTypeIdentifiers

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
    @Published private(set) var volume = 100.0
    @Published var isSeeking = false
    @Published private(set) var lastError: String?
    @Published private(set) var alwaysOnTop = false
    @Published private(set) var loopEnabled = false

    private var bridge: PlayerBridge?
    private var timer: Timer?
    private var renderErrorReported = false
    private var pendingVolume: Double?
    private let screenshotDirectoryKey = "screenshotDirectory"

    init() {
        configureBridge()
        configureScreenshotDirectory()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollEvents()
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
        snapshot.status == "playing"
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
        do {
            try bridge?.playPlaylistIndex(index)
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func next() {
        do {
            try bridge?.next()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func previous() {
        do {
            try bridge?.previous()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func togglePlayback() {
        do {
            try bridge?.toggle()
            lastError = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func toggleMute() {
        do {
            try bridge?.setMuted(!snapshot.muted)
            lastError = nil
        } catch {
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
        isSeeking = editing
        if !editing {
            do {
                try bridge?.seek(seekPosition)
                lastError = nil
            } catch {
                showError(error.localizedDescription)
            }
        }
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

    func render(fbo: Int32, width: Int32, height: Int32) {
        do {
            try bridge?.render(fbo: fbo, width: width, height: height)
            renderErrorReported = false
        } catch {
            if !renderErrorReported {
                renderErrorReported = true
                showError(error.localizedDescription)
            }
        }
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func fitWindowToVideo() {
        guard let width = snapshot.videoWidth, let height = snapshot.videoHeight, width > 0, height > 0 else {
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

        let rotated = snapshot.videoRotationDegrees % 180 != 0
        let sourceSize = NSSize(
            width: CGFloat(rotated ? height : width),
            height: CGFloat(rotated ? width : height)
        )
        let visibleFrame = screen.visibleFrame
        let chromeHeight = max(0, window.frame.height - (window.contentView?.frame.height ?? window.frame.height))
        let maximumSize = NSSize(
            width: visibleFrame.width * 0.9,
            height: max(1, visibleFrame.height - chromeHeight) * 0.9
        )
        let maximumScale = min(maximumSize.width / sourceSize.width, maximumSize.height / sourceSize.height)
        guard maximumScale > 0 else {
            showError("Unable to fit the video on this display")
            return
        }

        let minimumScale = max(720 / sourceSize.width, 460 / sourceSize.height)
        let scale = min(maximumScale, max(minimumScale, min(1, maximumScale)))
        let contentSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin = NSPoint(
            x: window.frame.midX - frame.width / 2,
            y: window.frame.midY - frame.height / 2
        )
        frame.origin.x = max(visibleFrame.minX, min(frame.origin.x, visibleFrame.maxX - frame.width))
        frame.origin.y = max(visibleFrame.minY, min(frame.origin.y, visibleFrame.maxY - frame.height))
        window.setFrame(frame, display: true, animate: true)
        lastError = nil
    }

    func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        NSApp.keyWindow?.level = alwaysOnTop ? .floating : .normal
    }

    private func configureBridge() {
        do {
            bridge = try PlayerBridge()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func configureScreenshotDirectory() {
        let defaultDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = UserDefaults.standard.string(forKey: screenshotDirectoryKey).map(URL.init(fileURLWithPath:)) ?? defaultDirectory
        setScreenshotDirectory(directory)
    }

    private func setScreenshotDirectory(_ url: URL) {
        do {
            try bridge?.setScreenshotDirectory(url)
            UserDefaults.standard.set(url.path, forKey: screenshotDirectoryKey)
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
        self.snapshot = snapshot
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
