import Foundation
import TOMLKit

public struct Config: Equatable, Sendable {
    public var recordingsDir: URL
    public var sttCommand: String
    public var transcript: TranscriptOptions

    public static let `default` = Config(
        recordingsDir: URL(fileURLWithPath: NSString(string: "~/MeetingRecordings").expandingTildeInPath),
        sttCommand: "parakeet-mlx {audio} --output-format json --output-dir {outdir}",
        transcript: TranscriptOptions()
    )

    public static func load(path: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: path.path) else { return .default }
        let text = try String(contentsOf: path, encoding: .utf8)
        let table = try TOMLTable(string: text)
        var cfg = Config.default

        if let dir = table["recordings_dir"]?.string {
            cfg.recordingsDir = URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath)
        }
        if let stt = table["stt"]?.table, let command = stt["command"]?.string {
            cfg.sttCommand = command
        }
        if let t = table["transcript"]?.table {
            if let gap = t["merge_gap_seconds"]?.double { cfg.transcript.mergeGapSeconds = gap }
            if let gap = t["merge_gap_seconds"]?.int { cfg.transcript.mergeGapSeconds = Double(gap) }
            if let me = t["speaker_me"]?.string { cfg.transcript.speakerMe = me }
            if let them = t["speaker_them"]?.string { cfg.transcript.speakerThem = them }
        }
        return cfg
    }

    public static func loadDefault() throws -> Config {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meet/config.toml")
        return try load(path: path)
    }
}
