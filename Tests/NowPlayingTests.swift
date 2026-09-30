import Foundation
import Testing

@Suite("Now playing")
struct NowPlayingTests {
    private func mediaRemote(_ title: String, owner: String, pid: pid_t = 10, artwork: String? = nil,
                             rate: Double = 1) -> NowPlayingSession {
        NowPlayingSession(source: .mediaRemote(pid: pid), ownerBundleID: owner, title: title, subtitle: nil,
                          duration: 100, position: 0, positionDate: Date(timeIntervalSince1970: 0), rate: rate,
                          artworkKey: artwork)
    }

    private func tab(_ title: String, owner: String, key: String, artwork: String? = nil) -> NowPlayingSession {
        NowPlayingSession(source: .browserTab(BrowserTabRef(windowID: "1", tabKey: key)), ownerBundleID: owner,
                          title: title, subtitle: nil, duration: 100, position: 0,
                          positionDate: Date(timeIntervalSince1970: 0), rate: 1, artworkKey: artwork)
    }

    @Test("helper snapshots decode, including null fields")
    func decodesHelperLine() throws {
        let line = Data("""
        {"sessions":[{"pid":42,"elected":true,"bundleID":"com.spotify.client","parentBundleID":null,\
        "displayName":"Spotify","title":"Song","artist":"Band","album":"","duration":200.5,"elapsed":12,"rate":1,\
        "timestamp":1000,"artworkKey":"abc","artwork":null}]}
        """.utf8)
        let clients = try #require(MediaRemoteClientInfo.decodeLine(line))
        let session = try #require(clients.first).session(ownerBundleID: "com.spotify.client")

        #expect(session.source == .mediaRemote(pid: 42))
        #expect(session.isElected)
        #expect(session.with(rate: 0, position: 5).isElected)
        #expect(session.subtitle == "Band")
        #expect(session.duration == 200.5)
        #expect(session.position(at: Date(timeIntervalSince1970: 1010)) == 22)
        #expect(session.artworkKey == "abc")
    }

    @Test("paused sessions hold position; playing ones clamp at the end")
    func positionExtrapolation() {
        let paused = mediaRemote("A", owner: "x", rate: 0)
        #expect(paused.position(at: Date(timeIntervalSince1970: 50)) == 0)
        let playing = mediaRemote("A", owner: "x")
        #expect(playing.position(at: Date(timeIntervalSince1970: 500)) == 100)
    }

    @Test("tab reports parse; live streams have no duration")
    func parsesTabReport() throws {
        let json = #"{"t":"Lofi radio","a":"youtube.com","d":-1,"e":30,"p":1,"art":""}"#
        let ref = BrowserTabRef(windowID: "7", tabKey: "123")
        let session = try #require(BrowserTabMedia.session(json: json, tab: ref, ownerBundleID: "com.google.Chrome"))

        #expect(session.source == .browserTab(ref))
        #expect(session.duration == nil)
        #expect(session.artworkKey == nil)
        #expect(session.isPlaying)
        #expect(BrowserTabMedia.session(json: #"{"t":"","d":1,"e":0,"p":0}"#, tab: ref, ownerBundleID: "b") == nil)
    }

    @Test("apps without scanned tabs keep their MediaRemote session")
    func mediaRemoteOnly() {
        let spotify = mediaRemote("Song", owner: "com.spotify.client")
        let merged = NowPlayingMerge.merge(mediaRemote: [spotify], tabs: [:])
        #expect(merged == [spotify])
    }

    @Test("a browser's MediaRemote session gives way to the matching tab and lends it artwork")
    func tabReplacesMatchingSession() {
        let chrome = "com.google.Chrome"
        let session = mediaRemote("Cool Video", owner: chrome, artwork: "art-1")
        let first = tab("(3) Cool Video - YouTube", owner: chrome, key: "1")
        let second = tab("Other Video", owner: chrome, key: "2", artwork: "https://example.com/a.jpg")
        let spotify = mediaRemote("Song", owner: "com.spotify.client", pid: 20)

        let merged = NowPlayingMerge.merge(mediaRemote: [session, spotify], tabs: [chrome: [first, second]])

        #expect(merged.map(\.title) == ["Song", "(3) Cool Video - YouTube", "Other Video"])
        #expect(merged[1].artworkKey == "art-1")
        #expect(merged[2].artworkKey == "https://example.com/a.jpg")
    }

