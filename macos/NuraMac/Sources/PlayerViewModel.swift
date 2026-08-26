import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var snapshot = PlaybackSnapshot(
        item: nil,
        status: "idle",
        positionSeconds: 0,
        durationSeconds: nil,
        volume: 100,
        muted: false,
        audioTracks: [],
        subtitleTracks: [],
        error: nil
    )
    @Published var seekPosition = 0.0
    @Published private(set) var volume = 100.0
    @Published var isSeeking = false
    @Published private(set) var lastError: String?

    private var bridge: PlayerBridge?
    private var timer: Timer?
    private var renderErrorReported = false
    private var pendingVolume: Double?

    init() {
        configureBridge()
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
        lastError ?? snapshot.error ?? snapshot.status.capitalized
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
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audio]
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
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

    private func configureBridge() {
        do {
            bridge = try PlayerBridge()
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
}
