import Foundation
import Observation
import SwiftUI
import Security

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePlayback
    case previousItem
    case nextItem
    case seekBackward
    case seekForward
    case screenshot
    case toggleFullscreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePlayback: L10n.text("Play or Pause")
        case .previousItem: L10n.text("Previous Item")
        case .nextItem: L10n.text("Next Item")
        case .seekBackward: L10n.text("Seek Backward")
        case .seekForward: L10n.text("Seek Forward")
        case .screenshot: L10n.text("Take Screenshot")
        case .toggleFullscreen: L10n.text("Toggle Full Screen")
        }
    }
}

enum ShortcutModifier: String, CaseIterable, Codable, Identifiable {
    case none
    case command
    case option
    case shift
    case control

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: L10n.text("No modifier")
        case .command: L10n.text("Command")
        case .option: L10n.text("Option")
        case .shift: L10n.text("Shift")
        case .control: L10n.text("Control")
        }
    }

    var eventModifiers: EventModifiers {
        switch self {
        case .none: []
        case .command: .command
        case .option: .option
        case .shift: .shift
        case .control: .control
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var key: String
    var modifier: ShortcutModifier

    static let defaults: [ShortcutAction: ShortcutBinding] = [
        .togglePlayback: ShortcutBinding(key: " ", modifier: .none),
        .previousItem: ShortcutBinding(key: "p", modifier: .none),
        .nextItem: ShortcutBinding(key: "n", modifier: .none),
        .seekBackward: ShortcutBinding(key: "j", modifier: .none),
        .seekForward: ShortcutBinding(key: "l", modifier: .none),
        .screenshot: ShortcutBinding(key: "s", modifier: .none),
        .toggleFullscreen: ShortcutBinding(key: "f", modifier: .none),
    ]
}

struct AdvancedMpvOption: Codable, Identifiable, Equatable {
    var key: String
    var value: String

    var id: String { key }
}

private enum KeychainStore {
    private static let service = "com.nura.player"

    static func value(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

@MainActor
@Observable
final class NuraSettings {
    private enum Key {
        static let nowPlayingEnabled = "nowPlayingEnabled"
        static let defaultPlaybackSpeed = "defaultPlaybackSpeed"
        static let defaultVolume = "defaultVolume"
        static let shortSeekSeconds = "shortSeekSeconds"
        static let longSeekSeconds = "longSeekSeconds"
        static let preferredAudioLanguages = "preferredAudioLanguages"
        static let preferredSubtitleLanguages = "preferredSubtitleLanguages"
        static let subtitleSearchLanguage = "subtitleSearchLanguage"
        static let ytdlEnabled = "ytdlEnabled"
        static let cacheEnabled = "cacheEnabled"
        static let cacheSizeKiB = "cacheSizeKiB"
        static let httpProxy = "httpProxy"
        static let userAgent = "userAgent"
        static let shortcuts = "shortcuts"
        static let advancedOptions = "advancedOptions"
    }

    private let defaults: UserDefaults

    var nowPlayingEnabled: Bool { didSet { defaults.set(nowPlayingEnabled, forKey: Key.nowPlayingEnabled) } }
    var defaultPlaybackSpeed: Double { didSet { defaults.set(defaultPlaybackSpeed, forKey: Key.defaultPlaybackSpeed) } }
    var defaultVolume: Double { didSet { defaults.set(defaultVolume, forKey: Key.defaultVolume) } }
    var shortSeekSeconds: Double { didSet { defaults.set(shortSeekSeconds, forKey: Key.shortSeekSeconds) } }
    var longSeekSeconds: Double { didSet { defaults.set(longSeekSeconds, forKey: Key.longSeekSeconds) } }
    var preferredAudioLanguages: String { didSet { defaults.set(preferredAudioLanguages, forKey: Key.preferredAudioLanguages) } }
    var preferredSubtitleLanguages: String { didSet { defaults.set(preferredSubtitleLanguages, forKey: Key.preferredSubtitleLanguages) } }
    var subtitleSearchLanguage: String { didSet { defaults.set(subtitleSearchLanguage, forKey: Key.subtitleSearchLanguage) } }
    var openSubtitlesAPIKey: String { didSet { KeychainStore.set(openSubtitlesAPIKey, for: "opensubtitles-api-key") } }
    var ytdlEnabled: Bool { didSet { defaults.set(ytdlEnabled, forKey: Key.ytdlEnabled) } }
    var cacheEnabled: Bool { didSet { defaults.set(cacheEnabled, forKey: Key.cacheEnabled) } }
    var cacheSizeKiB: Int { didSet { defaults.set(cacheSizeKiB, forKey: Key.cacheSizeKiB) } }
    var httpProxy: String { didSet { defaults.set(httpProxy, forKey: Key.httpProxy) } }
    var userAgent: String { didSet { defaults.set(userAgent, forKey: Key.userAgent) } }
    var shortcuts: [ShortcutAction: ShortcutBinding] { didSet { save(shortcuts, key: Key.shortcuts) } }
    var advancedOptions: [AdvancedMpvOption] { didSet { save(advancedOptions, key: Key.advancedOptions) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        nowPlayingEnabled = defaults.object(forKey: Key.nowPlayingEnabled) as? Bool ?? true
        defaultPlaybackSpeed = defaults.object(forKey: Key.defaultPlaybackSpeed) as? Double ?? 1
        defaultVolume = defaults.object(forKey: Key.defaultVolume) as? Double ?? 100
        shortSeekSeconds = defaults.object(forKey: Key.shortSeekSeconds) as? Double ?? 5
        longSeekSeconds = defaults.object(forKey: Key.longSeekSeconds) as? Double ?? 30
        preferredAudioLanguages = defaults.string(forKey: Key.preferredAudioLanguages) ?? ""
        preferredSubtitleLanguages = defaults.string(forKey: Key.preferredSubtitleLanguages) ?? ""
        subtitleSearchLanguage = defaults.string(forKey: Key.subtitleSearchLanguage) ?? "en"
        openSubtitlesAPIKey = KeychainStore.value(for: "opensubtitles-api-key")
        ytdlEnabled = defaults.object(forKey: Key.ytdlEnabled) as? Bool ?? true
        cacheEnabled = defaults.object(forKey: Key.cacheEnabled) as? Bool ?? true
        cacheSizeKiB = defaults.object(forKey: Key.cacheSizeKiB) as? Int ?? 0
        httpProxy = defaults.string(forKey: Key.httpProxy) ?? ""
        userAgent = defaults.string(forKey: Key.userAgent) ?? ""
        shortcuts = Self.load([ShortcutAction: ShortcutBinding].self, from: defaults, key: Key.shortcuts) ?? ShortcutBinding.defaults
        advancedOptions = Self.load([AdvancedMpvOption].self, from: defaults, key: Key.advancedOptions) ?? []
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        shortcuts[action] ?? ShortcutBinding.defaults[action]!
    }

    func updateShortcut(_ action: ShortcutAction, key: String? = nil, modifier: ShortcutModifier? = nil) {
        var binding = binding(for: action)
        if let key {
            let normalized = key == " " ? " " : String(key.lowercased().prefix(1))
            binding.key = normalized.isEmpty ? ShortcutBinding.defaults[action]!.key : normalized
        }
        if let modifier { binding.modifier = modifier }
        shortcuts[action] = binding
    }

    func resetShortcuts() {
        shortcuts = ShortcutBinding.defaults
    }

    func keyEquivalent(for action: ShortcutAction) -> KeyEquivalent {
        let key = binding(for: action).key.first ?? " "
        return KeyEquivalent(key)
    }

    func modifiers(for action: ShortcutAction) -> EventModifiers {
        binding(for: action).modifier.eventModifiers
    }

    var startupOptionsJSON: String {
        struct StartupOptions: Encodable {
            let ytdlEnabled: Bool
            let httpProxy: String?
            let userAgent: String?
            let preferredAudioLanguages: String?
            let preferredSubtitleLanguages: String?
            let cacheEnabled: Bool
            let cacheSizeKiB: Int?
            let advancedOptions: [AdvancedMpvOption]

            enum CodingKeys: String, CodingKey {
                case ytdlEnabled = "ytdl_enabled"
                case httpProxy = "http_proxy"
                case userAgent = "user_agent"
                case preferredAudioLanguages = "preferred_audio_languages"
                case preferredSubtitleLanguages = "preferred_subtitle_languages"
                case cacheEnabled = "cache_enabled"
                case cacheSizeKiB = "cache_size_kib"
                case advancedOptions = "advanced_options"
            }
        }
        let options = StartupOptions(
            ytdlEnabled: ytdlEnabled,
            httpProxy: httpProxy.emptyToNil,
            userAgent: userAgent.emptyToNil,
            preferredAudioLanguages: preferredAudioLanguages.emptyToNil,
            preferredSubtitleLanguages: preferredSubtitleLanguages.emptyToNil,
            cacheEnabled: cacheEnabled,
            cacheSizeKiB: cacheSizeKiB > 0 ? cacheSizeKiB : nil,
            advancedOptions: advancedOptions
        )
        let data = try? JSONEncoder().encode(options)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private extension String {
    var emptyToNil: String? { isEmpty ? nil : self }
}
