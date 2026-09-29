import Foundation

/// A browser tab, addressed the way its browser's AppleScript dictionary
/// allows: Chromium browsers give tabs stable ids, Safari only an index.
struct BrowserTabRef: Hashable, Sendable {
    let windowID: String
    let tabKey: String
    /// Whether the browser reported the window and tab ids as numbers (older
    /// Chrome, Safari) rather than text (current Chromium, Arc). Object
    /// specifiers must send them back with the same type or nothing matches.
    var numericIDs = false
}

enum PlaybackCommand: Sendable, Equatable {
    case play
    case pause
    case seek(TimeInterval)
}

/// One thing playing in one app. The same shape covers a MediaRemote
/// now-playing client (what Control Center shows) and a single browser tab.
struct NowPlayingSession: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// Commands go to the MediaRemote client with this process id.
        case mediaRemote(pid: pid_t)
        case browserTab(BrowserTabRef)
    }

    let source: Source
    /// The app the user knows (the browser, not its media helper); the
    /// popover lists the session under this app's row.
    let ownerBundleID: String
    let title: String
    let subtitle: String?
    /// Nil for live streams and players that don't report a length.
    let duration: TimeInterval?
    /// Playback position at `positionDate`.
    let position: TimeInterval
    let positionDate: Date
    /// 0 while paused.
    let rate: Double
    /// Key into NowPlayingMonitor's artwork cache: a MediaRemote artwork
    /// identifier, or an image URL for browser tabs.
    let artworkKey: String?
    /// The MediaRemote client macOS currently treats as the now-playing app,
    /// the only one MediaRemote commands from Fader reach. Always false for
    /// browser tabs.
    var isElected = false

    var id: String {
        switch source {
        case let .mediaRemote(pid): "mr:\(ownerBundleID):\(pid)"
        case let .browserTab(tab): "tab:\(ownerBundleID):\(tab.windowID):\(tab.tabKey)"
        }
    }

    var isPlaying: Bool {
        rate > 0
    }

    /// Current position, extrapolated from the last report while playing.
    func position(at date: Date) -> TimeInterval {
        let elapsed = position + max(0, date.timeIntervalSince(positionDate)) * rate
        guard let duration else { return max(0, elapsed) }
        return min(max(0, elapsed), duration)
    }

    func with(rate: Double, position: TimeInterval, at date: Date = Date()) -> NowPlayingSession {
        NowPlayingSession(source: source, ownerBundleID: ownerBundleID, title: title, subtitle: subtitle,
                          duration: duration, position: position, positionDate: date, rate: rate,
                          artworkKey: artworkKey, isElected: isElected)
    }

    func with(artworkKey: String?) -> NowPlayingSession {
        NowPlayingSession(source: source, ownerBundleID: ownerBundleID, title: title, subtitle: subtitle,
                          duration: duration, position: position, positionDate: positionDate, rate: rate,
                          artworkKey: artworkKey, isElected: isElected)
    }
}

/// A play, pause, or seek Fader sent that the app hasn't reported yet.
///
/// Reports keep arriving while the app acts on the command, and the first
/// ones can still describe the old state: Spotify, driven over AppleScript,
/// takes a moment to update MediaRemote, and any other session changing in
/// the meantime sends a fresh snapshot with Spotify still paused. A matching
/// report doesn't end the wait either: after a pause Spotify sends a second
/// report once its fade-out ends, about a second later, and now and then that
/// one claims it is playing before a third corrects it. Showing any of those
/// would flip the button back and forth, so for the whole `hold` a report
/// that contradicts the command gives way to what the command asked for.
struct PendingPlayback: Sendable {
    static let hold: TimeInterval = 2.5
    /// How far a reported position may be from the expected one and still
    /// count as the command having landed.
    private static let positionTolerance: TimeInterval = 2

    /// The session as the command should leave it.
    let expected: NowPlayingSession
    let expires: Date

    init(expected: NowPlayingSession, sentAt: Date) {
        self.expected = expected
        expires = sentAt + Self.hold
    }

    func isSatisfied(by reported: NowPlayingSession, at now: Date) -> Bool {
        reported.isPlaying == expected.isPlaying
            && abs(reported.position(at: now) - expected.position(at: now)) < Self.positionTolerance
    }

    /// The reported session (its metadata may have moved on) with the
    /// expected playback state.
    func apply(to reported: NowPlayingSession, at now: Date) -> NowPlayingSession {
        reported.with(rate: expected.rate, position: expected.position(at: now), at: now)
    }

    /// Reported sessions as they should be shown, keyed by session id.
    /// Expired entries are ignored.
    static func apply(_ pending: [String: PendingPlayback], to reported: [NowPlayingSession],
                      at now: Date) -> [NowPlayingSession] {
        reported.map { session in
            guard let entry = pending[session.id], entry.expires > now, !entry.isSatisfied(by: session, at: now)
            else { return session }
            return entry.apply(to: session, at: now)
        }
    }
}

