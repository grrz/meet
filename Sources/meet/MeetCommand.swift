import ArgumentParser
import Foundation
import MeetKit

@main
struct Meet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meet",
        abstract: "Record meetings (mic + system audio) and transcribe them locally.",
        subcommands: [RecordCommand.self, DebugRecord.self],
        defaultSubcommand: RecordCommand.self
    )
}

struct RecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Interactive recording mode (z: start/stop, space: pause, q: quit)."
    )

    func run() throws {
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
