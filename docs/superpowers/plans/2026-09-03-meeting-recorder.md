# Meeting Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS CLI (`meet`) that records mic + system audio as two WAV tracks without touching audio routing, transcribes them with a config-defined external STT command (parakeet-mlx today), and assembles a speaker-labeled markdown transcript.

**Architecture:** One Swift Package. `MeetKit` (library) holds capture, pipeline, and transcript assembly; `meet` (executable) is a thin interactive terminal UI (keys `z`/space/`q`) plus a `process` catch-up subcommand. STT is an external subprocess with a JSON file contract. Pipeline stages (`recorded → transcribed → merged → completed`) are tracked in per-session `meta.json` so any stage can be resumed or redone.

**Tech Stack:** Swift 6 toolchain (language mode 5), AVFoundation (mic, WAV writing, m4a compression), CoreAudio process taps (system audio, macOS 14.2+ API), swift-argument-parser, TOMLKit.

**Spec:** `docs/superpowers/specs/2026-09-03-meeting-recorder-design.md`

## Global Constraints

- Platform floor: `.macOS("15.0")` in Package.swift. Dev machine runs macOS 26.
- Repository content (code, comments, docs, commit messages) is English only.
- Audio internals are fixed constants: 48 000 Hz, mono, 16-bit PCM WAV during recording; not exposed in config.
- Default config values (used when `~/.config/meet/config.toml` absent):
  `recordings_dir = "~/MeetingRecordings"`,
  `stt.command = "parakeet-mlx {audio} --output-format json --output-dir {outdir}"`,
  `transcript.merge_gap_seconds = 2.0`, `speaker_me = "Me"`, `speaker_them = "Them"`.
- STT JSON contract (lenient): a top-level array of segments, or an object with `segments` or `sentences` array; each segment has `text` (string), `start`, `end` (seconds, numbers). Extra fields ignored. parakeet-mlx emits `{"text": ..., "sentences": [{"text","start","end",...}]}` — verified against installed v0.5.1.
- Recorded audio is sacred: no pipeline failure may delete or truncate WAV/m4a files. WAVs are deleted only after successful compression to m4a.
- Every task: run `swift build && swift test` before committing. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Tests must not require microphone/system-audio permissions; capture code is verified manually (Tasks 10–12 include manual verification steps to be run by the human or main agent, not asserted by subagents).

## File Structure

```
Package.swift
Sources/MeetKit/
  Config.swift              # Config struct + TOML loading with defaults
  Segment.swift             # Segment model + lenient JSON parser
  Transcript.swift          # pure assembly: two segment lists -> markdown
  SessionMeta.swift         # meta.json model: stages, timestamps, pauses
  SessionStore.swift        # session folder creation/lookup/listing
  STTRunner.swift           # external command execution + JSON discovery
  WavWriter.swift           # streaming PCM -> 48k mono 16-bit WAV
  AudioCompressor.swift     # WAV -> m4a (AAC), used post-transcription
  Pipeline.swift            # stage orchestration per meta.json
  MicRecorder.swift         # AVAudioEngine input -> WavWriter
  SystemAudioRecorder.swift # CoreAudio process tap -> WavWriter
  RecordingSession.swift    # both recorders + pause + stop -> session dir
Sources/meet/
  MeetCommand.swift         # ArgumentParser root: record (default), process
  InteractiveUI.swift       # raw-mode key loop, status line, job queue
Tests/MeetKitTests/
  SegmentTests.swift
  TranscriptTests.swift
  ConfigTests.swift
  SessionStoreTests.swift
  STTRunnerTests.swift
  WavWriterTests.swift
  CompressorTests.swift
  PipelineTests.swift
README.md
```

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/MeetKit/Segment.swift` (placeholder-free minimal type), `Sources/meet/MeetCommand.swift` (stub main), `Tests/MeetKitTests/SegmentTests.swift`

**Interfaces:**
- Produces: buildable package with targets `MeetKit`, `meet`, `MeetKitTests`; `struct Segment { var text: String; var start: Double; var end: Double }` (Codable, Equatable, public).

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meet",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "MeetKit",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "meet",
            dependencies: [
                "MeetKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeetKitTests",
            dependencies: ["MeetKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Write .gitignore**

```
.build/
.swiftpm/
*.xcodeproj
.DS_Store
```

- [ ] **Step 3: Minimal Segment type + smoke test**

`Sources/MeetKit/Segment.swift`:
```swift
import Foundation

public struct Segment: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}
```

`Sources/meet/MeetCommand.swift`:
```swift
import ArgumentParser

@main
struct Meet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meet",
        abstract: "Record meetings (mic + system audio) and transcribe them locally."
    )
}
```

`Tests/MeetKitTests/SegmentTests.swift`:
```swift
import XCTest
@testable import MeetKit

final class SegmentTests: XCTestCase {
    func testSegmentRoundTrip() throws {
        let s = Segment(text: "hi", start: 0.5, end: 1.25)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Segment.self, from: data)
        XCTAssertEqual(s, back)
    }
}
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: build succeeds, 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: scaffold Swift package (MeetKit + meet CLI)"
```

---

### Task 2: Segment JSON parser (lenient STT contract)

**Files:**
- Modify: `Sources/MeetKit/Segment.swift`
- Test: `Tests/MeetKitTests/SegmentTests.swift`

**Interfaces:**
- Produces: `enum SegmentParser { public static func parse(_ data: Data) throws -> [Segment] }` — accepts (a) top-level JSON array of segment objects, (b) `{"segments": [...]}`, (c) `{"sentences": [...]}` (parakeet-mlx shape). Extra fields ignored. Throws `SegmentParser.Error.unrecognizedShape` otherwise. Segments returned sorted by `start`.

- [ ] **Step 1: Write failing tests**

Append to `SegmentTests.swift`:
```swift
    func testParsesParakeetShape() throws {
        let json = """
        {"text": "Hello world.",
         "sentences": [
           {"text": "Hello", "start": 0.1, "end": 0.8, "duration": 0.7, "confidence": 0.98, "tokens": []},
           {"text": "world.", "start": 0.9, "end": 1.4, "duration": 0.5, "confidence": 0.97, "tokens": []}
         ]}
        """.data(using: .utf8)!
        let segs = try SegmentParser.parse(json)
        XCTAssertEqual(segs, [
            Segment(text: "Hello", start: 0.1, end: 0.8),
            Segment(text: "world.", start: 0.9, end: 1.4),
        ])
    }

    func testParsesBareArrayAndSegmentsKeySortedByStart() throws {
        let bare = """
        [{"text": "b", "start": 2.0, "end": 3.0}, {"text": "a", "start": 0.0, "end": 1.0}]
        """.data(using: .utf8)!
        XCTAssertEqual(try SegmentParser.parse(bare).map(\.text), ["a", "b"])

        let keyed = """
        {"segments": [{"text": "x", "start": 0, "end": 1}]}
        """.data(using: .utf8)!
        XCTAssertEqual(try SegmentParser.parse(keyed).count, 1)
    }

    func testRejectsUnknownShape() {
        let bad = "{\"foo\": 1}".data(using: .utf8)!
        XCTAssertThrowsError(try SegmentParser.parse(bad))
    }
```

- [ ] **Step 2: Run tests, verify the new ones fail** (`swift test`) — expected: compile error / failures for `SegmentParser`.

- [ ] **Step 3: Implement**

Append to `Segment.swift`:
```swift
public enum SegmentParser {
    public enum Error: Swift.Error, LocalizedError {
        case unrecognizedShape
        public var errorDescription: String? {
            "STT JSON has no top-level array nor 'segments'/'sentences' key"
        }
    }

