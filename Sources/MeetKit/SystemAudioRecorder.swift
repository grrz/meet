import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Errors thrown by `SystemAudioRecorder`.
public enum SystemAudioError: Error, LocalizedError {
    case tapCreationFailed(OSStatus)
    case formatUnavailable(OSStatus)
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
        case .formatUnavailable(let s):
            "Could not read the system audio tap's stream format (OSStatus \(s))"
        case .aggregateCreationFailed(let s): "Aggregate device creation failed (OSStatus \(s))"
        case .ioProcFailed(let s): "Audio IO proc failed (OSStatus \(s))"
        }
    }
}

/// Records the system audio mixdown via a CoreAudio process tap (macOS 14.2+).
/// Playback is untouched: the tap listens post-mix, nothing is rerouted.
///
/// Single-use: call `start()` once and `stop()` once per instance. `stopped`
/// latches permanently once `stop()` runs and is never reset, so a second
/// `start()` on the same instance will not resume capture — create a new
/// `SystemAudioRecorder` for a new recording. This matches how Task 12 uses
/// it: one fresh instance per session.
///
/// Threading, mirroring `MicRecorder`: callers use the main thread and
/// `start()`/`stop()` hop onto `AudioControl.queue` and wait; that queue owns
/// the tap/aggregate/IOProc chain, both CoreAudio listeners and
/// `rebuildScheduled`; the HAL IO thread runs the IOProc, which only writes a
/// buffer, drops it, or flips the health flag.
public final class SystemAudioRecorder {
    private let outputURL: URL
    private var writer: WavWriter?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var defaultDeviceListenerInstalled = false
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Nominal-sample-rate listener on the aggregate device, reinstalled with
    /// every chain build and removed by every teardown.
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    private var rateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
    /// Set when a rebuild has been queued on the control queue and cleared
    /// once it runs. Both signals — default output device and nominal sample
    /// rate — fire together when a Bluetooth headset connects, and a single
    /// rebuild reads the current device *and* the current rate, so coalescing
    /// them saves one full teardown/rebuild of the aggregate device.
    /// Control queue only, like every field above it.
    private var rebuildScheduled = false

    /// Guards `_paused`, `_isHealthy`, and `_stopped` — touched from both
    /// the HAL IO thread (via the IOProc block) and the control queue (via
    /// the default-device and sample-rate listener blocks) and by public
    /// callers on the main thread.
    ///
    /// The IOProc's own write/finalize race is already closed by a hard
    /// barrier, so this lock does not need to cover `writer` or `tapFormat`:
    /// `teardownCaptureChain()`'s calls to `AudioDeviceStop` and
    /// `AudioDeviceDestroyIOProcID` are documented to block until no further
    /// IOProc callback can fire, every path that touches those two fields runs
    /// `teardownCaptureChain()` first (`stop()` before `writer?.finalize()`,
    /// `rebuildAfterFormatChange` before the new format is installed), and the
    /// new chain only starts delivering at `AudioDeviceStart`.
    private let stateLock = NSLock()
    private var _paused = false
    private var _isHealthy = true
    private var _stopped = false

    public var paused: Bool {
        get { stateLock.withLock { _paused } }
        set { stateLock.withLock { _paused = newValue } }
    }

    public var isHealthy: Bool { stateLock.withLock { _isHealthy } }

    /// Set once by `stop()`; checked by both listener blocks so a
    /// notification already queued on the control queue before `stop()` ran
    /// can't rebuild a brand-new tap + aggregate device after the caller
    /// considers capture over.
    private var stopped: Bool {
        get { stateLock.withLock { _stopped } }
        set { stateLock.withLock { _stopped = newValue } }
    }

    /// Called on `AudioControl.queue` when health changes (for the status
    /// line). Set it before `start()`. Consumers must not block that queue;
    /// calling `stop()` from it is safe.
    public var onHealthChange: ((Bool) -> Void)?

