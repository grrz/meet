import Foundation

public enum PipelineError: Error, LocalizedError {
    /// `--force` was requested on a session that no longer has any audio
    /// track to re-transcribe — it was completed with `save_audio = false`,
    /// which deletes the WAVs and never writes an m4a. Re-transcribing is
    /// impossible, so this must be refused before the stage reset or the
    /// existing transcript is touched.
    case noAudioToReprocess

    public var errorDescription: String? {
        switch self {
        case .noAudioToReprocess:
            return "no audio tracks to re-transcribe; the session was recorded with save_audio = false"
        }
    }
}

public struct Pipeline: Sendable {
    public var config: Config

    public init(config: Config) { self.config = config }

    public func process(session: Session, force: Bool = false,
                        progress: (@Sendable (String) -> Void)? = nil) throws {
        var meta = try session.loadMeta()
        if force, meta.stage > .recorded {
            guard hasAnyAudio(session: session) else {
                throw PipelineError.noAudioToReprocess
            }
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
            // `debug` keeps everything the pre-cleanup pipeline used to leave
            // behind, regardless of `save_audio`. Otherwise, audio is either
            // compressed to m4a (save_audio = true, the default) or deleted
            // outright (save_audio = false) — and the STT/log intermediates
            // are always removed once debug is off. meta.json is never
            // touched here, so it survives every combination.
            if config.debug || config.saveAudio {
                progress?("compressing audio")
                for (wav, m4a) in [(session.micWAV, session.micM4A),
                                   (session.systemWAV, session.systemM4A)] {
                    if FileManager.default.fileExists(atPath: wav.path) {
                        try AudioCompressor.compress(wav: wav, to: m4a)
                    }
                }
            } else {
                progress?("deleting audio")
                for wav in [session.micWAV, session.systemWAV] {
                    try? FileManager.default.removeItem(at: wav)
                }
            }
            if !config.debug {
                for url in [session.micJSON, session.systemJSON, session.logFile] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            meta.stage = .completed
            try session.saveMeta(meta)
        }
    }

    /// Whether either track still has audio to transcribe from — a WAV (still
    /// recorded, not yet cleaned up) or an m4a (already compressed). False
    /// once a session was completed with `save_audio = false`, which leaves
    /// neither behind for either track.
    private func hasAnyAudio(session: Session) -> Bool {
        let fm = FileManager.default
        let tracks = [(session.micWAV, session.micM4A), (session.systemWAV, session.systemM4A)]
        return tracks.contains { wav, m4a in
            fm.fileExists(atPath: wav.path) || fm.fileExists(atPath: m4a.path)
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

    /// Appends a timestamped line to the session's pipeline log via the
    /// shared `SessionLog` lock — see its doc comment for why writes need to
    /// be serialized (`RecordingSession` writes to the same file from the
    /// recorders' `onEvent` closures).
    private func log(session: Session, _ message: String) {
        SessionLog.append(message, to: session.logFile)
    }
}