    public static func parse(_ data: Data) throws -> [Segment] {
        let decoder = JSONDecoder()
        let raw = try JSONSerialization.jsonObject(with: data)
        let array: Any?
        if raw is [Any] {
            array = raw
        } else if let dict = raw as? [String: Any] {
            array = dict["segments"] ?? dict["sentences"]
        } else {
            array = nil
        }
        guard let array, JSONSerialization.isValidJSONObject(array) else {
            throw Error.unrecognizedShape
        }
        let arrayData = try JSONSerialization.data(withJSONObject: array)
        struct Loose: Codable {
            var text: String
            var start: Double
            var end: Double
        }
        let loose = try decoder.decode([Loose].self, from: arrayData)
        return loose
            .map { Segment(text: $0.text, start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
    }
}
```

- [ ] **Step 4: Run tests, verify pass** (`swift test`)

- [ ] **Step 5: Commit** — `feat: lenient STT segment JSON parser`

---

### Task 3: Transcript assembly

**Files:**
- Create: `Sources/MeetKit/Transcript.swift`
- Test: `Tests/MeetKitTests/TranscriptTests.swift`

**Interfaces:**
- Consumes: `Segment` (Task 1).
- Produces:
```swift
public struct TranscriptOptions: Sendable {
    public var mergeGapSeconds: Double  // default 2.0
    public var speakerMe: String        // default "Me"
    public var speakerThem: String      // default "Them"
    public init(mergeGapSeconds: Double = 2.0, speakerMe: String = "Me", speakerThem: String = "Them")
}
public enum Transcript {
    /// title e.g. "Call 2026-09-03 14:20", duration in seconds of the longest track.
    public static func assemble(me: [Segment], them: [Segment],
                                title: String, durationSeconds: Double,
                                options: TranscriptOptions) -> String
}
```
Output format (exact):
```
# <title> (<N> min)

**[HH:MM:SS] <Speaker>:** <text>
**[HH:MM:SS] <Speaker>:** <text>
```
Merging rule: after sorting all labeled segments by `start`, consecutive segments with the same speaker merge into one utterance when `next.start - previous.end < mergeGapSeconds`; merged text joins with a single space; the utterance keeps the first segment's start time. `(<N> min)` is `Int((durationSeconds / 60).rounded())`; use `(<N> sec)` when under 60 s. Empty input on both tracks yields the header plus `_(no speech recognized)_` line.

- [ ] **Step 1: Write failing tests**

`Tests/MeetKitTests/TranscriptTests.swift`:
```swift
import XCTest
@testable import MeetKit

final class TranscriptTests: XCTestCase {
    let opts = TranscriptOptions()

    func testInterleavesSpeakersChronologically() {
        let md = Transcript.assemble(
            me: [Segment(text: "Yes, loud and clear.", start: 6, end: 8)],
            them: [Segment(text: "Hi Greg, can you hear me?", start: 3, end: 5)],
            title: "Call 2026-09-03 14:20", durationSeconds: 3120, options: opts)
        XCTAssertEqual(md, """
        # Call 2026-09-03 14:20 (52 min)

        **[00:00:03] Them:** Hi Greg, can you hear me?
        **[00:00:06] Me:** Yes, loud and clear.
        """)
    }

    func testMergesSameSpeakerWithinGap() {
        let md = Transcript.assemble(
            me: [Segment(text: "So,", start: 10, end: 11),
                 Segment(text: "let's start.", start: 12, end: 13),
                 Segment(text: "Next topic.", start: 20, end: 21)],
            them: [],
            title: "T", durationSeconds: 30, options: opts)
        XCTAssertTrue(md.contains("**[00:00:10] Me:** So, let's start."))
        XCTAssertTrue(md.contains("**[00:00:20] Me:** Next topic."))
    }

    func testEmptyTracksProducePlaceholderLine() {
        let md = Transcript.assemble(me: [], them: [], title: "T",
                                     durationSeconds: 5, options: opts)
        XCTAssertTrue(md.contains("(5 sec)"))
        XCTAssertTrue(md.contains("_(no speech recognized)_"))
    }

    func testHourLongTimecodes() {
        let md = Transcript.assemble(
            me: [Segment(text: "still here", start: 3725, end: 3726)],
            them: [], title: "T", durationSeconds: 3800, options: opts)
        XCTAssertTrue(md.contains("**[01:02:05] Me:**"))
    }
}
```

- [ ] **Step 2: Run, verify failure** (`swift test`)

- [ ] **Step 3: Implement**

`Sources/MeetKit/Transcript.swift`:
```swift
import Foundation

public struct TranscriptOptions: Sendable {
    public var mergeGapSeconds: Double
    public var speakerMe: String
    public var speakerThem: String

    public init(mergeGapSeconds: Double = 2.0,
                speakerMe: String = "Me",
                speakerThem: String = "Them") {
        self.mergeGapSeconds = mergeGapSeconds
        self.speakerMe = speakerMe
        self.speakerThem = speakerThem
    }
}

public enum Transcript {
    struct Utterance {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    public static func assemble(me: [Segment], them: [Segment],
                                title: String, durationSeconds: Double,
                                options: TranscriptOptions) -> String {
        let labeled = (me.map { (options.speakerMe, $0) } + them.map { (options.speakerThem, $0) })
            .sorted { $0.1.start < $1.1.start }

        var utterances: [Utterance] = []
        for (speaker, seg) in labeled {
            if var last = utterances.last,
               last.speaker == speaker,
               seg.start - last.end < options.mergeGapSeconds {
                last.text += " " + seg.text
                last.end = max(last.end, seg.end)
                utterances[utterances.count - 1] = last
            } else {
                utterances.append(Utterance(speaker: speaker, start: seg.start,
                                            end: seg.end, text: seg.text))
            }
        }

        let durationLabel: String
        if durationSeconds < 60 {
            durationLabel = "\(Int(durationSeconds.rounded())) sec"
        } else {
            durationLabel = "\(Int((durationSeconds / 60).rounded())) min"
        }

        var lines = ["# \(title) (\(durationLabel))", ""]
        if utterances.isEmpty {
            lines.append("_(no speech recognized)_")
        } else {
            for u in utterances {
                lines.append("**[\(timecode(u.start))] \(u.speaker):** \(u.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `feat: transcript assembly from two segment tracks`

---

### Task 4: Config loading

**Files:**
- Create: `Sources/MeetKit/Config.swift`
- Test: `Tests/MeetKitTests/ConfigTests.swift`

**Interfaces:**
- Produces:
```swift
public struct Config: Equatable, Sendable {
    public var recordingsDir: URL       // tilde expanded
    public var sttCommand: String
    public var transcript: TranscriptOptions  // (make TranscriptOptions Equatable)
    public static let `default`: Config
    /// Loads from path if it exists; missing file or missing keys fall back to defaults.
    /// Malformed TOML throws.
    public static func load(path: URL) throws -> Config
    /// Default path: ~/.config/meet/config.toml
    public static func loadDefault() throws -> Config
}
```

- [ ] **Step 1: Write failing tests**

`Tests/MeetKitTests/ConfigTests.swift`:
```swift
import XCTest
@testable import MeetKit

final class ConfigTests: XCTestCase {
    func testMissingFileGivesDefaults() throws {
        let cfg = try Config.load(path: URL(fileURLWithPath: "/nonexistent/config.toml"))
        XCTAssertEqual(cfg, Config.default)
        XCTAssertTrue(cfg.sttCommand.contains("parakeet-mlx"))
        XCTAssertEqual(cfg.transcript.speakerMe, "Me")
    }

    func testPartialFileOverridesOnlyGivenKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try """
        recordings_dir = "/tmp/rec"

        [transcript]
        speaker_me = "Greg"
        """.write(to: path, atomically: true, encoding: .utf8)

        let cfg = try Config.load(path: path)
        XCTAssertEqual(cfg.recordingsDir.path, "/tmp/rec")
        XCTAssertEqual(cfg.transcript.speakerMe, "Greg")
        XCTAssertEqual(cfg.transcript.speakerThem, "Them")       // default kept
        XCTAssertEqual(cfg.sttCommand, Config.default.sttCommand) // default kept
    }

    func testTildeExpansion() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try "recordings_dir = \"~/SomeDir\"".write(to: path, atomically: true, encoding: .utf8)
        let cfg = try Config.load(path: path)
        XCTAssertFalse(cfg.recordingsDir.path.contains("~"))
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

`Sources/MeetKit/Config.swift`:
```swift
import Foundation
import TOMLKit

extension TranscriptOptions: Equatable {}

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
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `feat: TOML config with full defaults`

---

### Task 5: Session meta + session store

**Files:**
- Create: `Sources/MeetKit/SessionMeta.swift`, `Sources/MeetKit/SessionStore.swift`
- Test: `Tests/MeetKitTests/SessionStoreTests.swift`

**Interfaces:**
- Produces:
```swift
public enum Stage: String, Codable, Sendable, Comparable {
    case recording, recorded, transcribed, merged, completed
    // Comparable by pipeline order (recording < recorded < ... < completed)
}
public struct PauseInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date?
    public init(start: Date, end: Date? = nil)
}
public struct SessionMeta: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var stage: Stage
    public var pauseIntervals: [PauseInterval]
    public var audioDurationSeconds: Double?  // frames written / 48000, pause-free
    public var engineCommand: String?         // stt command used at transcription time
    public var title: String?                 // future calendar integration writes this
    public init(startedAt: Date, stage: Stage = .recording)
}
public struct Session: Equatable, Sendable {
    public var directory: URL
    public var micWAV: URL        // directory/mic.wav
    public var systemWAV: URL     // directory/system.wav
    public var micM4A: URL        // directory/mic.m4a
    public var systemM4A: URL     // directory/system.m4a
    public var micJSON: URL       // directory/mic.json
    public var systemJSON: URL    // directory/system.json
    public var transcriptMD: URL  // directory/transcript.md
    public var metaJSON: URL      // directory/meta.json
    public var logFile: URL       // directory/pipeline.log
    public init(directory: URL)
    public func loadMeta() throws -> SessionMeta
    public func saveMeta(_ meta: SessionMeta) throws   // pretty-printed, ISO-8601 dates
    /// "Call 2026-09-03 14:20" derived from meta.title ?? startedAt
    public func displayTitle(meta: SessionMeta) -> String
}
public struct SessionStore: Sendable {
    public var rootDir: URL
    public init(rootDir: URL)
    /// Creates rootDir if needed and a new "yyyy-MM-dd-HHmm" folder ( "-2", "-3" on collision).
    public func createSession(at date: Date) throws -> Session
    /// All session folders (subdirectories containing meta.json), sorted by name.
    public func allSessions() throws -> [Session]
}
```

- [ ] **Step 1: Write failing tests**

`Tests/MeetKitTests/SessionStoreTests.swift`:
```swift
import XCTest
@testable import MeetKit

final class SessionStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meet-tests-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateSessionMakesNamedFolder() throws {
        let store = SessionStore(rootDir: root)
        let date = ISO8601DateFormatter().date(from: "2026-09-03T14:20:00+03:00")!
        let session = try store.createSession(at: date)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertTrue(session.directory.lastPathComponent.hasPrefix("2026-09-03-"))
        XCTAssertEqual(session.micWAV.lastPathComponent, "mic.wav")
    }

    func testCollisionAppendsSuffix() throws {
        let store = SessionStore(rootDir: root)
        let date = Date()
        let a = try store.createSession(at: date)
        let b = try store.createSession(at: date)
        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertTrue(b.directory.lastPathComponent.hasSuffix("-2"))
    }

    func testMetaRoundTripAndListing() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        var meta = SessionMeta(startedAt: Date())
        meta.stage = .recorded
        meta.pauseIntervals = [PauseInterval(start: Date(), end: Date())]
        try session.saveMeta(meta)
        let loaded = try session.loadMeta()
        XCTAssertEqual(loaded.stage, .recorded)
        XCTAssertEqual(loaded.pauseIntervals.count, 1)

        let all = try store.allSessions()
        XCTAssertEqual(all.map(\.directory), [session.directory])
    }

    func testStageOrdering() {
        XCTAssertTrue(Stage.recorded < Stage.transcribed)
        XCTAssertTrue(Stage.merged < Stage.completed)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

`Sources/MeetKit/SessionMeta.swift`:
```swift
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
```

`Sources/MeetKit/SessionStore.swift`:
```swift
import Foundation

public struct Session: Equatable, Sendable {
    public var directory: URL
    public var micWAV: URL { directory.appendingPathComponent("mic.wav") }
    public var systemWAV: URL { directory.appendingPathComponent("system.wav") }
    public var micM4A: URL { directory.appendingPathComponent("mic.m4a") }
    public var systemM4A: URL { directory.appendingPathComponent("system.m4a") }
    public var micJSON: URL { directory.appendingPathComponent("mic.json") }
    public var systemJSON: URL { directory.appendingPathComponent("system.json") }
    public var transcriptMD: URL { directory.appendingPathComponent("transcript.md") }
    public var metaJSON: URL { directory.appendingPathComponent("meta.json") }
    public var logFile: URL { directory.appendingPathComponent("pipeline.log") }

    public init(directory: URL) { self.directory = directory }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func loadMeta() throws -> SessionMeta {
        try Self.decoder.decode(SessionMeta.self, from: Data(contentsOf: metaJSON))
    }

    public func saveMeta(_ meta: SessionMeta) throws {
        try Self.encoder.encode(meta).write(to: metaJSON, options: .atomic)
    }

    public func displayTitle(meta: SessionMeta) -> String {
        if let title = meta.title { return title }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Call \(formatter.string(from: meta.startedAt))"
    }
}

public struct SessionStore: Sendable {
    public var rootDir: URL

    public init(rootDir: URL) { self.rootDir = rootDir }

    public func createSession(at date: Date) throws -> Session {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let base = formatter.string(from: date)
        let fm = FileManager.default
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)

        var candidate = rootDir.appendingPathComponent(base)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = rootDir.appendingPathComponent("\(base)-\(n)")
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return Session(directory: candidate)
    }

    public func allSessions() throws -> [Session] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDir.path) else { return [] }
        return try fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: url.appendingPathComponent("meta.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Session.init(directory:))
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `feat: session folders and meta.json with pipeline stages`

---

### Task 6: STT runner (external command contract)

**Files:**
- Create: `Sources/MeetKit/STTRunner.swift`
- Test: `Tests/MeetKitTests/STTRunnerTests.swift`

**Interfaces:**
- Consumes: `SegmentParser.parse` (Task 2).
- Produces:
```swift
public struct STTRunner: Sendable {
    public var commandTemplate: String
    public init(commandTemplate: String)
    /// Renders {audio}/{outdir} (shell-quoted), runs via /bin/sh -c,
    /// appends combined stdout+stderr to `log`, then parses
    /// <outdir>/<audio stem>.json. Throws STTError on nonzero exit or missing JSON.
    public func transcribe(audio: URL, outdir: URL, log: URL) throws -> [Segment]
}
public enum STTError: Error, LocalizedError {
    case engineFailed(exitCode: Int32, logFile: URL)
    case outputMissing(expected: URL, logFile: URL)
}
```
Also produces internal helpers used by tests: `STTRunner.render(template:audio:outdir:) -> String` and `shellQuote(_ s: String) -> String` (single-quote escaping).

- [ ] **Step 1: Write failing tests**

`Tests/MeetKitTests/STTRunnerTests.swift`:
```swift
import XCTest
@testable import MeetKit

final class STTRunnerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testShellQuoting() {
        XCTAssertEqual(shellQuote("/a b/c'd"), "'/a b/c'\\''d'")
    }

    func testRenderSubstitutesQuotedPaths() {
        let runner = STTRunner(commandTemplate: "engine {audio} --out {outdir}")
        let cmd = runner.render(audio: URL(fileURLWithPath: "/tmp/a b.wav"),
                                outdir: URL(fileURLWithPath: "/tmp/out"))
        XCTAssertEqual(cmd, "engine '/tmp/a b.wav' --out '/tmp/out'")
    }

    /// Fake engine: a shell script that writes a fixture JSON named after the audio stem.
    func testRunsFakeEngineAndParsesOutput() throws {
        let audio = dir.appendingPathComponent("mic.wav")
        try Data().write(to: audio)
        let engine = dir.appendingPathComponent("fake-engine.sh")
        try """
        #!/bin/sh
        # $1 = audio path, $2 = outdir
        stem=$(basename "$1" .wav)
        printf '{"sentences":[{"text":"hello","start":0.0,"end":1.0}]}' > "$2/$stem.json"
        echo "fake engine done"
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)

        let runner = STTRunner(commandTemplate: "\(shellQuote(engine.path)) {audio} {outdir}")
        let log = dir.appendingPathComponent("run.log")
        let segments = try runner.transcribe(audio: audio, outdir: dir, log: log)

        XCTAssertEqual(segments, [Segment(text: "hello", start: 0.0, end: 1.0)])
        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("fake engine done"))
    }

    func testNonzeroExitThrows() throws {
        let audio = dir.appendingPathComponent("mic.wav")
        try Data().write(to: audio)
        let runner = STTRunner(commandTemplate: "false {audio} {outdir}")
        XCTAssertThrowsError(try runner.transcribe(
            audio: audio, outdir: dir, log: dir.appendingPathComponent("l.log"))) { error in
            guard case STTError.engineFailed = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testMissingOutputThrows() throws {
        let audio = dir.appendingPathComponent("mic.wav")
        try Data().write(to: audio)
        let runner = STTRunner(commandTemplate: "true {audio} {outdir}")
        XCTAssertThrowsError(try runner.transcribe(
            audio: audio, outdir: dir, log: dir.appendingPathComponent("l.log"))) { error in
            guard case STTError.outputMissing = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

`Sources/MeetKit/STTRunner.swift`:
```swift
import Foundation

public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public enum STTError: Error, LocalizedError {
    case engineFailed(exitCode: Int32, logFile: URL)
    case outputMissing(expected: URL, logFile: URL)

    public var errorDescription: String? {
        switch self {
        case .engineFailed(let code, let log):
            "STT engine exited with code \(code); see \(log.path)"
        case .outputMissing(let expected, let log):
            "STT engine produced no \(expected.lastPathComponent); see \(log.path)"
        }
    }
}

public struct STTRunner: Sendable {
    public var commandTemplate: String

    public init(commandTemplate: String) {
        self.commandTemplate = commandTemplate
    }

    func render(audio: URL, outdir: URL) -> String {
        commandTemplate
            .replacingOccurrences(of: "{audio}", with: shellQuote(audio.path))
            .replacingOccurrences(of: "{outdir}", with: shellQuote(outdir.path))
    }

    public func transcribe(audio: URL, outdir: URL, log: URL) throws -> [Segment] {
        let command = render(audio: audio, outdir: outdir)

        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        try logHandle.seekToEnd()
        logHandle.write("$ \(command)\n".data(using: .utf8)!)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { logHandle.write(data) }
        }
        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw STTError.engineFailed(exitCode: process.terminationStatus, logFile: log)
        }

        let stem = audio.deletingPathExtension().lastPathComponent
        let expected = outdir.appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: expected.path) else {
            throw STTError.outputMissing(expected: expected, logFile: log)
        }
        return try SegmentParser.parse(Data(contentsOf: expected))
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `feat: external STT command runner with file contract`

---

### Task 7: WAV writer

**Files:**
- Create: `Sources/MeetKit/WavWriter.swift`
- Test: `Tests/MeetKitTests/WavWriterTests.swift`

**Interfaces:**
- Produces:
```swift
/// Streams AVAudioPCMBuffers of any source format into a 48 kHz mono 16-bit WAV.
/// Not thread-safe by design: each recorder owns one writer and calls it from
/// a single audio callback thread. finalize() may be called from another thread
/// only after the callback source is stopped.
public final class WavWriter {
    public init(url: URL, sourceFormat: AVAudioFormat) throws
    public func write(_ buffer: AVAudioPCMBuffer) throws
    /// Device changes alter the source format mid-recording.
    public func updateSourceFormat(_ format: AVAudioFormat)
    public private(set) var framesWritten: AVAudioFramePosition { get }
    public var durationSeconds: Double { get }  // framesWritten / 48000
    public func finalize()                       // closes the file
    public static let targetSampleRate: Double  // 48_000
}
```

- [ ] **Step 1: Write failing tests**

`Tests/MeetKitTests/WavWriterTests.swift`:
```swift
import XCTest
import AVFoundation
@testable import MeetKit

final class WavWriterTests: XCTestCase {
    func makeSine(format: AVAudioFormat, frames: AVAudioFrameCount,
                  freq: Double = 440) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let sr = format.sampleRate
        for ch in 0..<Int(format.channelCount) {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = Float(sin(2 * .pi * freq * Double(i) / sr) * 0.5)
            }
        }
        return buf
    }

    func testWritesResampledMonoWav() throws {
        // Source: 44.1 kHz stereo float — a typical mic/tap format.
        let source = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: source)
        for _ in 0..<10 {
            try writer.write(makeSine(format: source, frames: 4410)) // 0.1 s each
        }
        writer.finalize()

        // ~1 second of source audio -> ~48000 frames at 48 kHz (converter may
        // hold back a few frames of latency; allow 2% tolerance).
        XCTAssertEqual(Double(writer.framesWritten), 48000, accuracy: 48000 * 0.02)
        XCTAssertEqual(writer.durationSeconds, 1.0, accuracy: 0.02)

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 48000)
        XCTAssertEqual(readBack.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(readBack.length), Double(writer.framesWritten), accuracy: 16)
    }

    func testSourceFormatChangeMidStream() throws {
        let a = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let b = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: a)
        try writer.write(makeSine(format: a, frames: 4410))
        writer.updateSourceFormat(b)
        try writer.write(makeSine(format: b, frames: 4800))
        writer.finalize()

        XCTAssertEqual(writer.durationSeconds, 0.2, accuracy: 0.02)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

`Sources/MeetKit/WavWriter.swift`:
```swift
import AVFoundation
import Foundation

public final class WavWriter {
    public static let targetSampleRate: Double = 48_000

    private let file: AVAudioFile
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat
    private var closed = false
    public private(set) var framesWritten: AVAudioFramePosition = 0

    public var durationSeconds: Double {
        Double(framesWritten) / Self.targetSampleRate
    }

    public init(url: URL, sourceFormat: AVAudioFormat) throws {
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Self.targetSampleRate,
                                          channels: 1, interleaved: true)!
        self.file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.sourceFormat = sourceFormat
        self.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
    }

    public func updateSourceFormat(_ format: AVAudioFormat) {
        sourceFormat = format
        converter = AVAudioConverter(from: format, to: targetFormat)
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard !closed else { return }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error, out.frameLength > 0 else { return }

        try file.write(from: out)
        framesWritten += AVAudioFramePosition(out.frameLength)
    }

    public func finalize() {
        guard !closed else { return }
        closed = true
        // Drain converter tail.
        if let converter,
           let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) {
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status == .haveData, out.frameLength > 0, (try? file.write(from: out)) != nil {
                framesWritten += AVAudioFramePosition(out.frameLength)
            }
        }
        file.close()
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `feat: streaming WAV writer with resampling to 48k mono`

---

### Task 8: Audio compressor (WAV → m4a)

**Files:**
- Create: `Sources/MeetKit/AudioCompressor.swift`
- Test: `Tests/MeetKitTests/CompressorTests.swift`

**Interfaces:**
- Consumes: a WAV produced by `WavWriter` (tests build one with it).
- Produces:
```swift
public enum AudioCompressor {
    /// Reads `wav`, writes AAC 64 kbps mono into `m4a`, then deletes `wav`.
    /// The WAV is deleted ONLY after the m4a exists and is non-empty.
    /// Synchronous; safe to call on a background queue.
    public static func compress(wav: URL, to m4a: URL) throws
}
```
Implementation note: use `AVAudioFile` for reading and an `AVAudioFile(forWriting:settings:)` with `AVFormatIDKey: kAudioFormatMPEG4AAC` for writing — AVAudioFile supports writing compressed m4a and keeps this synchronous (no AVAssetExportSession async ceremony).

- [ ] **Step 1: Write failing test**

`Tests/MeetKitTests/CompressorTests.swift`:
```swift
import XCTest
import AVFoundation
@testable import MeetKit

final class CompressorTests: XCTestCase {
    func testCompressProducesM4aAndDeletesWav() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a 0.5 s WAV via WavWriter.
        let wav = dir.appendingPathComponent("track.wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let writer = try WavWriter(url: wav, sourceFormat: fmt)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 24000)!
        buf.frameLength = 24000
        for i in 0..<24000 {
            buf.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.4)
        }
        try writer.write(buf)
        writer.finalize()

        let m4a = dir.appendingPathComponent("track.m4a")
        try AudioCompressor.compress(wav: wav, to: m4a)

        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: m4a.path)
        XCTAssertGreaterThan(attrs[.size] as! Int, 0)
        let readBack = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(Double(readBack.length) / readBack.fileFormat.sampleRate,
                       0.5, accuracy: 0.1)
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

`Sources/MeetKit/AudioCompressor.swift`:
```swift
import AVFoundation
import Foundation

public enum AudioCompressor {
    public static func compress(wav: URL, to m4a: URL) throws {
        let input = try AVAudioFile(forReading: wav)
        let processingFormat = input.processingFormat

        try? FileManager.default.removeItem(at: m4a)
        let output = try AVAudioFile(
            forWriting: m4a,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: processingFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                            frameCapacity: chunk) else {
            throw CocoaError(.fileReadUnknown)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        output.close()

        let size = (try FileManager.default
            .attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.removeItem(at: wav)
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `feat: WAV to m4a compression stage`

---

### Task 9: Pipeline orchestration

**Files:**
- Create: `Sources/MeetKit/Pipeline.swift`
- Test: `Tests/MeetKitTests/PipelineTests.swift`

**Interfaces:**
- Consumes: `Config`, `Session`, `SessionMeta`, `Stage`, `STTRunner`, `SegmentParser`, `Transcript`, `AudioCompressor`, `WavWriter` (tests generate WAVs).
- Produces:
```swift
public struct Pipeline: Sendable {
    public var config: Config
    public init(config: Config)
    /// Runs all stages the session still needs, judged by meta.stage:
    ///   recorded    -> transcribe mic + system (sequentially) -> write mic.json/system.json, stage=transcribed
    ///   transcribed -> assemble transcript.md, stage=merged
    ///   merged      -> compress WAVs to m4a (delete WAVs),   stage=completed
    /// force=true restarts from `recorded` even if completed; transcription input
    /// is the WAV when present, else the m4a (post-compression re-runs).
    /// A missing audio track (file absent) yields an empty segment list and a log line.
    /// Progress callback receives short human strings ("transcribing mic", ...).
    /// Errors: logged to session.logFile, meta.stage untouched for the failed stage, rethrown.
    public func process(session: Session, force: Bool = false,
                        progress: (@Sendable (String) -> Void)? = nil) throws
}
```
Detail: transcription of a track when neither `<track>.wav` nor `<track>.m4a` exists writes an empty `[]` JSON to `<track>.json`. Assembly reads both JSONs with `SegmentParser.parse`. Duration for the title: `meta.audioDurationSeconds ?? max(end of last segment, 0)`. Title: `session.displayTitle(meta:)`. `engineCommand` is written into meta after successful transcription.

- [ ] **Step 1: Write failing tests**

`Tests/MeetKitTests/PipelineTests.swift`:
```swift
import XCTest
import AVFoundation
@testable import MeetKit

final class PipelineTests: XCTestCase {
    var root: URL!
    var fakeEngine: URL!
    var config: Config!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Fake engine echoes one segment whose text is the audio stem.
        fakeEngine = root.appendingPathComponent("fake-engine.sh")
        try """
        #!/bin/sh
        stem=$(basename "$1")
        stem="${stem%.*}"
        printf '{"segments":[{"text":"%s speech","start":1.0,"end":2.0}]}' "$stem" > "$2/$stem.json"
        """.write(to: fakeEngine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeEngine.path)

        config = Config.default
        config.recordingsDir = root
        config.sttCommand = "\(shellQuote(fakeEngine.path)) {audio} {outdir}"
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeRecordedSession(withSystemTrack: Bool = true) throws -> Session {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        for url in withSystemTrack ? [session.micWAV, session.systemWAV] : [session.micWAV] {
            let w = try WavWriter(url: url, sourceFormat: fmt)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
            buf.frameLength = 4800
            try w.write(buf)
            w.finalize()
        }
        var meta = SessionMeta(startedAt: Date())
        meta.stage = .recorded
        meta.endedAt = Date()
        meta.audioDurationSeconds = 0.1
        try session.saveMeta(meta)
        return session
    }

    func testFullPipelineRunsAllStages() throws {
        let session = try makeRecordedSession()
        try Pipeline(config: config).process(session: session)

        let meta = try session.loadMeta()
        XCTAssertEqual(meta.stage, .completed)
        XCTAssertEqual(meta.engineCommand, config.sttCommand)

        let transcript = try String(contentsOf: session.transcriptMD, encoding: .utf8)
        XCTAssertTrue(transcript.contains("**[00:00:01] Me:** mic speech"))
        XCTAssertTrue(transcript.contains("Them:** system speech"))

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: session.micWAV.path))
        XCTAssertTrue(fm.fileExists(atPath: session.micM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.systemM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.micJSON.path))
    }

    func testMissingTrackYieldsEmptySegments() throws {
        let session = try makeRecordedSession(withSystemTrack: false)
        try Pipeline(config: config).process(session: session)
        let systemSegs = try SegmentParser.parse(Data(contentsOf: session.systemJSON))
        XCTAssertEqual(systemSegs, [])
        XCTAssertEqual(try session.loadMeta().stage, .completed)
    }

    func testFailedEngineKeepsWavAndStage() throws {
        let session = try makeRecordedSession()
        var broken = config!
        broken.sttCommand = "false {audio} {outdir}"
        XCTAssertThrowsError(try Pipeline(config: broken).process(session: session))
        XCTAssertEqual(try session.loadMeta().stage, .recorded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.micWAV.path))
    }

    func testResumeFromTranscribed() throws {
        let session = try makeRecordedSession()
        var broken = config!
        broken.sttCommand = "false {audio} {outdir}"
        try? Pipeline(config: broken).process(session: session)      // fails, stays recorded
        try Pipeline(config: config).process(session: session)       // catches up fully
        XCTAssertEqual(try session.loadMeta().stage, .completed)
    }

    func testForceRerunsCompletedSessionFromM4a() throws {
        let session = try makeRecordedSession()
        let pipeline = Pipeline(config: config)
        try pipeline.process(session: session)                       // completed, WAVs gone
        try pipeline.process(session: session, force: true)          // must transcribe m4a
        XCTAssertEqual(try session.loadMeta().stage, .completed)
        let transcript = try String(contentsOf: session.transcriptMD, encoding: .utf8)
        XCTAssertTrue(transcript.contains("mic speech"))
    }
}
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

`Sources/MeetKit/Pipeline.swift`:
```swift
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
```
Note the scratch dir: the engine writes `<stem>.json` into `.stt-out/`, and the pipeline re-encodes parsed segments into the canonical `mic.json`/`system.json` at the session root. This keeps session files canonical regardless of engine output shape.

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `feat: staged pipeline (transcribe, merge, compress) with resume and force`

---

### Task 10: Mic recorder

**Files:**
- Create: `Sources/MeetKit/MicRecorder.swift`

**Interfaces:**
- Consumes: `WavWriter` (Task 7).
- Produces:
```swift
/// Records the default input device into a WAV via AVAudioEngine.
public final class MicRecorder {
    public init(outputURL: URL)
    public func start() throws
    public var paused: Bool { get set }        // atomic; drops buffers while true
    public private(set) var isHealthy: Bool    // false after an unrecovered engine failure
    public var durationSeconds: Double { get } // writer's audio time
    public func stop()                          // stops engine, finalizes WAV
    /// Called on the main queue when health changes (for the status line).
    public var onHealthChange: ((Bool) -> Void)?
}
```
No automated test (requires mic permission). Compile + manual verification.

- [ ] **Step 1: Implement**

`Sources/MeetKit/MicRecorder.swift`:
```swift
import AVFoundation
import Foundation

public final class MicRecorder {
    private let engine = AVAudioEngine()
    private let outputURL: URL
    private var writer: WavWriter?
    private let pausedLock = NSLock()
    private var _paused = false
    private var observer: NSObjectProtocol?

    public private(set) var isHealthy = true
    public var onHealthChange: ((Bool) -> Void)?

    public var paused: Bool {
        get { pausedLock.withLock { _paused } }
        set { pausedLock.withLock { _paused = newValue } }
    }

    public var durationSeconds: Double { writer?.durationSeconds ?? 0 }

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let writer = try WavWriter(url: outputURL, sourceFormat: format)
        self.writer = writer
        installTap(format: format)
        try engine.start()

        // The engine stops itself when the default input device changes or dies.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.recoverFromConfigurationChange()
        }
    }

    private func installTap(format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
            [weak self] buffer, _ in
            guard let self, !self.paused else { return }
            do {
                try self.writer?.write(buffer)
            } catch {
                self.setHealthy(false)
            }
        }
    }

    private func recoverFromConfigurationChange() {
        engine.inputNode.removeTap(onBus: 0)
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0 else {
            setHealthy(false)
            return
        }
        writer?.updateSourceFormat(newFormat)
        installTap(format: newFormat)
        do {
            try engine.start()
            setHealthy(true)
        } catch {
            setHealthy(false)
        }
    }

    private func setHealthy(_ value: Bool) {
        guard isHealthy != value else { return }
        isHealthy = value
        DispatchQueue.main.async { self.onHealthChange?(value) }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.finalize()
    }
}
```

- [ ] **Step 2: Build** (`swift build && swift test` — existing tests still pass)

- [ ] **Step 3: Manual verification (main agent or human, not the implementing subagent)**

Add a temporary hidden debug subcommand or run via a scratch main: record 5 seconds of speech, then `afplay mic.wav` — voice audible, `afinfo mic.wav` shows 48 000 Hz, 1 channel. This manual check is repeated properly in Task 12's checklist; at this task, compile-correctness plus code review is the gate.

- [ ] **Step 4: Commit** — `feat: mic recorder via AVAudioEngine with device-change recovery`

---

### Task 11: System audio recorder (CoreAudio process tap)

**Files:**
- Create: `Sources/MeetKit/SystemAudioRecorder.swift`

**Interfaces:**
- Consumes: `WavWriter`.
- Produces:
```swift
/// Records the system audio mixdown via a CoreAudio process tap (macOS 14.2+).
/// Playback is untouched: the tap listens post-mix, nothing is rerouted.
public final class SystemAudioRecorder {
    public init(outputURL: URL)
    public func start() throws     // throws SystemAudioError.tapCreationFailed(OSStatus) on TCC denial
    public var paused: Bool { get set }
    public private(set) var isHealthy: Bool
    public var onHealthChange: ((Bool) -> Void)?
    public var durationSeconds: Double { get }
    public func stop()
}
public enum SystemAudioError: Error, LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
}
```

- [ ] **Step 1: Implement**

`Sources/MeetKit/SystemAudioRecorder.swift`:
```swift
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

public enum SystemAudioError: Error, LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            """
            Could not create the system audio tap (OSStatus \(s)).
            Grant permission in System Settings → Privacy & Security → \
            Screen & System Audio Recording (allow your terminal app), then retry.
            """
        case .aggregateCreationFailed(let s): "Aggregate device creation failed (OSStatus \(s))"
        case .ioProcFailed(let s): "Audio IO proc failed (OSStatus \(s))"
        }
    }
}

public final class SystemAudioRecorder {
    private let outputURL: URL
    private var writer: WavWriter?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var defaultDeviceListenerInstalled = false

    private let pausedLock = NSLock()
    private var _paused = false
    public var paused: Bool {
        get { pausedLock.withLock { _paused } }
        set { pausedLock.withLock { _paused = newValue } }
    }

    public private(set) var isHealthy = true
    public var onHealthChange: ((Bool) -> Void)?
    public var durationSeconds: Double { writer?.durationSeconds ?? 0 }

    public init(outputURL: URL) { self.outputURL = outputURL }

    public func start() throws {
        try buildCaptureChain()
        installDefaultDeviceListener()
    }

    private func buildCaptureChain() throws {
        // 1. Global mixdown tap over all processes (exclude none).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "meet system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw SystemAudioError.tapCreationFailed(status) }
        tapID = newTapID

        // 2. Tap stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.tapCreationFailed(status)
        }
        tapFormat = format

        if let writer {
            writer.updateSourceFormat(format)
        } else {
            writer = try WavWriter(url: outputURL, sourceFormat: format)
        }

        // 3. Private aggregate device: default output as subdevice + our tap.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "meet-capture",
            kAudioAggregateDeviceUIDKey as String: "meet-capture-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else { throw SystemAudioError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID

        // 4. IO proc: tap audio arrives as the aggregate's input buffers.
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, !self.paused, let format = self.tapFormat else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: inInputData) else { return }
            do {
                try self.writer?.write(buffer)
            } catch {
                self.setHealthy(false)
            }
        }
        guard status == noErr, let procID else { throw SystemAudioError.ioProcFailed(status) }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw SystemAudioError.ioProcFailed(status) }
    }

