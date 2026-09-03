import ArgumentParser
import AVFoundation
import Foundation
import MeetKit

@main
struct Meet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meet",
        abstract: "Record meetings (mic + system audio) and transcribe them locally.",
        subcommands: [RecordCommand.self, ProcessCommand.self, DebugRecord.self],
        defaultSubcommand: RecordCommand.self
    )
}

struct RecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Interactive recording mode (z: start/stop, space: pause, q: quit)."
    )

    func run() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = DispatchSemaphore(value: 0)
            var allowed = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                allowed = ok
                granted.signal()
            }
            granted.wait()
            guard allowed else { throw MicPermissionError() }
        default:
            throw MicPermissionError()
        }
        let config = try Config.loadDefault()
        try InteractiveUI(config: config).run()
    }
}

/// Hidden capture smoke test: records N seconds of mic + system audio and
/// stops. Not part of the public CLI surface yet (no start/pause/stop UX);
/// exists so Task 12 can be verified end-to-end before that lands.
struct DebugRecord: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-record",
        abstract: "Record N seconds and stop (capture smoke test).",
        shouldDisplay: false
    )

    @Option var seconds: Int = 5

    func run() throws {
        let config = try Config.loadDefault()
        let store = SessionStore(rootDir: config.recordingsDir)
        print("Recording \(seconds)s of mic + system audio...")
        let recording = try RecordingSession(store: store, config: config)
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        let session = try recording.stop()
        print("Saved: \(session.directory.path)")
        print("Play back: afplay \(shellQuote(session.micWAV.path))")
        print("           afplay \(shellQuote(session.systemWAV.path))")
    }
}

struct ProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Finish or redo pipeline stages for recorded sessions."
    )

    @Argument(help: "Path to a session folder.")
    var folder: String?

    @Flag(help: "Process every session in the recordings directory.")
    var all = false

    @Flag(help: "Redo all stages even for completed sessions.")
    var force = false

    func run() throws {
        let config = try Config.loadDefault()
        let pipeline = Pipeline(config: config)

        let sessions: [Session]
        if all {
            sessions = try SessionStore(rootDir: config.recordingsDir).allSessions()
        } else if let folder {
            let url = URL(fileURLWithPath: NSString(string: folder).expandingTildeInPath)
            sessions = [Session(directory: url)]
        } else {
            throw ValidationError("Pass a session folder or --all.")
        }

        var failures = 0
        for session in sessions {
            let name = session.directory.lastPathComponent
            guard let meta = try? session.loadMeta() else {
                print("skip \(name): no readable meta.json")
                continue
            }
            if meta.stage == .completed && !force {
                print("skip \(name): already completed")
                continue
            }
            do {
                try pipeline.process(session: session, force: force) { step in
                    print("\(name): \(step)")
                }
                print("✓ \(name)")
            } catch {
                failures += 1
                print("✗ \(name): \(error.localizedDescription)")
            }
        }
        if failures > 0 { throw ExitCode(1) }
    }
}

struct MicPermissionError: Error, CustomStringConvertible {
    var description: String {
        """
        Microphone access denied. Allow your terminal app in
        System Settings → Privacy & Security → Microphone, then rerun.
        """
    }
}
