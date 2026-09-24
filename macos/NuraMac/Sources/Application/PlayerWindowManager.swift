import AppKit
import Observation

@MainActor
@Observable
final class PlayerWindowManager {
    private(set) var activeModel: PlayerViewModel?

    private let launchConfiguration: PlayerLaunchConfiguration
    private let settings: NuraSettings
    private var models: [ObjectIdentifier: PlayerViewModel] = [:]
    private var pendingModels: [String: PlayerViewModel] = [:]
    private var windowObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var openedSecondaryMediaForTesting = false
    private var openPlayerWindow: ((String) -> Void)?
    private var cachedRecentItems: [MediaItem] = []

    init(launchConfiguration: PlayerLaunchConfiguration, settings: NuraSettings) {
        self.launchConfiguration = launchConfiguration
        self.settings = settings
    }

    var recentItems: [MediaItem] {
        activeModel?.snapshot.recentItems ?? cachedRecentItems
    }

    var openMenuTitle: String {
        activeModel?.snapshot.item == nil ? L10n.text("Open…") : L10n.text("Open in New Window…")
    }

    var openURLMenuTitle: String {
        activeModel?.snapshot.item == nil ? L10n.text("Open URL…") : L10n.text("Open URL in New Window…")
    }

    func makeInitialModel() -> PlayerViewModel {
        PlayerViewModel(launchConfiguration: launchConfiguration, settings: settings)
    }

    func makePlayerModel(for sessionID: String?) -> PlayerViewModel {
        guard let sessionID, let model = pendingModels[sessionID] else {
            return PlayerViewModel(
                launchConfiguration: launchConfiguration.withoutInitialMedia,
                settings: settings
            )
        }
        return model
    }

    func configure(openPlayerWindow: @escaping (String) -> Void) {
        self.openPlayerWindow = openPlayerWindow
    }

    func register(window: NSWindow, model: PlayerViewModel) {
        let identifier = ObjectIdentifier(window)
        guard models[identifier] !== model else { return }

        models[identifier] = model
        model.attach(to: window)
        observe(window: window, identifier: identifier)
        activeModel = model
        openSecondaryMediaForTestingIfNeeded()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let expandedURLs = PlayerViewModel.expandMediaURLs(panel.urls)
        guard let first = expandedURLs.first else {
            targetModel?.openExpandedMediaURLs([])
            return
        }
        let requestedURL = panel.urls.count == 1 ? panel.urls[0] : nil
        guard let destination = resolveDestination(
            opensDifferentMedia: targetModel?.shouldOpenInNewWindow(for: requestedURL ?? first) ?? false
        ) else { return }
        destination.openExpandedMediaURLs(expandedURLs)
    }

    func openURL(_ value: String) {
        guard let destination = resolveDestination(
            opensDifferentMedia: targetModel?.shouldOpenInNewWindow(forURL: value) ?? false
        ) else { return }
        destination.openURL(value)
    }

    func openRecent(_ item: MediaItem) {
        guard let destination = resolveDestination(
            opensDifferentMedia: targetModel?.shouldOpenInNewWindow(for: item) ?? false
        ) else { return }
        destination.openRecent(item)
    }

    func openInNewWindow(_ item: MediaItem) {
        guard let newModel = makePlayerWindow() else { return }
        switch item.source {
        case .localFile(let path): newModel.open(URL(fileURLWithPath: path))
        case .publicURL(let value): newModel.openURL(value)
        }
    }

    private var targetModel: PlayerViewModel? {
        activeModel ?? models.values.first
    }

    private func resolveDestination(opensDifferentMedia: Bool) -> PlayerViewModel? {
        if opensDifferentMedia, let newModel = makePlayerWindow() {
            return newModel
        }
        if let model = targetModel {
            return model
        }
        return makePlayerWindow()
    }

    private func makePlayerWindow() -> PlayerViewModel? {
        let model = PlayerViewModel(
            launchConfiguration: launchConfiguration.withoutInitialMedia,
            settings: settings
        )
        guard let openPlayerWindow else { return nil }
        let sessionID = UUID().uuidString
        pendingModels[sessionID] = model
        openPlayerWindow(sessionID)
        return model
    }

    private func observe(window: NSWindow, identifier: ObjectIdentifier) {
        let center = NotificationCenter.default
        let becameKey = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            Task { @MainActor in
                self.activeModel = self.models[ObjectIdentifier(window)]
            }
        }
        let willClose = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            Task { @MainActor in
                self.unregister(window: window)
            }
        }
        windowObservers[identifier] = [becameKey, willClose]
    }

    private func unregister(window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        let model = models.removeValue(forKey: identifier)
        if let model {
            pendingModels = pendingModels.filter { $0.value !== model }
            cachedRecentItems = model.snapshot.recentItems
        }
        model?.detachWindow()
        for observer in windowObservers.removeValue(forKey: identifier) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        if activeModel === model {
            activeModel = models.values.first
        }
    }

    private func openSecondaryMediaForTestingIfNeeded() {
        guard !openedSecondaryMediaForTesting,
              models.count == 1,
              let url = launchConfiguration.secondaryMediaURL,
              let model = makePlayerWindow() else { return }
        openedSecondaryMediaForTesting = true
        model.open(url)
    }
}