    /// The default output device changed (e.g. headphones plugged in):
    /// tear the chain down and rebuild it, keeping the same WAV file open.
    private func installDefaultDeviceListener() {
        guard !defaultDeviceListenerInstalled else { return }
        defaultDeviceListenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            guard let self else { return }
            self.teardownCaptureChain()
            do {
                try self.buildCaptureChain()
                self.setHealthy(true)
            } catch {
                self.setHealthy(false)
            }
        }
    }

    private func teardownCaptureChain() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func setHealthy(_ value: Bool) {
        guard isHealthy != value else { return }
        isHealthy = value
        DispatchQueue.main.async { self.onHealthChange?(value) }
    }

    public func stop() {
        teardownCaptureChain()
        writer?.finalize()
    }

    static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw SystemAudioError.aggregateCreationFailed(status) }

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw SystemAudioError.aggregateCreationFailed(status) }
        return uid as String
    }
}
```
Implementation warnings for this task:
- `CATapDescription` lives in `CoreAudio` (import both `CoreAudio` and `AudioToolbox`). If the compiler cannot find a symbol, check the exact spelling in the macOS 15 SDK headers (`CoreAudio/AudioHardwareTapping.h`, `CATapDescription.h`) before renaming anything.
- If `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` returns nil at runtime, fall back to allocating a buffer and memcpy-ing the ABL bytes; keep that fallback out until proven needed.
- Do NOT add retry loops around `AudioHardwareCreateProcessTap` — a nonzero status here is almost always missing TCC permission and must surface to the user.

- [ ] **Step 2: Build** (`swift build && swift test`)

- [ ] **Step 3: Commit** — `feat: system audio recorder via CoreAudio process tap`

Manual verification happens in Task 12 (recording session) — this task's gate is compilation plus review.

---

### Task 12: Recording session controller + hidden debug command + manual capture verification

**Files:**
- Create: `Sources/MeetKit/RecordingSession.swift`
- Modify: `Sources/meet/MeetCommand.swift` (add hidden `debug-record` subcommand)

**Interfaces:**
- Consumes: `MicRecorder`, `SystemAudioRecorder`, `SessionStore`, `SessionMeta`, `Config`.
- Produces:
```swift
public final class RecordingSession {
    public let session: Session
    /// Creates the session folder and starts both recorders.
    /// If the system tap fails with a permission error, this throws — the caller
    /// decides whether to continue mic-only.
    public init(store: SessionStore, config: Config) throws
    public func pause()   // pauses both recorders, opens a PauseInterval
    public func resume()  // closes the PauseInterval
    public var isPaused: Bool { get }
    public var micHealthy: Bool { get }
    public var systemHealthy: Bool { get }
    public var elapsedSeconds: Double { get }  // max of both writers' audio time
    /// Stops recorders, finalizes WAVs, writes meta (stage = .recorded,
    /// endedAt, audioDurationSeconds, pauseIntervals). Returns the session.
    public func stop() throws -> Session
}
```

- [ ] **Step 1: Implement RecordingSession**

`Sources/MeetKit/RecordingSession.swift`:
```swift
import Foundation

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

    public init(store: SessionStore, config: Config) throws {
        session = try store.createSession(at: Date())
        meta = SessionMeta(startedAt: Date())
        try session.saveMeta(meta)

        mic = MicRecorder(outputURL: session.micWAV)
        system = SystemAudioRecorder(outputURL: session.systemWAV)
        try system.start()   // fail fast on missing TCC before touching the mic
        do {
            try mic.start()
        } catch {
            system.stop()
            throw error
        }
    }

    public func pause() {
        guard currentPause == nil else { return }
        mic.paused = true
        system.paused = true
        currentPause = PauseInterval(start: Date())
    }

    public func resume() {
        guard var pause = currentPause else { return }
        pause.end = Date()
        meta.pauseIntervals.append(pause)
        currentPause = nil
        mic.paused = false
        system.paused = false
    }

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
```

- [ ] **Step 2: Add hidden debug subcommand for manual capture testing**

In `Sources/meet/MeetCommand.swift`:
```swift
import ArgumentParser
import Foundation
import MeetKit

