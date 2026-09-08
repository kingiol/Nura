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

    init(launchConfiguration: PlayerLaunchConfiguration, settings: NuraSettings) {
        self.launchConfiguration = launchConfiguration
        self.settings = settings
    }

    var recentItems: [MediaItem] {
        activeModel?.snapshot.recentItems ?? []
    }

    var openMenuTitle: String {
        activeModel?.snapshot.item == nil ? "Open…" : "Open in New Window…"
    }

    var openURLMenuTitle: String {
        activeModel?.snapshot.item == nil ? "Open URL…" : "Open URL in New Window…"
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
        guard let model = targetModel else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            open(panel.urls, from: model)
        }
    }

    func openURL(_ value: String) {
        guard let model = targetModel else { return }
        let destination = destination(
            from: model,
            opensDifferentMedia: model.shouldOpenInNewWindow(forURL: value)
        )
        destination.openURL(value)
    }

    func openRecent(_ item: MediaItem) {
        guard let model = targetModel else { return }
        let destination = destination(
            from: model,
            opensDifferentMedia: model.shouldOpenInNewWindow(for: item)
        )
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

    private func open(_ urls: [URL], from model: PlayerViewModel) {
        let requestedURL = urls.count == 1 ? urls[0] : nil
        let expandedURLs = PlayerViewModel.expandMediaURLs(urls)
        guard let first = expandedURLs.first else {
            model.openExpandedMediaURLs([])
            return
        }
        let destination = destination(
            from: model,
            opensDifferentMedia: model.shouldOpenInNewWindow(for: requestedURL ?? first)
        )
        destination.openExpandedMediaURLs(expandedURLs)
    }

    private func destination(from model: PlayerViewModel, opensDifferentMedia: Bool) -> PlayerViewModel {
        guard opensDifferentMedia, let newModel = makePlayerWindow() else { return model }
        return newModel
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
