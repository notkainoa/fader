import Foundation

/// One group in the popover's app list: a mixer row, or just a header for
/// an app that plays media without a Core Audio process right now (a paused
/// browser whose audio service has exited, say). Either way its now-playing
/// cards follow.
struct AppsListEntry: Identifiable, Equatable {
    let bundleID: String
    let name: String
    /// Nil for a header-only group.
    let app: AudioApp?

    var id: String {
        bundleID
    }
}

enum AppsListOrder {
    /// Apps that are playing or have something loaded to resume come first,
    /// then silent apps kept only for their adjusted volume; each part is
    /// alphabetical. Pausing never moves a row: a paused app keeps its
    /// now-playing session, and whether it is making sound this second
    /// doesn't affect the order, so rows stay put while you reach for them.
    static func entries(apps: [AudioApp], nowPlayingBundleIDs: [String], isAdjusted: (AudioApp) -> Bool,
                        name: (String) -> String) -> [AppsListEntry] {
        let nowPlaying = Set(nowPlayingBundleIDs)
        var active: [AppsListEntry] = []
        var adjusted: [AppsListEntry] = []
        for app in apps {
            let entry = AppsListEntry(bundleID: app.bundleID, name: app.name, app: app)
            if app.isPlaying || nowPlaying.contains(app.bundleID) {
                active.append(entry)
            } else if isAdjusted(app) {
                adjusted.append(entry)
            }
        }
        let listed = Set(apps.map(\.bundleID))
        for bundleID in nowPlaying.subtracting(listed) {
            active.append(AppsListEntry(bundleID: bundleID, name: name(bundleID), app: nil))
        }
        return sorted(active) + sorted(adjusted)
    }

    private static func sorted(_ entries: [AppsListEntry]) -> [AppsListEntry] {
        entries.sorted {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.bundleID < $1.bundleID
            }
        }
    }
}