@main
struct Meet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meet",
        abstract: "Record meetings (mic + system audio) and transcribe them locally.",
        subcommands: [DebugRecord.self]
    )
}

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
```

- [ ] **Step 3: Build** (`swift build && swift test`)

- [ ] **Step 4: MANUAL CAPTURE VERIFICATION — run by the main agent/human in a terminal, expect TCC prompts on first run**

```bash
# Play something audible (e.g. a YouTube video), speak into the mic, then:
swift run meet debug-record --seconds 8
afplay ~/MeetingRecordings/<new-folder>/mic.wav      # your voice audible
afplay ~/MeetingRecordings/<new-folder>/system.wav   # the video audio audible
afinfo ~/MeetingRecordings/<new-folder>/mic.wav      # 48000 Hz, 1 ch, 16-bit
```
Also verify: audio kept playing normally during capture (no glitch/reroute). If the tap permission prompt did not appear and `system.wav` is silent, check System Settings → Privacy & Security → Screen & System Audio Recording.

- [ ] **Step 5: Commit** — `feat: recording session controller with pause tracking + debug-record smoke test`

---

### Task 13: Interactive terminal UI (`meet` default mode)

**Files:**
- Create: `Sources/meet/InteractiveUI.swift`
- Modify: `Sources/meet/MeetCommand.swift` (make interactive mode the default subcommand)

**Interfaces:**
- Consumes: `RecordingSession`, `Pipeline`, `SessionStore`, `Config`.
- Produces: `struct RecordCommand: ParsableCommand` (command name `record`, set as `defaultSubcommand`) that runs `InteractiveUI(config:).run()`.

Behavior contract (from spec):
- Keys: `z` start/stop recording; space pause/resume; `q` quit (stop active recording, wait for background transcriptions, exit); `Ctrl+D` = `q`; first `Ctrl+C` = `q`, second `Ctrl+C` = immediate exit.
- Transcriptions run on ONE serial background queue (GPU contention), status line shows both planes.
- Status line examples: `● rec 00:12:34  mic ✓  system ✓`, `‖ paused 00:12:34`, `idle`, suffix ` | transcribing: 2026-09-03-1420 (transcribing mic)` while jobs run, ` | pending: 2` when queued.

- [ ] **Step 1: Implement**

`Sources/meet/InteractiveUI.swift`:
```swift
import Darwin
import Dispatch
import Foundation
import MeetKit

