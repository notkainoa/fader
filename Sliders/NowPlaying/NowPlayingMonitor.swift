import AppKit
import Observation
import os

/// Everything playing right now, per app: MediaRemote clients (one per app,
/// what Control Center draws from) merged with per-tab sessions scanned from
/// scriptable browsers. Control Center shows only one; the popover shows all.
@MainActor
@Observable
final class NowPlayingMonitor {
    static let logger = Logger(subsystem: "me.kainoa.sliders", category: "NowPlayingMonitor")
    private static let scanInterval: Duration = .seconds(2)
    /// While the popover is closed, tabs are still checked now and then so
    /// the cards are already there when it opens.
    private static let backgroundScanInterval: Duration = .seconds(30)
    private static let dismissedHintsKey = "dismissedJavaScriptHints"

    private(set) var sessions: [NowPlayingSession] = []
    internal(set) var artwork: [String: NSImage] = [:]
    /// Browsers that need JavaScript from Apple Events turned on before
    /// their tabs can be listed one by one.
    private(set) var browsersNeedingJavaScript: Set<String> = []
    /// Apps whose media was just paused but whose audio output hasn't closed
    /// yet; their rows dim anyway (see PausedAudio).
    private(set) var pausedAudioBundleIDs: Set<String> = []
    /// Browsers whose JavaScript hint the user closed; it stays hidden.
    private(set) var dismissedJavaScriptHints = Set(
        UserDefaults.standard.stringArray(forKey: NowPlayingMonitor.dismissedHintsKey) ?? []
    )
    /// Media apps the user declined Automation access for; their sessions
    /// can't be controlled unless they are the elected now-playing app.
    internal(set) var deniedPlayers: Set<String> = []
    /// Per browser, how many cards wait behind its "Show more" toggle.
    internal(set) var overflowCounts: [String: Int] = [:]
    /// Browsers whose cards the user expanded; collapsed when the popover
    /// closes.
    internal(set) var expandedBrowsers: Set<String> = []
    /// Apps with a playing session, shown or not.
    private(set) var playingBundleIDs: Set<String> = []

    /// Bundle IDs of apps currently producing sound, for deciding which
    /// browsers are worth scanning.
    @ObservationIgnored var audibleBundleIDs: () -> Set<String> = { [] }

    @ObservationIgnored var mediaRemoteSessions: [NowPlayingSession] = []
    @ObservationIgnored private var tabPlanners: [String: TabProbePlanner] = [:]
    /// Per browser, normalized titles MediaRemote has reported and when each
    /// last played. The helper runs even while the popover is closed, so
    /// this remembers what was played between scans.
    @ObservationIgnored private(set) var recentMediaRemoteTitles: [String: [String: Date]] = [:]
    @ObservationIgnored var bridge: MediaRemoteBridge?
    @ObservationIgnored let scanner = BrowserTabScanner()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isPopoverVisible = false
    /// Commands awaiting confirmation, keyed by session id.
    @ObservationIgnored var pendingPlayback: [String: PendingPlayback] = [:]
    /// When each playing session (by id) started playing.
    @ObservationIgnored var playingSince: [String: Date] = [:]
    /// Per browser, the card ids on screen since the popover opened, in
    /// order; empty while it is closed.
    @ObservationIgnored var shownWhileOpen: [String: [String]] = [:]
    @ObservationIgnored private var deniedBrowsers: Set<String> = []
    @ObservationIgnored var artworkLoads: Set<String> = []
    /// Artwork URLs that failed to load, and when; retried after a while.
    @ObservationIgnored var failedArtwork: [String: Date] = [:]

    #if RENDER_SHOTS
        /// Render harness only: publish demo sessions without any helper process.
        func seedForRender(sessions: [NowPlayingSession], artwork: [String: NSImage] = [:]) {
            self.sessions = sessions
            self.artwork = artwork
            playingBundleIDs = Set(sessions.filter(\.isPlaying).map(\.ownerBundleID))
        }
    #endif

