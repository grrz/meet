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
public final class SystemAudioRecorder {
    private let outputURL: URL
    private var writer: WavWriter?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var defaultDeviceListenerInstalled = false
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Guards `_paused`, `_isHealthy`, and `_stopped` — touched from both
    /// the HAL IO thread (via the IOProc block) and the main queue (via the
    /// default-device listener block and public callers). The IOProc's own
    /// write/finalize race is already closed by a hard barrier
    /// (`AudioDeviceStop`/`AudioDeviceDestroyIOProcID` in
    /// `teardownCaptureChain()` run, and are documented to block until no
    /// further IOProc callback fires, before `stop()` ever reaches
    /// `writer?.finalize()`), so this lock does not need to cover `writer`.
    private let stateLock = NSLock()
    private var _paused = false
    private var _isHealthy = true
    private var _stopped = false

    public var paused: Bool {
        get { stateLock.withLock { _paused } }
        set { stateLock.withLock { _paused = newValue } }
    }

    public var isHealthy: Bool { stateLock.withLock { _isHealthy } }

    /// Set once by `stop()`; checked by the default-device listener block
    /// so a device-change notification already queued on the main queue
    /// before `stop()` ran can't rebuild a brand-new tap + aggregate device
    /// after the caller considers capture over.
    private var stopped: Bool {
        get { stateLock.withLock { _stopped } }
        set { stateLock.withLock { _stopped = newValue } }
    }

    public var onHealthChange: ((Bool) -> Void)?
    public var durationSeconds: Double { writer?.durationSeconds ?? 0 }

    public init(outputURL: URL) { self.outputURL = outputURL }

    public func start() throws {
        try buildCaptureChain()
        installDefaultDeviceListener()
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
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            self.teardownCaptureChain()
            do {
                try self.buildCaptureChain()
                self.setHealthy(true)
            } catch {
                self.setHealthy(false)
            }
        }
        defaultDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func removeDefaultDeviceListener() {
        guard defaultDeviceListenerInstalled, let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        defaultDeviceListenerBlock = nil
        defaultDeviceListenerInstalled = false
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
        removeDefaultDeviceListener()
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