final class InteractiveUI {
    private let config: Config
    private let store: SessionStore
    private let pipeline: Pipeline

    private var recording: RecordingSession?
    private var savedTermios = termios()
    private var rawModeEnabled = false

    private let pipelineQueue = DispatchQueue(label: "meet.pipeline", qos: .userInitiated)
    private let pipelineGroup = DispatchGroup()
    private let stateLock = NSLock()
    private var pendingJobs = 0
    private var currentJob: String?   // "2026-09-03-1420 (transcribing mic)"
    private var shouldQuit = false

    static var sigintCount = 0

    init(config: Config) {
        self.config = config
        self.store = SessionStore(rootDir: config.recordingsDir)
        self.pipeline = Pipeline(config: config)
    }

    func run() throws {
        installSignalHandler()
        enableRawMode()
        defer { disableRawMode() }
        printHelp()

        while !shouldQuit {
            redrawStatus()
            guard let key = readKey(timeoutMS: 1000) else { continue }
            switch key {
            case UInt8(ascii: "z"): toggleRecording()
            case UInt8(ascii: " "): togglePause()
            case UInt8(ascii: "q"), 0x04: quit()          // 0x04 = Ctrl+D
            default: break
            }
        }

        // Drain background transcriptions before exiting.
        let waiting = stateLock.withLock { pendingJobs > 0 || currentJob != nil }
        if waiting {
            print("\nwaiting for transcriptions to finish (Ctrl+C again to abandon)...")
        }
        pipelineGroup.wait()
        print("\nbye")
    }

