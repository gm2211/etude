import Foundation

/// One continuous commentary track over the whole reviewed game, like a YouTube analysis video: an intro, segments
/// that walk every ply in order at varying pace, "what if" excursions that leave the game and come back, a few
/// "find the move" pauses, and an outro. Written by the AI (or `ScriptWriter` without one), then grounded.
public struct VideoScript: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable { case calm, hype }
    public enum Pace: String, Sendable { case quick, normal, slow }

    public static let maxSegments = 40
    public static let maxExcursionSteps = 6
    public static let maxStepMoves = 2
    public static let maxArrows = 3
    public static let maxCircles = 4
    public static let maxTakeaways = 3
    /// A slow segment longer than this many plies plays at normal pace.
    public static let maxSlowPlies = 12
    public static let maxAsks = 3

    /// One narrated step of a "what if" excursion: moves are UCI after grounding (SAN or UCI as written before).
    public struct Step: Equatable, Sendable {
        public var say: String
        public var moves: [String]
        public var arrows: [GameLesson.Example.Arrow]
        public var circles: [Square]
        public init(say: String, moves: [String] = [], arrows: [GameLesson.Example.Arrow] = [], circles: [Square] = []) {
            self.say = say; self.moves = moves; self.arrows = arrows; self.circles = circles
        }
    }

    public struct Excursion: Equatable, Sendable {
        public enum Root: String, Sendable { case before, after }
        public var root: Root
        public var title: String
        public var steps: [Step]
        public init(root: Root, title: String, steps: [Step]) { self.root = root; self.title = title; self.steps = steps }
    }

    public struct Segment: Equatable, Sendable {
        public var from: Int
        public var to: Int
        public var say: String
        public var pace: Pace
        public var chapter: String?
        public var reaction: String?
        public var arrows: [GameLesson.Example.Arrow]
        public var circles: [Square]
        public var ask: Bool
        public var whatIf: Excursion?
        /// The last game move as the model wrote it ("14...Qxb2"); only set before grounding, which resolves it.
        public var until: String?

        public init(from: Int = 0, to: Int = 0, say: String = "", pace: Pace = .normal, chapter: String? = nil,
                    reaction: String? = nil, arrows: [GameLesson.Example.Arrow] = [], circles: [Square] = [],
                    ask: Bool = false, whatIf: Excursion? = nil, until: String? = nil) {
            self.from = from; self.to = to; self.say = say; self.pace = pace; self.chapter = chapter
            self.reaction = reaction; self.arrows = arrows; self.circles = circles; self.ask = ask
            self.whatIf = whatIf; self.until = until
        }
    }

    public var style: Style
    public var title: String
    public var intro: String
    public var segments: [Segment]
    public var outro: String
    public var takeaways: [String]

    public init(style: Style, title: String, intro: String, segments: [Segment], outro: String, takeaways: [String]) {
        self.style = style; self.title = title; self.intro = intro; self.segments = segments
        self.outro = outro; self.takeaways = takeaways
    }

    /// Chapter starts; the first segment always starts one ("The opening" when untitled).
    public var chapters: [(title: String, segment: Int)] {
        var out: [(title: String, segment: Int)] = []
        for (i, s) in segments.enumerated() {
            if let c = s.chapter, !c.isEmpty { out.append((c, i)) } else if i == 0 { out.append(("The opening", 0)) }
        }
        return out
    }

    // MARK: Parsing

    /// Lenient: code fences and chatter around the object, "move"/"to" for `until`, "line"/"moves" for `play`,
    /// "rewind"/"root" for `from`, booleans as strings, numbered SAN. Nil without any segment.
    public static func parse(_ text: String, style: Style) -> VideoScript? {
        guard let o = AIJSON.object(in: text) else { return nil }
        let raw = (AIJSON.value(o, "segments") as? [Any]) ?? []
        let segments = raw.compactMap(parseSegment)
        guard !segments.isEmpty else { return nil }
        return VideoScript(style: style, title: AIJSON.string(AIJSON.value(o, "title")) ?? "",
                           intro: AIJSON.string(AIJSON.value(o, "intro")) ?? "", segments: segments,
                           outro: AIJSON.string(AIJSON.value(o, "outro")) ?? "",
                           takeaways: AIJSON.strings(AIJSON.value(o, "takeaways") ?? AIJSON.value(o, "lessons")))
    }

    private static func bool(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        case let s as String: ["true", "yes", "1"].contains(s.lowercased())
        default: false
        }
    }

    private static func squares(_ v: Any?) -> [Square] {
        AIJSON.strings(v).compactMap { Sq.parse($0.lowercased().trimmingCharacters(in: .whitespaces)) }
    }

    private static func parseSegment(_ v: Any) -> Segment? {
        guard let d = v as? [String: Any] else { return nil }
        guard let until = AIJSON.string(AIJSON.value(d, "until") ?? AIJSON.value(d, "move") ?? AIJSON.value(d, "to")
                                        ?? AIJSON.value(d, "at")) else { return nil }
        let pace: Pace = switch (AIJSON.string(AIJSON.value(d, "pace")) ?? "").lowercased() {
        case "quick", "fast": .quick
        case "slow": .slow
        default: .normal
        }
        var whatIf: Excursion?
        if let w = (AIJSON.value(d, "whatIf") ?? AIJSON.value(d, "excursion")) as? [String: Any] { whatIf = parseExcursion(w) }
        return Segment(say: AIJSON.string(AIJSON.value(d, "say") ?? AIJSON.value(d, "text")) ?? "", pace: pace,
                       chapter: AIJSON.string(AIJSON.value(d, "chapter")),
                       reaction: AIJSON.string(AIJSON.value(d, "reaction")),
                       arrows: GameLesson.Example.parseArrows(AIJSON.value(d, "arrows")),
                       circles: squares(AIJSON.value(d, "circles") ?? AIJSON.value(d, "squares")),
                       ask: bool(AIJSON.value(d, "ask")), whatIf: whatIf, until: until)
    }

    private static func parseExcursion(_ d: [String: Any]) -> Excursion? {
        let root: Excursion.Root
        switch AIJSON.value(d, "from") ?? AIJSON.value(d, "rewind") ?? AIJSON.value(d, "root") {
        case let s as String:
            let t = s.lowercased()
            root = (t.contains("after") || t.contains("game") || t.contains("played")) ? .after : .before
        default: root = .before
        }
        let steps: [Step] = ((AIJSON.value(d, "steps") as? [Any]) ?? []).prefix(maxExcursionSteps).compactMap { sv in
            guard let s = sv as? [String: Any] else { return nil }
            let say = AIJSON.string(AIJSON.value(s, "say") ?? AIJSON.value(s, "text")) ?? ""
            let rawMoves = AIJSON.value(s, "play") ?? AIJSON.value(s, "line") ?? AIJSON.value(s, "moves") ?? AIJSON.value(s, "move")
            let moves = AIJSON.strings(rawMoves).flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
                .map(GameLesson.SceneStep.stripNumber).filter { !$0.isEmpty }
            guard !say.isEmpty || !moves.isEmpty else { return nil }
            return Step(say: say, moves: Array(moves.prefix(maxStepMoves + 1)),
                        arrows: GameLesson.Example.parseArrows(AIJSON.value(s, "arrows")),
                        circles: squares(AIJSON.value(s, "circles") ?? AIJSON.value(s, "squares")))
        }
        guard !steps.isEmpty else { return nil }
        return Excursion(root: root, title: AIJSON.string(AIJSON.value(d, "title") ?? AIJSON.value(d, "label")) ?? "",
                         steps: steps)
    }

    // MARK: Grounding

    /// The script made safe to play. Pure; see the individual steps below.
    public static func grounded(_ s: VideoScript, line: LessonLine, allowed: Set<String>,
                                questionPlies: Set<Int>) -> VideoScript {
        let first = line.firstPly
        let last = first + max(line.positions.count - 2, -1)
        func unique<T: Equatable>(_ xs: [T], _ n: Int) -> [T] {
            var out: [T] = []
            for x in xs where !out.contains(x) { out.append(x) }
            return Array(out.prefix(n))
        }

        // 1. Resolve plies: consecutive, advancing, inside the line.
        var segs: [Segment] = []
        var prev = first - 1
        for var seg in s.segments {
            let to: Int?
            if let u = seg.until { to = line.ply(of: u) } else { to = seg.to > 0 ? seg.to : nil }
            guard let t = to, t > prev, t <= last else { continue }
            seg.from = prev + 1; seg.to = t; seg.until = nil
            segs.append(seg); prev = t
        }
        if segs.count > maxSegments { segs = Array(segs.prefix(maxSegments)); prev = segs[segs.count - 1].to }
        if prev < last {
            if segs.count < maxSegments {
                segs.append(Segment(from: prev + 1, to: last, say: "", pace: .quick))
            } else {
                segs[segs.count - 1].to = last
                segs[segs.count - 1].ask = false; segs[segs.count - 1].whatIf = nil
            }
        }

        // 2. Per segment.
        var asks = 0
        let nonEmpty: (String) -> Bool = { !$0.isEmpty }
        for i in segs.indices {
            var g = segs[i]
            if g.pace == .slow, g.to - g.from + 1 > maxSlowPlies { g.pace = .normal }
            if g.ask { if questionPlies.contains(g.to), asks < maxAsks { asks += 1 } else { g.ask = false } }
            g.arrows = unique(g.arrows, maxArrows); g.circles = unique(g.circles, maxCircles)

            let own = (g.from...g.to).compactMap { p in line.sans.indices.contains(p - first) ? line.sans[p - first] : nil }
            var ok = allowed.union(Grounding.allowed(own))
            var exc: Excursion?
            if let w = g.whatIf {
                let rootPos = line.position(atPly: w.root == .before ? g.to - 1 : g.to)
                if let rootPos { (exc, ok) = groundedExcursion(w, root: rootPos, ok: ok) }
            }
            if var e = exc {
                e.title = Grounding.prune(e.title.trimmingCharacters(in: .whitespacesAndNewlines), allowed: ok).text
                if e.title.isEmpty { e.title = e.root == .before ? "Instead" : "What if\u{2026}" }
                e.steps = e.steps.map { st in
                    var st = st
                    st.say = Grounding.prune(st.say.trimmingCharacters(in: .whitespacesAndNewlines), allowed: ok).text
                    st.arrows = unique(st.arrows, maxArrows); st.circles = unique(st.circles, maxCircles)
                    return st
                }
                exc = e
            }
            g.whatIf = exc
            g.say = Grounding.prune(g.say.trimmingCharacters(in: .whitespacesAndNewlines), allowed: ok).text
            if let c = g.chapter?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { g.chapter = String(c.prefix(40)) } else { g.chapter = nil }
            if let r = g.reaction?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
                g.reaction = String(r.split(separator: " ").prefix(3).joined(separator: " ").prefix(24))
            } else { g.reaction = nil }
            segs[i] = g
        }

        func prose(_ t: String) -> String { Grounding.prune(t.trimmingCharacters(in: .whitespacesAndNewlines), allowed: allowed).text }
        var title = prose(s.title)
        if title.isEmpty { title = "Game review" }
        title = String(title.prefix(70))
        return VideoScript(style: s.style, title: title, intro: prose(s.intro), segments: segs, outro: prose(s.outro),
                           takeaways: Array(s.takeaways.map(prose).filter(nonEmpty).prefix(maxTakeaways)))
    }

    /// The excursion replayed from `root`: moves become UCI, the first illegal move drops its step and the rest.
    /// Returns nil when nothing plays, and the allowed set extended with the SAN of the moves played.
    private static func groundedExcursion(_ w: Excursion, root: Position, ok: Set<String>) -> (Excursion?, Set<String>) {
        var cur = root
        var steps: [Step] = []
        var sans: [String] = []
        outer: for st in w.steps.prefix(maxExcursionSteps) {
            var p = cur, ucis: [String] = [], stepSans: [String] = []
            for raw in st.moves.prefix(maxStepMoves) {
                let t = GameLesson.SceneStep.stripNumber(raw)
                guard let m = p.move(fromUCI: t.lowercased()) ?? (try? p.parseSAN(t)), let n = try? p.applying(m) else { break outer }
                stepSans.append(p.san(m)); ucis.append(m.uci); p = n
            }
            var step = st; step.moves = ucis
            if step.say.isEmpty && ucis.isEmpty { continue }
            steps.append(step); sans += stepSans; cur = p
        }
        guard steps.contains(where: { !$0.moves.isEmpty }) else { return (nil, ok) }
        var e = w; e.steps = steps
        return (e, ok.union(Grounding.allowed(sans)))
    }
}
