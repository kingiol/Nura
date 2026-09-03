import SwiftUI

struct NuraSettingsView: View {
    let settings: NuraSettings
    let model: PlayerViewModel

    var body: some View {
        TabView {
            GeneralSettingsPage(settings: settings, model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            PlaybackSettingsPage(settings: settings)
                .tabItem { Label("Playback", systemImage: "play.circle") }
            ControlsSettingsPage(settings: settings)
                .tabItem { Label("Controls", systemImage: "keyboard") }
            VideoSettingsPage(model: model)
                .tabItem { Label("Video", systemImage: "rectangle.on.rectangle") }
            AudioSettingsPage(settings: settings, model: model)
                .tabItem { Label("Audio", systemImage: "waveform") }
            SubtitleSettingsPage(settings: settings, model: model)
                .tabItem { Label("Subtitles", systemImage: "captions.bubble") }
            NetworkSettingsPage(settings: settings)
                .tabItem { Label("Network", systemImage: "network") }
            AdvancedSettingsPage(settings: settings)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            HistorySettingsPage(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AboutSettingsPage()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 760, height: 560)
    }
}

private struct GeneralSettingsPage: View {
    let settings: NuraSettings
    let model: PlayerViewModel

    var body: some View {
        Form {
            Section("System") {
                Toggle("Show Now Playing controls", isOn: Binding(
                    get: { settings.nowPlayingEnabled },
                    set: {
                        settings.nowPlayingEnabled = $0
                        model.refreshNowPlaying()
                    }
                ))
            }
            Section("Screenshots") {
                Text("Choose a destination from the player settings when saving screenshots.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct PlaybackSettingsPage: View {
    @Bindable var settings: NuraSettings

    var body: some View {
        Form {
            Section("Defaults") {
                LabeledContent("Playback speed") {
                    HStack {
                        Slider(value: $settings.defaultPlaybackSpeed, in: 0.25...4, step: 0.25)
                            .frame(width: 220)
                        Text("\(settings.defaultPlaybackSpeed.formatted(.number.precision(.fractionLength(2))))x")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: $settings.defaultVolume, in: 0...100, step: 1)
                            .frame(width: 220)
                        Text("\(Int(settings.defaultVolume))%")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Section("Seeking") {
                Stepper("Short seek: \(Int(settings.shortSeekSeconds)) seconds", value: $settings.shortSeekSeconds, in: 1...60, step: 1)
                Stepper("Long seek: \(Int(settings.longSeekSeconds)) seconds", value: $settings.longSeekSeconds, in: 5...300, step: 5)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ControlsSettingsPage: View {
    let settings: NuraSettings

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutEditor(action: action, settings: settings)
                }
            }
            Section {
                Button("Restore Defaults", action: settings.resetShortcuts)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ShortcutEditor: View {
    let action: ShortcutAction
    let settings: NuraSettings

    var body: some View {
        let binding = settings.binding(for: action)
        LabeledContent(action.title) {
            HStack(spacing: 8) {
                TextField(
                    "Key",
                    text: Binding(
                        get: { settings.binding(for: action).key == " " ? "Space" : settings.binding(for: action).key.uppercased() },
                        set: { value in
                            settings.updateShortcut(action, key: value.lowercased() == "space" ? " " : value)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 68)
                Picker("Modifier", selection: Binding(
                    get: { settings.binding(for: action).modifier },
                    set: { settings.updateShortcut(action, modifier: $0) }
                )) {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        Text(modifier == .none ? "No modifier" : modifier.title).tag(modifier)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
            }
            .accessibilityValue("\(binding.modifier.title) \(binding.key)")
        }
    }
}

private struct VideoSettingsPage: View {
    let model: PlayerViewModel

    var body: some View {
        Form {
            Section("Current Video") {
                Picker("Aspect ratio", selection: Binding(
                    get: { model.snapshot.videoAspect },
                    set: { model.setVideoAspect($0) }
                )) {
                    ForEach(["Auto", "4:3", "16:9", "1.85:1", "2.35:1"], id: \.self) { value in
                        Text(value == "Auto" ? "Default" : value).tag(value)
                    }
                }
                Button("Fit Window to Video", action: model.fitWindowToVideo)
                Button("Rotate 90°", action: model.rotateVideo)
                Toggle("Flip video", isOn: Binding(
                    get: { model.snapshot.videoFlipped },
                    set: { _ in model.toggleVideoFlip() }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AudioSettingsPage: View {
    @Bindable var settings: NuraSettings
    let model: PlayerViewModel

    var body: some View {
        Form {
            Section("Defaults") {
                TextField("Preferred audio languages", text: $settings.preferredAudioLanguages)
            }
            Section("Current Playback") {
                LabeledContent("Volume") {
                    Slider(value: Binding(
                        get: { model.volume },
                        set: { model.setVolume($0) }
                    ), in: 0...100, step: 1)
                    .frame(width: 250)
                }
                Picker("Output device", selection: Binding(
                    get: { model.snapshot.audioDevices.first(where: \.selected)?.id ?? "" },
                    set: { model.setAudioDevice($0) }
                )) {
                    Text("Default Output").tag("")
                    ForEach(model.snapshot.audioDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct SubtitleSettingsPage: View {
    @Bindable var settings: NuraSettings
    let model: PlayerViewModel

    var body: some View {
        Form {
            Section("Language") {
                TextField("Preferred subtitle languages", text: $settings.preferredSubtitleLanguages)
                TextField("Online search language", text: $settings.subtitleSearchLanguage)
            }
            Section("OpenSubtitles") {
                SecureField("API key", text: $settings.openSubtitlesAPIKey)
                Button("Search Current Media", action: model.searchOnlineSubtitles)
                    .disabled(model.snapshot.item == nil || model.isSearchingOnlineSubtitles)
                if model.isSearchingOnlineSubtitles {
                    ProgressView()
                }
                ForEach(model.onlineSubtitleResults) { result in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(result.fileName).lineLimit(1)
                            Text(result.language)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Load") { model.loadOnlineSubtitle(result) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct NetworkSettingsPage: View {
    @Bindable var settings: NuraSettings

    var body: some View {
        Form {
            Section("Online Media") {
                Toggle("Enable yt-dlp for public video URLs", isOn: $settings.ytdlEnabled)
                TextField("HTTP proxy", text: $settings.httpProxy)
                TextField("User agent", text: $settings.userAgent)
            }
            Section("Cache") {
                Toggle("Enable cache", isOn: $settings.cacheEnabled)
                Stepper("Maximum cache: \(settings.cacheSizeKiB == 0 ? "Automatic" : "\(settings.cacheSizeKiB) KiB")", value: $settings.cacheSizeKiB, in: 0...1_048_576, step: 16_384)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AdvancedSettingsPage: View {
    @Bindable var settings: NuraSettings
    private let allowedOptions = ["deband", "interpolation", "scale", "cscale", "dscale", "video-sync"]

    var body: some View {
        Form {
            Section("libmpv Options") {
                ForEach($settings.advancedOptions) { $option in
                    HStack {
                        Picker("Option", selection: $option.key) {
                            ForEach(allowedOptions, id: \.self) { key in
                                Text(key).tag(key)
                            }
                        }
                        .labelsHidden()
                        TextField("Value", text: $option.value)
                        Button(role: .destructive) {
                            settings.advancedOptions.removeAll { $0.id == option.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove option")
                    }
                }
                Button {
                    guard let available = allowedOptions.first(where: { key in
                        !settings.advancedOptions.contains(where: { $0.key == key })
                    }) else {
                        return
                    }
                    settings.advancedOptions.append(AdvancedMpvOption(key: available, value: "yes"))
                } label: {
                    Label("Add Option", systemImage: "plus")
                }
                .disabled(settings.advancedOptions.count >= allowedOptions.count)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct HistorySettingsPage: View {
    let model: PlayerViewModel
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            List(model.snapshot.historyItems) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.item.source.isRemote ? "link" : "film")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.title).lineLimit(1)
                        Text(Date(timeIntervalSince1970: TimeInterval(entry.openedAtSeconds)), style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let resume = entry.resumeSeconds {
                        Text(format(resume))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.openRecent(entry.item)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Open")
                    Button(role: .destructive) {
                        model.removeHistoryItem(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            .overlay {
                if model.snapshot.historyItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                        Text("No Playback History")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(model.snapshot.historyItems.count) items")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", role: .destructive) { confirmClear = true }
                    .disabled(model.snapshot.historyItems.isEmpty)
            }
            .padding()
        }
        .alert("Clear Playback History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive, action: model.clearHistory)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct AboutSettingsPage: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"

    var body: some View {
        Form {
            Section("Nura") {
                LabeledContent("Version", value: version)
                LabeledContent("Playback engine", value: "libmpv")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private extension MediaSource {
    var isRemote: Bool {
        if case .publicURL = self { return true }
        return false
    }
}
