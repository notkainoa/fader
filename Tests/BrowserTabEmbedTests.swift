import Foundation
import JavaScriptCore
import Testing

@Suite("Embedded players")
struct BrowserTabEmbedTests {
    private func mediaRemote(_ title: String, owner: String, artwork: String? = nil) -> NowPlayingSession {
        NowPlayingSession(source: .mediaRemote(pid: 10), ownerBundleID: owner, title: title, subtitle: nil,
                          duration: 100, position: 0, positionDate: Date(timeIntervalSince1970: 0), rate: 1,
                          artworkKey: artwork)
    }

    @Test("embed reports parse; media reports and empty titles don't")
    func parsesEmbedReport() throws {
        let embed = try #require(BrowserTabEmbed.parse(
            json: #"{"x":1,"t":"Movie Night","a":"example.com","art":"https://example.com/p.jpg","f":1}"#
        ))
        #expect(embed == BrowserTabEmbed(title: "Movie Night", site: "example.com",
                                         artwork: "https://example.com/p.jpg", isFocused: true))
        #expect(BrowserTabEmbed.parse(json: #"{"x":1,"t":"Movie Night","a":"example.com","art":""}"#)?.artwork == nil)
        #expect(BrowserTabEmbed.parse(json: #"{"t":"Clip","a":"x.com","d":1,"e":0,"p":0}"#) == nil)
        #expect(BrowserTabEmbed.parse(json: #"{"x":1,"t":"","a":"x.com"}"#) == nil)
    }

    @Test("an unmatched session takes its player tab's title, site, and image")
    func embedDescribesSession() {
        let chrome = "com.google.Chrome"
        let embedded = mediaRemote("Video Player", owner: chrome)
        let page = BrowserTabEmbed(title: "Movie Night", site: "example.com", artwork: "https://example.com/p.jpg",
                                   isFocused: false)
        let merged = NowPlayingMerge.merge(mediaRemote: [embedded], tabs: [chrome: []], embeds: [chrome: [page]])

        #expect(merged.map(\.title) == ["Movie Night"])
        #expect(merged.first?.subtitle == "example.com")
        #expect(merged.first?.artworkKey == "https://example.com/p.jpg")
        #expect(merged.first?.id == embedded.id)

        let withArtwork = mediaRemote("Video Player", owner: chrome, artwork: "mr-art")
        let kept = NowPlayingMerge.merge(mediaRemote: [withArtwork], tabs: [chrome: []], embeds: [chrome: [page]])
        #expect(kept.first?.artworkKey == "mr-art")
    }

    @Test("the page script reports a player frame, and skips small, unprivileged, or off-screen frames")
    func pageScriptFindsPlayerFrame() throws {
        func run(width: Int, allow: String, focused: Bool, top: Int = 100, height: Int = 450,
                 video: Bool = false) throws -> String {
            let context = try #require(JSContext())
            context.evaluateScript("""
            var innerWidth=1200,innerHeight=600;
            var frame={tagName:'IFRAME',getBoundingClientRect:function(){return {width:\(width),height:\(height),\
            top:\(top),left:0,bottom:\(top + height),right:\(width)};},\
            getAttribute:function(n){return n==='allow'?'\(allow)':null;},hasAttribute:function(){return false;}};
            var media={readyState:4,muted:false,volume:1,duration:60,ended:false,paused:false,currentTime:5,\
            playbackRate:1};
            var document={title:'Movie Night',activeElement:\(focused ? "frame" : "null"),\
            querySelectorAll:function(s){return s==='iframe'?[frame]:\(video ? "[media]" : "[]");},\
            querySelector:function(){return null;}};
            var location={hostname:'www.example.com',href:'https://www.example.com/watch'};var navigator={};
            """)
            return context.evaluateScript(BrowserTabScanner.reportMedia)?.toString() ?? ""
        }
        let embed = try #require(BrowserTabEmbed.parse(json: run(width: 800, allow: "autoplay; fullscreen",
                                                                 focused: true)))
        #expect(embed == BrowserTabEmbed(title: "Movie Night", site: "example.com", artwork: nil, isFocused: true))
        #expect(try run(width: 300, allow: "fullscreen", focused: false).isEmpty)
        #expect(try run(width: 800, allow: "", focused: false).isEmpty)
        // Taller than the window but in view counts; scrolled far away doesn't.
        #expect(try !run(width: 704, allow: "fullscreen", focused: false, height: 843).isEmpty)
        #expect(try run(width: 800, allow: "fullscreen", focused: false, top: 2000).isEmpty)

        let ref = BrowserTabRef(windowID: "1", tabKey: "1")
        let media = try run(width: 800, allow: "fullscreen", focused: false, video: true)
        #expect(BrowserTabMedia.session(json: media, tab: ref, ownerBundleID: "b")?.isPlaying == true)
        #expect(BrowserTabEmbed.parse(json: media) == nil)
    }

    @Test("with several player tabs, only a focused one describes the session")
    func ambiguousEmbeds() {
        let page = { (title: String, focused: Bool) in
            BrowserTabEmbed(title: title, site: "a.com", artwork: nil, isFocused: focused)
        }
        #expect(BrowserTabEmbed.likelySource(among: [page("A", false), page("B", false)]) == nil)
        #expect(BrowserTabEmbed.likelySource(among: [page("A", false), page("B", true)])?.title == "B")
        #expect(BrowserTabEmbed.likelySource(among: [page("A", true), page("B", true)]) == nil)
        #expect(BrowserTabEmbed.likelySource(among: []) == nil)
    }
}