    /// Called on `AudioControl.queue` with a short, English, one-line
    /// description of a lifecycle event (device/rate-change rebuild starting,
    /// succeeding, or failing) — for the session log, not for control flow.
    /// Set it before `start()`. Consumers must not block that queue; calling
    /// `stop()` from it is safe, and delivery is always asynchronous with
    /// respect to the rebuild that produced the event, so doing so cannot
    /// re-enter a rebuild still on the stack.
    public var onEvent: ((String) -> Void)?

    public var durationSeconds: Double { writer?.durationSeconds ?? 0 }

    public init(outputURL: URL) { self.outputURL = outputURL }

    /// Starts capture. Call from the main thread; the work runs on
    /// `AudioControl.queue` and this waits for it.
    public func start() throws {
        try AudioControl.sync {
            try buildCaptureChain()
            installDefaultDeviceListener()
        }
    }

    /// Stops capture and finalizes the WAV. Call from the main thread (or
    /// from an `onEvent`/`onHealthChange` callback, which already runs on the
    /// control queue — `AudioControl.sync` handles both).
    ///
    /// Everything is done synchronously before returning: the `stopped` latch,
    /// cancelling a scheduled rebuild, removing both CoreAudio listeners,
    /// tearing the capture chain down (which is documented to block until no
    /// further IOProc callback can fire), then finalizing the writer. Any
    /// rebuild already queued behind this call re-checks `stopped` and returns
    /// without touching the device.
    public func stop() {
        AudioControl.sync {
            stopped = true
            // Bookkeeping only; the `stopped` latch is what stops a rebuild
            // block that is already queued behind this one.
            rebuildScheduled = false
            removeDefaultDeviceListener()
            teardownCaptureChain()
            writer?.finalize()
        }
    }

    /// Builds the tap → aggregate device → IO proc chain, or tears down
    /// whatever partial state it created before rethrowing. Without this,
    /// a failure after the tap is created (e.g. aggregate-device creation
    /// fails) would leak `tapID` since nothing else ever destroys it.
    ///
    /// If this attempt is the one that created `writer` (i.e. this is the
    /// initial `start()`, not a later device-change rebuild of an
    /// already-recording session), a failure also finalizes and deletes the
    /// half-written WAV rather than leaving a header-only file behind for
    /// the pipeline to trip over. A rebuild that fails after real audio was
    /// already captured must never delete that file, so this only fires
    /// when `writer` was nil going into the attempt.
    /// Control queue only.
    private func buildCaptureChain() throws {
        let writerExistedBeforeAttempt = writer != nil
        do {
            try buildCaptureChainOrThrow()
        } catch {
            teardownCaptureChain()
            if !writerExistedBeforeAttempt, let writer {
                writer.finalize()
                self.writer = nil
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
        }
    }

    /// Control queue only.
    private func buildCaptureChainOrThrow() throws {
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
            throw SystemAudioError.formatUnavailable(status)
        }
        _ = format // sample layout validated; the effective rate is fixed up below

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

        // 3b. The IOProc is clocked by the aggregate device, whose rate is the
        // output device's actual rate — NOT necessarily the rate the tap's
        // format property claims. Example: a Bluetooth headset in handsfree
        // mode runs at 16 kHz while the tap still reports 48 kHz; trusting
        // the tap's rate then writes 8 seconds of audio into 2.7 seconds of
        // file (3x speed). Use the tap's sample layout with the aggregate's
        // real rate as the effective IO format.
        var aggregateRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &rateSize, &aggregateRate)
        var ioASBD = asbd
        if status == noErr, aggregateRate > 0 {
            ioASBD.mSampleRate = aggregateRate
        }
        guard let ioFormat = AVAudioFormat(streamDescription: &ioASBD) else {
            throw SystemAudioError.formatUnavailable(status)
        }
        tapFormat = ioFormat

        if let writer {
            writer.updateSourceFormat(ioFormat)
        } else {
            writer = try WavWriter(url: outputURL, sourceFormat: ioFormat)
        }

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

