import Foundation

/// Owns one recording: creates the session folder, starts both recorders,
/// tracks pause intervals, and finalizes `meta.json` on stop.
///
/// Not thread-safe for concurrent calls to `pause()`/`resume()`/`stop()` —
/// callers (the CLI, the future status-line loop) are expected to serialize
/// these on a single control thread/queue.
public final class RecordingSession {
    public let session: Session
    private let mic: MicRecorder
    private let system: SystemAudioRecorder
    private var meta: SessionMeta
    private var currentPause: PauseInterval?

    public var micHealthy: Bool { mic.isHealthy }
    public var systemHealthy: Bool { system.isHealthy }
    public var isPaused: Bool { currentPause != nil }
    public var elapsedSeconds: Double { max(mic.durationSeconds, system.durationSeconds) }

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
        try system.start()  // fail fast on missing TCC before touching the mic
        do {
            try mic.start()
        } catch {
            system.stop()
            throw error
        }
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
        meta.audioDurationSeconds = elapsedSeconds
        meta.stage = .recorded
        try session.saveMeta(meta)
        return session
    }
}
