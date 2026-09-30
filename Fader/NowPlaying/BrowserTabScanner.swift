import Foundation
import os

/// Browsers whose AppleScript dictionary can run JavaScript in a tab. Each
/// entry must also be listed under the apple-events temporary exception in
/// Fader.entitlements, or the sandbox drops the event.
enum BrowserFlavor: Sendable {
    /// Chrome's dictionary: `execute tab javascript`, tabs have stable ids.
    case chromium
    /// `do JavaScript … in tab`, tabs addressed by index.
    case safari

    static let supported: [String: BrowserFlavor] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "company.thebrowser.Browser": .chromium,
        "company.thebrowser.dia": .chromium,
        "net.imput.helium": .chromium,
        "ai.perplexity.comet": .chromium,
    ]

    /// Where the browser keeps its "Allow JavaScript from Apple Events"
    /// switch. Most Chromium browsers inherit Chrome's menu; a few moved it.
    static func javaScriptSettingLocation(for bundleID: String) -> String {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": "Settings › Developer"
        case "com.microsoft.edgemac": "Tools › Developer"
        case "com.vivaldi.Vivaldi": "Settings › Privacy and Security"
        default: "View › Developer"
        }
    }
}

/// One tab from a browser's tab list.
struct BrowserTab: Hashable, Sendable {
    let ref: BrowserTabRef
    let url: String
    let title: String
    /// The selected tab of its window.
    let isActive: Bool
}

/// How a tab answered the media script.
enum TabProbeOutcome: Sendable, Equatable {
    /// JSON describing the tab's main media element.
    case media(String)
    case noMedia
    /// No reply in time. Chromium holds the request until the page's script
    /// runs, which never happens in a sleeping or discarded tab.
    case timedOut
    /// JavaScript from Apple Events is off for this tab's browser profile.
    case blocked
    /// The user declined Automation access for this browser.
    case notAuthorized
    case failed
}

/// Lists a browser's tabs and runs a small page script in each one to find
/// its media. MediaRemote only ever sees one session per browser; this is
/// what lets two YouTube tabs show as two entries.
///
/// Page scripts are sent as raw Apple Events, each with its own short
/// timeout, so many tabs can be asked at once and a tab that never answers
/// costs one timeout instead of stalling the rest.
final class BrowserTabScanner: @unchecked Sendable {
    enum TabListResult: Sendable, Equatable {
        case tabs([BrowserTab])
        /// The user declined Automation access for this browser.
        case notAuthorized
        case failed
    }

