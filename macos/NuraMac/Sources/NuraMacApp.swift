import SwiftUI

@main
struct NuraMacApp: App {
    private let launchConfiguration: PlayerLaunchConfiguration
    @StateObject private var model: PlayerViewModel

    init() {
        let launchConfiguration = PlayerLaunchConfiguration.current
        self.launchConfiguration = launchConfiguration
        _model = StateObject(wrappedValue: PlayerViewModel(launchConfiguration: launchConfiguration))
    }

    var body: some Scene {
        WindowGroup("Nura") {
            PlayerView(model: model, keepControlsVisible: launchConfiguration.keepControlsVisible)
        }
        .defaultSize(width: 1080, height: 680)
        .windowStyle(.hiddenTitleBar)
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
        }
    }
}
