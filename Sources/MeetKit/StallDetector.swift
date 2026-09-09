import Foundation

/// Detects a track whose writer stopped advancing while recording is live.
///
/// A device-switch recovery can silently stop delivering buffers (see
/// `MicRecorder`'s and `SystemAudioRecorder`'s rebuild paths) without ever
/// flipping `isHealthy` to false — the engine/tap looks fine, it just isn't
/// being fed. `StallDetector` catches that class of failure independently,
/// by watching whether the writer's reported duration is actually moving.
public struct StallDetector {
    public var thresholdSeconds: Double

    /// The duration last observed, and when it was last seen to change.
    private var lastDuration: Double?
    private var lastChangeAt: Date?
    private var stalled = false

    public init(thresholdSeconds: Double = 5) {
        self.thresholdSeconds = thresholdSeconds
    }

    /// Feed one sample per tick. Returns true when the track is stalled:
    /// recording (not paused) and duration unchanged for >= threshold.
    ///
    /// Paused ticks always reset the clock — a paused track legitimately
    /// stops advancing, so pause is never reported as a stall, and the
    /// window restarts fresh from the moment recording resumes. A duration
    /// change also resets the clock and immediately clears `stalled`; once
    /// set, `stalled` stays true until duration moves again.
    public mutating func update(duration: Double, isPaused: Bool, now: Date) -> Bool {
        if isPaused {
            lastDuration = duration
            lastChangeAt = now
            stalled = false
            return false
        }

        if lastDuration == nil || duration != lastDuration {
            lastDuration = duration
            lastChangeAt = now
            stalled = false
        } else if let lastChangeAt, now.timeIntervalSince(lastChangeAt) >= thresholdSeconds {
            stalled = true
        }
        return stalled
    }
}
