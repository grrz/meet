import Foundation

public struct TranscriptOptions: Equatable, Sendable {
    public var mergeGapSeconds: Double
    public var speakerMe: String
    public var speakerThem: String

    public init(mergeGapSeconds: Double = 2.0,
                speakerMe: String = "Me",
                speakerThem: String = "Them") {
        self.mergeGapSeconds = mergeGapSeconds
        self.speakerMe = speakerMe
        self.speakerThem = speakerThem
    }
}

public enum Transcript {
    struct Utterance {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    public static func assemble(me: [Segment], them: [Segment],
                                title: String, durationSeconds: Double,
                                options: TranscriptOptions) -> String {
        let labeled = (me.map { (options.speakerMe, $0) } + them.map { (options.speakerThem, $0) })
            .sorted { $0.1.start < $1.1.start }

        var utterances: [Utterance] = []
        for (speaker, seg) in labeled {
            if var last = utterances.last,
               last.speaker == speaker,
               seg.start - last.end < options.mergeGapSeconds {
                last.text += " " + seg.text
                last.end = max(last.end, seg.end)
                utterances[utterances.count - 1] = last
            } else {
                utterances.append(Utterance(speaker: speaker, start: seg.start,
                                            end: seg.end, text: seg.text))
            }
        }

        let durationLabel: String
        if durationSeconds < 60 {
            durationLabel = "\(Int(durationSeconds.rounded())) sec"
        } else {
            durationLabel = "\(Int((durationSeconds / 60).rounded())) min"
        }

        var lines = ["# \(title) (\(durationLabel))", ""]
        if utterances.isEmpty {
            lines.append("_(no speech recognized)_")
        } else {
            for u in utterances {
                lines.append("\(timecode(u.start)) \(u.speaker): \(u.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
