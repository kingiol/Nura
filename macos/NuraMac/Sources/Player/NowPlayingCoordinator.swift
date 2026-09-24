import MediaPlayer

@MainActor
final class NowPlayingCoordinator {
    private weak var model: PlayerViewModel?

    init(model: PlayerViewModel) {
        self.model = model
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak model] _ in
            Task { @MainActor in model?.togglePlayback() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak model] _ in
            Task { @MainActor in model?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak model] _ in
            Task { @MainActor in model?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak model] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in model?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    func update(snapshot: PlaybackSnapshot, enabled: Bool) {
        guard enabled, let item = snapshot.item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status == "playing" ? snapshot.speed : 0,
        ]
        if let duration = snapshot.durationSeconds {
            information[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = information
    }
}