    @Test("a stale report after pressing play doesn't flip the button back")
    func pendingPlaybackHoldsAgainstStaleReports() {
        let sent = Date(timeIntervalSince1970: 0)
        let paused = mediaRemote("Song", owner: "com.spotify.client", rate: 0)
        let pending = PendingPlayback(expected: paused.with(rate: 1, position: 0, at: sent), sentAt: sent)
        let now = sent + 0.5

        #expect(!pending.isSatisfied(by: paused, at: now))
        let shown = pending.apply(to: paused, at: now)
        #expect(shown.isPlaying)
        #expect(shown.position(at: now) == 0.5)

        let confirmed = paused.with(rate: 1, position: 0.4, at: now)
        #expect(pending.isSatisfied(by: confirmed, at: now))
        #expect(pending.expires == sent + PendingPlayback.hold)
    }

    @Test("Spotify's stray playing report right after a pause is held off for the whole hold")
    func strayReportAfterPause() {
        // Captured from Spotify: paused at 43.07, a "playing" report 0.8 s
        // later, then paused again.
        let sent = Date(timeIntervalSince1970: 0)
        let playing = mediaRemote("Song", owner: "com.spotify.client").with(rate: 1, position: 43, at: sent)
        let pending = [playing.id: PendingPlayback(expected: playing.with(rate: 0, position: 43, at: sent),
                                                   sentAt: sent)]
        let shown = { (report: NowPlayingSession, at: TimeInterval) in
            PendingPlayback.apply(pending, to: [report], at: sent + at).first?.isPlaying
        }

        #expect(shown(playing.with(rate: 0, position: 43.07, at: sent + 0.1), 0.1) == false)
        #expect(shown(playing.with(rate: 1, position: 43.3, at: sent + 0.9), 0.9) == false)
        #expect(shown(playing.with(rate: 1, position: 43.3, at: sent + 0.9), PendingPlayback.hold + 0.1) == true)
    }

    @Test("a paused app reads as silent while its output stream lingers, until it plays or the stream closes")
    func pausedAudio() {
        let spotify: Set = ["com.spotify.client"]
        // Paused while Core Audio still reports output.
        let paused = PausedAudio.update([], wasPlaying: spotify, isPlaying: [], audible: spotify)
        #expect(paused == spotify)
        // Stream still open on later updates: stays silent.
        #expect(PausedAudio.update(paused, wasPlaying: [], isPlaying: [], audible: spotify) == spotify)
        // Played again, or the stream closed.
        #expect(PausedAudio.update(paused, wasPlaying: [], isPlaying: spotify, audible: spotify).isEmpty)
        #expect(PausedAudio.update(paused, wasPlaying: [], isPlaying: [], audible: []).isEmpty)
        // Pausing an app whose output already stopped needs no override.
        #expect(PausedAudio.update([], wasPlaying: spotify, isPlaying: [], audible: []).isEmpty)
    }

    @Test("a seek counts as landed only once the reported position is near the target")
    func pendingSeek() {
        let sent = Date(timeIntervalSince1970: 0)
        let playing = mediaRemote("Song", owner: "com.spotify.client")
        let pending = PendingPlayback(expected: playing.with(rate: 1, position: 60, at: sent), sentAt: sent)

        #expect(!pending.isSatisfied(by: playing, at: sent + 0.2))
        #expect(pending.isSatisfied(by: playing.with(rate: 1, position: 60.1, at: sent + 0.2), at: sent + 0.2))
    }

    @Test("hiding a tab doesn't bring its media back as the browser's own session")
    func hiddenTabAbsorbsSession() {
        let chrome = "com.google.Chrome"
        let session = mediaRemote("Old Video", owner: chrome, rate: 0)
        let merged = NowPlayingMerge.merge(mediaRemote: [session], tabs: [chrome: []],
                                           hiddenTabTitles: [chrome: ["old video"]])
        #expect(merged.isEmpty)
    }

    @Test("media the tab scan can't see stays visible")
    func unmatchedSessionStays() {
        let chrome = "com.google.Chrome"
        let embedded = mediaRemote("Embedded clip", owner: chrome)
        let merged = NowPlayingMerge.merge(mediaRemote: [embedded], tabs: [chrome: []])
        #expect(merged == [embedded])
    }

    @Test("title normalization strips counters and site suffixes")
    func normalization() {
        #expect(NowPlayingMerge.normalized("(12) Song Title - YouTube") == "song title")
        #expect(NowPlayingMerge.normalized("Podcast | Spotify") == "podcast")
        #expect(NowPlayingMerge.normalized("(live) Show") == "(live) show")
    }

