import AVFoundation
import Foundation

/// Records the default input device into a WAV via AVAudioEngine.
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private let outputURL: URL
    private var writer: WavWriter?
    private let pausedLock = NSLock()
    private var _paused = false
    private var observer: NSObjectProtocol?

    public private(set) var isHealthy = true
    /// Called on the main queue when health changes (for the status line).
    public var onHealthChange: ((Bool) -> Void)?

    /// Atomic; drops buffers while true.
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
