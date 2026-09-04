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
///
/// Threading. Three separate contexts touch this object:
///
/// * **Callers** (`start()`, `stop()`, `paused`, `isHealthy`,
///   `durationSeconds`) run on the main thread. `start()`/`stop()` hop onto
///   `AudioControl.queue` internally and wait.
/// * **`AudioControl.queue`** owns all capture lifecycle state: `engine`,
///   `observer`, `defaultInputListenerBlock`, `rebuildScheduled`, and the
///   engine generation counter. Every device-change signal is delivered there
///   and every rebuild runs there, so rebuilds are serialized with each other
///   and with `SystemAudioRecorder`'s.
/// * **The render thread** runs the tap block. It only writes a buffer, drops
///   it, or flips the health flag — it never rebuilds and never blocks on the
///   control queue.
public final class MicRecorder {
    /// The live engine, or nil before `start()`, after `stop()`, and between
    /// a failed rebuild and the next recovery signal.
    ///
    /// Rebuilt from scratch on every recovery — see `rebuildEngine(reason:)`.
    /// Reinstalling a tap on a post-configuration-change engine is what
    /// silently stopped delivering buffers in production (macOS tears down
    /// more than the tap when the default input device changes), so
    /// recovery always discards this instance and creates a new one rather
    /// than reusing it.
    ///
    /// Optional, and actually released, because a live `AVAudioEngine` object
    /// holds a Bluetooth headset in its degraded call mode (SCO, 16 kHz) even
    /// after `engine.stop()` — verified empirically. Dropping the last
    /// reference is what lets the headset return to A2DP. Control queue only.
    private var engine: AVAudioEngine?
    private let outputURL: URL
    private var writer: WavWriter?
    /// Observes `.AVAudioEngineConfigurationChange` on the *current* engine
    /// instance; re-subscribed to the new engine after every successful
    /// rebuild, since the old observer would otherwise watch a discarded
    /// object. Control queue only.
    private var observer: NSObjectProtocol?
    /// CoreAudio listener on the system's default input device, independent
    /// of the engine-configuration-change notification: a device switch
    /// does not always fire `.AVAudioEngineConfigurationChange` promptly (or
    /// at all) in every combination of driver/OS, so both signals feed the
    /// same rebuild path. Installed once in `start()`, removed in `stop()`.
    /// Control queue only.
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    /// Guards every field the audio-render thread and other threads both
    /// touch: `_paused`, `_isHealthy`, `_stopped`, `_generation`, and access
    /// to `writer` itself (write in the tap callback vs. format swap in a
    /// rebuild and finalize in `stop()`). Each property below acquires it
    /// only for the single access it needs and never while calling back into
    /// `engine`/`onHealthChange`/another locked accessor, so there is no
    /// nesting and no lock held across a call that could re-enter.
    private let stateLock = NSLock()
    private var _paused = false
    private var _isHealthy = true
    private var _stopped = false
    /// Monotonic id of the current engine/tap pair, bumped on every engine
    /// creation. Every tap block and configuration-change observer captures
    /// the generation it belongs to, so work arriving from a discarded engine
    /// is recognizable and dropped:
    ///
    /// * a straggler buffer from the old tap would otherwise reach the writer
    ///   *after* `updateSourceFormat` swapped in a converter for the new
    ///   format, which either errors (permanent false ✗) or trips an
    ///   unhandled exception inside the converter;
    /// * a stale configuration-change notification would otherwise queue a
    ///   rebuild of an engine that no longer exists.
    ///
    /// Mutated only on the control queue but read from the render thread, so
    /// it lives under `stateLock` with the other shared scalars.
    private var _generation: UInt64 = 0

    /// Set when a rebuild has been queued on the control queue and cleared
    /// once it actually runs. Both recovery signals land on the control queue
    /// (the CoreAudio listener block is registered with it, and the
    /// configuration-change observer hops onto it), so this flag — touched
    /// only from that queue — is enough to coalesce a double-fire (e.g. both
    /// signals for the same device switch) into a single rebuild without
    /// needing its own lock.
    private var rebuildScheduled = false

    /// Called on `AudioControl.queue` when health changes (for the status
    /// line). Set it before `start()`. Consumers must not block that queue;
    /// calling `stop()` from it is safe.
    public var onHealthChange: ((Bool) -> Void)?

    /// Called on `AudioControl.queue` with a short, English, one-line
    /// description of a lifecycle event (device-change rebuild starting,
    /// succeeding, or failing) — for the session log, not for control flow.
    /// Set it before `start()`. Consumers must not block that queue; calling
    /// `stop()` from it is safe, and delivery is always asynchronous with
    /// respect to the rebuild that produced the event, so doing so cannot
    /// re-enter a rebuild still on the stack.
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

    private var generation: UInt64 { stateLock.withLock { _generation } }