    @Test("commands go to the elected MediaRemote session, scriptable media apps, and browser tabs only")
    func playbackRoutes() {
        var elected = mediaRemote("A", owner: "com.spotify.client", pid: 7)
        elected.isElected = true
        let spotify = mediaRemote("B", owner: "com.spotify.client")

        #expect(PlaybackRoute.route(for: elected, deniedPlayers: []) == .mediaRemote(7))
        #expect(PlaybackRoute.route(for: spotify, deniedPlayers: []) == .appleScript)
        #expect(PlaybackRoute.route(for: spotify, deniedPlayers: ["com.spotify.client"]) == nil)
        #expect(PlaybackRoute.route(for: mediaRemote("C", owner: "com.example.player"), deniedPlayers: []) == nil)
        #expect(PlaybackRoute.route(for: tab("D", owner: "com.google.Chrome", key: "1"), deniedPlayers: [])
            == .browserTab(BrowserTabRef(windowID: "1", tabKey: "1"), .chromium))
        #expect(PlaybackRoute.route(for: tab("E", owner: "org.mozilla.firefox", key: "1"), deniedPlayers: []) == nil)
    }

    @Test("media app scripts use the player dictionary")
    func scriptedPlayerScripts() {
        #expect(ScriptedPlayer.script(.pause, bundleID: "com.spotify.client")
            .contains(#"tell application id "com.spotify.client" to pause"#))
        #expect(ScriptedPlayer.script(.seek(42.5), bundleID: "com.apple.Music")
            .contains("to set player position to 42.5"))
        #expect(ScriptedPlayer.script(.seek(-3), bundleID: "com.apple.Music")
            .contains("to set player position to 0.0"))
    }

    @Test("scripts never launch an app that isn't running")
    func scriptsCheckRunning() {
        #expect(ScriptedPlayer.script(.play, bundleID: "com.spotify.client")
            .contains(#"if application id "com.spotify.client" is running then"#))
        #expect(BrowserTabScanner.listScript(bundleID: "com.google.Chrome", flavor: .chromium)
            .contains(#"if application id "com.google.Chrome" is not running then error"#))
    }

    @Test("the JavaScript hint points at each browser's own setting location")
    func javaScriptSettingLocations() {
        #expect(BrowserFlavor.javaScriptSettingLocation(for: "com.apple.Safari") == "Settings › Developer")
        #expect(BrowserFlavor.javaScriptSettingLocation(for: "com.microsoft.edgemac") == "Tools › Developer")
        #expect(BrowserFlavor.javaScriptSettingLocation(for: "net.imput.helium") == "View › Developer")
    }

    @Test("tab lists keep each id's type and mark the selected tab")
    func parsesTabList() {
        func row(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let list = NSAppleEventDescriptor.list()
            for item in items {
                list.insert(item, at: 0)
            }
            return list
        }
        let text = { (value: String) in NSAppleEventDescriptor(string: value) }
        let number = { (value: Int32) in NSAppleEventDescriptor(int32: value) }
        let list = row([
            row([text("w1"), text("t1"), text("https://youtube.com"), text("Video"), text("t2")]),
            row([text("w1"), text("t2"), text(""), text("New Tab"), text("t2")]),
            row([number(5), number(1), text("https://a.com"), text("A"),
                 NSAppleEventDescriptor(typeCode: BrowserTabScanner.fourCharCode("msng"))]),
            row([text("w1"), text("t3")]),
        ])

        #expect(BrowserTabScanner.parseTabList(list) == [
            BrowserTab(ref: BrowserTabRef(windowID: "w1", tabKey: "t1"), url: "https://youtube.com", title: "Video",
                       isActive: false),
            BrowserTab(ref: BrowserTabRef(windowID: "w1", tabKey: "t2"), url: "", title: "New Tab", isActive: true),
            BrowserTab(ref: BrowserTabRef(windowID: "5", tabKey: "1", numericIDs: true), url: "https://a.com",
                       title: "A", isActive: false),
        ])
    }

    @Test("page script errors map to timeouts, refused JavaScript, and denied access")
    func probeErrors() {
        #expect(BrowserTabScanner.outcome(errorNumber: -1712, message: "") == .timedOut)
        #expect(BrowserTabScanner.outcome(errorNumber: -1743, message: "") == .notAuthorized)
        #expect(BrowserTabScanner.outcome(
            errorNumber: 12, message: "Executing JavaScript through AppleScript is turned off."
        ) == .blocked)
        #expect(BrowserTabScanner.outcome(errorNumber: -1728, message: "Can't get tab id 4.") == .failed)
    }

    @Test("page scripts address the tab by id in Chromium and by index in Safari")
    func javaScriptEvents() throws {
        let code = BrowserTabScanner.fourCharCode
        let chromium = try #require(BrowserTabScanner.javaScriptEvent(
            "1+1", in: BrowserTabRef(windowID: "9", tabKey: "42"), bundleID: "net.imput.helium", flavor: .chromium
        ))
        #expect(chromium.eventClass == code("CrSu") && chromium.eventID == code("ExJa"))
        #expect(chromium.paramDescriptor(forKeyword: code("JvSc"))?.stringValue == "1+1")
        let tab = try #require(chromium.paramDescriptor(forKeyword: code("----")))
        #expect(tab.descriptorType == code("obj "))
        #expect(tab.forKeyword(code("want"))?.typeCodeValue == code("CrTb"))
        #expect(tab.forKeyword(code("seld"))?.descriptorType == code("utxt"))
        #expect(tab.forKeyword(code("seld"))?.stringValue == "42")
        #expect(tab.forKeyword(code("from"))?.forKeyword(code("want"))?.typeCodeValue == code("cwin"))

        let safari = try #require(BrowserTabScanner.javaScriptEvent(
            "1+1", in: BrowserTabRef(windowID: "3", tabKey: "2", numericIDs: true), bundleID: "com.apple.Safari",
            flavor: .safari
        ))
        #expect(safari.eventClass == code("sfri") && safari.eventID == code("dojs"))
        #expect(safari.paramDescriptor(forKeyword: code("----"))?.stringValue == "1+1")
        let safariTab = try #require(safari.paramDescriptor(forKeyword: code("dcnm")))
        #expect(safariTab.forKeyword(code("form"))?.enumCodeValue == code("indx"))
        #expect(safariTab.forKeyword(code("seld"))?.int32Value == 2)
        #expect(safariTab.forKeyword(code("from"))?.forKeyword(code("seld"))?.int32Value == 3)
    }

    @Test("every scriptable browser and media app is allowed by the sandbox's Apple Events exception")
    func entitlementsCoverScriptedApps() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fader/Resources/Fader.entitlements")
        let plist = try #require(NSDictionary(contentsOf: url))
        let allowed = Set(plist["com.apple.security.temporary-exception.apple-events"] as? [String] ?? [])

        #expect(plist["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(Set(BrowserFlavor.supported.keys).subtracting(allowed).isEmpty)
        #expect(ScriptedPlayer.supported.subtracting(allowed).isEmpty)
    }
}

