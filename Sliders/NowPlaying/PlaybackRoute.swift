import Foundation

/// How a play, pause, or seek reaches a session's player.
enum PlaybackRoute: Equatable, Sendable {
    /// Through the MediaRemote helper, to the client with this pid.
    case mediaRemote(pid_t)
    /// Through the app's AppleScript player dictionary (ScriptedPlayer).
    case appleScript
    /// Through JavaScript run in the tab.
    case browserTab(BrowserTabRef, BrowserFlavor)

    /// Nil when nothing Sliders can do reaches the player. MediaRemote delivers
    /// the app's commands to the elected now-playing app no matter which client
    /// they name, so any other MediaRemote session needs an AppleScript-capable
    /// app the user hasn't blocked.
    static func route(for session: NowPlayingSession, deniedPlayers: Set<String>) -> PlaybackRoute? {
        let bundleID = session.ownerBundleID
        switch session.source {
        case let .mediaRemote(pid):
            if session.isElected { return .mediaRemote(pid) }
            if ScriptedPlayer.supported.contains(bundleID), !deniedPlayers.contains(bundleID) { return .appleScript }
            return nil
        case let .browserTab(tab):
            return BrowserFlavor.supported[bundleID].map { .browserTab(tab, $0) }
        }
    }
}
