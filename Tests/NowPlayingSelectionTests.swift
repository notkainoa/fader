import Foundation
import Testing

@Suite("Browser card selection")
struct NowPlayingSelectionTests {
    private let owner = "com.google.Chrome"
    private let start = Date(timeIntervalSince1970: 1000)

    private func tab(_ key: String, playing: Bool) -> NowPlayingSession {
        NowPlayingSession(source: .browserTab(BrowserTabRef(windowID: "1", tabKey: key)), ownerBundleID: owner,
                          title: key.uppercased(), subtitle: nil, duration: 100, position: 0, positionDate: start,
                          rate: playing ? 1 : 0, artworkKey: nil)
    }

    private func select(_ sessions: [NowPlayingSession], played: [String: Date] = [:],
                        playingSince: [String: Date] = [:], expanded: Bool = false,
                        kept: [String]? = nil) -> (titles: [String], hidden: Int) {
        let result = NowPlayingSelection.select(sessions, played: played, playingSince: playingSince,
                                                expanded: expanded, kept: kept)
        return (result.shown.map(\.title), result.hiddenCount)
    }

    @Test("paused tabs get no card while another tab plays")
    func pausedHiddenWhilePlaying() {
        let sessions = [tab("a", playing: false), tab("b", playing: true), tab("c", playing: false)]
        let played = [sessions[0].id: start + 5, sessions[1].id: start, sessions[2].id: start + 9]
        #expect(select(sessions, played: played).titles == ["B"])
    }

    @Test("with nothing playing, only the most recently played session shows")
    func latestWhenNothingPlays() {
        let sessions = [tab("a", playing: false), tab("b", playing: false), tab("c", playing: false)]
        let played = [sessions[0].id: start + 5, sessions[1].id: start + 9, sessions[2].id: start]
        #expect(select(sessions, played: played) == (["B"], 0))
        #expect(select([]) == ([], 0))
    }

    @Test("the three newest playing tabs show, newest first; the rest wait behind the toggle")
    func capNewestFirst() {
        let sessions = ["a", "b", "c", "d", "e"].map { tab($0, playing: true) }
        var since: [String: Date] = [:]
        for (offset, session) in sessions.enumerated() {
            since[session.id] = start + Double(offset)
        }
        #expect(select(sessions, playingSince: since) == (["E", "D", "C"], 2))
        #expect(select(sessions, playingSince: since, expanded: true) == (["E", "D", "C", "B", "A"], 0))
    }

    @Test("tabs that started playing together keep tab order")
    func tiesKeepTabOrder() {
        let sessions = [tab("a", playing: true), tab("b", playing: true)]
        let since = [sessions[0].id: start, sessions[1].id: start]
        #expect(select(sessions, playingSince: since).titles == ["A", "B"])
    }

    @Test("while the popover is open a paused card keeps its place and new cards go below")
    func keptWhileOpen() {
        let sessions = [tab("a", playing: false), tab("b", playing: true), tab("c", playing: true)]
        let since = [sessions[1].id: start, sessions[2].id: start + 1]
        let kept = [sessions[0].id, sessions[1].id]
        #expect(select(sessions, playingSince: since, kept: kept) == (["A", "B", "C"], 0))
    }

    @Test("kept cards don't push past the cap; expanding adds the rest below them")
    func keptRespectsCap() {
        let sessions = ["a", "b", "c", "d"].map { tab($0, playing: true) }
        let kept = sessions.prefix(3).map(\.id)
        #expect(select(sessions, kept: kept) == (["A", "B", "C"], 1))
        #expect(select(sessions, expanded: true, kept: kept) == (["A", "B", "C", "D"], 0))
    }

    @Test("a kept card goes away once its session is gone")
    func keptDropsMissing() {
        let sessions = [tab("b", playing: true)]
        let kept = [tab("a", playing: false).id, sessions[0].id]
        #expect(select(sessions, kept: kept).titles == ["B"])
    }

    @Test("an unmatched MediaRemote session competes like any tab")
    func mediaRemoteSession() {
        let embedded = NowPlayingSession(source: .mediaRemote(pid: 7), ownerBundleID: owner, title: "Embedded",
                                         subtitle: nil, duration: nil, position: 0, positionDate: start, rate: 0,
                                         artworkKey: nil)
        let paused = tab("a", playing: false)
        let played = [embedded.id: start + 9, paused.id: start]
        #expect(select([embedded, paused], played: played).titles == ["Embedded"])
        #expect(select([embedded, tab("b", playing: true)], played: played).titles == ["B"])
    }
}