    // MARK: keys & terminal

    private func enableRawMode() {
        tcgetattr(STDIN_FILENO, &savedTermios)
        var raw = savedTermios
        raw.c_lflag &= ~UInt(ECHO | ICANON)  // keep ISIG so Ctrl+C raises SIGINT
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        rawModeEnabled = true
    }

    private func disableRawMode() {
        guard rawModeEnabled else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
        rawModeEnabled = false
    }

    /// poll stdin with a timeout so the status line refreshes every second.
    private func readKey(timeoutMS: Int32) -> UInt8? {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = poll(&fds, 1, timeoutMS)
        guard result > 0, fds.revents & Int16(POLLIN) != 0 else { return nil }
        var byte: UInt8 = 0
        let n = read(STDIN_FILENO, &byte, 1)
        return n == 1 ? byte : nil
    }

    private func installSignalHandler() {
        signal(SIGINT, { _ in
            InteractiveUI.sigintCount += 1
            if InteractiveUI.sigintCount >= 2 {
                // Second Ctrl+C: immediate exit. WAVs on disk are intact;
                // `meet process --all` catches up later.
                var restore = termios()
                tcgetattr(STDIN_FILENO, &restore)
                restore.c_lflag |= UInt(ECHO | ICANON)
                tcsetattr(STDIN_FILENO, TCSANOW, &restore)
                _exit(1)
            }
        })
        // First Ctrl+C is noticed in the run loop via sigintCount.
    }

