import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Errors thrown by `MicRecorder`.
public enum MicRecorderError: Error, LocalizedError {
    /// The input node reports an unusable format (0 Hz and/or 0 channels),
    /// which is what AVAudioEngine does when there is no input device at all.
    case noInputDevice(sampleRate: Double, channelCount: AVAudioChannelCount)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice(let sampleRate, let channelCount):
            """
            No input device available: the system reports \(channelCount) \
            channel(s) at \(Int(sampleRate)) Hz for the default microphone. \
            Connect a microphone, or pick one under System Settings → Sound → \
            Input, then retry.
            """
        }
    }
}

/// Records the default input device into a WAV via AVAudioEngine.
///
/// Single-use: call `start()` once and `stop()` once per instance. `stopped`
/// latches permanently once `stop()` runs and is never reset, so a second
/// `start()` on the same instance will not resume capture — create a new
/// `MicRecorder` for a new recording. This matches how Task 12 uses it: one
/// fresh instance per session.
public final class MicRecorder {
    /// Rebuilt from scratch on every recovery — see `rebuildEngine()`.
    /// Reinstalling a tap on a post-configuration-change engine is what
    /// silently stopped delivering buffers in production (macOS tears down
    /// more than the tap when the default input device changes), so
    /// recovery always discards this instance and creates a new one rather
    /// than reusing it.
    private var engine = AVAudioEngine()
    private let outputURL: URL
    private var writer: WavWriter?
    /// Observes `.AVAudioEngineConfigurationChange` on the *current* engine
    /// instance; re-subscribed to the new engine at the end of every
    /// rebuild, since the old observer would otherwise watch a discarded
    /// object.
    private var observer: NSObjectProtocol?
    /// CoreAudio listener on the system's default input device, independent
    /// of the engine-configuration-change notification: a device switch
    /// does not always fire `.AVAudioEngineConfigurationChange` promptly (or
    /// at all) in every combination of driver/OS, so both signals feed the
    /// same rebuild path. Installed once in `start()`, removed in `stop()`.
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

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

    /// Set when a rebuild has been queued on the main queue and cleared
    /// once it actually runs. Both recovery signals land on the main queue
    /// (the configuration-change notification is delivered there, and the
    /// CoreAudio listener block is installed on `.main`), so this flag —
    /// touched only from the main queue — is enough to coalesce a
    /// double-fire (e.g. both signals for the same device switch) into a
    /// single rebuild without needing its own lock.
    private var rebuildScheduled = false

    /// Called on the main queue when health changes (for the status line).
    public var onHealthChange: ((Bool) -> Void)?

    /// Called on the main queue with a short, English, one-line description
    /// of a lifecycle event (device-change rebuild starting, succeeding, or
    /// failing) — for the session log, not for control flow.
    public var onEvent: ((String) -> Void)?

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
        // With no input device the node reports 0 Hz / 0 channels, and
        // WavWriter would then fail with a bare converterCreationFailed that
        // says nothing about the actual problem. Name it here instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicRecorderError.noInputDevice(sampleRate: format.sampleRate,
                                                 channelCount: format.channelCount)
        }
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

        subscribeToConfigurationChange()
        installDefaultInputDeviceListener()
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

    // MARK: - recovery

    /// The engine stops itself when the default input device changes or
    /// dies. Re-subscribed after every rebuild since the previous observer
    /// watched the now-discarded engine instance.
    private func subscribeToConfigurationChange() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.requestRebuild()
        }
    }

    /// A device switch (e.g. Zoom moving the default input from the built-in
    /// mic to a Bluetooth headset) doesn't reliably fire
    /// `.AVAudioEngineConfigurationChange` in time, or at all, on every
    /// macOS/driver combination — that gap is exactly what silently dropped
    /// 55 minutes of mic audio in production, since nothing else was
    /// watching. This CoreAudio listener on the system's default input
    /// device is the second, independent signal into the same rebuild path.
    /// Mirrors `SystemAudioRecorder`'s default-output listener: the
    /// `stopped` guard, and installed once / removed in `stop()`.
    private func installDefaultInputDeviceListener() {
        guard defaultInputListenerBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            self.requestRebuild()
        }
        defaultInputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func removeDefaultInputDeviceListener() {
        guard let block = defaultInputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        defaultInputListenerBlock = nil
    }

    /// Funnels both recovery signals into one debounced, deferred rebuild.
    /// Both signals already land on the main queue synchronously with the
    /// system event; deferring via `DispatchQueue.main.async` and gating on
    /// `rebuildScheduled` means a configuration-change notification and a
    /// default-device notification for the *same* switch coalesce into a
    /// single `rebuildEngine()` call instead of two back-to-back ones.
    private func requestRebuild() {
        guard !stopped, !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.performRebuild()
        }
    }

    private func performRebuild() {
        rebuildScheduled = false
        guard !stopped else { return }
        rebuildEngine()
    }

    /// Discards the old engine entirely and builds a fresh one: stop + untap
    /// the old engine, create a new `AVAudioEngine`, validate its input
    /// format, point the writer at it, install a tap, and start. This is
    /// deliberately not "remove tap → reinstall on the same engine →
    /// restart" — that path is exactly what looked healthy but silently
    /// stopped receiving buffers after a device switch in production.
    private func rebuildEngine() {
        onEventAsync("input device changed; rebuilding audio engine")

        let oldEngine = engine
        oldEngine.stop()
        oldEngine.inputNode.removeTap(onBus: 0)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil

        let newEngine = AVAudioEngine()
        engine = newEngine
        subscribeToConfigurationChange()

        let newFormat = newEngine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            setHealthy(false)
            onEventAsync("audio engine rebuild failed: no input device available")
            return
        }

        // Locked: a straggler tap callback from the outgoing tap may still
        // be inside writeLocked(), using the writer's current converter,
        // when this runs — without the lock both threads could mutate the
        // same AVAudioConverter/AVAudioFile at once.
        stateLock.withLock { writer?.updateSourceFormat(newFormat) }
        installTap(format: newFormat)
        do {
            try newEngine.start()
            setHealthy(true)
            onEventAsync("audio engine rebuilt (rate=\(Int(newFormat.sampleRate)), "
                         + "ch=\(newFormat.channelCount))")
        } catch {
            setHealthy(false)
            onEventAsync("audio engine rebuild failed: \(error.localizedDescription)")
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

    private func onEventAsync(_ message: String) {
        DispatchQueue.main.async { self.onEvent?(message) }
    }

    public func stop() {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        removeDefaultInputDeviceListener()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stateLock.lock()
        writer?.finalize()
        stateLock.unlock()
    }
}
