import Foundation

@MainActor
struct PlayerLaunchConfiguration {
    let mediaURL: URL?
    let stateDirectory: URL?
    let defaults: UserDefaults
    let keepControlsVisible: Bool
    let disableWindowResize: Bool

    static let current = PlayerLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        mediaURL = value(after: "-e2e-media-path").map(URL.init(fileURLWithPath:))
        stateDirectory = value(after: "-e2e-state-dir").map(URL.init(fileURLWithPath:))

        if let suite = value(after: "-e2e-defaults-suite"), !suite.isEmpty, let isolatedDefaults = UserDefaults(suiteName: suite) {
            defaults = isolatedDefaults
        } else {
            defaults = .standard
        }

        keepControlsVisible = arguments.contains("-e2e-keep-controls-visible")
        disableWindowResize = arguments.contains("-e2e-disable-window-resize")
    }
}