    // MARK: actions

    private func toggleRecording() {
        if let active = recording {
            recording = nil
            do {
                let session = try active.stop()
                enqueuePipeline(for: session)
            } catch {
                printLine("error stopping recording: \(error.localizedDescription)")
            }
        } else {
            do {
                recording = try RecordingSession(store: store, config: config)
            } catch {
                printLine("cannot start recording: \(error.localizedDescription)")
            }
        }
    }

    private func togglePause() {
        guard let recording else { return }
        recording.isPaused ? recording.resume() : recording.pause()
    }

    private func quit() {
        if recording != nil { toggleRecording() }  // stop + enqueue
        shouldQuit = true
    }

    private func enqueuePipeline(for session: Session) {
        stateLock.withLock { pendingJobs += 1 }
        pipelineGroup.enter()
        pipelineQueue.async { [self] in
            let name = session.directory.lastPathComponent
            stateLock.withLock {
                pendingJobs -= 1
                currentJob = name
            }
            do {
                try pipeline.process(session: session) { step in
                    self.stateLock.withLock { self.currentJob = "\(name) (\(step))" }
                }
                printLine("✓ \(name): transcript ready")
            } catch {
                printLine("✗ \(name): \(error.localizedDescription) — retry with: meet process \(shellQuote(session.directory.path))")
            }
            stateLock.withLock { currentJob = nil }
            pipelineGroup.leave()
        }
    }

