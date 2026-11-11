import Foundation

/// An error the review found, with the engine's lines as UCI.
public struct ScriptMoment: Sendable, Equatable {
    public var ply: Int
    public var side: Side
    public var severity: Int            // 1 inaccuracy, 2 mistake, 3 blunder, 0 not an error
    public var classification: String
    public var best: [String]           // engine line from the position before the move
    public var refutation: [String]     // engine line after the move played

    public init(ply: Int, side: Side, severity: Int, classification: String, best: [String], refutation: [String]) {
        self.ply = ply; self.side = side; self.severity = severity; self.classification = classification
        self.best = best; self.refutation = refutation
    }
}

/// Writes a watchable video track with no AI. The whole game in order: quick segments through the opening, short
/// segments for quiet stretches, a slow segment ENDING ON each of the three worst errors (ask = true), and a finish.
///
/// Design choice: a segment supports one excursion, so an error segment carries the refutation (`.after`,
/// "But wait\u{2026}"); the better move is revealed by the app's ask/verdict flow. Only when the engine gave no
/// usable refutation does the segment carry the better move instead (`.before`, "Instead: 14...Nd7").
/// Calm and hype differ in word choice only. The output is a fixed point of `VideoScript.grounded`.
public enum ScriptWriter {
    typealias Arrow = GameLesson.Example.Arrow

    public static func script(line: LessonLine, moments: [ScriptMoment], white: String?, black: String?,
                              opening: String?, result: String?, style: VideoScript.Style) -> VideoScript {
        let first = line.firstPly
        let last = first + max(line.positions.count - 2, -1)
        let hype = style == .hype

        // The three worst errors (severity, then earliest), in game order.
        let errors = Array(moments.filter { $0.severity > 0 && (first...max(first, last)).contains($0.ply) && $0.ply <= last
                                            && line.position(atPly: $0.ply - 1) != nil }
            .sorted { ($0.severity, -$0.ply) > ($1.severity, -$1.ply) }.prefix(VideoScript.maxAsks))
        let worst = errors.first?.ply
        let errorByPly = Dictionary(errors.map { ($0.ply, $0) }, uniquingKeysWith: { a, _ in a })

        // Blocks in order.
        enum Kind { case quiet, error(ScriptMoment), finish }
        var blocks: [(Int, Int, Kind)] = []
        var cursor = first
        for e in errors.sorted(by: { $0.ply < $1.ply }) {
            let start = max(e.ply - 1, cursor)
            if start > cursor { blocks.append((cursor, start - 1, .quiet)) }
            blocks.append((start, e.ply, .error(e))); cursor = e.ply + 1
        }
        if cursor <= last {
            let n = last - cursor + 1
            let fin = min(2, n)
            if n > fin { blocks.append((cursor, last - fin, .quiet)) }
            blocks.append((last - fin + 1, last, .finish))
        }

        let total = max(last - first + 1, 0)
        let midMax = max(8, Int((Double(total) / 24).rounded(.up)))
        let openingEnd = first + 11
        var segments: [VideoScript.Segment] = []
        var seed = first + total
        func pick(_ calm: [String], _ hy: [String]) -> String {
            defer { seed += 1 }
            let xs = hype ? hy : calm
            return xs[abs(seed) % xs.count]
        }
        var sawMiddle = false

        func quietSegments(_ a: Int, _ b: Int) {
            func emit(_ ranges: [(Int, Int)], opening isOpening: Bool) {
                for (x, y) in ranges {
                    var seg = VideoScript.Segment(from: x, to: y, say: quietLine(line, x, y, hype: hype, pick: pick,
                                                                                lead: isOpening && x == first),
                                                  pace: .quick)
                    if segments.isEmpty { seg.chapter = "The opening" }
                    else if !isOpening && !sawMiddle { seg.chapter = "The middlegame" }
                    if !isOpening { sawMiddle = true }
                    if !isOpening, notable(line, x, y).contains(where: { $0.rank >= 3 }) { seg.pace = .normal }
                    segments.append(seg)
                }
            }
            if a <= openingEnd {
                let e = min(b, openingEnd)
                let n = e - a + 1
                emit(split(a, e, k: max(1, Int((Double(n) / 5).rounded()))), opening: true)
                if b > e {
                    let m = b - e
                    emit(split(e + 1, b, k: max(Int((Double(m) / 6).rounded()), Int((Double(m) / Double(midMax)).rounded(.up)), 1)), opening: false)
                }
            } else {
                let m = b - a + 1
                emit(split(a, b, k: max(Int((Double(m) / 6).rounded()), Int((Double(m) / Double(midMax)).rounded(.up)), 1)), opening: false)
            }
        }

        for (a, b, kind) in blocks {
            switch kind {
            case .quiet: quietSegments(a, b)
            case .error(let e):
                var seg = errorSegment(line, e, from: a, hype: hype, pick: pick)
                seg.chapter = e.ply == worst ? "The turning point" : "The slip"
                if segments.isEmpty { seg.chapter = seg.chapter ?? "The opening" }
                segments.append(seg)
            case .finish:
                var seg = finishSegment(line, a, b, result: result, hype: hype, pick: pick)
                seg.chapter = "The finish"
                segments.append(seg)
            }
        }
        _ = errorByPly

        let w = clean(white) ?? "White", bl = clean(black) ?? "Black"
        let hasErrors = !errors.isEmpty
        var title = "\(w) vs \(bl)"
        if hasErrors { title += hype ? ": the move that changed everything" : ": and the move that decided it" }
        if title.count > 70 { title = "\(w) vs \(bl)" }
        return VideoScript(style: style, title: String(title.prefix(70)),
                           intro: intro(w, bl, opening: speakableOpening(opening), result: result, hasErrors: hasErrors, hype: hype),
                           segments: segments, outro: outro(hasErrors: hasErrors, hype: hype),
                           takeaways: takeaways(hasErrors: hasErrors, hasOpening: first <= openingEnd && total > 6))
    }

