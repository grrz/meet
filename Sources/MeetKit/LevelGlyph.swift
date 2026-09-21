/// Maps a track's peak level (0...1) to a braille glyph for the status line.
public enum LevelGlyph {
    public static func glyph(forPeak peak: Double) -> Character {
        switch peak {
        case ..<0.005: return "_"
        case ..<0.02: return "⣀"
        case ..<0.08: return "⣤"
        case ..<0.3: return "⣶"
        default: return "⣿"
        }
    }
}
