import Darwin
import Dispatch
import Foundation
import MeetKit

// @unchecked Sendable: every field that's touched from more than one thread
// (currentJob, pendingJobs) is only ever read or mutated while holding
// `stateLock`; everything else is confined to the main control loop.
final class InteractiveUI: @unchecked Sendable {
    private let config: Config
    private let store: SessionStore
    private let pipeline: Pipeline

    private var recording: RecordingSession?
    private var savedTermios = termios()
    private var rawModeEnabled = false

    // Reset whenever a new recording starts (see toggleRecording). Fed once
    // per redrawStatus tick so a paused recording keeps their clocks from
    // false-triggering on the frozen duration a pause legitimately causes.
    private var micStallDetector = StallDetector()
    private var systemStallDetector = StallDetector()
    private var micWasStalled = false
    private var systemWasStalled = false

    private let pipelineQueue = DispatchQueue(label: "meet.pipeline", qos: .userInitiated)
    private let pipelineGroup = DispatchGroup()
    private let stateLock = NSLock()
    private var pendingJobs = 0
    private var currentJob: String?   // "2026-09-03-1420 (transcribing mic)"
    private var shouldQuit = false

    // nonisolated(unsafe): only ever incremented (never read-modify-written
    // in a way that needs atomicity) from the SIGINT handler and polled from
    // the main loop; a torn read at worst delays quit-detection by one tick.
    nonisolated(unsafe) static var sigintCount = 0

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
            // How many more Ctrl+Cs it takes to reach the _exit depends on
            // how we got here: quitting with `q`/Ctrl+D leaves sigintCount at
            // 0, so "again" would be wrong — two are needed from a standing
            // start. Only a first Ctrl+C makes a single further one enough.
            let hint = InteractiveUI.sigintCount == 0
                ? "Ctrl+C twice to abandon"
                : "Ctrl+C again to abandon"
            print("\nwaiting for transcriptions to finish (\(hint))...")
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
                micStallDetector = StallDetector()
                systemStallDetector = StallDetector()
                micWasStalled = false
                systemWasStalled = false
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

            // Fed every tick regardless of pause state so the detectors'
            // clocks stay in sync with wall time; StallDetector itself
            // treats a paused tick as never-stalled and resets its window.
            let now = Date()
            let micStalled = micStallDetector.update(
                duration: recording.micDurationSeconds, isPaused: recording.isPaused, now: now)
            let systemStalled = systemStallDetector.update(
                duration: recording.systemDurationSeconds, isPaused: recording.isPaused, now: now)
            if micStalled, !micWasStalled {
                printLine("⚠ mic track stopped advancing — check your input device")
            }
            if systemStalled, !systemWasStalled {
                // The system track records the default *output* device's
                // mixdown, not an input, so pointing at the input device here
                // sent people to the wrong half of Sound settings.
                printLine("⚠ system track stopped advancing — check your output device")
            }
            micWasStalled = micStalled
            systemWasStalled = systemStalled

            if recording.isPaused {
                left = "‖ paused \(time)"
            } else {
                // An unhealthy recorder wins over a stalled one: ✗ means the
                // recorder itself reported a hard failure, ⚠ means it still
                // looks healthy but stopped producing audio.
                let micMark = !recording.micHealthy ? "✗" : (micStalled ? "⚠" : "✓")
                let sysMark = !recording.systemHealthy ? "✗" : (systemStalled ? "⚠" : "✓")
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