    // MARK: Text

    static func clean(_ s: String?) -> String? {
        guard let t = PGN.meaningful(s) else { return nil }
        return Grounding.citations(in: t).isEmpty ? t : nil
    }

    static func speakableOpening(_ s: String?) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let i = t.range(of: " (") { t = String(t[..<i.lowerBound]) }
        if !Grounding.citations(in: t).isEmpty { t = String(t.prefix { $0 != ":" }) }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || !Grounding.citations(in: t).isEmpty ? nil : t
    }

    static func intro(_ w: String, _ b: String, opening: String?, result: String?, hasErrors: Bool, hype: Bool) -> String {
        var parts: [String] = []
        parts.append(hype ? "Welcome back! \(w) takes White against \(b), and this one gets spicy."
                          : "Today we look at \(w), playing White, against \(b).")
        if let o = opening { parts.append("It starts out as the \(o).") }
        parts.append(hasErrors ? (hype ? "Stay with me, because it all changes in one move."
                                       : "Watch for the moment where everything changes.")
                               : (hype ? "Let's see how it goes." : "Let's see how it unfolds."))
        return parts.joined(separator: " ")
    }

    static func outro(hasErrors: Bool, hype: Bool) -> String {
        if hype {
            return hasErrors ? "And that's the game! One slip and the whole story flipped. Check what the reply does before you move, and I'll see you next time."
                             : "And that's the game! Clean play from both sides. See you next time."
        }
        return hasErrors ? "And that is the game. One careless moment changed everything. Before you move, ask what your opponent's best reply does."
                         : "And that is the game. Both sides played soundly. Thanks for watching."
    }

    static func takeaways(hasErrors: Bool, hasOpening: Bool) -> [String] {
        var out: [String] = []
        if hasErrors { out.append("Before every move, ask what your opponent's best reply threatens.") }
        if hasOpening { out.append("Develop your pieces and castle early.") }
        out.append("Keep your pieces defended.")
        return Array(out.prefix(VideoScript.maxTakeaways))
    }

    // MARK: Moves

    static func name(_ s: Side) -> String { s == .white ? "White" : "Black" }
    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func move(_ line: LessonLine, _ ply: Int) -> (Move, Position)? {
        guard let before = line.position(atPly: ply - 1), line.sans.indices.contains(ply - line.firstPly),
              let m = try? before.parseSAN(line.sans[ply - line.firstPly]) else { return nil }
        return (m, before)
    }

    struct Note { var ply: Int; var rank: Int; var text: String }

    /// Moves in plies a...b worth a mention, best first (mate 5, castling 4, big capture 3, check 2, capture 1).
    static func notable(_ line: LessonLine, _ a: Int, _ b: Int) -> [Note] {
        var out: [Note] = []
        for p in a...b {
            guard let (m, before) = move(line, p) else { continue }
            let f = before.features(m)
            let spoken = before.spoken(m)
            let side = name(before.turn)
            let castles = before.board[m.from]?.type == .king && abs(Sq.file(m.to) - Sq.file(m.from)) == 2
            if f.mate { out.append(Note(ply: p, rank: 5, text: cap(spoken) + ".")) }
            else if castles { out.append(Note(ply: p, rank: 4, text: "\(side) \(spoken).")) }
            else if let c = f.captured { out.append(Note(ply: p, rank: c.type.value >= 3 ? 3 : (f.check ? 2 : 1), text: cap(spoken) + ".")) }
            else if f.check { out.append(Note(ply: p, rank: 2, text: cap(spoken) + ".")) }
        }
        return out
    }

    static func quietLine(_ line: LessonLine, _ a: Int, _ b: Int, hype: Bool, pick: ([String], [String]) -> String,
                          lead: Bool) -> String {
        var parts: [String] = []
        if lead { parts.append(pick(["Both sides stake a claim in the centre.", "Pieces start coming out."],
                                    ["Here we go!", "Both sides grab the centre."])) }
        let top = notable(line, a, b).sorted { ($0.rank, -$0.ply) > ($1.rank, -$1.ply) }.prefix(2).sorted { $0.ply < $1.ply }
        if top.isEmpty {
            if !lead { parts.append(pick(["Both sides keep developing.", "A quiet stretch, nothing forced yet.", "The pieces find their squares."],
                                         ["Nothing crazy yet.", "Just developing, folks.", "Moves fly by here."])) }
        } else {
            for (i, n) in top.enumerated() {
                parts.append(i == 0 ? n.text : pick(["Then", "And"], ["Then", "And now"]) + " " + n.text.prefix(1).lowercased() + n.text.dropFirst())
            }
        }
        return parts.joined(separator: " ")
    }

    static func split(_ a: Int, _ b: Int, k: Int) -> [(Int, Int)] {
        let n = b - a + 1
        guard n > 0 else { return [] }
        let k = min(max(k, 1), n)
        var out: [(Int, Int)] = []
        var x = a
        for i in 0..<k {
            let size = n / k + (i < n % k ? 1 : 0)
            out.append((x, x + size - 1)); x += size
        }
        return out
    }

    // MARK: Errors

    static func errorSegment(_ line: LessonLine, _ e: ScriptMoment, from: Int, hype: Bool,
                             pick: ([String], [String]) -> String) -> VideoScript.Segment {
        guard let (m, before) = move(line, e.ply), let after = line.position(atPly: e.ply) else {
            return VideoScript.Segment(from: from, to: e.ply, say: "", pace: .slow, ask: true)
        }
        let side = before.turn
        let nm = name(side)
        let verdict: String = switch e.severity {
        case 3: pick(["And this is the moment the game turns.", "This is the turning point."], ["Oh no. That's a blunder!", "And that's the blunder!"])
        case 2: pick(["It looks natural, but it's a mistake.", "This one goes wrong."], ["Yikes, that's a mistake!", "Ooh, that's not good."])
        default: pick(["A small slip, but it matters.", "Not the most accurate."], ["Hmm, a small slip.", "Not quite the best."])
        }
        let reaction: String = switch e.severity {
        case 3: hype ? "Oh no." : "Oof."
        case 2: hype ? "Yikes." : "Hmm."
        default: hype ? "Hmm." : "Careful."
        }
        var seg = VideoScript.Segment(from: from, to: e.ply,
                                      say: "\(nm) plays \(before.spoken(m)). \(verdict)", pace: .slow,
                                      reaction: reaction, circles: [m.to], ask: true)
        if let x = refutation(e, played: m, after: after, side: side, hype: hype, pick: pick) { seg.whatIf = x }
        else if let x = better(e, root: before, played: m, hype: hype, pick: pick) { seg.whatIf = x }
        return seg
    }

    /// The engine's reply, up to 4 plies in steps of 1, 2 and 1, to its punchline.
    static func refutation(_ e: ScriptMoment, played: Move, after: Position, side: Side, hype: Bool,
                           pick: ([String], [String]) -> String) -> VideoScript.Excursion? {
        let ref = Array(SceneWriter.moves(e.refutation, from: after).prefix(4))
        guard !ref.isEmpty else { return nil }
        let opp = name(side.opposite), nm = name(side)
        let startGap = after.material(side.opposite) - after.material(side)
        var p = after
        var steps: [VideoScript.Step] = []
        var i = 0
        var noted = false
        for size in [1, 2, 1] where i < ref.count {
            let group = Array(ref[i..<min(i + size, ref.count)])
            var texts: [String] = [], arrows: [Arrow] = [], circles: [Square] = []
            noted = false
            for mv in group {
                let byOpp = p.turn == side.opposite
                let d = SceneWriter.describe(mv, p)
                if byOpp {
                    texts.append(texts.isEmpty && i == 0 ? pick(["\(cap(d.spoken)).", "\(opp) replies \(d.spoken)."], ["Boom. \(cap(d.spoken)).", "\(opp) hits back with \(d.spoken)."])
                                 : pick(["And now \(d.spoken).", "Then \(d.spoken)."], ["And now \(d.spoken)!", "Then \(d.spoken)."]))
                    if let n = d.note { texts.append(n); noted = true }
                    arrows = d.arrows; circles = d.circles
                } else {
                    texts.append(pick(["\(nm) tries \(d.spoken).", "\(nm) answers \(d.spoken)."], ["\(nm) tries \(d.spoken).", "\(nm) scrambles with \(d.spoken)."]))
                }
                p = p.applyingUnchecked(mv)
            }
            i += group.count
            steps.append(VideoScript.Step(say: texts.joined(separator: " "), moves: group.map(\.uci),
                                          arrows: Array(arrows.prefix(VideoScript.maxArrows)),
                                          circles: Array(circles.prefix(VideoScript.maxCircles))))
        }
        if let end = SceneWriter.punchline(p, side: side, startGap: startGap, severity: e.severity, noted: noted), !steps.isEmpty {
            steps[steps.count - 1].say += " " + end
        }
        return VideoScript.Excursion(root: .after, title: "But wait\u{2026}", steps: steps)
    }

    /// Fallback: the better move and its idea, from before the error.
    static func better(_ e: ScriptMoment, root: Position, played: Move, hype: Bool,
                       pick: ([String], [String]) -> String) -> VideoScript.Excursion? {
        let line = Array(SceneWriter.moves(e.best, from: root).prefix(4))
        guard let b = line.first else { return nil }
        let r = SceneWriter.reason(b, root, punish: nil, punishFrom: root.applyingUnchecked(played))
        var steps = [VideoScript.Step(say: pick(["Instead, \(root.spoken(b)). ", "Better was \(root.spoken(b)). "],
                                                ["Instead, \(root.spoken(b))! ", "What you want is \(root.spoken(b)). "]) + cap(r.text),
                                      moves: [b.uci], arrows: r.arrows, circles: r.circles)]
        var p = root.applyingUnchecked(b)
        var rest = Array(line.dropFirst()), parts: [VideoScript.Step] = []
        while !rest.isEmpty {
            let g = Array(rest.prefix(2)); rest.removeFirst(g.count)
            var texts: [String] = []
            for mv in g { texts.append(cap(p.spoken(mv)) + "."); p = p.applyingUnchecked(mv) }
            parts.append(VideoScript.Step(say: texts.joined(separator: " "), moves: g.map(\.uci)))
        }
        steps += parts
        let n = root.fullmove, label = "\(n)\(root.turn == .white ? ". " : "\u{2026}")\(root.san(b))"
        return VideoScript.Excursion(root: .before, title: "Instead: \(label)", steps: steps)
    }

    // MARK: Finish

    static func finishSegment(_ line: LessonLine, _ a: Int, _ b: Int, result: String?, hype: Bool,
                              pick: ([String], [String]) -> String) -> VideoScript.Segment {
        let mate = line.position(atPly: b)?.isCheckmate ?? false
        let winner: String? = switch result {
        case "1-0": "White"
        case "0-1": "Black"
        default: nil
        }
        let draw = result == "1/2-1/2"
        var say: String
        if mate {
            say = hype ? "And it's over! Checkmate!" : "And that is checkmate."
            if let w = winner { say += " \(w) wins." }
        } else if let w = winner {
            say = hype ? "And that's it, \(w) takes the point!" : "The game ends here, and \(w) takes the point."
        } else if draw {
            say = "And the game ends in a draw."
        } else {
            say = pick(["And that is where the game ends."], ["And that's where it ends!"])
        }
        return VideoScript.Segment(from: a, to: b, say: say, pace: mate ? .slow : .normal,
                                   reaction: mate ? "Checkmate!" : nil)
    }
}