        // The rate read in 3b is a snapshot, so watch it for changes.
        installSampleRateListener(on: aggregateID)
    }

    /// A Bluetooth headset flips between A2DP (48 kHz) and SCO (16 kHz) on the
    /// *same* device the moment a call app opens its mic — no default-device
    /// change, so the listener above never fires. The aggregate's rate follows
    /// the flip while our capture format stays at the rate read during the
    /// build, and the system track then records at the wrong speed (the 3x
    /// bug 3b describes, from the other direction).
    ///
    /// The aggregate is the right object to watch rather than the output
    /// device, because its nominal rate is exactly the value fed into
    /// `ioASBD.mSampleRate`: if that has not changed, our format is still
    /// correct.
    /// Control queue only.
    private func installSampleRateListener(on deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown, rateListenerBlock == nil else { return }
        var address = Self.nominalSampleRateAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            self.requestRebuild(reason: "sample rate changed")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID, &address, AudioControl.queue, block)
        guard status == noErr else {
            emit("could not watch the capture device's sample rate "
                 + "(OSStatus \(status)); a Bluetooth A2DP/SCO flip may go unnoticed")
            return
        }
        rateListenerBlock = block
        rateListenerDeviceID = deviceID
    }

    /// Control queue only.
    private func removeSampleRateListener() {
        guard let block = rateListenerBlock,
              rateListenerDeviceID != kAudioObjectUnknown else { return }
        var address = Self.nominalSampleRateAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            rateListenerDeviceID, &address, AudioControl.queue, block)
        if status != noErr {
            emit("could not remove the sample-rate listener (OSStatus \(status))")
        }
        rateListenerBlock = nil
        rateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private static var nominalSampleRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Funnels both recovery signals into one debounced, deferred rebuild.
    ///
    /// Deferred rather than rebuilt inline because the rebuild's teardown
    /// removes the very listener blocks that call this, and a block must not
    /// remove itself while it is executing. The `stopped` guard is rechecked
    /// inside the deferred work, since `stop()` can run in between.
    /// Control queue only.
    private func requestRebuild(reason: String) {
        guard !stopped, !rebuildScheduled else { return }
        rebuildScheduled = true
        AudioControl.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard !self.stopped else { return }
            self.rebuildAfterFormatChange(reason: reason)
        }
    }

    /// Teardown + rebuild keeping the same WAV file open. Shared by the
    /// default-output-device path and the sample-rate path, which need
    /// identical handling: both invalidate the capture format. `reason` is
    /// a short label for the triggering signal, used only for the emitted
    /// event text.
    /// Control queue only.
    private func rebuildAfterFormatChange(reason: String) {
        emit("\(reason); rebuilding audio capture chain")
        teardownCaptureChain()
        do {
            try buildCaptureChain()
            setHealthy(true)
            if let tapFormat {
                emit("audio capture chain rebuilt (rate=\(Int(tapFormat.sampleRate)), "
                     + "ch=\(tapFormat.channelCount))")
            }
        } catch {
            setHealthy(false)
            emit("audio capture chain rebuild failed: \(error.localizedDescription)")
        }
    }

    /// The default output device changed (e.g. headphones plugged in):
    /// tear the chain down and rebuild it, keeping the same WAV file open.
    /// Control queue only.
    private func installDefaultDeviceListener() {
        guard !defaultDeviceListenerInstalled else { return }
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            self.requestRebuild(reason: "output device changed")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, AudioControl.queue, block)
        guard status == noErr else {
            emit("could not watch the default output device (OSStatus \(status)); "
                 + "device-change recovery is degraded")
            return
        }
        defaultDeviceListenerBlock = block
        defaultDeviceListenerInstalled = true
    }

    /// Control queue only.
    private func removeDefaultDeviceListener() {
        guard defaultDeviceListenerInstalled, let block = defaultDeviceListenerBlock else { return }
        var address = Self.defaultOutputAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, AudioControl.queue, block)
        if status != noErr {
            emit("could not remove the default-output listener (OSStatus \(status))")
        }
        defaultDeviceListenerBlock = nil
        defaultDeviceListenerInstalled = false
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Control queue only.
    private func teardownCaptureChain() {
        // Symmetric with installSampleRateListener at the end of every
        // successful build, and removed before the device it watches is
        // destroyed below.
        removeSampleRateListener()
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

    /// Safe from the HAL IO thread: takes `stateLock` briefly and hands the
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