@Suite("Popover app order")
struct AppsListOrderTests {
    private func app(_ name: String, playing: Bool) -> AudioApp {
        AudioApp(id: pid_t(name.count), bundleID: "b.\(name)", name: name, objectIDs: [],
                 isPlaying: playing, isRecording: false)
    }

    private func order(_ apps: [AudioApp], nowPlaying: [String] = [], adjusted: Set<String> = []) -> [String] {
        AppsListOrder.entries(apps: apps, nowPlayingBundleIDs: nowPlaying,
                              isAdjusted: { adjusted.contains($0.bundleID) },
                              name: { $0.replacingOccurrences(of: "b.", with: "") })
            .map(\.name)
    }

    @Test("pausing an app with something loaded doesn't move it")
    func pausedAppKeepsItsPlace() {
        let playing = order([app("Spotify", playing: true), app("Helium", playing: true)],
                            nowPlaying: ["b.Helium", "b.Spotify"])
        let paused = order([app("Spotify", playing: true), app("Helium", playing: false)],
                           nowPlaying: ["b.Helium", "b.Spotify"])
        #expect(playing == ["Helium", "Spotify"])
        #expect(paused == playing)
    }

    @Test("an app with media but no audio process sorts among the rows, not after them")
    func headerOnlyGroupsSortWithRows() {
        let entries = AppsListOrder.entries(apps: [app("Spotify", playing: true), app("Zoom", playing: true)],
                                            nowPlayingBundleIDs: ["b.Helium"], isAdjusted: { _ in false },
                                            name: { _ in "Helium" })
        #expect(entries.map(\.name) == ["Helium", "Spotify", "Zoom"])
        #expect(entries.first?.app == nil)
    }

    @Test("silent apps kept for their volume go last; other silent apps are hidden")
    func silentApps() {
        let apps = [app("Arc", playing: false), app("Mail", playing: false), app("Zoom", playing: true)]
        #expect(order(apps, adjusted: ["b.Arc"]) == ["Zoom", "Arc"])
    }
}
