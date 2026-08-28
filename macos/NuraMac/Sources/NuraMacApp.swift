import SwiftUI

@main
struct NuraMacApp: App {
    private let launchConfiguration = PlayerLaunchConfiguration.current

    var body: some Scene {
        WindowGroup("Nura") {
            PlayerView(launchConfiguration: launchConfiguration)
        }
        .defaultSize(width: 1080, height: 680)
        .windowStyle(.hiddenTitleBar)
    }
}
