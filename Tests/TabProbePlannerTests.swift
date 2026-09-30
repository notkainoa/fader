import Foundation
import Testing

@Suite("Browser tab probing")
struct TabProbePlannerTests {
    private let owner = "net.imput.helium"
    private let start = Date(timeIntervalSince1970: 1000)
    private let media = #"{"t":"Cool Video","d":100,"e":5,"p":0}"#

    private func tab(_ key: String, title: String = "Page", url: String? = nil,
                     active: Bool = false) -> BrowserTab {
        BrowserTab(ref: BrowserTabRef(windowID: "1", tabKey: key), url: url ?? "https://\(key).com", title: title,
                   isActive: active)
    }

    @Test("likely media tabs are asked first: MediaRemote's title, earlier media, the selected tab")
    func priority() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        _ = planner.plan(tabs: [tab("a"), tab("b")], preferredTitles: [], now: start)
        planner.record(.media(media), for: tab("b").ref, now: start)

        let tabs = [tab("a"), tab("b"), tab("c", active: true), tab("d", title: "(2) Song - YouTube")]
        let order = planner.plan(tabs: tabs, preferredTitles: ["song"], now: start).map(\.ref.tabKey)
        #expect(order == ["d", "b", "c", "a"])
    }

    @Test("a tab that doesn't answer is left alone for a while, longer each time")
    func backoff() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        let tabs = [tab("a"), tab("b")]
        _ = planner.plan(tabs: tabs, preferredTitles: [], now: start)
        planner.record(.timedOut, for: tab("a").ref, now: start)

        #expect(planner.plan(tabs: tabs, preferredTitles: [], now: start + 19).map(\.ref.tabKey) == ["b"])
        #expect(planner.plan(tabs: tabs, preferredTitles: [], now: start + 20).map(\.ref.tabKey) == ["a", "b"])
        planner.record(.timedOut, for: tab("a").ref, now: start + 20)
        #expect(planner.plan(tabs: tabs, preferredTitles: [], now: start + 59).map(\.ref.tabKey) == ["b"])
        #expect(planner.status(of: tab("a").ref) == .unresponsive)
    }

    @Test("waking or navigating a sleeping tab gets it asked again right away")
    func changedTabRetries() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        _ = planner.plan(tabs: [tab("a")], preferredTitles: [], now: start)
        planner.record(.timedOut, for: tab("a").ref, now: start)

        let woken = [tab("a", title: "Cool Video - YouTube")]
        #expect(planner.plan(tabs: woken, preferredTitles: [], now: start + 1).map(\.ref.tabKey) == ["a"])
    }

    @Test("a media tab that misses one reply keeps its card for one round")
    func keepsMediaAfterOneMiss() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        let tabs = [tab("a")]
        _ = planner.plan(tabs: tabs, preferredTitles: [], now: start)
        planner.record(.media(media), for: tab("a").ref, now: start)
        planner.record(.timedOut, for: tab("a").ref, now: start + 2)

        #expect(planner.sessions.map(\.title) == ["Cool Video"])
        #expect(planner.plan(tabs: tabs, preferredTitles: [], now: start + 2).count == 1)
        planner.record(.timedOut, for: tab("a").ref, now: start + 4)
        #expect(planner.sessions.isEmpty)
    }

    @Test("closed tabs drop out and sessions follow tab order")
    func closedTabsAndOrder() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        _ = planner.plan(tabs: [tab("a"), tab("b"), tab("c")], preferredTitles: [], now: start)
        planner.record(.media(media), for: tab("c").ref, now: start)
        planner.record(.media(media.replacingOccurrences(of: "Cool", with: "Other")), for: tab("a").ref, now: start)
        #expect(planner.sessions.map(\.title) == ["Other Video", "Cool Video"])

        _ = planner.plan(tabs: [tab("c"), tab("b")], preferredTitles: [], now: start + 2)
        #expect(planner.sessions.map(\.title) == ["Cool Video"])
    }

    @Test("a tab refusing JavaScript flags the browser until it answers")
    func blockedTabs() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        _ = planner.plan(tabs: [tab("a"), tab("b")], preferredTitles: [], now: start)
        planner.record(.noMedia, for: tab("a").ref, now: start)
        planner.record(.blocked, for: tab("b").ref, now: start)
        #expect(planner.hasBlockedTabs)

        planner.record(.noMedia, for: tab("b").ref, now: start + 2)
        #expect(!planner.hasBlockedTabs)
    }

    @Test("paused tabs show only once seen playing or reported by MediaRemote")
    func recentlyPlayedOnly() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        _ = planner.plan(tabs: [tab("a"), tab("b"), tab("c")], preferredTitles: [], now: start)
        let playing = media.replacingOccurrences(of: #""p":0"#, with: #""p":1"#)
        planner.record(.media(playing.replacingOccurrences(of: "Cool", with: "Watched")), for: tab("a").ref,
                       now: start)
        planner.record(.media(media.replacingOccurrences(of: "Cool", with: "Stale")), for: tab("b").ref, now: start)
        planner.record(.media(media), for: tab("c").ref, now: start)

        #expect(planner.visibleSessions(recentTitles: ["cool video": start], now: start).map(\.title)
            == ["Watched Video", "Cool Video"])
    }

    @Test("a paused tab's card goes away an hour after it last played; a playing one stays")
    func pausedTabsExpire() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        _ = planner.plan(tabs: [tab("a"), tab("b")], preferredTitles: [], now: start)
        let playing = media.replacingOccurrences(of: #""p":0"#, with: #""p":1"#)
        planner.record(.media(playing), for: tab("a").ref, now: start)
        planner.record(.media(media), for: tab("a").ref, now: start + 1)
        planner.record(.media(playing.replacingOccurrences(of: "Cool", with: "Live")), for: tab("b").ref,
                       now: start)

        let later = start + TabProbePlanner.pausedLifetime + 1
        #expect(planner.visibleSessions(recentTitles: [:], now: start + 60).map(\.title)
            == ["Cool Video", "Live Video"])
        #expect(planner.visibleSessions(recentTitles: [:], now: later).map(\.title) == ["Live Video"])
        #expect(planner.knownTitles == ["cool video", "live video"])
    }

    @Test("a new page in a tab slot doesn't inherit the old page's played history")
    func pageChangeForgetsPlayed() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        let playing = media.replacingOccurrences(of: #""p":0"#, with: #""p":1"#)
        _ = planner.plan(tabs: [tab("1", url: "https://a.com")], preferredTitles: [], now: start)
        planner.record(.media(playing), for: tab("1").ref, now: start)

        // Safari: the playing tab closed and a long-paused one slid into index 1.
        _ = planner.plan(tabs: [tab("1", url: "https://b.com")], preferredTitles: [], now: start + 2)
        #expect(planner.visibleSessions(recentTitles: [:], now: start + 2).map(\.title) == ["Cool Video"])
        planner.record(.media(media.replacingOccurrences(of: "Cool", with: "Stale")), for: tab("1").ref,
                       now: start + 2)
        #expect(planner.visibleSessions(recentTitles: [:], now: start + 2).isEmpty)

        // An autoplaying next video keeps its card throughout.
        _ = planner.plan(tabs: [tab("1", url: "https://c.com")], preferredTitles: [], now: start + 4)
        planner.record(.media(playing.replacingOccurrences(of: "Cool", with: "Next")), for: tab("1").ref,
                       now: start + 4)
        _ = planner.plan(tabs: [tab("1", url: "https://d.com")], preferredTitles: [], now: start + 6)
        #expect(planner.visibleSessions(recentTitles: [:], now: start + 6).map(\.title) == ["Next Video"])
    }

    @Test("at most three tab cards: playing first, then most recently played, shown in tab order")
    func visibleLimit() {
        var planner = TabProbePlanner(ownerBundleID: owner)
        let keys = ["a", "b", "c", "d", "e"]
        _ = planner.plan(tabs: keys.map { tab($0) }, preferredTitles: [], now: start)
        let playing = media.replacingOccurrences(of: #""p":0"#, with: #""p":1"#)
        for (offset, key) in keys.enumerated() {
            planner.record(.media(playing.replacingOccurrences(of: "Cool", with: key.uppercased())),
                           for: tab(key).ref, now: start + Double(offset))
        }
        // "e" stays playing; the others were paused after playing.
        for key in keys.dropLast() {
            planner.record(.media(media.replacingOccurrences(of: "Cool", with: key.uppercased())),
                           for: tab(key).ref, now: start + 10)
        }

        #expect(planner.visibleSessions(recentTitles: [:], now: start + 20).map(\.title)
            == ["C Video", "D Video", "E Video"])
        #expect(planner.visibleSessions(recentTitles: ["a video": start + 20], now: start + 20).map(\.title)
            == ["A Video", "D Video", "E Video"])
    }
}
