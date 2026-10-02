import Foundation

/// Decides which of a browser's tabs to ask for media each scan, in what
/// order, and keeps each tab's last answer.
///
/// Sleeping and discarded tabs never answer, and a browser can have dozens
/// of them, so a tab that times out is left alone for a while: 20 seconds,
/// growing to a minute, or until its URL or title changes (it was woken or
/// navigated). Tabs most likely to hold media are asked first so their
/// cards show up before the long tail finishes.
struct TabProbePlanner {
    enum Status: Equatable {
        case unknown
        case answered
        /// JavaScript from Apple Events is off in this tab's profile.
        case blocked
        case unresponsive
    }

    private struct Entry {
        var tab: BrowserTab
        var status = Status.unknown
        var session: NowPlayingSession?
        /// No media on the page, but a player frame from another site.
        var embed: BrowserTabEmbed?
        var timeouts = 0
        var retryAt: Date?
        /// The tab had media and missed one reply; its card is kept for one
        /// more round in case the page was only busy.
        var keptAfterMiss = false
        /// Last time the tab was seen playing.
        var lastPlayed: Date?
        /// The URL changed since the tab last answered: a new page, or with
        /// Safari's index keys another tab sliding into this slot. Its media
        /// hasn't been seen playing unless the next answer says so; until
        /// then the old card stays, so an autoplaying next video doesn't
        /// flicker.
        var pageChanged = false

        mutating func markAnswered(_ newStatus: Status) {
            status = newStatus
            timeouts = 0
            retryAt = nil
            keptAfterMiss = false
            pageChanged = false
        }

        /// No reply: keep a media card for one more round, then back off.
        mutating func recordMiss(now: Date) {
            status = .unresponsive
            if session != nil || embed != nil, !keptAfterMiss {
                keptAfterMiss = true
                retryAt = nil
            } else {
                session = nil
                embed = nil
                keptAfterMiss = false
                timeouts += 1
                retryAt = now + TabProbePlanner.backoff[min(timeouts, TabProbePlanner.backoff.count) - 1]
            }
        }
    }

    /// A tab worth a card, and when it last played.
    struct Candidate: Equatable {
        let session: NowPlayingSession
        let played: Date
    }

    static let backoff: [TimeInterval] = [20, 40, 60]
    /// A paused tab's card goes away this long after it last played.
    static let pausedLifetime: TimeInterval = 15 * 60

    let ownerBundleID: String
    private var order: [BrowserTabRef] = []
    private var entries: [BrowserTabRef: Entry] = [:]

    init(ownerBundleID: String) {
        self.ownerBundleID = ownerBundleID
    }

    /// Every media element found in the browser's tabs, in tab-strip order.
    var sessions: [NowPlayingSession] {
        order.compactMap { entries[$0]?.session }
    }

    /// Tabs with a player frame from another site, in tab-strip order.
    var embeds: [BrowserTabEmbed] {
        order.compactMap { entries[$0]?.embed }
    }

    /// Normalized titles of every media element found, shown or not.
    var knownTitles: Set<String> {
        Set(sessions.map { NowPlayingMerge.normalized($0.title) })
    }

    /// The tabs worth a card, in tab-strip order: playing now, or paused
    /// within the last `pausedLifetime`. NowPlayingSelection picks which of
    /// them are shown.
    ///
    /// A video left paused halfway through hours ago still reports itself,
    /// so a paused tab only counts once it has been seen playing, or when
    /// MediaRemote reported its title (`recentTitles`, normalized title to
    /// last time seen), which covers media played before Sliders launched.
    func candidates(recentTitles: [String: Date], now: Date) -> [Candidate] {
        order.compactMap { ref -> Candidate? in
            guard let entry = entries[ref], let session = entry.session else { return nil }
            let played = [entry.lastPlayed, recentTitles[NowPlayingMerge.normalized(session.title)]]
                .compactMap(\.self).max()
            guard let played, session.isPlaying || now.timeIntervalSince(played) < Self.pausedLifetime
            else { return nil }
            return Candidate(session: session, played: played)
        }
    }

    /// Some tab refused JavaScript: the setting is off in at least one
    /// profile (or the whole browser).
    var hasBlockedTabs: Bool {
        entries.values.contains { $0.status == .blocked }
    }

    func status(of tab: BrowserTabRef) -> Status? {
        entries[tab]?.status
    }

    /// Takes a fresh tab list, forgets closed tabs, and returns the tabs to
    /// ask this round, most likely media first. `preferredTitles` are
    /// normalized titles of media MediaRemote reports for this browser.
    mutating func plan(tabs: [BrowserTab], preferredTitles: Set<String>, now: Date) -> [BrowserTab] {
        var next: [BrowserTabRef: Entry] = [:]
        for tab in tabs {
            var entry = entries[tab.ref] ?? Entry(tab: tab)
            if entry.tab.url != tab.url || entry.tab.title != tab.title {
                entry.timeouts = 0
                entry.retryAt = nil
            }
            if entry.tab.url != tab.url { entry.pageChanged = true }
            entry.tab = tab
            next[tab.ref] = entry
        }
        entries = next
        order = tabs.map(\.ref)

        func rank(_ tab: BrowserTab) -> Int {
            if preferredTitles.contains(NowPlayingMerge.normalized(tab.title)) { return 0 }
            if entries[tab.ref]?.session != nil || entries[tab.ref]?.embed != nil { return 1 }
            if tab.isActive { return 2 }
            return 3
        }
        return tabs.enumerated()
            .filter { _, tab in entries[tab.ref]?.retryAt.map { $0 <= now } ?? true }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    mutating func record(_ outcome: TabProbeOutcome, for ref: BrowserTabRef, now: Date) {
        guard var entry = entries[ref] else { return }
        switch outcome {
        case let .media(json):
            entry.session = BrowserTabMedia.session(json: json, tab: ref, ownerBundleID: ownerBundleID, now: now)
            entry.embed = entry.session == nil ? BrowserTabEmbed.parse(json: json) : nil
            if entry.session?.isPlaying == true {
                entry.lastPlayed = now
            } else if entry.pageChanged {
                entry.lastPlayed = nil
            }
            entry.markAnswered(.answered)
        case .noMedia:
            entry.session = nil
            entry.embed = nil
            if entry.pageChanged { entry.lastPlayed = nil }
            entry.markAnswered(.answered)
        case .blocked:
            entry.session = nil
            entry.embed = nil
            if entry.pageChanged { entry.lastPlayed = nil }
            entry.markAnswered(.blocked)
        case .timedOut, .failed:
            entry.recordMiss(now: now)
        case .notAuthorized:
            return
        }
        entries[ref] = entry
    }
}
