import Foundation

public struct Pipeline: Sendable {
    public var config: Config

    public init(config: Config) { self.config = config }

    public func process(session: Session, force: Bool = false,
                        progress: (@Sendable (String) -> Void)? = nil) throws {
        var meta = try session.loadMeta()
        if force, meta.stage > .recorded {
            // Persist the reset *before* any work starts. Otherwise a --force
            // rerun that fails partway leaves meta at `completed` alongside
            // half-replaced artifacts, and a plain `meet process` then skips
            // the session entirely instead of retrying it.
            meta.stage = .recorded
            try session.saveMeta(meta)
        }
        // A crash during recording leaves stage == .recording; the WAVs on disk
        // are all we have — treat it as recorded.
        if meta.stage == .recording { meta.stage = .recorded }

        if meta.stage == .recorded {
            repairStaleTrackHeaders(session: session)
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

    /// Recordings made before `WavWriter` started keeping the header
    /// consistent can carry a stale `data` chunk size — killed mid-recording,
    /// their header claims zero frames over real audio. Such a track would be
    /// transcribed as silence and then, worse, "compressed" into an empty m4a
    /// with the WAV deleted. Patch the sizes from the real file length first.
    ///
    /// Deliberately non-throwing: a header we cannot interpret is not a reason
    /// to abandon the run, so it is logged and the track is left exactly as it
    /// was for the stages downstream to judge.
    private func repairStaleTrackHeaders(session: Session) {
        for wav in [session.micWAV, session.systemWAV]
        where FileManager.default.fileExists(atPath: wav.path) {
            do {
                if case .repaired = try WavHeaderRepair.repairIfStale(at: wav) {
                    log(session: session, "repaired stale WAV header: \(wav.lastPathComponent)")
                }
            } catch {
                log(session: session, "could not inspect WAV header for "
                    + "\(wav.lastPathComponent): \(error.localizedDescription)")
            }
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
            _ = try? handle.seekToEnd()
            handle.write(line.data(using: .utf8)!)
            _ = try? handle.close()
        } else {
            FileManager.default.createFile(atPath: session.logFile.path,
                                           contents: line.data(using: .utf8))
        }
    }
}
