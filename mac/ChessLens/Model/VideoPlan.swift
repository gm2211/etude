import Foundation
import ChessCore

/// A script compiled to cues with an estimated length for each, so the summary card and the player bar can show
/// timestamps before anything has played. The player replaces an estimate with the measured time as a cue plays.
struct VideoPlan {
    let script: VideoScript
    let compiled: VideoCues.Compiled
    /// Seconds per cue at 1x.
    let durations: [Double]

    var cues: [VideoCue] { compiled.cues }
    var chapters: [VideoCues.Chapter] { compiled.chapters }

    init(script: VideoScript) {
        self.script = script
        compiled = VideoCues.compile(script)
        durations = Self.estimates(compiled.cues)
    }

    var starts: [Double] { Self.starts(durations) }
    var total: Double { durations.reduce(0, +) }

    static func starts(_ durations: [Double]) -> [Double] {
        var t = 0.0
        return durations.map { d in defer { t += d }; return t }
    }

    /// "1:05" / "12:30".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Timing

    static let chapterCard = 1.6
    static let askHold = 5.0
    static let revealHold = 2.6
    static let answerHold = 1.8

    /// How long a move cue takes: the slide plus a hold, longer when the commentary lingers.
    static func moveTime(_ pace: VideoScript.Pace) -> Double {
        switch pace { case .quick: 0.7; case .normal: 1.1; case .slow: 1.5 }
    }
    static func slideTime(_ pace: VideoScript.Pace) -> Double {
        switch pace { case .quick: 0.32; case .normal: 0.5; case .slow: 0.7 }
    }

    /// Seconds to read a line silently: short lines go by quickly, at least 1.6 s.
    static func readingTime(_ text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return max(1.6, Double(words) / 3.2 + 0.5)
    }

    /// A voice is slower than silent reading.
    static func speechTime(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let words = text.split(whereSeparator: \.isWhitespace).count
        return max(1.6, Double(words) / 2.6 + 0.4)
    }

    static func estimates(_ cues: [VideoCue]) -> [Double] {
        var out: [Double] = cues.map { c in
            var t: Double
            switch c.kind {
            case .intro: t = max(3.4, speechTime(c.say) + 0.8)
            case .move: t = moveTime(c.pace)
            case .marks: t = (c.say.isEmpty ? 1.2 : speechTime(c.say)) + 0.3
            case .ask: t = askHold + revealHold
            case .excursionEnter: t = 1.4
            case .excursionStep: t = 0.35 + Double(c.moves.count) * 0.9 + max(c.say.isEmpty ? 1.0 : speechTime(c.say) - Double(c.moves.count) * 0.9, 0.3) + 0.3
            case .excursionExit: t = 1.6
            case .outro: t = max(4, speechTime(c.say) + 2)
            }
            if c.chapterStart != nil { t += chapterCard }
            return t
        }
        // A quick segment's line starts with its first move and runs on over the rest; the segment ends when it does.
        var i = 0
        while i < cues.count {
            guard case .move = cues[i].kind, cues[i].pace == .quick, !cues[i].say.isEmpty else { i += 1; continue }
            var j = i
            while j + 1 < cues.count, cues[j + 1].segment == cues[i].segment { j += 1 }
            let span = out[i...j].reduce(0, +)
            let need = speechTime(cues[i].say)
            if need > span { out[j] += need - span }
            i = j + 1
        }
        return out
    }
}
