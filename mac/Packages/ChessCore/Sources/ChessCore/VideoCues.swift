import Foundation

/// One step of the video's timeline. The script is compiled into a flat list of these (see `VideoCues`), which the
/// app's player walks: a game move, the marks and line spoken once the moves land, a "find the move" pause, the
/// three parts of a "what if" excursion, and the intro and outro cards.
public struct VideoCue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case intro
        /// The game move at this ply slides in.
        case move(ply: Int)
        /// Arrows, circles and the reaction (and the spoken line, unless it started with the first move).
        case marks
        /// The question on the position before the segment's last move.
        case ask
        /// The board leaves the game: `root` says whether it rewinds to before the segment's last move or stays after it.
        case excursionEnter(root: VideoScript.Excursion.Root)
        /// Step `index` of the excursion: its preview moves are played on top of the root, never added to the game.
        case excursionStep(index: Int)
        case excursionExit
        case outro
    }

    public var kind: Kind
    /// Index into `VideoScript.segments`; -1 for the intro, `segments.count` for the outro.
    public var segment: Int
    /// The segment's last game ply (the one `ask` and the excursion are about); 0 for intro and outro.
    public var ply: Int
    public var pace: VideoScript.Pace
    /// What is said at this cue (empty: nothing).
    public var say: String
    public var arrows: [GameLesson.Example.Arrow]
    public var circles: [Square]
    public var reaction: String?
    /// Excursion title for `.excursionEnter`.
    public var title: String
    /// UCI preview moves of an excursion step.
    public var moves: [String]
    /// The chapter that starts at this cue, if any (an index into `VideoCues.Compiled.chapters`).
    public var chapterStart: Int?

    public init(kind: Kind, segment: Int, ply: Int = 0, pace: VideoScript.Pace = .normal, say: String = "",
                arrows: [GameLesson.Example.Arrow] = [], circles: [Square] = [], reaction: String? = nil,
                title: String = "", moves: [String] = [], chapterStart: Int? = nil) {
        self.kind = kind; self.segment = segment; self.ply = ply; self.pace = pace; self.say = say
        self.arrows = arrows; self.circles = circles; self.reaction = reaction; self.title = title
        self.moves = moves; self.chapterStart = chapterStart
    }

    /// A move of the game itself (as opposed to an excursion step).
    public var isGameMove: Bool { if case .move = kind { true } else { false } }
}

public enum VideoCues {
    public struct Chapter: Equatable, Sendable {
        public var title: String
        /// The first cue of the chapter's first segment (where its title card plays).
        public var cue: Int
        public var segment: Int
        /// Where seeking to the chapter lands: cue 0 (the intro) for the first chapter.
        public var seekCue: Int
    }

    public struct Compiled: Equatable, Sendable {
        public var cues: [VideoCue]
        public var chapters: [Chapter]
        /// The chapter a cue belongs to (the last one that started at or before it).
        public func chapter(at cue: Int) -> Int {
            var out = 0
            for (i, c) in chapters.enumerated() where c.seekCue <= cue { out = i }
            return out
        }
    }

    /// The cue list for a grounded script. Order per segment: a move cue for every ply `from...to` (the quick
    /// segment's line starts with its first move; otherwise it is said on the marks cue once the moves land);
    /// then, by kind: plain, a marks cue; `ask`, moves `from...to-1`, the question, the move `to`, then marks;
    /// `whatIf`, marks, then enter, one cue per step, exit. Intro first, outro last.
    public static func compile(_ script: VideoScript) -> Compiled {
        var cues: [VideoCue] = [VideoCue(kind: .intro, segment: -1, say: script.intro)]
        var chapters: [Chapter] = []
        let chapterAt = Dictionary(script.chapters.enumerated().map { ($0.element.segment, $0.offset) }, uniquingKeysWith: { a, _ in a })

        for (si, seg) in script.segments.enumerated() {
            let segStart = cues.count
            let quick = seg.pace == .quick
            func move(_ p: Int, first: Bool) -> VideoCue {
                VideoCue(kind: .move(ply: p), segment: si, ply: seg.to, pace: seg.pace, say: quick && first ? seg.say : "")
            }
            let hasMarks = !seg.arrows.isEmpty || !seg.circles.isEmpty || seg.reaction != nil
            let marks = VideoCue(kind: .marks, segment: si, ply: seg.to, pace: seg.pace, say: quick ? "" : seg.say,
                                 arrows: seg.arrows, circles: seg.circles, reaction: seg.reaction)
            let wantsMarks = hasMarks || (!quick && !seg.say.isEmpty)

            let lastBefore = seg.ask ? seg.to - 1 : seg.to
            var first = true
            if seg.from <= lastBefore {
                for p in seg.from...lastBefore { cues.append(move(p, first: first)); first = false }
            }
            if seg.ask {
                cues.append(VideoCue(kind: .ask, segment: si, ply: seg.to, pace: seg.pace))
                var m = move(seg.to, first: first)
                if seg.from > lastBefore { m.say = quick ? seg.say : "" }
                cues.append(m)
            }
            if wantsMarks { cues.append(marks) }

            if let w = seg.whatIf, !w.steps.isEmpty {
                cues.append(VideoCue(kind: .excursionEnter(root: w.root), segment: si, ply: seg.to, pace: seg.pace, title: w.title))
                for (k, st) in w.steps.enumerated() {
                    cues.append(VideoCue(kind: .excursionStep(index: k), segment: si, ply: seg.to, pace: seg.pace, say: st.say,
                                         arrows: st.arrows, circles: st.circles, moves: st.moves))
                }
                cues.append(VideoCue(kind: .excursionExit, segment: si, ply: seg.to, pace: seg.pace))
            }

            if let ci = chapterAt[si] {
                let title = script.chapters[ci].title
                chapters.append(Chapter(title: title, cue: segStart, segment: si, seekCue: chapters.isEmpty ? 0 : segStart))
                cues[segStart].chapterStart = chapters.count - 1
            }
        }
        cues.append(VideoCue(kind: .outro, segment: script.segments.count, say: script.outro))
        return Compiled(cues: cues, chapters: chapters)
    }
}
