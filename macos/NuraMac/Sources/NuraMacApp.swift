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
        .windowResizability(.contentMinSize)
        WindowGroup("Nura", id: "player", for: String.self) { sessionID in
            AdditionalPlayerWindow(
                sessionID: sessionID.wrappedValue,
                playerWindows: playerWindows,
                keepControlsVisible: launchConfiguration.keepControlsVisible
            )
        }
        .defaultSize(width: 1080, height: 680)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
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
            onOpenPanel: playerWindows.openPanel,
            onOpenInNewWindow: playerWindows.openInNewWindow,
            onWindowAvailable: { window in
                playerWindows.configure { sessionID in
                    openWindow(id: "player", value: sessionID)
                }
                playerWindows.register(window: window, model: model)
            }
        )
        .frame(minWidth: 600, minHeight: 360)
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
            onOpenPanel: playerWindows.openPanel,
            onOpenInNewWindow: playerWindows.openInNewWindow,
            onWindowAvailable: { window in
                playerWindows.register(window: window, model: model)
            }
        )
        .frame(minWidth: 600, minHeight: 360)
    }
}

private struct NuraPlayerCommands: Commands {
    let playerWindows: PlayerWindowManager
    let settings: NuraSettings
    private let playbackSpeedValues = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

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
                .disabled(!(playerWindows.activeModel?.canPlaybackControl ?? false))
                .keyboardShortcut(settings.keyEquivalent(for: .togglePlayback), modifiers: settings.modifiers(for: .togglePlayback))
            Button("Previous Item", action: { playerWindows.activeModel?.previous() })
                .disabled(!(playerWindows.activeModel?.canNavigateItems ?? false))
                .keyboardShortcut(settings.keyEquivalent(for: .previousItem), modifiers: settings.modifiers(for: .previousItem))
            Button("Next Item", action: { playerWindows.activeModel?.next() })
                .disabled(!(playerWindows.activeModel?.canNavigateItems ?? false))
                .keyboardShortcut(settings.keyEquivalent(for: .nextItem), modifiers: settings.modifiers(for: .nextItem))
            Divider()
            Button("Next Frame", action: { playerWindows.activeModel?.frameStep() })
                .disabled(!(playerWindows.activeModel?.canFrameStep ?? false))
                .keyboardShortcut(settings.keyEquivalent(for: .frameStep), modifiers: settings.modifiers(for: .frameStep))
            Button("Previous Frame", action: { playerWindows.activeModel?.frameBackStep() })
                .disabled(!(playerWindows.activeModel?.canFrameStep ?? false))
                .keyboardShortcut(settings.keyEquivalent(for: .frameBackStep), modifiers: settings.modifiers(for: .frameBackStep))
            Divider()
            Menu("Playback Speed") {
                ForEach(playbackSpeedValues, id: \.self) { value in
                    Button {
                        playerWindows.activeModel?.setSpeed(value)
                    } label: {
                        HStack {
                            Text(speedLabel(for: value))
                            if abs((playerWindows.activeModel?.snapshot.speed ?? 0) - value) < 0.001 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .disabled(playerWindows.activeModel == nil)
            Button(L10n.format("Seek Backward %d Seconds", Int(settings.shortSeekSeconds))) { playerWindows.activeModel?.seekRelative(-settings.shortSeekSeconds) }
                .disabled(!(playerWindows.activeModel?.canSeek ?? false))
                .keyboardShortcut(settings.keyEquivalent(for: .seekBackward), modifiers: settings.modifiers(for: .seekBackward))
            Button(L10n.format("Seek Forward %d Seconds", Int(settings.shortSeekSeconds))) { playerWindows.activeModel?.seekRelative(settings.shortSeekSeconds) }
                .disabled(!(playerWindows.activeModel?.canSeek ?? false))
                .keyboardShortcut(settings.keyEquivalent(for: .seekForward), modifiers: settings.modifiers(for: .seekForward))
            Divider()
            Button(playerWindows.activeModel?.abLoopLabel ?? "Set Loop Start") {
                playerWindows.activeModel?.advanceABLoop()
            }
            .disabled(!(playerWindows.activeModel?.canAdvanceABLoop ?? false))
            .keyboardShortcut("l", modifiers: [.option])
            Button("Toggle Full Screen", action: { playerWindows.activeModel?.toggleFullscreen() })
                .keyboardShortcut(settings.keyEquivalent(for: .toggleFullscreen), modifiers: settings.modifiers(for: .toggleFullscreen))
            Divider()
            Menu("Screenshot") {
                Button("Take Screenshot", action: { playerWindows.activeModel?.screenshot() })
                    .disabled(!(playerWindows.activeModel?.canScreenshot ?? false))
                    .keyboardShortcut(settings.keyEquivalent(for: .screenshot), modifiers: settings.modifiers(for: .screenshot))
                Button("Copy Screenshot", action: { playerWindows.activeModel?.copyScreenshot() })
                    .disabled(!(playerWindows.activeModel?.canScreenshot ?? false))
                    .keyboardShortcut(settings.keyEquivalent(for: .copyScreenshot), modifiers: settings.modifiers(for: .copyScreenshot))
                Button("Choose Screenshot Folder", action: { playerWindows.activeModel?.chooseScreenshotDirectory() })
                    .keyboardShortcut(settings.keyEquivalent(for: .chooseScreenshotFolder), modifiers: settings.modifiers(for: .chooseScreenshotFolder))
            }
        }
        CommandMenu("Notes") {
            Button("New Note", action: { playerWindows.activeModel?.beginNoteCapture() })
                .disabled(!(playerWindows.activeModel?.canUseLocalTranscriptTools ?? false))
                .keyboardShortcut("n", modifiers: [.command])
        }
    }

    private func speedLabel(for value: Double) -> String {
        value == 1.0 ? "1x" : "\(value)x"
    }
}