    /// Enough to find media in a responsive tab; a live renderer answers in
    /// milliseconds.
    static let probeTimeout: TimeInterval = 1
    static let commandTimeout: TimeInterval = 2
    /// Most page scripts a browser is asked to run at once.
    static let maxConcurrentProbes = 16

    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "BrowserTabScanner")
    private static let notAuthorizedError = -1743
    private static let timeoutError = -1712

    /// Tab lists go through NSAppleScript, which must stay on one thread;
    /// listing never runs page scripts, so it stays quick.
    private var listQueue: DispatchQueue { ScriptedPlayer.appleScriptQueue }
    private var compiledLists: [String: NSAppleScript] = [:]
    private let probeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.pantafive.fader.browser-tab-probes"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = maxConcurrentProbes
        return queue
    }()

    func listTabs(bundleID: String, flavor: BrowserFlavor) async -> TabListResult {
        await withCheckedContinuation { continuation in
            listQueue.async { [self] in
                continuation.resume(returning: runList(bundleID: bundleID, flavor: flavor))
            }
        }
    }

    func probe(_ tab: BrowserTabRef, bundleID: String, flavor: BrowserFlavor) async -> TabProbeOutcome {
        await withCheckedContinuation { continuation in
            probeQueue.addOperation {
                continuation.resume(returning: Self.runJavaScript(Self.reportMedia, in: tab, bundleID: bundleID,
                                                                  flavor: flavor, timeout: Self.probeTimeout))
            }
        }
    }

    /// Whether the user already allowed Automation of this browser. Never
    /// shows the consent prompt, so it is safe to ask with no window open.
    func isAutomationAllowed(bundleID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let status = withExtendedLifetime(target) {
                    AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard),
                                                          AEEventID(typeWildCard), false)
                }
                continuation.resume(returning: status == noErr)
            }
        }
    }

    /// Commands skip the probe queue so a click never waits behind a scan.
    func perform(_ command: PlaybackCommand, tab: BrowserTabRef, bundleID: String,
                 flavor: BrowserFlavor) async -> TabProbeOutcome {
        let js = Self.commandJavaScript(command)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runJavaScript(js, in: tab, bundleID: bundleID, flavor: flavor,
                                                                  timeout: Self.commandTimeout))
            }
        }
    }

    // MARK: - Tab list

    private func runList(bundleID: String, flavor: BrowserFlavor) -> TabListResult {
        let script = compiledLists[bundleID] ?? {
            let script = NSAppleScript(source: Self.listScript(bundleID: bundleID, flavor: flavor))
            compiledLists[bundleID] = script
            return script
        }()
        guard let script else { return .failed }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == Self.notAuthorizedError { return .notAuthorized }
            Self.logger.debug("Listing tabs of \(bundleID, privacy: .public) failed: \(number)")
            return .failed
        }
        return .tabs(Self.parseTabList(result))
    }

    /// Reads the `{windowID, tabID, URL, title, activeTabID}` rows the list
    /// script returns. Ids keep the type the browser used for them.
    static func parseTabList(_ list: NSAppleEventDescriptor) -> [BrowserTab] {
        guard list.numberOfItems > 0 else { return [] }
        return (1 ... list.numberOfItems).compactMap { index in
            guard let row = list.atIndex(index), row.numberOfItems == 5,
                  let window = identifier(row.atIndex(1)), let tab = identifier(row.atIndex(2))
            else { return nil }
            let active = identifier(row.atIndex(5))
            return BrowserTab(ref: BrowserTabRef(windowID: window.value, tabKey: tab.value,
                                                 numericIDs: window.numeric && tab.numeric),
                              url: row.atIndex(3)?.stringValue ?? "",
                              title: row.atIndex(4)?.stringValue ?? "",
                              isActive: active?.value == tab.value)
        }
    }

    private static func identifier(_ descriptor: NSAppleEventDescriptor?) -> (value: String, numeric: Bool)? {
        guard let descriptor else { return nil }
        let numericTypes = [typeSInt16, typeSInt32, typeUInt16, typeUInt32, typeSInt64, typeUInt64]
        if numericTypes.map({ DescType($0) }).contains(descriptor.descriptorType) {
            return (String(descriptor.int32Value), true)
        }
        // `missing value` arrives as a type code.
        guard descriptor.descriptorType != DescType(typeNull), descriptor.descriptorType != DescType(typeType),
              let text = descriptor.stringValue, !text.isEmpty
        else { return nil }
        return (text, false)
    }

    /// One row per tab. Each property is fetched for a whole window in one
    /// event; a window without tabs (Safari's settings, DevTools) is skipped.
    static func listScript(bundleID: String, flavor: BrowserFlavor) -> String {
        """
        on asText(v)
            try
                return v as text
            on error
                return ""
            end try
        end asText

        -- `tell` would relaunch a browser the user quit mid-scan.
        if application id "\(bundleID)" is not running then error number -600

        with timeout of 3 seconds
            tell application id "\(bundleID)"
                set out to {}
                repeat with w in windows
                    try
                        set wid to id of w
                        \(windowRows(flavor).replacingOccurrences(of: "\n", with: "\n                "))
                    end try
                end repeat
                return out
            end tell
        end timeout
        """
    }

    /// Appends one row per tab of window `w` to `out`.
    private static func windowRows(_ flavor: BrowserFlavor) -> String {
        switch flavor {
        case .chromium:
            """
            set selKey to missing value
            try
                set selKey to id of active tab of w
            end try
            set ids to id of tabs of w
            set urls to URL of tabs of w
            set titles to title of tabs of w
            repeat with i from 1 to count of ids
                set end of out to {wid, item i of ids, my asText(item i of urls), my asText(item i of titles), selKey}
            end repeat
            """
        case .safari:
            """
            set selKey to missing value
            try
                set selKey to index of current tab of w
            end try
            set urls to URL of tabs of w
            set titles to name of tabs of w
            repeat with i from 1 to count of titles
                set end of out to {wid, i, my asText(item i of urls), my asText(item i of titles), selKey}
            end repeat
            """
        }
    }
}

// MARK: - Page scripts

