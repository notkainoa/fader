import SwiftUI

/// The scrolling list of app groups (see AppsListOrder): mixer rows and
/// header-only groups, each followed by whatever the app is playing.
struct AppsList: View {
    @Environment(MixerEngine.self) private var engine
    let entries: [AppsListEntry]
    let routeTargetBundleID: String?

    /// Cards make rows tall; past this the list scrolls even under six rows.
    private static let maxHeight: CGFloat = 440
    private static let groupSpacing: CGFloat = 8

    var body: some View {
        let rows = VStack(spacing: Self.groupSpacing) {
            ForEach(entries) { entry in
                if let app = entry.app {
                    AppRowView(app: app, isRouteTarget: routeTargetBundleID == app.bundleID)
                } else {
                    headerOnlyGroup(for: entry.bundleID)
                }
            }
        }
        .padding(.vertical, 2)

        #if RENDER_SHOTS
            // ImageRenderer doesn't lay out ScrollView content; the render
            // harness seeds few enough apps that a flat list needs no scroll.
            if RenderHarness.isActive {
                rows
            } else {
                scrolling(rows)
            }
        #else
            scrolling(rows)
        #endif
    }

    /// Cards fade in and out and the list eases to its new height when media
    /// comes or goes. Keyed on which cards and hints are showing, not their
    /// contents, so playback progress doesn't animate.
    private func scrolling(_ rows: some View) -> some View {
        ScrollView { rows }
            .frame(height: listHeight)
            .animation(.easeInOut(duration: 0.25), value: nowPlayingLayout)
    }

    private var nowPlayingLayout: [String] {
        let nowPlaying = engine.nowPlaying
        return nowPlaying.sessions.map(\.id)
            + nowPlaying.browsersNeedingJavaScript.subtracting(nowPlaying.dismissedJavaScriptHints).sorted()
            .map { "hint:\($0)" }
    }

    private func headerOnlyGroup(for bundleID: String) -> some View {
        VStack(alignment: .leading, spacing: AppRowView.lineSpacing) {
            NowPlayingAppHeader(bundleID: bundleID)
            ForEach(engine.nowPlaying.sessions(forBundleID: bundleID)) { session in
                NowPlayingCard(session: session)
                    .transition(.opacity)
            }
            if engine.nowPlaying.shouldShowJavaScriptHint(for: bundleID) {
                BrowserJavaScriptHint(bundleID: bundleID)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
    }

    /// MenuBarExtra windows size to the content's ideal height, and a
    /// ScrollView's ideal height is zero — give it an explicit one. Cap the
    /// viewport at six groups, summing each one's real height: routed rows
    /// carry a device card, playing apps their media cards.
    private var listHeight: CGFloat {
        let heights = entries.map { entry in
            entry.app.map(rowHeight(for:)) ?? headerOnlyHeight(for: entry.bundleID)
        }
        return min(heights.prefix(6).reduce(0, +), Self.maxHeight)
    }

    private func rowHeight(for app: AudioApp) -> CGFloat {
        let pins = engine.routeUIDs(for: app).count
        let base = pins == 0
            ? AppRowView.rowHeight
            : AppRowView.routedHeaderHeight + CGFloat(pins) * AppRowView.routeDeviceHeight
        return base + nowPlayingHeight(for: app.bundleID)
    }

    private func headerOnlyHeight(for bundleID: String) -> CGFloat {
        NowPlayingAppHeader.height + Self.groupSpacing + nowPlayingHeight(for: bundleID)
    }

    /// Height of the now-playing cards (and JavaScript hint) under one app.
    private func nowPlayingHeight(for bundleID: String) -> CGFloat {
        let cards = CGFloat(engine.nowPlaying.sessions(forBundleID: bundleID).count)
        let hint: CGFloat = engine.nowPlaying.shouldShowJavaScriptHint(for: bundleID)
            ? BrowserJavaScriptHint.height + AppRowView.lineSpacing : 0
        return cards * (NowPlayingCard.height + AppRowView.lineSpacing) + hint
    }
}
