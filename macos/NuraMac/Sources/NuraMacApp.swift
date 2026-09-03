import SwiftUI

@main
struct NuraMacApp: App {
    private let launchConfiguration: PlayerLaunchConfiguration
    @StateObject private var settings: NuraSettings
    @StateObject private var model: PlayerViewModel

    init() {
        let launchConfiguration = PlayerLaunchConfiguration.current
        self.launchConfiguration = launchConfiguration
        let settings = NuraSettings(defaults: launchConfiguration.defaults)
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(
            wrappedValue: PlayerViewModel(launchConfiguration: launchConfiguration, settings: settings)
        )
    }

    var body: some Scene {
        WindowGroup("Nura") {
            PlayerView(model: model, keepControlsVisible: launchConfiguration.keepControlsVisible)
        }
        .defaultSize(width: 1080, height: 680)
        .windowStyle(.hiddenTitleBar)
        Settings {
            NuraSettingsView(settings: settings, model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…", action: model.openPanel)
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Open URL…") {
                    showOpenURLPanel(model: model)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Menu("Open Recent") {
                    if model.snapshot.recentItems.isEmpty {
                        Text("No Recent Media")
                    } else {
                        ForEach(Array(model.snapshot.recentItems.enumerated()), id: \.offset) { _, item in
                            Button(item.title) {
                                model.openRecent(item)
                            }
                        }
                    }
                }
            }
            CommandMenu("Playback") {
                Button("Play/Pause", action: model.togglePlayback)
                    .keyboardShortcut(settings.keyEquivalent(for: .togglePlayback), modifiers: settings.modifiers(for: .togglePlayback))
                Button("Previous Item", action: model.previous)
                    .keyboardShortcut(settings.keyEquivalent(for: .previousItem), modifiers: settings.modifiers(for: .previousItem))
                Button("Next Item", action: model.next)
                    .keyboardShortcut(settings.keyEquivalent(for: .nextItem), modifiers: settings.modifiers(for: .nextItem))
                Divider()
                Button("Seek Backward") { model.seekRelative(-settings.shortSeekSeconds) }
                    .keyboardShortcut(settings.keyEquivalent(for: .seekBackward), modifiers: settings.modifiers(for: .seekBackward))
                Button("Seek Forward") { model.seekRelative(settings.shortSeekSeconds) }
                    .keyboardShortcut(settings.keyEquivalent(for: .seekForward), modifiers: settings.modifiers(for: .seekForward))
                Divider()
                Button("Take Screenshot", action: model.screenshot)
                    .keyboardShortcut(settings.keyEquivalent(for: .screenshot), modifiers: settings.modifiers(for: .screenshot))
                Button("Toggle Full Screen", action: model.toggleFullscreen)
                    .keyboardShortcut(settings.keyEquivalent(for: .toggleFullscreen), modifiers: settings.modifiers(for: .toggleFullscreen))
            }
        }
    }
}