    func start() {
        guard bridge == nil else { return }
        let bridge = MediaRemoteBridge { [weak self] clients in
            Task { @MainActor in self?.receive(clients) }
        }
        self.bridge = bridge
        bridge.start()
        restartScans(waitFirst: true)
    }

    func stop() {
        bridge?.stop()
        bridge = nil
        scanTask?.cancel()
        scanTask = nil
    }

    /// Browser tabs are scanned every couple of seconds while the popover is
    /// on screen and only occasionally while it is closed: each scan runs a
    /// script in every awake tab.
    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        if visible {
            // Reopening is the natural moment to retry after the user changed
            // a browser setting or an Automation permission.
            // browsersNeedingJavaScript stays: the first scan clears an entry
            // once the setting is on, and dropping it here would pop the hint
            // out and back in (shifting the list) on every open.
            deniedBrowsers.removeAll()
            deniedPlayers.removeAll()
            bridge?.retryIfNeeded()
            keepShownCards()
        } else {
            releaseShownCards()
        }
        restartScans(waitFirst: !visible)
    }

    private func restartScans(waitFirst: Bool) {
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            if waitFirst { try? await Task.sleep(for: Self.backgroundScanInterval, tolerance: .seconds(5)) }
            while !Task.isCancelled {
                await self?.scanBrowsers()
                if self?.isPopoverVisible == true {
                    try? await Task.sleep(for: Self.scanInterval, tolerance: .milliseconds(300))
                } else {
                    try? await Task.sleep(for: Self.backgroundScanInterval, tolerance: .seconds(5))
                }
            }
        }
    }

    // MARK: - Sources

    private func receive(_ clients: [MediaRemoteClientInfo]) {
        let now = Date()
        mediaRemoteSessions = clients.compactMap { client in
            if let key = client.artworkKey, let base64 = client.artwork,
               let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                artwork[key] = image
            }
            guard let owner = ownerBundleID(of: client), owner != Bundle.main.bundleIdentifier else { return nil }
            return client.session(ownerBundleID: owner, now: now)
        }
        rememberMediaRemoteTitles(now: now)
        publish()
    }

    private func rememberMediaRemoteTitles(now: Date) {
        for session in mediaRemoteSessions where BrowserFlavor.supported[session.ownerBundleID] != nil {
            let title = NowPlayingMerge.normalized(session.title)
            var titles = recentMediaRemoteTitles[session.ownerBundleID] ?? [:]
            // A paused session seen for the first time was still the last
            // thing played in that browser, so it counts as played now.
            guard session.isPlaying || titles[title] == nil else { continue }
            titles[title] = now
            if titles.count > NowPlayingSelection.collapsedLimit * 4,
               let oldest = titles.min(by: { $0.value < $1.value })?.key {
                titles[oldest] = nil
            }
            recentMediaRemoteTitles[session.ownerBundleID] = titles
        }
    }

    /// Media helpers (WebKit's GPU process, Electron renderers) register as
    /// their own clients; attribute them to the app the user knows, the same
    /// way the audio process list does.
    private func ownerBundleID(of client: MediaRemoteClientInfo) -> String? {
        let owner = AudioProcessMonitor.responsiblePID(for: client.pid)
        if let bundleID = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier {
            return bundleID
        }
        return client.parentBundleID ?? client.bundleID
    }

    private func scanBrowsers() async {
        let candidates = Set(mediaRemoteSessions.map(\.ownerBundleID))
            .union(audibleBundleIDs())
            .union(tabPlanners.keys)
        var browsers = candidates
            .filter { BrowserFlavor.supported[$0] != nil && !deniedBrowsers.contains($0) }
            .filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        if !isPopoverVisible {
            // The first scan of a browser asks for Automation access; that
            // prompt should follow opening the popover, not appear on its own.
            var allowed: Set<String> = []
            for bundleID in browsers where await scanner.isAutomationAllowed(bundleID: bundleID) {
                allowed.insert(bundleID)
            }
            guard !Task.isCancelled else { return }
            browsers = allowed
        }

        for gone in Set(tabPlanners.keys).subtracting(browsers) {
            tabPlanners[gone] = nil
        }
        let quitBrowsers = browsersNeedingJavaScript.subtracting(browsers)
        if !quitBrowsers.isEmpty { browsersNeedingJavaScript.subtract(quitBrowsers) }
        publish()

        for bundleID in browsers.sorted() {
            guard let flavor = BrowserFlavor.supported[bundleID] else { continue }
            await scanTabs(of: bundleID, flavor: flavor)
            guard !Task.isCancelled else { return }
        }
    }

    /// Lists the browser's tabs, then asks the due ones for media several at
    /// a time, publishing each answer as it arrives.
    private func scanTabs(of bundleID: String, flavor: BrowserFlavor) async {
        let tabs: [BrowserTab]
        switch await scanner.listTabs(bundleID: bundleID, flavor: flavor) {
        case let .tabs(list):
            tabs = list
        case .notAuthorized:
            denyAutomation(for: bundleID)
            return
        case .failed:
            // A busy browser; keep the last results rather than flicker.
            return
        }
        guard !Task.isCancelled, !deniedBrowsers.contains(bundleID) else { return }

        let preferred = Set(mediaRemoteSessions.filter { $0.ownerBundleID == bundleID }
            .map { NowPlayingMerge.normalized($0.title) })
        var planner = tabPlanners[bundleID] ?? TabProbePlanner(ownerBundleID: bundleID)
        let due = planner.plan(tabs: tabs, preferredTitles: preferred, now: Date())
        tabPlanners[bundleID] = planner
        publish()

        let started = Date()
        let timeouts = await probe(due, bundleID: bundleID, flavor: flavor)
        Self.logger.debug("""
        Scanned \(bundleID, privacy: .public): \(tabs.count) tabs, asked \(due.count), \
        \(timeouts) timed out, \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s
        """)
        guard !Task.isCancelled else { return }
        updateJavaScriptHint(for: bundleID)
    }

    /// Asks the tabs several at a time, applying each answer as it arrives.
    /// Returns how many timed out.
    private func probe(_ due: [BrowserTab], bundleID: String, flavor: BrowserFlavor) async -> Int {
        var timeouts = 0
        await withTaskGroup(of: (BrowserTabRef, TabProbeOutcome).self) { [scanner] group in
            var queue = due[...]
            var running = 0
            while true {
                while running < BrowserTabScanner.maxConcurrentProbes, !Task.isCancelled,
                      !deniedBrowsers.contains(bundleID), let tab = queue.popFirst() {
                    group.addTask { await (tab.ref, scanner.probe(tab.ref, bundleID: bundleID, flavor: flavor)) }
                    running += 1
                }
                guard let (ref, outcome) = await group.next() else { break }
                running -= 1
                // A replaced scan's probes still finish; a newer scan owns
                // the planner now.
                guard !Task.isCancelled else { continue }
                if outcome == .timedOut { timeouts += 1 }
                apply(outcome, to: ref, bundleID: bundleID)
            }
        }
        return timeouts
    }

    private func updateJavaScriptHint(for bundleID: String) {
        let needsJavaScript = tabPlanners[bundleID]?.hasBlockedTabs ?? false
        // Guarded: an @Observable set notifies on every write, and this runs
        // every scan.
        guard needsJavaScript != browsersNeedingJavaScript.contains(bundleID) else { return }
        if needsJavaScript {
            browsersNeedingJavaScript.insert(bundleID)
        } else {
            browsersNeedingJavaScript.remove(bundleID)
        }
    }

    func probe(_ tab: BrowserTabRef, bundleID: String, flavor: BrowserFlavor) async {
        guard tabPlanners[bundleID] != nil else { return }
        await apply(scanner.probe(tab, bundleID: bundleID, flavor: flavor), to: tab, bundleID: bundleID)
    }

    private func apply(_ outcome: TabProbeOutcome, to tab: BrowserTabRef, bundleID: String) {
        if outcome == .notAuthorized {
            denyAutomation(for: bundleID)
            return
        }
        guard tabPlanners[bundleID] != nil else { return }
        tabPlanners[bundleID]?.record(outcome, for: tab, now: Date())
        publish()
    }

    private func denyAutomation(for bundleID: String) {
        Self.logger.info("Automation denied for \(bundleID, privacy: .public)")
        deniedBrowsers.insert(bundleID)
        tabPlanners[bundleID] = nil
        publish()
    }

    func publish() {
        let now = Date()
        let candidates = tabPlanners.mapValues {
            $0.candidates(recentTitles: recentMediaRemoteTitles[$0.ownerBundleID] ?? [:], now: now)
        }
        let tabs = candidates.mapValues { $0.map(\.session) }
        var hiddenTabTitles: [String: Set<String>] = [:]
        for (bundleID, planner) in tabPlanners {
            let shown = Set((tabs[bundleID] ?? []).map { NowPlayingMerge.normalized($0.title) })
            hiddenTabTitles[bundleID] = planner.knownTitles.subtracting(shown)
        }
        // A browser's own now-playing session follows the same rule as its
        // tabs: a paused one goes away `pausedLifetime` after it last played, even
        // when its tab is asleep and can't be matched.
        let mediaRemote = mediaRemoteSessions.filter { session in
            guard !session.isPlaying, BrowserFlavor.supported[session.ownerBundleID] != nil,
                  let played = recentMediaRemoteTitles[session.ownerBundleID]?[
                      NowPlayingMerge.normalized(session.title)
                  ]
            else { return true }
            return now.timeIntervalSince(played) < TabProbePlanner.pausedLifetime
        }
        pendingPlayback = pendingPlayback.filter { $0.value.expires > now }
        let merged = PendingPlayback.apply(
            pendingPlayback,
            to: NowPlayingMerge.merge(mediaRemote: mediaRemote, tabs: tabs, hiddenTabTitles: hiddenTabTitles,
                                      embeds: tabPlanners.mapValues(\.embeds)),
            at: now
        )
        updatePlayingSince(merged, now: now)
        let played = playedDates(tabs: candidates.values.joined(), mediaRemote: mediaRemote)
        let selected = selectBrowserCards(merged, played: played)
        if selected != sessions { sessions = selected }

        let playing = Set(merged.filter(\.isPlaying).map(\.ownerBundleID))
        if playing != playingBundleIDs {
            updatePausedAudio(wasPlaying: playingBundleIDs, isPlaying: playing)
            playingBundleIDs = playing
        }
        loadMissingArtwork()
        pruneArtwork()
    }
}