extension BrowserTabScanner {
    private static func runJavaScript(_ js: String, in tab: BrowserTabRef, bundleID: String, flavor: BrowserFlavor,
                                      timeout: TimeInterval) -> TabProbeOutcome {
        guard let event = javaScriptEvent(js, in: tab, bundleID: bundleID, flavor: flavor) else { return .failed }
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch {
            return outcome(errorNumber: (error as NSError).code, message: "")
        }
        // Script errors (JavaScript turned off, a closed tab) come back
        // inside the reply rather than as a thrown error.
        if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? ""
            return outcome(errorNumber: Int(number), message: message)
        }
        let text = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? ""
        return text.isEmpty ? .noMedia : .media(text)
    }

    static func outcome(errorNumber: Int, message: String) -> TabProbeOutcome {
        switch errorNumber {
        case notAuthorizedError: return .notAuthorized
        case timeoutError: return .timedOut
        default:
            if message.localizedCaseInsensitiveContains("JavaScript") { return .blocked }
            logger.debug("Page script failed: \(errorNumber) \(message, privacy: .public)")
            return .failed
        }
    }

    /// Chromium: `execute (tab id T of window id W) javascript js`.
    /// Safari: `do JavaScript js in (tab T of window id W)`.
    static func javaScriptEvent(_ js: String, in tab: BrowserTabRef, bundleID: String,
                                flavor: BrowserFlavor) -> NSAppleEventDescriptor? {
        let window = objectSpecifier(class: "cwin", form: DescType(formUniqueID),
                                     key: identifierDescriptor(tab.windowID, numeric: tab.numericIDs),
                                     container: .null())
        guard let window else { return nil }
        let event: NSAppleEventDescriptor
        switch flavor {
        case .chromium:
            guard let target = objectSpecifier(class: "CrTb", form: DescType(formUniqueID),
                                               key: identifierDescriptor(tab.tabKey, numeric: tab.numericIDs),
                                               container: window)
            else { return nil }
            event = appleEvent(class: "CrSu", id: "ExJa", bundleID: bundleID)
            event.setParam(target, forKeyword: AEKeyword(keyDirectObject))
            event.setParam(NSAppleEventDescriptor(string: js), forKeyword: fourCharCode("JvSc"))
        case .safari:
            guard let index = Int32(tab.tabKey),
                  let target = objectSpecifier(class: "bTab", form: DescType(formAbsolutePosition),
                                               key: NSAppleEventDescriptor(int32: index), container: window)
            else { return nil }
            event = appleEvent(class: "sfri", id: "dojs", bundleID: bundleID)
            event.setParam(NSAppleEventDescriptor(string: js), forKeyword: AEKeyword(keyDirectObject))
            event.setParam(target, forKeyword: fourCharCode("dcnm"))
        }
        return event
    }

    private static func appleEvent(class eventClass: String, id eventID: String,
                                   bundleID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(withEventClass: fourCharCode(eventClass), eventID: fourCharCode(eventID),
                                          targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
    }

    static func objectSpecifier(class objectClass: String, form: DescType, key: NSAppleEventDescriptor,
                                container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode(objectClass)),
                             forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    }

    private static func identifierDescriptor(_ id: String, numeric: Bool) -> NSAppleEventDescriptor {
        if numeric, let number = Int32(id) { return NSAppleEventDescriptor(int32: number) }
        return NSAppleEventDescriptor(string: id)
    }

    static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// Picks a tab's main media element: audible, loaded, and either playing
    /// or paused partway through. Muted elements are skipped so silent
    /// autoplay previews and background loops don't show up as media.
    private static let pickMedia = """
    function(){var l=[].slice.call(document.querySelectorAll('video,audio')).filter(function(m){\
    return m.readyState>0&&!m.muted&&m.volume>0&&m.duration>0&&!m.ended&&(!m.paused||m.currentTime>0);});\
    l.sort(function(a,b){return (a.paused-b.paused)||(b.currentTime-a.currentTime);});return l[0];}
    """

    static let reportMedia = """
    (function(){try{var m=(\(pickMedia))();if(!m)return '';\
    var s=navigator.mediaSession&&navigator.mediaSession.metadata;var art='';\
    if(s&&s.artwork&&s.artwork.length){art=s.artwork[s.artwork.length-1].src;}\
    if(!art){var o=document.querySelector('meta[property="og:image"]');if(o)art=o.content;}\
    if(art){try{art=new URL(art,location.href).href;}catch(e){art='';}}\
    return JSON.stringify({t:(s&&s.title)||document.title,a:(s&&s.artist)||location.hostname.replace(/^www\\./,''),\
    d:isFinite(m.duration)?m.duration:-1,e:m.currentTime,p:m.paused?0:m.playbackRate,art:art});\
    }catch(e){return '';}})()
    """

    static func commandJavaScript(_ command: PlaybackCommand) -> String {
        let action = switch command {
        case .play: "m.play();"
        case .pause: "m.pause();"
        case let .seek(seconds): "m.currentTime=\(max(0, seconds.isFinite ? seconds : 0));"
        }
        return "(function(){var m=(\(pickMedia))();if(!m)return;\(action)})()"
    }
}
