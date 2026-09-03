import AVFoundation
import Foundation

/// Records the default input device into a WAV via AVAudioEngine.
///
/// Single-use: call `start()` once and `stop()` once per instance. `stopped`
/// latches permanently once `stop()` runs and is never reset, so a second
/// `start()` on the same instance will not resume capture — create a new
/// `MicRecorder` for a new recording. This matches how Task 12 uses it: one
/// fresh instance per session.
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private let outputURL: URL
    private var writer: WavWriter?
    private var observer: NSObjectProtocol?

    /// Guards every field the audio-render thread and the main thread both
    /// touch: `_paused`, `_isHealthy`, `_stopped`, and access to `writer`
    /// itself (write in the tap callback vs. finalize in `stop()`). Each
    /// property below acquires it only for the single access it needs and
    /// never while calling back into `engine`/`onHealthChange`/another
    /// locked accessor, so there is no nesting and no lock held across a
    /// call that could re-enter.
    private let stateLock = NSLock()
    private var _paused = false
    private var _isHealthy = true
    private var _stopped = false

    /// Called on the main queue when health changes (for the status line).
    public var onHealthChange: ((Bool) -> Void)?

    /// Atomic; drops buffers while true.
    public var paused: Bool {
        get { stateLock.withLock { _paused } }
        set { stateLock.withLock { _paused = newValue } }
    }

    public var isHealthy: Bool { stateLock.withLock { _isHealthy } }

    /// Set once by `stop()`; checked by the device-change recovery path so
    /// a recovery notification that was already queued before `stop()` ran
    /// can't re-light the engine after the caller considers capture over.
    private var stopped: Bool {
        get { stateLock.withLock { _stopped } }
        set { stateLock.withLock { _stopped = newValue } }
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
        do {
            try engine.start()
        } catch {
            // Nothing ever recorded on this attempt: don't leave a
            // header-only WAV behind for the pipeline to trip over.
            engine.inputNode.removeTap(onBus: 0)
            writer.finalize()
            self.writer = nil
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

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
                try self.writeLocked(buffer)
            } catch {
                self.setHealthy(false)
            }
        }
    }

    /// Locked so a straggler tap callback (AVAudioEngine buffers arrive on
    /// an internal queue; `removeTap`/`stop()` don't document draining)
    /// can never run concurrently with `finalize()` closing the same
    /// `AVAudioFile` in `stop()`.
    private func writeLocked(_ buffer: AVAudioPCMBuffer) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        try writer?.write(buffer)
    }

    private func recoverFromConfigurationChange() {
        guard !stopped else { return }
        engine.inputNode.removeTap(onBus: 0)
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0 else {
            setHealthy(false)
            return
        }
        // Locked: a straggler tap callback from the outgoing tap may still
        // be inside writeLocked(), using the writer's current converter,
        // when this runs — without the lock both threads could mutate the
        // same AVAudioConverter/AVAudioFile at once.
        stateLock.withLock { writer?.updateSourceFormat(newFormat) }
        installTap(format: newFormat)
        do {
            try engine.start()
            setHealthy(true)
        } catch {
            setHealthy(false)
        }
    }

    private func setHealthy(_ value: Bool) {
        let changed: Bool = stateLock.withLock {
            guard _isHealthy != value else { return false }
            _isHealthy = value
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { self.onHealthChange?(value) }
    }

    public func stop() {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stateLock.lock()
        writer?.finalize()
        stateLock.unlock()
    }
}
