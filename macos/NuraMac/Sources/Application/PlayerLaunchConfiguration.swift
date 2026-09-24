import Foundation

@MainActor
struct PlayerLaunchConfiguration {
    let mediaURL: URL?
    let secondaryMediaURL: URL?
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
        secondaryMediaURL = value(after: "-e2e-secondary-media-path").map(URL.init(fileURLWithPath:))
        stateDirectory = value(after: "-e2e-state-dir").map(URL.init(fileURLWithPath:))

        if let suite = value(after: "-e2e-defaults-suite"), !suite.isEmpty, let isolatedDefaults = UserDefaults(suiteName: suite) {
            defaults = isolatedDefaults
        } else {
            defaults = .standard
        }

        keepControlsVisible = arguments.contains("-e2e-keep-controls-visible")
        disableWindowResize = arguments.contains("-e2e-disable-window-resize")
    }

    private init(
        mediaURL: URL?,
        secondaryMediaURL: URL?,
        stateDirectory: URL?,
        defaults: UserDefaults,
        keepControlsVisible: Bool,
        disableWindowResize: Bool
    ) {
        self.mediaURL = mediaURL
        self.secondaryMediaURL = secondaryMediaURL
        self.stateDirectory = stateDirectory
        self.defaults = defaults
        self.keepControlsVisible = keepControlsVisible
        self.disableWindowResize = disableWindowResize
    }

    var withoutInitialMedia: PlayerLaunchConfiguration {
        PlayerLaunchConfiguration(
            mediaURL: nil,
            secondaryMediaURL: nil,
            stateDirectory: stateDirectory,
            defaults: defaults,
            keepControlsVisible: keepControlsVisible,
            disableWindowResize: disableWindowResize
        )
    }
}
