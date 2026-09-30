import Foundation

extension NowPlayingMonitor {
    /// Whether play/pause and scrubbing can reach this session.
    func canControl(_ session: NowPlayingSession) -> Bool {
        PlaybackRoute.route(for: session, deniedPlayers: deniedPlayers) != nil
    }

    func togglePlayPause(_ session: NowPlayingSession) {
        let now = Date()
        let playing = !session.isPlaying
        guard send(playing ? .play : .pause, to: session) else { return }
        expect(session.with(rate: playing ? 1 : 0, position: session.position(at: now), at: now), sentAt: now)
    }

    func seek(_ session: NowPlayingSession, to position: TimeInterval) {
        let now = Date()
        guard send(.seek(position), to: session) else { return }
        expect(session.with(rate: session.rate, position: position, at: now), sentAt: now)
    }

    /// Shows the command's result right away and holds it against stale or
    /// stray reports (see PendingPlayback). When the hold runs out the latest
    /// real report shows again, which undoes it if the app ignored the command.
    private func expect(_ session: NowPlayingSession, sentAt now: Date) {
        pendingPlayback[session.id] = PendingPlayback(expected: session, sentAt: now)
        publish()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PendingPlayback.hold + 0.05))
            self?.publish()
        }
    }

    private func send(_ command: PlaybackCommand, to session: NowPlayingSession) -> Bool {
        guard let route = PlaybackRoute.route(for: session, deniedPlayers: deniedPlayers) else { return false }
        let bundleID = session.ownerBundleID
        switch route {
        case let .mediaRemote(pid):
            switch command {
            case .play: bridge?.send("play \(pid)")
            case .pause: bridge?.send("pause \(pid)")
            case let .seek(position): bridge?.send("seek \(pid) \(position)")
            }
        case .appleScript:
            ScriptedPlayer.perform(command, bundleID: bundleID) { [weak self] outcome in
                Task { @MainActor [weak self] in self?.scriptedCommandFinished(bundleID: bundleID, outcome) }
            }
        case let .browserTab(tab, flavor):
            Task { @MainActor [weak self, scanner] in
                let outcome = await scanner.perform(command, tab: tab, bundleID: bundleID, flavor: flavor)
                if outcome != .noMedia {
                    let reason = String(describing: outcome)
                    Self.logger
                        .error("Tab command to \(bundleID, privacy: .public) failed: \(reason, privacy: .public)")
                }
                // play() starts asynchronously; give the page a moment before
                // asking again so the answer can confirm the pending command.
                try? await Task.sleep(for: .milliseconds(300))
                await self?.probe(tab, bundleID: bundleID, flavor: flavor)
            }
        }
        return true
    }

    private func scriptedCommandFinished(bundleID: String, _ outcome: ScriptedPlayer.Outcome) {
        if case .notAuthorized = outcome {
            Self.logger.info("Automation denied for \(bundleID, privacy: .public)")
            deniedPlayers.insert(bundleID)
        }
    }
}
