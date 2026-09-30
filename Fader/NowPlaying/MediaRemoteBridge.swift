import Foundation
import os

/// Runs the bundled FaderMediaRemote library inside `/usr/bin/perl`, the one
/// reliable way left for a third-party app to read MediaRemote (see the
/// comment at the top of FaderMediaRemote.m). The helper streams a snapshot
/// of every now-playing client on each change and takes playback commands on
/// stdin; one long-lived process serves both.
final class MediaRemoteBridge: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.pantafive.fader", category: "MediaRemoteBridge")
    private static let libraryName = "libFaderMediaRemote.dylib"
    /// The helper's exit status when MediaRemote can't be loaded at all;
    /// restarting would only fail again.
    private static let unavailableStatus: Int32 = 2
    private static let perlLoader = """
    use DynaLoader;
    my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($h, "fader_media_remote_run") or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::run", $s);
    run();
    """

    /// Serializes all process state; the pipe handlers fire on arbitrary threads.
    private let queue = DispatchQueue(label: "dev.pantafive.fader.mediaremote-bridge", qos: .utility)
    private let onUpdate: @Sendable ([MediaRemoteClientInfo]) -> Void
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var isStopped = false
    private var isUnavailable = false
    private var recentCrashes = 0
    private var launchedAt = Date.distantPast

    init(onUpdate: @escaping @Sendable ([MediaRemoteClientInfo]) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [self] in
            isStopped = false
            launch()
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            process?.terminate()
            process = nil
            input = nil
        }
    }

    /// Launches the helper again if it gave up after repeated crashes or
    /// failed to launch, e.g. when the user opens the popover.
    func retryIfNeeded() {
        queue.async { [self] in
            guard process == nil, !isStopped, !isUnavailable else { return }
            recentCrashes = 0
            launch()
        }
    }

    /// Sends one helper command, e.g. "toggle 1234" or "seek 1234 42.5".
    func send(_ command: String) {
        queue.async { [self] in
            guard let input else { return }
            do {
                try input.write(contentsOf: Data((command + "\n").utf8))
            } catch {
                Self.logger.error("Command write failed: \(error.localizedDescription)")
            }
        }
    }

    private func launch() {
        guard process == nil, !isStopped else { return }
        guard let frameworks = Bundle.main.privateFrameworksURL else { return }
        let library = frameworks.appendingPathComponent(Self.libraryName)
        guard FileManager.default.fileExists(atPath: library.path) else {
            Self.logger.error("Helper library missing at \(library.path, privacy: .public)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.perlLoader, library.path]
        // PERL5OPT, PERL5LIB and the like from the user's environment would
        // change how perl loads the library.
        let inherited = ProcessInfo.processInfo.environment
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            .merging(["HOME", "TMPDIR"].compactMap { key in inherited[key].map { (key, $0) } }) { $1 }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self, let process else { return }
            queue.async {
                // Output still in the pipe after the helper exited is stale.
                guard process === self.process else { return }
                self.consume(data)
            }
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let status = finished.terminationStatus
            queue.async { self.handleExit(of: finished, status: status) }
        }

        do {
            try process.run()
        } catch {
            Self.logger.error("Could not launch helper: \(error.localizedDescription)")
            return
        }
        self.process = process
        // A write racing the helper's exit would otherwise raise SIGPIPE and
        // kill Fader; with this it just fails with EPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = stdinPipe.fileHandleForWriting
        buffer.removeAll()
        launchedAt = Date()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if let sessions = MediaRemoteClientInfo.decodeLine(Data(line)) {
                onUpdate(sessions)
            }
        }
    }

    private func handleExit(of finished: Process, status: Int32) {
        guard finished === process else { return }
        process = nil
        input = nil
        onUpdate([])
        guard !isStopped else { return }

        if status == Self.unavailableStatus {
            isUnavailable = true
            Self.logger.error("MediaRemote unavailable; now playing disabled")
            return
        }
        // A helper that ran a good while crashed by bad luck; one that dies
        // right away will keep dying, so back off and eventually give up.
        if Date().timeIntervalSince(launchedAt) > 60 { recentCrashes = 0 }
        recentCrashes += 1
        guard recentCrashes <= 5 else {
            Self.logger.error("Helper keeps exiting (status \(status)); giving up")
            return
        }
        let delay = Double(1 << recentCrashes)
        Self.logger.info("Helper exited (status \(status)); relaunching in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }
}