    // MARK: rendering

    private func printHelp() {
        print("meet — z: start/stop  space: pause  q: quit")
    }

    private func redrawStatus() {
        if InteractiveUI.sigintCount >= 1 && !shouldQuit { quit() }

        var left = "idle"
        if let recording {
            let time = Transcript.timecode(recording.elapsedSeconds)
            if recording.isPaused {
                left = "‖ paused \(time)"
            } else {
                let micMark = recording.micHealthy ? "✓" : "✗"
                let sysMark = recording.systemHealthy ? "✓" : "✗"
                left = "● rec \(time)  mic \(micMark)  system \(sysMark)"
            }
        }
        let (job, pending) = stateLock.withLock { (currentJob, pendingJobs) }
        var right = ""
        if let job { right += " | transcribing: \(job)" }
        if pending > 0 { right += " | pending: \(pending)" }

        print("\r\u{1B}[K\(left)\(right)", terminator: "")
        fflush(stdout)
    }

    /// Print a full line above the status line.
    private func printLine(_ text: String) {
        print("\r\u{1B}[K\(text)")
    }
}
```
Note: `Transcript.timecode` must be made `public` in `Transcript.swift` for this to compile (change `static func timecode` to `public static func timecode`).

- [ ] **Step 2: Wire as default subcommand**

In `MeetCommand.swift`:
```swift
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
```

- [ ] **Step 3: Build + tests** (`swift build && swift test`)

- [ ] **Step 4: Manual verification (main agent/human)**

```bash
swift run meet
```
Checklist: `z` starts (status shows `● rec` with ticking time), space pauses/resumes (time freezes/continues), `z` stops and status gains `| transcribing: ...` (needs parakeet-mlx installed), a `✓ <name>: transcript ready` line appears, `z` again during transcription starts a second recording, `q` waits for jobs then exits, terminal echo restored after exit.

- [ ] **Step 5: Commit** — `feat: interactive single-key terminal UI with background pipeline queue`

---

### Task 14: `meet process` subcommand + permission preflight

**Files:**
- Modify: `Sources/meet/MeetCommand.swift`

**Interfaces:**
- Consumes: `Pipeline`, `SessionStore`, `Session`, `Stage`.
- Produces: `struct ProcessCommand: ParsableCommand` — `meet process <folder>` / `meet process --all` / `--force`. Also a mic-permission preflight in `RecordCommand.run()` before entering the UI.

- [ ] **Step 1: Implement ProcessCommand**

Append to `MeetCommand.swift` (and add `ProcessCommand.self` to `subcommands:`):
```swift
import AVFoundation

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
```

- [ ] **Step 2: Add mic permission preflight to RecordCommand**

```swift
struct RecordCommand: ParsableCommand {
    // ... configuration as before ...

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

struct MicPermissionError: Error, CustomStringConvertible {
    var description: String {
        """
        Microphone access denied. Allow your terminal app in
        System Settings → Privacy & Security → Microphone, then rerun.
        """
    }
}
```
(System-audio permission has no preflight API; `RecordingSession.init` already fails fast with guidance when the tap cannot be created.)

- [ ] **Step 3: Build + tests**

- [ ] **Step 4: Manual verification**

```bash
swift run meet process --all           # completes any unfinished sessions
swift run meet process --all --force   # redoes a completed one (from m4a)
```

- [ ] **Step 5: Commit** — `feat: process subcommand and mic permission preflight`

---

### Task 15: README + end-to-end verification

**Files:**
- Create: `README.md`

**Interfaces:** none (documentation + final gate).

- [ ] **Step 1: Write README.md**

Content requirements (write actual prose, in English):
- What it is: records meetings (mic + system audio, no audio rerouting) and transcribes locally with a pluggable STT engine.
- Requirements: macOS 15+, Swift toolchain to build, an STT CLI (default: `parakeet-mlx`, install via `pipx install parakeet-mlx` / `uv tool install parakeet-mlx`).
- Install: `swift build -c release`, copy `.build/release/meet` into PATH.
- Usage: `meet` (keys table: z / space / q), `meet process <folder> | --all [--force]`.
- Permissions: first run prompts for Microphone and System Audio Recording; both attach to the terminal app; where to fix in System Settings.
- Config: full `config.toml` example (all keys = defaults) + the STT contract paragraph: command template placeholders `{audio}`, `{outdir}`; must write `<audio stem>.json` with `{text,start,end}` segments in a top-level array or under `segments`/`sentences`; how to plug a different engine via an adapter script.
- Session folder layout (the tree from the spec) and pipeline stages.

- [ ] **Step 2: End-to-end manual test (the real thing)**

Join or simulate a call (e.g. play a video with speech), run `meet`, record ~2 minutes with a pause in the middle, speak into the mic over it, stop, wait for `✓ transcript ready`. Verify:
- `transcript.md` interleaves `Me`/`Them` sensibly with plausible timecodes;
- Russian and English both recognized;
- WAVs replaced by m4a files; `meta.json` says `completed` with one pause interval;
- playback in the call/video never glitched.

- [ ] **Step 3: Commit** — `docs: README with install, usage, permissions, STT contract`

---

## Self-review notes

- Spec coverage: capture (T10–12), interactive keys (T13), STT contract + swap (T6, README T15), pipeline stages + resume + force (T9, T14), transcript format + merging (T3), storage layout (T5, T9), compression (T8), permissions preflight (T14), error principles (T9 tests: failed engine keeps WAV and stage; T6 log capture), device-change handling (T10 recover, T11 listener), pause intervals (T12), Ctrl+C double-tap (T13). Calendar/diarization/menu-bar are spec non-goals — no tasks, correctly.
- Type consistency: `Session` computed-property URLs used identically in T9/T12/T13/T14; `Stage` Comparable used in T9 (`meta.stage > .recorded`); `Transcript.timecode` made public in T13 (noted inline).
- Known risk concentrations: T11 (CoreAudio tap keys/signatures) and T7 (AVAudioConverter streaming semantics) — both flagged with implementation warnings; everything else is standard-library-grade.
