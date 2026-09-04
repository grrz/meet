import Foundation

/// Owns one recording: creates the session folder, starts both recorders,
/// tracks pause intervals, and finalizes `meta.json` on stop.
///
/// Not thread-safe for concurrent calls to `pause()`/`resume()`/`stop()` —
/// callers (the CLI, the future status-line loop) are expected to serialize
/// these on a single control thread/queue.
///
/// The recorders' lifecycle events land on `AudioControl.queue`, so the
/// `onEvent` closures installed below run there rather than on the caller's
/// thread; they only append to the session log, which is why `appendLog`
/// takes a lock.
public final class RecordingSession {
    public let session: Session
    private let mic: MicRecorder
    private let system: SystemAudioRecorder
    private var meta: SessionMeta
    private var currentPause: PauseInterval?

    public var micHealthy: Bool { mic.isHealthy }
    public var systemHealthy: Bool { system.isHealthy }
    public var isPaused: Bool { currentPause != nil }
    public var micDurationSeconds: Double { mic.durationSeconds }
    public var systemDurationSeconds: Double { system.durationSeconds }
    public var elapsedSeconds: Double { max(micDurationSeconds, systemDurationSeconds) }

    /// Creates the session folder, writes the initial `meta.json` (stage
    /// `.recording`), and starts both recorders.
    ///
    /// The system tap is started first so a TCC permission failure surfaces
    /// before the mic (which prompts separately and would otherwise leave a
    /// half-started recording) is touched. If the system tap throws, the
    /// caller decides whether to continue mic-only; the session folder and
    /// its `meta.json` are left in place either way — nothing here deletes
    /// them, matching "recorded audio is sacred" for anything that *did*
    /// get written.
    public init(store: SessionStore, config: Config) throws {
        session = try store.createSession(at: Date())
        meta = SessionMeta(startedAt: Date())
        try session.saveMeta(meta)

        mic = MicRecorder(outputURL: session.micWAV)
        system = SystemAudioRecorder(outputURL: session.systemWAV)
        // Capture `session` (a value type) rather than `self`, which isn't
        // fully initialized yet at this point in init().
        let loggedSession = session
        mic.onEvent = { message in RecordingSession.appendLog(message, to: loggedSession) }
        system.onEvent = { message in RecordingSession.appendLog(message, to: loggedSession) }
        try system.start()  // fail fast on missing TCC before touching the mic
        meta.systemStartedAt = Date()
        do {
            try mic.start()
        } catch {
            system.stop()
            throw error
        }
        meta.micStartedAt = Date()
        // Re-save now that both start timestamps exist. The initial save above
        // still happens first, so a crash during startup leaves a recoverable
        // session folder either way.
        try session.saveMeta(meta)
    }

    /// Pauses both recorders and opens a pause interval. No-op if already paused.
    public func pause() {
        guard currentPause == nil else { return }
        mic.paused = true
        system.paused = true
        currentPause = PauseInterval(start: Date())
    }

    /// Resumes both recorders and closes the open pause interval. No-op if not paused.
    public func resume() {
        guard var pause = currentPause else { return }
        pause.end = Date()
        meta.pauseIntervals.append(pause)
        currentPause = nil
        mic.paused = false
        system.paused = false
    }

    /// Stops both recorders, finalizes the WAVs, and writes the final
    /// `meta.json` (stage `.recorded`, `endedAt`, `audioDurationSeconds`,
    /// `pauseIntervals`). A dangling open pause interval (stop called while
    /// paused) is closed first so it isn't lost.
    @discardableResult
    public func stop() throws -> Session {
        if currentPause != nil { resume() }  // close a dangling pause interval
        mic.stop()
        system.stop()
        meta.endedAt = Date()
        meta.micDurationSeconds = micDurationSeconds
        meta.systemDurationSeconds = systemDurationSeconds
        meta.audioDurationSeconds = elapsedSeconds
        meta.stage = .recorded
        try session.saveMeta(meta)
        return session
    }

    /// Serializes `appendLog`. The two recorders' `onEvent` callbacks already
    /// arrive on one serial queue (`AudioControl.queue`), so they cannot
    /// interleave with each other, but the pipeline writes to the same file
    /// from its own queue once a session is being processed — and
    /// open/seek-to-end/write/close is not atomic, so two writers can produce
    /// a torn line.
    private static let logLock = NSLock()

    /// Appends a timestamped line to the session's pipeline log — same
    /// format as `Pipeline`'s log helper. Used to record recorder lifecycle
    /// events (device-change rebuilds, rebuild failures) that don't fit the
    /// health flag but matter when reading back what happened to a session.
    /// Static, and takes `session` explicitly, so it can be used from the
    /// recorder `onEvent` closures set up during `init()`, before `self` is
    /// fully initialized.
    ///
    /// Called on `AudioControl.queue`, never on the caller's thread.
    private static func appendLog(_ message: String, to session: Session) {
        logLock.lock()
        defer { logLock.unlock() }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: session.logFile) {
            _ = try? handle.seekToEnd()
            handle.write(line.data(using: .utf8)!)
            _ = try? handle.close()
        } else {
            FileManager.default.createFile(atPath: session.logFile.path,
                                           contents: line.data(using: .utf8))
        }
    }
}
