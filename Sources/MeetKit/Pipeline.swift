import Foundation

public struct Pipeline: Sendable {
    public var config: Config

    public init(config: Config) { self.config = config }

    public func process(session: Session, force: Bool = false,
                        progress: (@Sendable (String) -> Void)? = nil) throws {
        var meta = try session.loadMeta()
        if force, meta.stage > .recorded { meta.stage = .recorded }
        // A crash during recording leaves stage == .recording; the WAVs on disk
        // are all we have — treat it as recorded.
        if meta.stage == .recording { meta.stage = .recorded }

        if meta.stage == .recorded {
            progress?("transcribing mic")
            try transcribeTrack(session: session, wav: session.micWAV,
                                m4a: session.micM4A, json: session.micJSON)
            progress?("transcribing system")
            try transcribeTrack(session: session, wav: session.systemWAV,
                                m4a: session.systemM4A, json: session.systemJSON)
            meta.engineCommand = config.sttCommand
            meta.stage = .transcribed
            try session.saveMeta(meta)
        }

        if meta.stage == .transcribed {
            progress?("assembling transcript")
            let me = try SegmentParser.parse(Data(contentsOf: session.micJSON))
            let them = try SegmentParser.parse(Data(contentsOf: session.systemJSON))
            let duration = meta.audioDurationSeconds
                ?? max(me.last?.end ?? 0, them.last?.end ?? 0)
            let markdown = Transcript.assemble(
                me: me, them: them,
                title: session.displayTitle(meta: meta),
                durationSeconds: duration,
                options: config.transcript)
            try markdown.write(to: session.transcriptMD, atomically: true, encoding: .utf8)
            meta.stage = .merged
            try session.saveMeta(meta)
        }

        if meta.stage == .merged {
            progress?("compressing audio")
            for (wav, m4a) in [(session.micWAV, session.micM4A),
                               (session.systemWAV, session.systemM4A)] {
                if FileManager.default.fileExists(atPath: wav.path) {
                    try AudioCompressor.compress(wav: wav, to: m4a)
                }
            }
            meta.stage = .completed
            try session.saveMeta(meta)
        }
    }

    private func transcribeTrack(session: Session, wav: URL, m4a: URL, json: URL) throws {
        let fm = FileManager.default
        let audio: URL? = fm.fileExists(atPath: wav.path) ? wav
            : fm.fileExists(atPath: m4a.path) ? m4a : nil
        guard let audio else {
            log(session: session, "track \(wav.lastPathComponent) missing; writing empty segments")
            try "[]".write(to: json, atomically: true, encoding: .utf8)
            return
        }
        let runner = STTRunner(commandTemplate: config.sttCommand)
        let scratch = session.directory.appendingPathComponent(".stt-out", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let segments = try runner.transcribe(audio: audio, outdir: scratch,
                                             log: session.logFile)
        let data = try JSONEncoder().encode(segments)
        try data.write(to: json, options: .atomic)
    }

    private func log(session: Session, _ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: session.logFile) {
            try? handle.seekToEnd()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: session.logFile.path,
                                           contents: line.data(using: .utf8))
        }
    }
}
