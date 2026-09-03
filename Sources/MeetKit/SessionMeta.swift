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

    public init(startedAt: Date, stage: Stage = .recording) {
        self.startedAt = startedAt
        self.stage = stage
        self.pauseIntervals = []
    }
}
