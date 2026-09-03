import SwiftUI

@main
struct NuraMacApp: App {
    private let launchConfiguration: PlayerLaunchConfiguration
    @State private var settings: NuraSettings
    @State private var playerWindows: PlayerWindowManager
    @State private var mainModel: PlayerViewModel

    init() {
        let launchConfiguration = PlayerLaunchConfiguration.current
        self.launchConfiguration = launchConfiguration
        let settings = NuraSettings(defaults: launchConfiguration.defaults)
        let playerWindows = PlayerWindowManager(launchConfiguration: launchConfiguration, settings: settings)
        _settings = State(initialValue: settings)
        _playerWindows = State(initialValue: playerWindows)
        _mainModel = State(initialValue: playerWindows.makeInitialModel())
    }

    var body: some Scene {
        WindowGroup("Nura") {
            MainPlayerWindow(
                model: mainModel,
                playerWindows: playerWindows,
                keepControlsVisible: launchConfiguration.keepControlsVisible
            )
        }
        .defaultSize(width: 1080, height: 680)
        .windowStyle(.hiddenTitleBar)
        WindowGroup("Nura", id: "player", for: String.self) { sessionID in
            AdditionalPlayerWindow(
                sessionID: sessionID.wrappedValue,
                playerWindows: playerWindows,
                keepControlsVisible: launchConfiguration.keepControlsVisible
            )
        }
        .defaultSize(width: 1080, height: 680)
        .windowStyle(.hiddenTitleBar)
        Settings {
            NuraSettingsView(settings: settings, model: mainModel)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            NuraPlayerCommands(playerWindows: playerWindows, settings: settings)
        }
    }
}

private struct MainPlayerWindow: View {
    @Environment(\.openWindow) private var openWindow
    let model: PlayerViewModel
    let playerWindows: PlayerWindowManager
    let keepControlsVisible: Bool

    var body: some View {
        PlayerView(
            model: model,
            keepControlsVisible: keepControlsVisible,
            onWindowAvailable: { window in
                playerWindows.configure { sessionID in
                    openWindow(id: "player", value: sessionID)
                }
                playerWindows.register(window: window, model: model)
            }
        )
    }
}

private struct AdditionalPlayerWindow: View {
    let playerWindows: PlayerWindowManager
    @State private var model: PlayerViewModel
    private let keepControlsVisible: Bool

    init(sessionID: String?, playerWindows: PlayerWindowManager, keepControlsVisible: Bool) {
        self.playerWindows = playerWindows
        self.keepControlsVisible = keepControlsVisible
        _model = State(initialValue: playerWindows.makePlayerModel(for: sessionID))
    }

    var body: some View {
        PlayerView(
            model: model,
            keepControlsVisible: keepControlsVisible,
            onWindowAvailable: { window in
                playerWindows.register(window: window, model: model)
            }
        )
    }
}

private struct NuraPlayerCommands: Commands {
    let playerWindows: PlayerWindowManager
    let settings: NuraSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(playerWindows.openMenuTitle, action: playerWindows.openPanel)
                .keyboardShortcut("o", modifiers: [.command])
            Button(playerWindows.openURLMenuTitle) {
                showOpenURLPanel(open: playerWindows.openURL)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Menu("Open Recent") {
                if playerWindows.recentItems.isEmpty {
                    Text("No Recent Media")
                } else {
                    ForEach(Array(playerWindows.recentItems.enumerated()), id: \.offset) { _, item in
                        Button(item.title) {
                            playerWindows.openRecent(item)
                        }
                    }
                }
            }
        }
        CommandMenu("Playback") {
            Button("Play/Pause", action: { playerWindows.activeModel?.togglePlayback() })
                .keyboardShortcut(settings.keyEquivalent(for: .togglePlayback), modifiers: settings.modifiers(for: .togglePlayback))
            Button("Previous Item", action: { playerWindows.activeModel?.previous() })
                .keyboardShortcut(settings.keyEquivalent(for: .previousItem), modifiers: settings.modifiers(for: .previousItem))
            Button("Next Item", action: { playerWindows.activeModel?.next() })
                .keyboardShortcut(settings.keyEquivalent(for: .nextItem), modifiers: settings.modifiers(for: .nextItem))
            Divider()
            Button("Seek Backward") { playerWindows.activeModel?.seekRelative(-settings.shortSeekSeconds) }
                .keyboardShortcut(settings.keyEquivalent(for: .seekBackward), modifiers: settings.modifiers(for: .seekBackward))
            Button("Seek Forward") { playerWindows.activeModel?.seekRelative(settings.shortSeekSeconds) }
                .keyboardShortcut(settings.keyEquivalent(for: .seekForward), modifiers: settings.modifiers(for: .seekForward))
            Divider()
            Button("Take Screenshot", action: { playerWindows.activeModel?.screenshot() })
                .keyboardShortcut(settings.keyEquivalent(for: .screenshot), modifiers: settings.modifiers(for: .screenshot))
            Button("Toggle Full Screen", action: { playerWindows.activeModel?.toggleFullscreen() })
                .keyboardShortcut(settings.keyEquivalent(for: .toggleFullscreen), modifiers: settings.modifiers(for: .toggleFullscreen))
        }
        CommandMenu("Window") {
            Button("Picture in Picture", action: { playerWindows.activeModel?.togglePiP() })
        }
    }
}
