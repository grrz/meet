import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Errors thrown by `SystemAudioRecorder`.
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

    /// Builds the tap → aggregate device → IO proc chain, or tears down
    /// whatever partial state it created before rethrowing. Without this,
    /// a failure after the tap is created (e.g. aggregate-device creation
    /// fails) would leak `tapID` since nothing else ever destroys it.
    private func buildCaptureChain() throws {
        do {
            try buildCaptureChainOrThrow()
        } catch {
            teardownCaptureChain()
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
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
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
        guard isHealthy != value else { return }
        isHealthy = value
        DispatchQueue.main.async { self.onHealthChange?(value) }
    }

    public func stop() {
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
