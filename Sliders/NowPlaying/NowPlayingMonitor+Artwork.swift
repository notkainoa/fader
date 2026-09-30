import AppKit

extension NowPlayingMonitor {
    func loadMissingArtwork() {
        let now = Date()
        for key in Set(sessions.compactMap(\.artworkKey)) {
            // Plain http is blocked by App Transport Security anyway.
            guard artwork[key] == nil, !artworkLoads.contains(key),
                  failedArtwork[key].map({ now.timeIntervalSince($0) > Self.artworkRetryDelay }) ?? true,
                  let url = URL(string: key), url.scheme == "https"
            else { continue }
            artworkLoads.insert(key)
            Task { @MainActor [weak self] in
                let image = await Self.downloadArtwork(url).flatMap(NSImage.init(data:))
                guard let self else { return }
                artworkLoads.remove(key)
                if let image {
                    artwork[key] = image
                    failedArtwork[key] = nil
                } else {
                    failedArtwork[key] = Date()
                }
            }
        }
    }

    private static let artworkRetryDelay: TimeInterval = 300
    private nonisolated static let maxArtworkBytes = 4 << 20
    /// Page-supplied addresses: no cookies or cache, short timeouts.
    private nonisolated static let artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    private nonisolated static func downloadArtwork(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await artworkSession.bytes(from: url),
              response.expectedContentLength <= maxArtworkBytes
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxArtworkBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }

    func pruneArtwork() {
        // The helper sends MediaRemote artwork only once, so it stays while
        // its session exists, even when a tab card is shown instead.
        let live = Set(sessions.compactMap(\.artworkKey))
            .union(mediaRemoteSessions.compactMap(\.artworkKey))
        let stale = artwork.keys.filter { !live.contains($0) }
        // A little slack so artwork survives a brief gap between reports.
        guard stale.count > 8 else { return }
        for key in stale {
            artwork[key] = nil
        }
    }
}
