import Foundation

private typealias NuraHandle = OpaquePointer

@_silgen_name("nura_player_create")
private func nura_player_create(_ directory: UnsafePointer<CChar>?) -> NuraHandle?
@_silgen_name("nura_player_destroy")
private func nura_player_destroy(_ player: NuraHandle?)
@_silgen_name("nura_player_open_async")
private func nura_player_open_async(_ player: NuraHandle?, _ path: UnsafePointer<CChar>?) -> Int32
@_silgen_name("nura_player_play")
private func nura_player_play(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_pause")
private func nura_player_pause(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_toggle_async")
private func nura_player_toggle_async(_ player: NuraHandle?) -> Int32
@_silgen_name("nura_player_seek_async")
private func nura_player_seek_async(_ player: NuraHandle?, _ position: Double) -> Int32
@_silgen_name("nura_player_set_volume_async")
private func nura_player_set_volume_async(_ player: NuraHandle?, _ volume: Double) -> Int32
@_silgen_name("nura_player_set_mute_async")
private func nura_player_set_mute_async(_ player: NuraHandle?, _ muted: Int32) -> Int32
@_silgen_name("nura_player_select_audio_track_async")
private func nura_player_select_audio_track_async(_ player: NuraHandle?, _ trackID: Int64) -> Int32
@_silgen_name("nura_player_select_subtitle_track_async")
private func nura_player_select_subtitle_track_async(_ player: NuraHandle?, _ trackID: Int64) -> Int32
@_silgen_name("nura_player_attach_opengl_context")
private func nura_player_attach_opengl_context(_ player: NuraHandle?) -> Int32
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

struct MediaItem: Decodable { let path: String; let title: String }
struct PlaybackSnapshot: Decodable {
    let item: MediaItem?
    let status: String
    let positionSeconds: Double
    let durationSeconds: Double?
    let volume: Double
    let muted: Bool
    let audioTracks: [Track]
    let subtitleTracks: [Track]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case item, status, positionSeconds = "position_seconds", durationSeconds = "duration_seconds", volume, muted
        case audioTracks = "audio_tracks", subtitleTracks = "subtitle_tracks", error
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

    init() throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nura", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let created = directory.path.withCString { nura_player_create($0) }
        guard let created else { throw PlayerBridgeError.unavailable(Self.lastError()) }
        handle = created
    }

    deinit { nura_player_destroy(handle) }

    func open(_ url: URL) throws { try command { url.path.withCString { nura_player_open_async(handle, $0) } } }
    func toggle() throws { try command { nura_player_toggle_async(handle) } }
    func seek(_ position: Double) throws { try command { nura_player_seek_async(handle, position) } }
    func setVolume(_ volume: Double) throws { try command { nura_player_set_volume_async(handle, volume) } }
    func setMuted(_ muted: Bool) throws { try command { nura_player_set_mute_async(handle, muted ? 1 : 0) } }
    func selectAudioTrack(_ id: Int64) throws { try command { nura_player_select_audio_track_async(handle, id) } }
    func selectSubtitleTrack(_ id: Int64) throws { try command { nura_player_select_subtitle_track_async(handle, id) } }
    func attachOpenGLContext() throws { try command { nura_player_attach_opengl_context(handle) } }

    func render(fbo: Int32, width: Int32, height: Int32) throws {
        try command { nura_player_render_opengl(handle, fbo, width, height) }
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
