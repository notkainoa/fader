import Foundation

extension NowPlayingMonitor {
    /// The cards shown under one app.
    func sessions(forBundleID bundleID: String) -> [NowPlayingSession] {
        sessions.filter { $0.ownerBundleID == bundleID }
    }

    func isExpanded(_ bundleID: String) -> Bool {
        expandedBrowsers.contains(bundleID)
    }

    func toggleExpanded(_ bundleID: String) {
        if expandedBrowsers.remove(bundleID) == nil {
            expandedBrowsers.insert(bundleID)
        } else if let kept = shownWhileOpen[bundleID] {
            // Otherwise every card shown while expanded would stay kept.
            shownWhileOpen[bundleID] = Array(kept.prefix(NowPlayingSelection.collapsedLimit))
        }
        publish()
    }

    /// The popover opened: the browser cards on screen stay until it closes.
    func keepShownCards() {
        shownWhileOpen = Dictionary(grouping: sessions.filter { BrowserFlavor.supported[$0.ownerBundleID] != nil },
                                    by: \.ownerBundleID).mapValues { $0.map(\.id) }
    }

    /// The popover closed: cards follow the plain rule again, collapsed.
    func releaseShownCards() {
        shownWhileOpen.removeAll()
        if !expandedBrowsers.isEmpty { expandedBrowsers.removeAll() }
        publish()
    }

    /// When each session (by id) last played: tabs as their planner saw
    /// them, browsers' own sessions as MediaRemote reported them.
    func playedDates(tabs: some Sequence<TabProbePlanner.Candidate>,
                     mediaRemote: [NowPlayingSession]) -> [String: Date] {
        var played: [String: Date] = [:]
        for candidate in tabs {
            played[candidate.session.id] = candidate.played
        }
        for session in mediaRemote {
            played[session.id] = recentMediaRemoteTitles[session.ownerBundleID]?[
                NowPlayingMerge.normalized(session.title)
            ]
        }
        return played
    }

    /// Ids of playing sessions keep the time they were first seen playing;
    /// a pause forgets it.
    func updatePlayingSince(_ sessions: [NowPlayingSession], now: Date) {
        let playing = Set(sessions.filter(\.isPlaying).map(\.id))
        playingSince = playingSince.filter { playing.contains($0.key) }
        for id in playing where playingSince[id] == nil {
            playingSince[id] = now
        }
    }

    /// Other apps' sessions pass through; each browser's go through
    /// NowPlayingSelection. Records what is on screen while the popover is
    /// open, and how many cards each browser hides.
    func selectBrowserCards(_ sessions: [NowPlayingSession], played: [String: Date]) -> [NowPlayingSession] {
        var result = sessions.filter { BrowserFlavor.supported[$0.ownerBundleID] == nil }
        var overflow: [String: Int] = [:]
        var stillExpanded: Set<String> = []
        let byBrowser = Dictionary(grouping: sessions.filter { BrowserFlavor.supported[$0.ownerBundleID] != nil },
                                   by: \.ownerBundleID)
        for (bundleID, browserSessions) in byBrowser.sorted(by: { $0.key < $1.key }) {
            let expanded = expandedBrowsers.contains(bundleID)
            let selection = NowPlayingSelection.select(
                browserSessions, played: played, playingSince: playingSince, expanded: expanded,
                kept: isPopoverVisible ? shownWhileOpen[bundleID] ?? [] : nil
            )
            result += selection.shown
            if selection.hiddenCount > 0 { overflow[bundleID] = selection.hiddenCount }
            if isPopoverVisible { shownWhileOpen[bundleID] = selection.shown.map(\.id) }
            // Down to what fits collapsed: the next overflow starts collapsed.
            if expanded, selection.shown.count > NowPlayingSelection.collapsedLimit {
                stillExpanded.insert(bundleID)
            }
        }
        if overflow != overflowCounts { overflowCounts = overflow }
        if stillExpanded != expandedBrowsers { expandedBrowsers = stillExpanded }
        return result
    }
}
