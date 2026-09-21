/// Interactive-mode key commands, decoupled from keyboard layout: the
/// terminal delivers characters, not physical keys, so a Russian layout
/// sends `я`/`й` where a US layout sends `z`/`q`.
public enum KeyCommand: Equatable, Sendable {
    case toggleRecording
    case space
    case quit

    public static func parse(_ key: String) -> KeyCommand? {
        switch key {
        case "z", "Z", "я", "Я": return .toggleRecording
        case "q", "Q", "й", "Й", "\u{04}": return .quit
        case " ": return .space
        default: return nil
        }
    }
}
