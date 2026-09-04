import Dispatch

/// The one serial queue that owns audio-device lifecycle work for the whole
/// process.
///
/// Everything that reconfigures capture — CoreAudio property listeners,
/// `AVAudioEngineConfigurationChange` handling, engine/tap/aggregate-device
/// rebuilds and teardown — runs here, and nowhere else.
///
/// Two reasons it is one queue rather than one per recorder:
///
/// 1. `.main` is unusable. The interactive CLI's control loop is a bare
///    `while { poll(stdin) }`; it never services the main dispatch queue or a
///    run loop, so every callback registered with `.main` — CoreAudio listener
///    blocks, `NotificationCenter` observers, `DispatchQueue.main.async`
///    deferrals — was silently never delivered. All device-change recovery was
///    dead code in the shipped binary. A queue we own is serviced regardless of
///    what the main thread is doing.
/// 2. One connect event moves both devices. Plugging in a Bluetooth headset
///    changes the default *input* and the default *output* at the same instant,
///    so `MicRecorder` and `SystemAudioRecorder` would otherwise rebuild
///    concurrently and contend inside CoreAudio (creating/destroying aggregate
///    devices while the HAL is already reconfiguring). Serializing both
///    recorders on one queue makes those rebuilds strictly sequential.
///
/// Real-time audio callbacks (the mic tap block, the system IOProc) must never
/// touch this queue synchronously: they only write buffers, drop them, or flip
/// a health flag.
enum AudioControl {
    private static let isCurrentKey = DispatchSpecificKey<Bool>()

    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "meet.audio-control", qos: .userInitiated)
        queue.setSpecific(key: isCurrentKey, value: true)
        return queue
    }()

    /// True when the calling thread is currently executing a block on `queue`.
    /// Used by `sync` to stay re-entrant instead of deadlocking.
    static var isCurrent: Bool {
        DispatchQueue.getSpecific(key: isCurrentKey) ?? false
    }

    /// Runs `work` on the control queue and waits for it.
    ///
    /// Re-entrant on purpose: a caller that is *already* on the queue runs
    /// `work` inline instead of dispatching, because `DispatchQueue.sync` onto
    /// the queue you are running on deadlocks. That is what makes it safe for
    /// an `onEvent`/`onHealthChange` consumer (those fire on this queue) to
    /// call a recorder's `stop()` directly.
    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        if isCurrent { return try work() }
        return try queue.sync(execute: work)
    }

    /// Schedules `work` on the control queue. Always asynchronous, including
    /// from the queue itself — callbacks delivered this way can therefore never
    /// re-enter the middle of a rebuild that is still on the stack.
    static func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }
}
