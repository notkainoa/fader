import SwiftUI

/// A compact take on Control Center's now-playing tile: artwork on the left
/// with the play/pause button over it, title and artist, then a scrubbable
/// progress bar. No skip buttons; the popover is about seeing everything
/// that plays, not driving a queue.
struct NowPlayingCard: View {
    /// MixerView sizes its scroll viewport from this; keep it in sync with
    /// the layout below (artwork height plus vertical padding).
    static let height: CGFloat = 68

    private static let artworkSize = CGSize(width: 92, height: 52)

    @Environment(MixerEngine.self) private var engine
    let session: NowPlayingSession

    @State private var isHovering = false
    /// Position under the finger while scrubbing; nil otherwise.
    @State private var scrubPosition: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = session.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 2)
                timeline
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(height: Self.height)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
    }

    // MARK: - Artwork and play button

    private var canControl: Bool {
        engine.nowPlaying.canControl(session)
    }

    private var artwork: some View {
        let size = Self.artworkSize
        return Button {
            engine.nowPlaying.togglePlayPause(session)
        } label: {
            ZStack {
                artworkImage
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if isHovering || !session.isPlaying {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(canControl ? 1 : 0.4))
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.45), in: Circle())
                        .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // Not .disabled: macOS hides tooltips on disabled controls, and the
        // tooltip is what explains why the button does nothing.
        .animation(.easeOut(duration: 0.15), value: isHovering || !session.isPlaying)
        .help(helpText)
    }

    private var helpText: String {
        if canControl { return session.isPlaying ? "Pause" : "Play" }
        if engine.nowPlaying.deniedPlayers.contains(session.ownerBundleID) {
            return "Allow Sliders to control this app in System Settings › Privacy & Security › Automation"
        }
        if engine.nowPlaying.browsersNeedingJavaScript.contains(session.ownerBundleID) {
            let location = BrowserFlavor.javaScriptSettingLocation(for: session.ownerBundleID)
            let scope = BrowserFlavor.supported[session.ownerBundleID] == .chromium
                ? " (in the profile this tab is open in)" : ""
            return "Another app played more recently. To control this browser anyway, turn on "
                + "Allow JavaScript from Apple Events in \(location)\(scope)."
        }
        return "macOS only lets Sliders control the app that played most recently. Use the app itself to "
            + (session.isPlaying ? "pause" : "play") + " this."
    }

    /// Square album art is letterboxed over a blurred copy of itself so it
    /// fills the video-shaped frame without cropping the cover.
    @ViewBuilder
    private var artworkImage: some View {
        if let key = session.artworkKey, let image = engine.nowPlaying.artwork[key] {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 10)
                    .opacity(0.7)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
            .background(.black)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var timeline: some View {
        if let duration = session.duration {
            // Only a playing session needs the clock; a paused one is static.
            TimelineView(.periodic(from: .now, by: session.isPlaying ? 0.5 : 3600)) { context in
                let position = scrubPosition ?? session.position(at: context.date)
                VStack(spacing: 2) {
                    progressBar(fraction: duration > 0 ? position / duration : 0, duration: duration)
                    HStack {
                        Text(Self.format(position))
                        Spacer()
                        Text("-" + Self.format(max(0, duration - position)))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(session.isPlaying ? Color.red : Color.secondary).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func progressBar(fraction: Double, duration: TimeInterval) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, min(1, fraction)) * width)
            }
            .frame(height: scrubPosition == nil ? 4 : 6)
            .frame(maxHeight: .infinity)
            // The bar is thin; a taller invisible strip makes it easy to grab.
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubPosition = Self.position(atX: value.location.x, width: width, duration: duration)
                    }
                    .onEnded { value in
                        let target = Self.position(atX: value.location.x, width: width, duration: duration)
                        engine.nowPlaying.seek(session, to: target)
                        scrubPosition = nil
                    },
                including: canControl ? .all : .none
            )
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.1), value: scrubPosition == nil)
    }

    private static func position(atX x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(max(0, min(1, x / width))) * duration
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// Header for an app that has something playing but no mixer row (it holds
/// no Core Audio process right now, or per-app volume is paused).
struct NowPlayingAppHeader: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Self.icon(for: bundleID))
                .resizable()
                .frame(width: 18, height: 18)
            Text(Self.name(for: bundleID))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
        .frame(height: Self.height)
    }

    static let height: CGFloat = 22

    @MainActor
    private static func icon(for bundleID: String) -> NSImage {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    @MainActor
    static func name(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent
            ?? bundleID
    }
}

/// Shown under a browser whose tabs could be listed one by one if it allowed
/// JavaScript from Apple Events. It is also what makes a browser controllable
/// when it isn't the elected now-playing app: tab sessions take commands
/// through JavaScript, not MediaRemote.
struct BrowserJavaScriptHint: View {
    /// Four 10pt lines, the Chromium wrap at popover width. Safari's shorter
    /// text often fits in three; overshooting leaves a little space, where
    /// undershooting would scroll the list and clip its last row.
    static let height: CGFloat = 48

    private static let safariDeveloperTip =
        "Safari shows the Developer tab once Settings › Advanced › Show features for web developers is on."

    @Environment(MixerEngine.self) private var engine
    let bundleID: String

    var body: some View {
        let name = NowPlayingAppHeader.name(for: bundleID)
        let location = BrowserFlavor.javaScriptSettingLocation(for: bundleID)
        // Chromium stores the setting per profile; Safari's is global.
        let scope = BrowserFlavor.supported[bundleID] == .chromium ? ", in every profile you use" : ""
        HStack(alignment: .top, spacing: 4) {
            Text("To play and pause \(name) even when another app played last, and to list each tab, "
                + "turn on Allow JavaScript from Apple Events in \(location)\(scope).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(BrowserFlavor.supported[bundleID] == .safari ? Self.safariDeveloperTip : "")
            Button {
                engine.nowPlaying.dismissJavaScriptHint(for: bundleID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don't show this again")
        }
    }
}
