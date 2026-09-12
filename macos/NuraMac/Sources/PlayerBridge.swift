import Foundation

private typealias NuraHandle = OpaquePointer
private let nuraRenderSkipped: Int32 = 1

@_silgen_name("nura_player_create")
private func nura_player_create(
    _ directory: UnsafePointer<CChar>?,
    _ startupOptionsJSON: UnsafePointer<CChar>?
) -> NuraHandle?
@_silgen_name("nura_player_destroy")
private func nura_player_destroy(_ player: NuraHandle?)
@_silgen_name("nura_player_open_async")
private func nura_player_open_async(_ player: NuraHandle?, _ path: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_open_url_async")
private func nura_player_open_url_async(_ player: NuraHandle?, _ url: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_enqueue_async")
private func nura_player_enqueue_async(_ player: NuraHandle?, _ locator: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_clear_playlist_async")
private func nura_player_clear_playlist_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_remove_index_async")
private func nura_player_remove_index_async(_ player: NuraHandle?, _ index: Int) -> Int32
@_silgen_name("nura_player_move_index_async")
private func nura_player_move_index_async(_ player: NuraHandle?, _ from: Int, _ to: Int) -> Int32
@_silgen_name("nura_player_play_index_async")
private func nura_player_play_index_async(_ player: NuraHandle?, _ index: Int) -> Int32
@_silgen_name("nura_player_next_async")
private func nura_player_next_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_previous_async")
private func nura_player_previous_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_play")
private func nura_player_play(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_pause")
private func nura_player_pause(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_toggle_async")
private func nura_player_toggle_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_seek_async")
private func nura_player_seek_async(_ player: NuraHandle?, _ position: Double) -> Int32
@_silgen_name("nura_player_seek_relative_async")
private func nura_player_seek_relative_async(_ player: NuraHandle?, _ offset: Double) -> Int32
@_silgen_name("nura_player_frame_step_async")
private func nura_player_frame_step_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_frame_back_step_async")
private func nura_player_frame_back_step_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_set_volume_async")
private func nura_player_set_volume_async(_ player: NuraHandle?, _ volume: Double) -> Int32
@_silgen_name("nura_player_set_mute_async")
private func nura_player_set_mute_async(_ player: NuraHandle?, _ muted: Int32) -> Int32
@_silgen_name("nura_player_set_speed_async")
private func nura_player_set_speed_async(_ player: NuraHandle?, _ speed: Double) -> Int32
@_silgen_name("nura_player_screenshot_async")
private func nura_player_screenshot_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_screenshot_to_file")
private func nura_player_screenshot_to_file(_ player: NuraHandle?, _ path: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_set_loop_async")
private func nura_player_set_loop_async(_ player: NuraHandle?, _ enabled: Int32) -> Int32
@_silgen_name("nura_player_set_playlist_loop_async")
private func nura_player_set_playlist_loop_async(_ player: NuraHandle?, _ enabled: Int32) -> Int32
@_silgen_name("nura_player_shuffle_async")
private func nura_player_shuffle_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_set_ab_loop_async")
private func nura_player_set_ab_loop_async(_ player: NuraHandle?, _ start: Double, _ end: Double) -> Int32
@_silgen_name("nura_player_set_subtitle_delay_async")
private func nura_player_set_subtitle_delay_async(_ player: NuraHandle?, _ delay: Double) -> Int32
@_silgen_name("nura_player_set_audio_delay_async")
private func nura_player_set_audio_delay_async(_ player: NuraHandle?, _ delay: Double) -> Int32
@_silgen_name("nura_player_set_audio_device_async")
private func nura_player_set_audio_device_async(_ player: NuraHandle?, _ deviceID: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_set_subtitle_visibility_async")
private func nura_player_set_subtitle_visibility_async(_ player: NuraHandle?, _ visible: Int32) -> Int32
@_silgen_name("nura_player_set_subtitle_scale_async")
private func nura_player_set_subtitle_scale_async(_ player: NuraHandle?, _ scale: Double) -> Int32
@_silgen_name("nura_player_set_subtitle_position_async")
private func nura_player_set_subtitle_position_async(_ player: NuraHandle?, _ position: Double) -> Int32
@_silgen_name("nura_player_set_video_aspect_async")
private func nura_player_set_video_aspect_async(_ player: NuraHandle?, _ aspect: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_set_video_rotation_async")
private func nura_player_set_video_rotation_async(_ player: NuraHandle?, _ degrees: Int32) -> Int32
@_silgen_name("nura_player_set_video_flip_async")
private func nura_player_set_video_flip_async(_ player: NuraHandle?, _ flipped: Int32) -> Int32
@_silgen_name("nura_player_set_screenshot_directory_async")
private func nura_player_set_screenshot_directory_async(_ player: NuraHandle?, _ directory: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_select_audio_track_async")
private func nura_player_select_audio_track_async(_ player: NuraHandle?, _ trackID: Int64) -> Int32
@_silgen_name("nura_player_select_subtitle_track_async")
private func nura_player_select_subtitle_track_async(_ player: NuraHandle?, _ trackID: Int64) -> Int32
@_silgen_name("nura_player_select_video_track_async")
private func nura_player_select_video_track_async(_ player: NuraHandle?, _ trackID: Int64) -> Int32
@_silgen_name("nura_player_add_external_subtitle_async")
private func nura_player_add_external_subtitle_async(_ player: NuraHandle?, _ path: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_remove_history_item_async")
private func nura_player_remove_history_item_async(_ player: NuraHandle?, _ pathKey: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_clear_history_async")
private func nura_player_clear_history_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_attach_opengl_context")
private func nura_player_attach_opengl_context(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_detach_opengl_context")
private func nura_player_detach_opengl_context(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_render_opengl")
private func nura_player_render_opengl(_ player: NuraHandle?, _ fbo: Int32, _ width: Int32, _ height: Int32) -> Int32
@_silgen_name("nura_player_next_event")
private func nura_player_next_event(_ player: NuraHandle?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("nura_string_free")
private func nura_string_free(_ value: UnsafeMutablePointer<CChar>?)
@_silgen_name("nura_last_error")
private func nura_last_error() -> UnsafeMutablePointer<CChar>?

struct Track: Decodable {
    let id: Int64
    let kind: String
    let title: String?
    let language: String?
    let external: Bool
    let selected: Bool
}

struct AudioDevice: Decodable, Identifiable {
    let id: String
    let name: String
    let selected: Bool
}

enum MediaSource: Decodable {
    case localFile(String)
    case publicURL(String)

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "local_file": self = .localFile(try container.decode(String.self, forKey: .value))
        case "public_url": self = .publicURL(try container.decode(String.self, forKey: .value))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown media source")
        }
    }
}

struct MediaItem: Decodable {
    let source: MediaSource
    let title: String

    var locator: String {
        switch source {
        case .localFile(let path), .publicURL(let path): path
        }
    }
}

struct HistoryEntry: Decodable, Identifiable {
    let item: MediaItem
    let resumeSeconds: Double?
    let openedAtSeconds: Int64

    var id: String { item.locator }

    enum CodingKeys: String, CodingKey {
        case item
        case resumeSeconds = "resume_seconds"
        case openedAtSeconds = "opened_at_seconds"
    }
}

struct Chapter: Decodable, Identifiable {
    let id: Int64
    let title: String
    let startSeconds: Double

    enum CodingKeys: String, CodingKey {
        case id, title, startSeconds = "start_seconds"
    }
}

struct PlaybackSnapshot: Decodable {
    let item: MediaItem?
    let playlist: [MediaItem]
    let recentItems: [MediaItem]
    let historyItems: [HistoryEntry]
    let playlistIndex: Int?
    let chapters: [Chapter]
    let playlistLoop: Bool
    let abLoopStartSeconds: Double?
    let abLoopEndSeconds: Double?
    let status: String
    let positionSeconds: Double
    let durationSeconds: Double?
    let videoWidth: Int?
    let videoHeight: Int?
    let speed: Double
    let audioDelaySeconds: Double
    let subtitleDelaySeconds: Double
    let subtitlesVisible: Bool
    let subtitleScale: Double
    let subtitlePosition: Double
    let videoAspect: String
    let videoRotationDegrees: Int
    let videoFlipped: Bool
    let bufferingPercent: Double?
    let volume: Double
    let muted: Bool
    let videoTracks: [Track]
    let audioTracks: [Track]
    let audioDevices: [AudioDevice]
    let subtitleTracks: [Track]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case item, playlist, recentItems = "recent_items", historyItems = "history_items", playlistIndex = "playlist_index", chapters
        case playlistLoop = "playlist_loop"
        case abLoopStartSeconds = "ab_loop_start_seconds", abLoopEndSeconds = "ab_loop_end_seconds"
        case status
        case positionSeconds = "position_seconds", durationSeconds = "duration_seconds"
        case videoWidth = "video_width", videoHeight = "video_height"
        case speed, audioDelaySeconds = "audio_delay_seconds", subtitleDelaySeconds = "subtitle_delay_seconds"
        case subtitlesVisible = "subtitles_visible", subtitleScale = "subtitle_scale", subtitlePosition = "subtitle_position"
        case videoAspect = "video_aspect", videoRotationDegrees = "video_rotation_degrees", videoFlipped = "video_flipped"
        case bufferingPercent = "buffering_percent", volume, muted
        case videoTracks = "video_tracks"
        case audioTracks = "audio_tracks", audioDevices = "audio_devices", subtitleTracks = "subtitle_tracks", error
    }
}

enum PlayerEvent: Decodable {
    case state(PlaybackSnapshot)
    case error(String)

    private enum CodingKeys: String, CodingKey { case type, snapshot, message }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "state": self = .state(try container.decode(PlaybackSnapshot.self, forKey: .snapshot))
        case "error": self = .error(try container.decode(String.self, forKey: .message))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown player event")
        }
    }
}

enum PlayerBridgeError: LocalizedError {
    case unavailable(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .command(let message): return message
        }
    }
}

final class PlayerBridge {
    private var handle: NuraHandle?
    private let decoder = JSONDecoder()

    init(stateDirectory: URL? = nil, startupOptionsJSON: String = "{}") throws {
        let directory = stateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nura", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let created = directory.path.withCString { directoryPath in
            startupOptionsJSON.withCString { options in
                nura_player_create(directoryPath, options)
            }
        }
        guard let created else { throw PlayerBridgeError.unavailable(Self.lastError()) }
        handle = created
    }

    deinit { nura_player_destroy(handle) }

    func open(_ url: URL) throws {
        if url.isFileURL {
            try command { url.path.withCString { nura_player_open_async(handle, $0) } }
        } else {
            try command { url.absoluteString.withCString { nura_player_open_url_async(handle, $0) } }
        }
    }

    func openURL(_ value: String) throws {
        try command { value.withCString { nura_player_open_url_async(handle, $0) } }
    }
    func enqueue(_ url: URL) throws {
        let value = url.isFileURL ? url.path : url.absoluteString
        try command { value.withCString { nura_player_enqueue_async(handle, $0) } }
    }
    func enqueueURL(_ value: String) throws {
        try command { value.withCString { nura_player_enqueue_async(handle, $0) } }
    }
    func clearPlaylist() throws { try command { nura_player_clear_playlist_async(handle) } }
    func removePlaylistIndex(_ index: Int) throws { try command { nura_player_remove_index_async(handle, index) } }
    func movePlaylistItem(from: Int, to: Int) throws { try command { nura_player_move_index_async(handle, from, to) } }
    func playPlaylistIndex(_ index: Int) throws { try command { nura_player_play_index_async(handle, index) } }
    func next() throws { try command { nura_player_next_async(handle) } }
    func previous() throws { try command { nura_player_previous_async(handle) } }
    func toggle() throws { try command { nura_player_toggle_async(handle) } }
    func seek(_ position: Double) throws { try command { nura_player_seek_async(handle, position) } }
    func seekRelative(_ offset: Double) throws { try command { nura_player_seek_relative_async(handle, offset) } }
    func frameStep() throws { try command { nura_player_frame_step_async(handle) } }
    func frameBackStep() throws { try command { nura_player_frame_back_step_async(handle) } }
    func setVolume(_ volume: Double) throws { try command { nura_player_set_volume_async(handle, volume) } }
    func setMuted(_ muted: Bool) throws { try command { nura_player_set_mute_async(handle, muted ? 1 : 0) } }
    func setSpeed(_ speed: Double) throws { try command { nura_player_set_speed_async(handle, speed) } }
    func screenshot() throws { try command { nura_player_screenshot_async(handle) } }
    func screenshotToFile(_ url: URL) throws {
        try command { url.path.withCString { nura_player_screenshot_to_file(handle, $0) } }
    }
    func setLoop(_ enabled: Bool) throws { try command { nura_player_set_loop_async(handle, enabled ? 1 : 0) } }
    func setPlaylistLoop(_ enabled: Bool) throws { try command { nura_player_set_playlist_loop_async(handle, enabled ? 1 : 0) } }
    func shuffle() throws { try command { nura_player_shuffle_async(handle) } }
    func setABLoop(start: Double?, end: Double?) throws {
        try command { nura_player_set_ab_loop_async(handle, start ?? .nan, end ?? .nan) }
    }
    func setSubtitleDelay(_ delay: Double) throws { try command { nura_player_set_subtitle_delay_async(handle, delay) } }
    func setAudioDelay(_ delay: Double) throws { try command { nura_player_set_audio_delay_async(handle, delay) } }
    func setAudioDevice(_ deviceID: String) throws { try command { deviceID.withCString { nura_player_set_audio_device_async(handle, $0) } } }
    func setSubtitlesVisible(_ visible: Bool) throws { try command { nura_player_set_subtitle_visibility_async(handle, visible ? 1 : 0) } }
    func setSubtitleScale(_ scale: Double) throws { try command { nura_player_set_subtitle_scale_async(handle, scale) } }
    func setSubtitlePosition(_ position: Double) throws { try command { nura_player_set_subtitle_position_async(handle, position) } }
    func setVideoAspect(_ aspect: String) throws { try command { aspect.withCString { nura_player_set_video_aspect_async(handle, $0) } } }
    func setVideoRotation(_ degrees: Int) throws { try command { nura_player_set_video_rotation_async(handle, Int32(degrees)) } }
    func setVideoFlipped(_ flipped: Bool) throws { try command { nura_player_set_video_flip_async(handle, flipped ? 1 : 0) } }
    func setScreenshotDirectory(_ url: URL) throws { try command { url.path.withCString { nura_player_set_screenshot_directory_async(handle, $0) } } }
    func selectAudioTrack(_ id: Int64) throws { try command { nura_player_select_audio_track_async(handle, id) } }
    func selectSubtitleTrack(_ id: Int64) throws { try command { nura_player_select_subtitle_track_async(handle, id) } }
    func selectVideoTrack(_ id: Int64) throws { try command { nura_player_select_video_track_async(handle, id) } }
    func addExternalSubtitle(_ url: URL) throws {
        try command { url.path.withCString { nura_player_add_external_subtitle_async(handle, $0) } }
    }
    func removeHistoryItem(_ item: HistoryEntry) throws {
        try command { item.item.locator.withCString { nura_player_remove_history_item_async(handle, $0) } }
    }
    func clearHistory() throws { try command { nura_player_clear_history_async(handle) } }
    func attachOpenGLContext() throws { try command { nura_player_attach_opengl_context(handle) } }
    func detachOpenGLContext() throws { try command { nura_player_detach_opengl_context(handle) } }

    func render(fbo: Int32, width: Int32, height: Int32) throws -> Bool {
        switch nura_player_render_opengl(handle, fbo, width, height) {
        case 0:
            return true
        case nuraRenderSkipped:
            return false
        default:
            throw PlayerBridgeError.command(Self.lastError())
        }
    }

    func events() -> [PlayerEvent] {
        var result: [PlayerEvent] = []
        while let raw = nura_player_next_event(handle) {
            let string = String(cString: raw)
            nura_string_free(raw)
            if let data = string.data(using: .utf8), let event = try? decoder.decode(PlayerEvent.self, from: data) { result.append(event) }
        }
        return result
    }

    private func command(_ operation: () -> Int32) throws {
        guard operation() == 0 else { throw PlayerBridgeError.command(Self.lastError()) }
    }

    private static func lastError() -> String {
        guard let raw = nura_last_error() else { return "Unknown player error" }
        let value = String(cString: raw)
        nura_string_free(raw)
        return value.isEmpty ? "Unknown player error" : value
    }
}
