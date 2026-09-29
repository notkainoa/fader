#if RENDER_SHOTS
    import AppKit

    extension RenderHarness {
        /// Several things playing at once: a song in Spotify and two YouTube
        /// tabs in one browser, one of them paused with its play button up.
        static func nowPlayingEngine() -> MixerEngine {
            let engine = MixerEngine()
            engine.deviceMonitor.seedForRender(devices: [speakers, airpodsPro],
                                               defaultDeviceID: airpodsPro.id, recentUIDs: [speakers.uid])
            engine.systemVolume.seedForRender(volume: 0.6, isMuted: false, deviceName: airpodsPro.name)
            engine.processMonitor.seedForRender(apps: [
                app(701, "com.spotify.client", "Spotify", playing: true),
                app(703, "com.google.Chrome", "Google Chrome", playing: true),
            ])
            engine.seedForRender(volumes: ["com.spotify.client": AppVolume(volume: 0.65)])

            let now = Date()
            let song = NowPlayingSession(
                source: .mediaRemote(pid: 701), ownerBundleID: "com.spotify.client", title: "Midnight City",
                subtitle: "M83", duration: 244, position: 71, positionDate: now, rate: 1, artworkKey: "art-song"
            )
            let tabs = [
                ("1", "Building a Synth From Scratch", "Look Mum No Computer", 1834.0, 583.0, 1.0),
                ("2", "Lo-fi Beats to Study To", "Chillhop Music", 3600.0, 1260.0, 0.0),
            ].map { key, title, channel, duration, position, rate in
                NowPlayingSession(source: .browserTab(BrowserTabRef(windowID: "1", tabKey: key)),
                                  ownerBundleID: "com.google.Chrome", title: title, subtitle: channel,
                                  duration: duration, position: position, positionDate: now, rate: rate,
                                  artworkKey: "art-\(key)")
            }
            engine.nowPlaying.seedForRender(
                sessions: [song] + tabs,
                artwork: [
                    "art-song": demoArtwork(width: 300, height: 300, colors: [.systemPurple, .systemPink]),
                    "art-1": demoArtwork(width: 480, height: 270, colors: [.systemOrange, .systemRed]),
                    "art-2": demoArtwork(width: 480, height: 270, colors: [.systemTeal, .systemBlue]),
                ]
            )
            return engine
        }

        /// A gradient stand-in for cover art; the harness never hits the network.
        private static func demoArtwork(width: CGFloat, height: CGFloat, colors: [NSColor]) -> NSImage {
            NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
                NSGradient(colors: colors)?.draw(in: rect, angle: 35)
                return true
            }
        }
    }
#endif
