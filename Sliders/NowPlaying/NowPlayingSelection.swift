import Foundation

/// Which of a browser's sessions get a card.
///
/// Every session that is playing gets one, the most recently started first.
/// When nothing plays, only the most recently played session does: paused
/// tabs next to the one actually playing are noise. Past `collapsedLimit`
/// the rest wait behind a "Show more" toggle.
///
/// While the popover is open, cards already on screen keep their place
/// (`kept`) for as long as their session exists, so pausing one of several
/// tabs leaves its play button where it was, and nothing shifts under the
/// pointer. New cards go below them.
enum NowPlayingSelection {
    static let collapsedLimit = 3

    struct Result: Equatable {
        var shown: [NowPlayingSession]
        /// Sessions that would get a card if the list were expanded.
        var hiddenCount: Int
    }

    /// - Parameters:
    ///   - sessions: One browser's candidate sessions, in tab-strip order.
    ///   - played: When each session (by id) last played.
    ///   - playingSince: When each playing session (by id) started playing.
    ///   - expanded: Whether the user asked to see every card.
    ///   - kept: Ids of the cards on screen since the popover opened, in
    ///     their on-screen order; nil while it is closed.
    static func select(_ sessions: [NowPlayingSession], played: [String: Date], playingSince: [String: Date],
                       expanded: Bool, kept: [String]?) -> Result {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = rank(sessions, played: played, playingSince: playingSince)

        let keptSessions = (kept ?? []).compactMap { byID[$0] }
        let keptIDs = Set(keptSessions.map(\.id))
        let fresh = ranked.filter { !keptIDs.contains($0.id) }
        let room = expanded ? fresh.count : max(0, collapsedLimit - keptSessions.count)
        let shown = keptSessions + fresh.prefix(room)
        return Result(shown: shown, hiddenCount: fresh.count - min(room, fresh.count))
    }

    /// Playing sessions, newest first; or, with none playing, the one that
    /// played last.
    private static func rank(_ sessions: [NowPlayingSession], played: [String: Date],
                             playingSince: [String: Date]) -> [NowPlayingSession] {
        let playing = sessions.enumerated().filter(\.element.isPlaying)
        if !playing.isEmpty {
            // Ties (tabs first seen in the same scan) fall back to tab order.
            return playing.sorted { lhs, rhs in
                let left = playingSince[lhs.element.id] ?? .distantPast
                let right = playingSince[rhs.element.id] ?? .distantPast
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
        let latest = sessions.enumerated().max { lhs, rhs in
            let left = played[lhs.element.id] ?? .distantPast
            let right = played[rhs.element.id] ?? .distantPast
            return left != right ? left < right : lhs.offset > rhs.offset
        }
        return latest.map { [$0.element] } ?? []
    }
}