    public var durationSeconds: Double { writer?.durationSeconds ?? 0 }

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Starts capture. Call from the main thread; the work runs on
    /// `AudioControl.queue` and this waits for it.
    public func start() throws {
        try AudioControl.sync { try performStart() }
    }

    /// Stops capture and finalizes the WAV. Call from the main thread (or
    /// from an `onEvent`/`onHealthChange` callback, which already runs on the
    /// control queue — `AudioControl.sync` handles both).
    ///
    /// Everything is done synchronously before returning: the `stopped` latch,
    /// cancelling a scheduled rebuild, removing the observer and the CoreAudio
    /// listener, tearing down and *releasing* the engine, and finalizing the
    /// writer. Any rebuild already queued behind this call re-checks `stopped`
    /// and returns without touching the device.
    public func stop() {
        AudioControl.sync { performStop() }
    }

    // MARK: - control queue internals

    /// Control queue only.
    private func performStart() throws {
        let newEngine = AVAudioEngine()
        let format = newEngine.inputNode.outputFormat(forBus: 0)
        // With no input device the node reports 0 Hz / 0 channels, and
        // WavWriter would then fail with a bare converterCreationFailed that
        // says nothing about the actual problem. Name it here instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicRecorderError.noInputDevice(sampleRate: format.sampleRate,
                                                 channelCount: format.channelCount)
        }
        let writer = try WavWriter(url: outputURL, sourceFormat: format)
        let generation: UInt64 = stateLock.withLock {
            self.writer = writer
            _generation += 1
            return _generation
        }
        engine = newEngine
        installTap(on: newEngine, format: format, generation: generation)
        do {
            try newEngine.start()
        } catch {
            // Nothing ever recorded on this attempt: don't leave a
            // header-only WAV behind for the pipeline to trip over.
            newEngine.inputNode.removeTap(onBus: 0)
            engine = nil
            stateLock.withLock {
                writer.finalize()
                self.writer = nil
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        // Only after a successful start, and only for the engine that
        // actually started: subscribing earlier means a notification posted
        // *during* startup queues a rebuild of an engine that is already the
        // current one, which can feed itself indefinitely.
        subscribeToConfigurationChange(engine: newEngine, generation: generation)
        installDefaultInputDeviceListener()
    }

    /// Control queue only.
    private func performStop() {
        stopped = true
        // A rebuild block may already be queued behind this call; clearing the
        // flag is only bookkeeping, the `stopped` latch above is what stops it.
        rebuildScheduled = false
        removeConfigurationChangeObserver()
        removeDefaultInputDeviceListener()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Release the engine, not just stop it — see the property's comment.
        engine = nil
        stateLock.lock()
        writer?.finalize()
        stateLock.unlock()
    }

    /// Control queue only.
    private func installTap(on engine: AVAudioEngine,
                            format: AVAudioFormat,
                            generation: UInt64) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
            [weak self] buffer, _ in
            guard let self, !self.paused else { return }
            do {
                try self.writeLocked(buffer, generation: generation)
            } catch {
                self.setHealthy(false)
            }
        }
    }

    /// Locked so a straggler tap callback (AVAudioEngine buffers arrive on
    /// an internal queue; `removeTap`/`stop()` don't document draining)
    /// can never run concurrently with a rebuild's `updateSourceFormat` or
    /// with `finalize()` closing the same file in `stop()`.
    ///
    /// `generation` is the engine the calling tap belongs to. A buffer from a
    /// discarded engine is dropped rather than written, because the writer's
    /// converter has already been rebuilt for the new engine's format. The
    /// rate/channel check behind it is a cheap belt for the same hazard.
    private func writeLocked(_ buffer: AVAudioPCMBuffer, generation: UInt64) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == _generation, let writer else { return }
        let expected = writer.sourceFormat
        guard buffer.format.sampleRate == expected.sampleRate,
              buffer.format.channelCount == expected.channelCount else { return }
        try writer.write(buffer)
    }

    // MARK: - recovery

    /// The engine stops itself when the default input device changes or
    /// dies. Re-subscribed after every rebuild since the previous observer
    /// watched the now-discarded engine instance.
    ///
    /// `queue: nil` on purpose: `NotificationCenter` takes an `OperationQueue`,
    /// not a `DispatchQueue`, so instead of wrapping the control queue in one
    /// the block is delivered on the posting thread and immediately hops onto
    /// the control queue itself. Everything it touches lives there.
    /// Control queue only.
    private func subscribeToConfigurationChange(engine: AVAudioEngine, generation: UInt64) {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            AudioControl.async {
                guard !self.stopped, generation == self.generation else { return }
                self.requestRebuild(reason: "audio engine configuration changed")
            }
        }
    }

    /// Control queue only.
    private func removeConfigurationChangeObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// A device switch (e.g. Zoom moving the default input from the built-in
    /// mic to a Bluetooth headset) doesn't reliably fire
    /// `.AVAudioEngineConfigurationChange` in time, or at all, on every
    /// macOS/driver combination — that gap is exactly what silently dropped
    /// 55 minutes of mic audio in production, since nothing else was
    /// watching. This CoreAudio listener on the system's default input
    /// device is the second, independent signal into the same rebuild path.
    /// It is also the *only* signal left after a failed rebuild, which
    /// releases the engine and with it the configuration-change observer.
    ///
    /// Mirrors `SystemAudioRecorder`'s default-output listener: the `stopped`
    /// guard, the control queue, and installed once / removed in `stop()`.
    /// Control queue only.
    private func installDefaultInputDeviceListener() {
        guard defaultInputListenerBlock == nil else { return }
        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            self.requestRebuild(reason: "input device changed")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, AudioControl.queue, block)
        guard status == noErr else {
            // Recovery now rests on the configuration-change notification
            // alone; say so rather than failing the recording.
            emit("could not watch the default input device (OSStatus \(status)); "
                 + "device-change recovery is degraded")
            return
        }
        defaultInputListenerBlock = block
    }

    /// Control queue only.
    private func removeDefaultInputDeviceListener() {
        guard let block = defaultInputListenerBlock else { return }
        var address = Self.defaultInputAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, AudioControl.queue, block)
        if status != noErr {
            emit("could not remove the default-input listener (OSStatus \(status))")
        }
        defaultInputListenerBlock = nil
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Funnels both recovery signals into one debounced, deferred rebuild.
    ///
    /// Deferring instead of rebuilding inline matters for the listener block:
    /// a rebuild may remove listeners, and a block must not remove itself
    /// while it is executing. Gating on `rebuildScheduled` means a
    /// configuration-change notification and a default-device notification for
    /// the *same* switch coalesce into a single `rebuildEngine` call instead of
    /// two back-to-back ones. `stopped` is re-checked inside the deferred
    /// block, since `stop()` can run in between.
    /// Control queue only.
    private func requestRebuild(reason: String) {
        guard !stopped, !rebuildScheduled else { return }
        rebuildScheduled = true
        AudioControl.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard !self.stopped else { return }
            self.rebuildEngine(reason: reason)
        }
    }

    /// Discards the old engine entirely and builds a fresh one: unsubscribe,
    /// stop + untap + release the old engine, create a new `AVAudioEngine`,
    /// validate its input format, point the writer at it, install a tap, and
    /// start. This is deliberately not "remove tap → reinstall on the same
    /// engine → restart" — that path is exactly what looked healthy but
    /// silently stopped receiving buffers after a device switch in production.
    /// Control queue only.
    private func rebuildEngine(reason: String) {
        emit("\(reason); rebuilding audio engine")

        removeConfigurationChangeObserver()
        if let oldEngine = engine {
            oldEngine.stop()
            oldEngine.inputNode.removeTap(onBus: 0)
        }
        engine = nil

        let newEngine = AVAudioEngine()
        let newFormat = newEngine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            setHealthy(false)
            emit("audio engine rebuild failed: no input device available")
            return
        }

        // One locked step: bump the generation and swap the writer's
        // converter together, so a straggler buffer from the outgoing tap is
        // either written before the swap (still with its own converter) or
        // dropped after it — never converted with the wrong format.
        let generation: UInt64 = stateLock.withLock {
            _generation += 1
            writer?.updateSourceFormat(newFormat)
            return _generation
        }
        engine = newEngine
        installTap(on: newEngine, format: newFormat, generation: generation)
        do {
            try newEngine.start()
            subscribeToConfigurationChange(engine: newEngine, generation: generation)
            setHealthy(true)
            emit("audio engine rebuilt (rate=\(Int(newFormat.sampleRate)), "
                 + "ch=\(newFormat.channelCount))")
        } catch {
            // Release the engine that would not start, both to free a
            // Bluetooth headset and so the next signal starts from scratch.
            newEngine.inputNode.removeTap(onBus: 0)
            engine = nil
            setHealthy(false)
            emit("audio engine rebuild failed: \(error.localizedDescription)")
        }
    }

    /// Safe from the render thread: takes `stateLock` briefly and hands the
    /// callback to the control queue rather than invoking it inline.
    private func setHealthy(_ value: Bool) {
        let changed: Bool = stateLock.withLock {
            guard _isHealthy != value else { return false }
            _isHealthy = value
            return true
        }
        guard changed else { return }
        // Strong capture: an event queued moments before the last reference
        // goes away should still reach the log rather than vanish.
        AudioControl.async { self.onHealthChange?(value) }
    }

    private func emit(_ message: String) {
        AudioControl.async { self.onEvent?(message) }
    }
}
