import Foundation
import os

/// Media apps whose AppleScript dictionary has a player with play, pause
/// and a settable position. MediaRemote commands from Fader only reach the
/// elected now-playing app, so these are driven over AppleScript instead
/// whenever another app is elected. Each entry must also be listed under the
/// apple-events temporary exception in Fader.entitlements.
enum ScriptedPlayer {
    enum Outcome: Sendable {
        case done
        /// The user declined Automation access for this app.
        case notAuthorized
        case failed
    }

    static let supported: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.TV",
    ]

    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "ScriptedPlayer")
    private static let notAuthorizedError = -1743
    /// Every NSAppleScript in the app runs here: AppleScript's shared
    /// component isn't safe to use from two threads at once.
    static let appleScriptQueue = DispatchQueue(label: "dev.pantafive.fader.applescript", qos: .userInitiated)

    static func perform(_ command: PlaybackCommand, bundleID: String,
                        completion: @escaping @Sendable (Outcome) -> Void) {
        let source = script(command, bundleID: bundleID)
        appleScriptQueue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else {
                completion(.done)
                return
            }
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            logger.error("Command to \(bundleID, privacy: .public) failed: \(number)")
            completion(number == notAuthorizedError ? .notAuthorized : .failed)
        }
    }

    static func script(_ command: PlaybackCommand, bundleID: String) -> String {
        let action = switch command {
        case .play: "play"
        case .pause: "pause"
        case let .seek(seconds): "set player position to \(max(0, seconds.isFinite ? seconds : 0))"
        }
        // `tell` would launch an app that quit since its last report.
        return """
        if application id "\(bundleID)" is running then
            with timeout of 3 seconds
                tell application id "\(bundleID)" to \(action)
            end timeout
        end if
        """
    }
}