// MARK: - Hints and paused audio

extension NowPlayingMonitor {
    func shouldShowJavaScriptHint(for bundleID: String) -> Bool {
        browsersNeedingJavaScript.contains(bundleID) && !dismissedJavaScriptHints.contains(bundleID)
    }

    func dismissJavaScriptHint(for bundleID: String) {
        dismissedJavaScriptHints.insert(bundleID)
        UserDefaults.standard.set(dismissedJavaScriptHints.sorted(), forKey: Self.dismissedHintsKey)
    }

    /// Called when Core Audio's per-app playing flags change, so an app drops
    /// out of `pausedAudioBundleIDs` once its output stream closes.
    func audioStateChanged() {
        guard !pausedAudioBundleIDs.isEmpty else { return }
        updatePausedAudio(wasPlaying: playingBundleIDs, isPlaying: playingBundleIDs)
    }

    private func updatePausedAudio(wasPlaying: Set<String>, isPlaying: Set<String>) {
        let next = PausedAudio.update(pausedAudioBundleIDs, wasPlaying: wasPlaying, isPlaying: isPlaying,
                                      audible: audibleBundleIDs())
        // Guarded: an @Observable set notifies on every write.
        if next != pausedAudioBundleIDs { pausedAudioBundleIDs = next }
    }
}