/// Apps whose media was paused while macOS still reports them producing
/// audio. Players and browsers keep their output stream open for a while
/// after a pause, so Core Audio's flag alone keeps a just-paused app's row
/// bright; the pause itself is the better signal until that stream closes.
enum PausedAudio {
    /// - Parameters:
    ///   - silenced: The current set.
    ///   - wasPlaying, isPlaying: Apps with a playing session before and
    ///     after the latest update.
    ///   - audible: Apps Core Audio reports as producing sound.
    static func update(_ silenced: Set<String>, wasPlaying: Set<String>, isPlaying: Set<String>,
                       audible: Set<String>) -> Set<String> {
        // Playing again, or the stream finally closed: Core Audio is right
        // again from here on.
        silenced.subtracting(isPlaying)
            .union(wasPlaying.subtracting(isPlaying))
            .intersection(audible)
    }
}

// MARK: - MediaRemote helper messages

/// One client as reported by the FaderMediaRemote helper.
struct MediaRemoteClientInfo: Decodable, Equatable, Sendable {
    let pid: pid_t
    let elected: Bool?
    let bundleID: String?
    let parentBundleID: String?
    let displayName: String?
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsed: Double?
    let rate: Double?
    /// Seconds since 1970 at which `elapsed` was sampled.
    let timestamp: Double?
    let artworkKey: String?
    /// Base64 image data, sent only the first time a key appears.
    let artwork: String?

    struct Message: Decodable {
        let sessions: [MediaRemoteClientInfo]
    }

    static func decodeLine(_ line: Data) -> [MediaRemoteClientInfo]? {
        try? JSONDecoder().decode(Message.self, from: line).sessions
    }

    func session(ownerBundleID: String, now: Date = Date()) -> NowPlayingSession {
        let subtitle = [artist, album].compactMap { $0?.isEmpty == false ? $0 : nil }.first
        return NowPlayingSession(
            source: .mediaRemote(pid: pid),
            ownerBundleID: ownerBundleID,
            title: title,
            subtitle: subtitle,
            duration: duration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil },
            position: elapsed ?? 0,
            positionDate: timestamp.map { Date(timeIntervalSince1970: $0) } ?? now,
            rate: rate ?? 0,
            artworkKey: artworkKey,
            isElected: elected ?? false
        )
    }
}

// MARK: - Browser tab reports

/// What the injected page script reports about a tab's main media element.
struct BrowserTabMedia: Decodable, Equatable, Sendable {
    let title: String
    let subtitle: String?
    /// Negative for live streams (the element reports an infinite duration).
    let duration: Double
    let position: Double
    let rate: Double
    let artwork: String?

    enum CodingKeys: String, CodingKey {
        case title = "t", subtitle = "a", duration = "d", position = "e", rate = "p", artwork = "art"
    }

    /// Parses the JSON the page script returned for one tab.
    static func session(json: String, tab: BrowserTabRef, ownerBundleID: String,
                        now: Date = Date()) -> NowPlayingSession? {
        guard let media = try? JSONDecoder().decode(BrowserTabMedia.self, from: Data(json.utf8)),
              !media.title.isEmpty
        else { return nil }
        return NowPlayingSession(
            source: .browserTab(tab),
            ownerBundleID: ownerBundleID,
            title: media.title,
            subtitle: media.subtitle?.isEmpty == false ? media.subtitle : nil,
            duration: media.duration > 0 && media.duration.isFinite ? media.duration : nil,
            position: media.position,
            positionDate: now,
            rate: media.rate,
            artworkKey: media.artwork?.isEmpty == false ? media.artwork : nil
        )
    }
}

// MARK: - Merging

enum NowPlayingMerge {
    /// Combines MediaRemote sessions with per-tab browser sessions.
    ///
    /// MediaRemote sees at most one session per browser; the tab scan sees
    /// each tab. For a browser whose tabs were scanned, a MediaRemote session
    /// that matches a tab by title is the same media and is dropped (lending
    /// its artwork if the tab has none). So is one matching a tab that was
    /// found but isn't shown (`hiddenTabTitles`, normalized, per browser):
    /// hiding the tab must not bring its media back as a separate card. One
    /// that matches no tab, such as a video in a cross-origin frame the page
    /// script can't reach, stays.
    static func merge(mediaRemote: [NowPlayingSession], tabs: [String: [NowPlayingSession]],
                      hiddenTabTitles: [String: Set<String>] = [:]) -> [NowPlayingSession] {
        var result: [NowPlayingSession] = []
        var tabsByOwner = tabs

        for session in mediaRemote {
            guard var ownerTabs = tabsByOwner[session.ownerBundleID] else {
                result.append(session)
                continue
            }
            let key = normalized(session.title)
            if let index = ownerTabs.firstIndex(where: { normalized($0.title) == key }) {
                if ownerTabs[index].artworkKey == nil, session.artworkKey != nil {
                    ownerTabs[index] = ownerTabs[index].with(artworkKey: session.artworkKey)
                    tabsByOwner[session.ownerBundleID] = ownerTabs
                }
            } else if hiddenTabTitles[session.ownerBundleID]?.contains(key) != true {
                result.append(session)
            }
        }

        for (_, ownerTabs) in tabsByOwner.sorted(by: { $0.key < $1.key }) {
            result.append(contentsOf: ownerTabs)
        }
        return result
    }

    /// Page titles often carry a site suffix ("… - YouTube") or an unread
    /// counter prefix ("(3) …") that the media session title lacks.
    static func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"),
           text[text.index(after: text.startIndex) ..< close].allSatisfy(\.isNumber) {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        for separator in [" - ", " – ", " — ", " | "] {
            if let range = text.range(of: separator, options: .backwards) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.lowercased()
    }
}
