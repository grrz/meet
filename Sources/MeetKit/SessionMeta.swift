import Foundation

public enum Stage: String, Codable, Sendable, Comparable {
    case recording, recorded, transcribed, merged, completed

    private var order: Int {
        switch self {
        case .recording: 0
        case .recorded: 1
        case .transcribed: 2
        case .merged: 3
        case .completed: 4
        }
    }
    public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.order < rhs.order }
}

public struct PauseInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date?
    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }
}

public struct SessionMeta: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var stage: Stage
    public var pauseIntervals: [PauseInterval]
    public var audioDurationSeconds: Double?
    public var engineCommand: String?
    public var title: String?
    /// When each recorder actually began capturing. The two tracks do not
    /// start together — the system tap is started first so a missing TCC
    /// grant surfaces before the mic prompts — so `startedAt` alone cannot
    /// align them. Optional, and decoded with `decodeIfPresent`, so
    /// `meta.json` files written before these fields existed still load.
    ///
    /// Second-resolution: the session store encodes dates as plain ISO8601,
    /// which has no fractional part — same as `startedAt`/`endedAt`.
    public var micStartedAt: Date?
    public var systemStartedAt: Date?
    /// Per-track writer durations at stop(), independent of
    /// `audioDurationSeconds` (which is `max` of the two). A track whose
    /// duration is far short of the other's is the on-disk trace of a
    /// silent recovery failure (see `StallDetector`) — optional, and
    /// decoded with `decodeIfPresent`, so `meta.json` files written before
    /// these fields existed still load.
    public var micDurationSeconds: Double?
    public var systemDurationSeconds: Double?

    public init(startedAt: Date, stage: Stage = .recording) {
        self.startedAt = startedAt
        self.stage = stage
        self.pauseIntervals = []
    }
}
