import Foundation
import Observation
import ChessCore

/// The guided review as a video: ONE continuous commentary track that walks the whole game in order (see
/// `VideoScript`, compiled into flat `VideoCue`s). Moves slide in at the script's pace, the narrator talks over
/// them, a "what if" excursion visibly leaves the game and comes back (its moves are a preview on top of the board,
/// never added to the game), and at the worst errors the video pauses to ask "find a better move" (judged with
/// `BetterMove`). Hands-free nobody has to do anything: a question counts down and then shows its answer.
/// Owned by `AppModel.video`; see AppModel+Video.
@Observable @MainActor
final class GameVideo {
    /// Everything needed to ask and judge "find a better move" at an error.
    struct Quiz: Equatable {
        var parentID: Int           // the position before the error: the question
        var side: Side
        var best: String            // UCI, the review's best move there
        var bestEval: Eval          // White's view, the review's eval of that position
        var bestLine: [String]      // the review's line from there
        var played: String          // UCI, the move played in the game
        var refutation: [String]    // the review's line after the move played
    }

    enum Phase: Equatable {
        case playing
        /// The question is open: a move on the board is a try.
        case asking
        case judging(Move)
        case verdict(BetterMove.Verdict, tried: Move, reply: String?)
        /// The better move is shown (nobody answered, or "Show me").
        case reveal
    }

    enum Card: Equatable {
        case none
        case intro
        case chapter(number: Int, title: String)
        case outro
    }

    struct Reaction: Equatable {
        var text: String
        var square: Square
        var epoch: Int
    }

    /// Facts for the intro and outro cards.
    struct Facts: Equatable {
        var title = ""
        var white = "White", black = "Black"
        var whiteElo: String?, blackElo: String?
        var event: String?, opening: String?, result: String?
        var takeaways: [String] = []
        var whiteAccuracy: Double?, blackAccuracy: Double?
    }

    static let narrateKey = "beats.narrate"
    static let captionsKey = "video.captions"
    static let speeds: [Double] = [1, 1.25, 1.5, 2]
    /// Test hooks (the headless playback simulation): every wait is multiplied by `holdScale`, and `muted` keeps the
    /// narrator silent without touching the saved preference.
    static var holdScale = 1.0
    static var muted = false
    /// Called when a cue has played to its end.
    @ObservationIgnored var onCueFinished: ((Int) -> Void)?

    let plan: VideoPlan
    let facts: Facts
    /// Node ids of the reviewed line, root first; `nodes[i]` is the position after ply `firstPly + i - 1`.
    let nodes: [Int]
    let firstPly: Int

    // MARK: Observable state

    private(set) var index = 0
    /// The video runs hands-free.
    private(set) var isPlaying = false
    private(set) var finished = false
    private(set) var phase: Phase = .playing
    private(set) var card: Card = .none
    /// The line being said (captions).
    private(set) var subtitle: String?
    private(set) var arrows: [GameLesson.Example.Arrow] = []
    private(set) var circles: [Square] = []
    /// Bumps each time marks appear, so the board can draw arrows and pop circles.
    private(set) var marksEpoch = 0
    private(set) var reaction: Reaction?
    /// UCI moves shown on top of `nodeID` during an excursion or a try (never added to the game).
    private(set) var previewMoves: [String] = []
    /// The title of the "what if" excursion being shown (the board is tinted while it is set).
    private(set) var excursionTitle: String?
    /// Bumps when an excursion ends, for the "Back to the game" flash.
    private(set) var returnEpoch = 0
    /// The eval bar shows the game's eval of this node; it is dimmed while the board is off the game.
    private(set) var barDimmed = false
    /// Bumps when the game move on the board is a mistake or blunder, for the eval bar's pulse.
    private(set) var swingEpoch = 0
    private(set) var swingClass: MoveClass?
    /// The hands-free countdown on an open question.
    private(set) var countdown: (start: Date, duration: Double)?
    /// The node the video put on the board; any other navigation closes it (see `AppModel.currentID`).
    private(set) var nodeID: Int
    /// Seconds a piece takes to slide now.
    private(set) var slideDuration = 0.3
    private(set) var durations: [Double]
    private(set) var starts: [Double]
    /// The question at the current ask cue.
    private(set) var quiz: Quiz?

    var speed = 1.0 {
        didSet { narrator.rate = speed }
    }
    var captions = UserDefaults.standard.object(forKey: GameVideo.captionsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(captions, forKey: Self.captionsKey) }
    }
    var narrate = UserDefaults.standard.object(forKey: GameVideo.narrateKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(narrate, forKey: Self.narrateKey)
            if !narrate { stopSpeech() }
        }
    }

    // MARK: Private

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var judgeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSpeech: Task<Void, Never>?
    @ObservationIgnored private let narrator = VoiceNarrator()
    /// How the next ask cue resolves: a countdown (hands-free), straight to the answer, or skipped.
    private enum AskMode { case countdown, reveal, skip }
    @ObservationIgnored private var askMode = AskMode.countdown
    @ObservationIgnored private var replyUCI: String?
    @ObservationIgnored private var cueStart = Date()
    @ObservationIgnored private var pausedOffset = 0.0
    @ObservationIgnored private var segmentSquares: [Int: [Square]] = [:]
    @ObservationIgnored private var frozenNode: Int?
    @ObservationIgnored private var scrubbing: Bool?

    init(plan: VideoPlan, nodes: [Int], firstPly: Int, facts: Facts, app: AppModel) {
        self.plan = plan; self.nodes = nodes; self.firstPly = firstPly; self.facts = facts; self.app = app
        durations = plan.durations
        starts = VideoPlan.starts(plan.durations)
        nodeID = nodes.first ?? 0
        narrator.rate = 1
        segmentSquares = Self.squares(plan: plan, nodes: nodes, firstPly: firstPly, app: app)
    }

    // MARK: Derived

    var cues: [VideoCue] { plan.cues }
    var cue: VideoCue { plan.cues[min(max(index, 0), plan.cues.count - 1)] }
    var chapters: [VideoCues.Chapter] { plan.chapters }
    var chapterIndex: Int { plan.compiled.chapter(at: index) }
    var chapterTitle: String { chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : "" }
    var totalTime: Double { durations.reduce(0, +) }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < cues.count - 1 }

    /// The game node after `ply` (the line's start for the plies before the first).
    func node(atPly ply: Int) -> Int {
        nodes[min(max(ply - firstPly + 1, 0), nodes.count - 1)]
    }

    /// Where the video is, in seconds at 1x.
    func time(at date: Date) -> Double {
        if finished { return totalTime }
        guard starts.indices.contains(index) else { return 0 }
        let inCue = isPlaying ? max(0, date.timeIntervalSince(cueStart)) * speed : pausedOffset
        return starts[index] + min(inCue, durations[index])
    }

    /// The cue that plays at `t` seconds (at 1x).
    func cueIndex(atTime t: Double) -> Int {
        var lo = 0
        for (i, s) in starts.enumerated() where s <= t { lo = i }
        return lo
    }

    /// The eval the bar shows: the game's own eval (from the review) of the position, never a live engine line,
    /// so a question's answer can't leak.
    var barEval: Eval? {
        guard let app else { return nil }
        let id = frozenNode ?? nodeID
        if let e = app.review.entries[id]?.eval { return e }
        return nil
    }

    /// The question is open: a move on the board is a try.
    var acceptsMove: Bool {
        guard let q = quiz, app?.currentID == q.parentID, previewMoves.isEmpty else { return false }
        switch phase {
        case .asking: return true
        case .verdict(let v, _, _): return !v.isCorrect
        default: return false
        }
    }

    /// The video is on a question that waits for the viewer (paused, or answered wrong).
    var isWaitingForAnswer: Bool {
        switch phase {
        case .asking: return !isPlaying
        case .verdict(let v, _, _): return !v.isCorrect
        default: return false
        }
    }

    /// The player's try, the better move being shown, or the excursion's moves, on top of the board node.
    var preview: LessonPlayer.Preview? {
        guard let app, app.game.nodes.indices.contains(nodeID) else { return nil }
        switch phase {
        case .judging(let m), .verdict(_, let m, _):
            guard let q = quiz, app.game.nodes.indices.contains(q.parentID) else { return nil }
            let pos = app.game.nodes[q.parentID].position
            guard let next = try? pos.applying(m) else { return nil }
            return LessonPlayer.Preview(pieces: PieceLayout.applying(m, before: pos, to: app.pieces(for: q.parentID)),
                                        position: next, lastMove: m)
        default: break
        }
        guard !previewMoves.isEmpty else { return nil }
        var pos = app.game.nodes[nodeID].position
        var pieces = app.pieces(for: nodeID)
        var last: Move?
        for u in previewMoves {
            guard let m = pos.move(fromUCI: u) else { break }
            pieces = PieceLayout.applying(m, before: pos, to: pieces)
            pos = (try? pos.applying(m)) ?? pos; last = m
        }
        return LessonPlayer.Preview(pieces: pieces, position: pos, lastMove: last)
    }

    /// Arrows the board draws now (the cue's marks, the better move when revealed, the engine's answer to a wrong try).
    var boardArrows: [BoardArrow] {
        var out: [BoardArrow] = []
        switch phase {
        case .asking, .judging: return []
        case .verdict(let v, _, _):
            if !v.isCorrect, let u = replyUCI, let m = Move(uci: u) {
                out.append(BoardArrow(from: m.from, to: m.to, kind: .threat, opacity: 0.85))
            }
            return out
        case .reveal:
            if let b = quiz?.best, let m = Move(uci: b) { out.append(BoardArrow(from: m.from, to: m.to, kind: .best, opacity: 0.9)) }
            return out
        case .playing: break
        }
        return arrows.map { BoardArrow(from: $0.from, to: $0.to, kind: .lesson, opacity: 0.85) }
    }

    var boardCircles: [Square] {
        switch phase {
        case .playing: return circles
        default: return []
        }
    }

    /// Squares the current segment's action touches, for placing the captions away from them.
    func activity(ofSegment s: Int) -> [Square] { segmentSquares[s] ?? [] }

    // MARK: Transport

    /// Opens the video at chapter `chapter` and starts playing.
    func start(atChapter chapter: Int = 0, play: Bool = true) {
        let target = chapters.indices.contains(chapter) ? chapters[chapter].seekCue : 0
        if play { run(from: target) } else { show(target) }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if finished { run(from: 0); return }
        if case .judging = phase { return }
        run(from: index)
    }

    func pause() {
        guard isPlaying else { return }
        pausedOffset = max(0, Date().timeIntervalSince(cueStart)) * speed
        stopRun()
        isPlaying = false
        countdown = nil
        if quiz != nil, cue.kind == .ask, phase == .reveal || phase == .playing || phase == .asking {
            phase = .asking; previewMoves = []; subtitle = nil
        }
    }

    func stop() {
        stopRun()
        judgeTask?.cancel(); judgeTask = nil
        isPlaying = false
    }

    func next() { go(to: min(index + 1, cues.count - 1)) }
    func previous() { go(to: max(index - 1, 0)) }
    func seek(toCue i: Int) { go(to: i) }

    func nextChapter() {
        guard let c = chapters.first(where: { $0.seekCue > index }) else { return }
        go(to: c.seekCue)
    }

    func previousChapter() {
        let cur = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil
        // Within the first moments of a chapter, back goes to the one before; otherwise it restarts this one.
        if let cur, index > cur.seekCue + 2 || chapterIndex == 0 { go(to: cur.seekCue); return }
        if chapters.indices.contains(chapterIndex - 1) { go(to: chapters[chapterIndex - 1].seekCue) }
    }

    func replayChapter() {
        if chapters.indices.contains(chapterIndex) { go(to: chapters[chapterIndex].seekCue) }
    }

    func cycleSpeed() {
        let i = Self.speeds.firstIndex(of: speed) ?? 0
        speed = Self.speeds[(i + 1) % Self.speeds.count]
    }

    /// Goes to cue `i`: playing on from its start when the video is playing, else showing it as it looks once it has played.
    private func go(to i: Int) {
        guard cues.indices.contains(i) else { return }
        if isPlaying { run(from: i) } else { show(i) }
    }

    // MARK: Scrubbing

    func beginScrub() {
        guard scrubbing == nil else { return }
        scrubbing = isPlaying
        if isPlaying { pause() }
    }

    func scrub(toTime t: Double) {
        let i = cueIndex(atTime: t)
        if i != index || phase != .playing || card != .none { show(i, quiet: true) }
        pausedOffset = max(0, t - starts[i])
    }

    func endScrub() {
        guard let wasPlaying = scrubbing else { return }
        scrubbing = nil
        if wasPlaying { run(from: index) }
    }

    // MARK: Showing a cue without playing it

    /// For the headless snapshot renderer: cue `i` as it looks once played, optionally with a card, a question state
    /// or the hands-free countdown on top (animations don't run when rendering to an image).
    func presentForSnapshot(cue i: Int, card c: Card? = nil, phase p: Phase? = nil, countdownLeft: Double? = nil) {
        show(i, quiet: true)
        if let c { card = c }
        if let p {
            phase = p
            if case .verdict = p { replyUCI = quiz?.refutation.first }
            if p == .reveal, let q = quiz {
                let san = app?.game.nodes[q.parentID].position.move(fromUCI: q.best).flatMap { app?.game.nodes[q.parentID].position.san($0) } ?? q.best
                subtitle = "The better move was \(san)."
                previewMoves = [q.best]
            }
        }
        if let left = countdownLeft { countdown = (Date().addingTimeInterval(left - VideoPlan.askHold), VideoPlan.askHold) }
    }

    /// The board and overlays as they look once cue `i` has played.
    func show(_ i: Int, quiet: Bool = false) {
        stopRun()
        judgeTask?.cancel(); judgeTask = nil
        isPlaying = false
        finished = false
        pausedOffset = 0
        settle(i)
        if !quiet { app?.refreshEngine() }
    }

    private func clearTransient() {
        subtitle = nil; arrows = []; circles = []; reaction = nil; card = .none
        previewMoves = []; excursionTitle = nil; phase = .playing; quiz = nil; replyUCI = nil
        countdown = nil; frozenNode = nil; barDimmed = false
    }

    /// Stateless: puts the state cue `i` ends in on the board.
    private func settle(_ i: Int) {
        clearTransient()
        index = i
        let c = cues[i]
        switch c.kind {
        case .intro:
            put(nodes[0]); card = .intro; subtitle = c.say.isEmpty ? nil : c.say
        case .move(let ply):
            put(node(atPly: ply))
            subtitle = segmentLine(c.segment)
        case .marks:
            put(node(atPly: c.ply))
            subtitle = c.say.isEmpty ? segmentLine(c.segment) : c.say
            showMarks(c)
        case .ask:
            if let q = app?.quiz(at: node(atPly: c.ply)) {
                put(q.parentID); quiz = q; phase = .asking; barDimmed = true
            } else { put(node(atPly: c.ply - 1)) }
        case .excursionEnter(let root):
            put(root == .before ? node(atPly: c.ply - 1) : node(atPly: c.ply))
            excursionTitle = c.title
            freezeEval(at: node(atPly: c.ply))
        case .excursionStep:
            let enter = enterIndex(before: i)
            if case .excursionEnter(let root) = cues[enter].kind {
                put(root == .before ? node(atPly: c.ply - 1) : node(atPly: c.ply))
            }
            excursionTitle = cues[enter].title
            previewMoves = cues[enter..<(i + 1)].flatMap { $0.moves }
            subtitle = c.say.isEmpty ? nil : c.say
            showMarks(c)
            freezeEval(at: node(atPly: c.ply))
        case .excursionExit:
            put(node(atPly: c.ply))
        case .outro:
            put(nodes[nodes.count - 1]); card = .outro; subtitle = c.say.isEmpty ? nil : c.say
        }
    }

    /// The segment's own line (for a quick segment, said from its first move).
    private func segmentLine(_ s: Int) -> String? {
        let line = cues.first { $0.segment == s && !$0.say.isEmpty && ($0.isGameMove || $0.kind == .marks) }?.say
        return line
    }

    private func enterIndex(before i: Int) -> Int {
        var j = i
        while j > 0 { if case .excursionEnter = cues[j].kind { return j }; j -= 1 }
        return j
    }

    private func freezeEval(at id: Int) { frozenNode = id; barDimmed = true }

    private func showMarks(_ c: VideoCue) {
        arrows = c.arrows; circles = c.circles
        if !c.arrows.isEmpty || !c.circles.isEmpty { marksEpoch += 1 }
        if let r = c.reaction, let app, let sq = app.game.nodes[nodeID].move?.to {
            marksEpoch += 1
            reaction = Reaction(text: r, square: sq, epoch: marksEpoch)
        }
    }

    // MARK: Running

    private func stopRun() {
        task?.cancel(); task = nil
        stopSpeech()
        slideDuration = 0.3
    }

    private func stopSpeech() {
        pendingSpeech?.cancel(); pendingSpeech = nil
        narrator.stop()
    }

    /// Plays on from cue `start` hands-free, from the state just before it.
    private func run(from start: Int) {
        stopRun()
        judgeTask?.cancel(); judgeTask = nil
        isPlaying = true
        finished = false
        pausedOffset = 0
        if start > 0 { settle(start - 1) } else { clearTransient(); put(nodes[0]) }
        index = start
        app?.refreshEngine()
        task = Task { [weak self] in
            guard let self else { return }
            var i = start
            while i < self.cues.count {
                guard !Task.isCancelled else { return }
                await self.perform(i)
                guard !Task.isCancelled else { return }
                i += 1
            }
            self.task = nil
            self.isPlaying = false
            self.finished = true
        }
    }

    /// Plays one cue: animates from the state before it into the state `settle` gives, in the time it takes.
    private func perform(_ i: Int) async {
        let c = cues[i]
        let began = ContinuousClock.now
        defer { if !Task.isCancelled { onCueFinished?(i) } }
        index = i
        cueStart = Date()
        pausedOffset = 0
        if i == 0 || cues[i - 1].segment != c.segment { subtitle = nil }
        arrows = []; circles = []; reaction = nil; card = .none
        switch c.kind {
        case .ask, .excursionEnter, .excursionStep, .excursionExit: break
        default:
            phase = .playing; quiz = nil; barDimmed = false; frozenNode = nil; excursionTitle = nil; previewMoves = []
        }
        if narrate && !Self.muted { narrator.prepare(cues[i...].lazy.map(\.say).filter { !$0.isEmpty }.prefix(3).map { $0 }) }

        if let ch = c.chapterStart {
            card = .chapter(number: ch + 1, title: chapters[ch].title)
            await sleep(VideoPlan.chapterCard)
            guard !Task.isCancelled else { return }
            card = .none
        }

        switch c.kind {
        case .intro:
            put(nodes[0]); card = .intro
            if !c.say.isEmpty { subtitle = c.say }
            let t0 = ContinuousClock.now
            await speak(c.say)
            guard !Task.isCancelled else { return }
            let spent = (ContinuousClock.now - t0).seconds
            if spent < 3.2 { await sleep(3.2 - spent) }
            guard !Task.isCancelled else { return }
            card = .none; subtitle = nil

        case .move(let ply):
            slideDuration = VideoPlan.slideTime(c.pace) / speed
            if !c.say.isEmpty { subtitle = c.say; await settleSpeech(); beginSpeech(c.say) }
            put(node(atPly: ply), swing: true)
            await sleep(VideoPlan.moveTime(c.pace))

        case .marks:
            showMarks(c)
            if !c.say.isEmpty {
                await settleSpeech()
                subtitle = c.say
                await speak(c.say)
            } else {
                await sleep(1.2)
            }
            guard !Task.isCancelled else { return }
            await sleep(0.3)

        case .ask:
            await performAsk(c)

        case .excursionEnter(let root):
            await settleSpeech()
            slideDuration = 0.55 / speed
            excursionTitle = c.title
            freezeEval(at: node(atPly: c.ply))
            subtitle = nil
            put(root == .before ? node(atPly: c.ply - 1) : node(atPly: c.ply))
            await sleep(1.4)

        case .excursionStep:
            slideDuration = 0.5 / speed
            subtitle = c.say.isEmpty ? nil : c.say
            async let spoken: Void = speak(c.say)
            await sleep(0.35)
            for u in c.moves {
                guard !Task.isCancelled else { return }
                previewMoves.append(u)
                await sleep(0.9)
            }
            guard !Task.isCancelled else { return }
            showMarks(c)
            if c.say.isEmpty { await sleep(1.0) }
            await spoken
            guard !Task.isCancelled else { return }
            await sleep(0.3)

        case .excursionExit:
            slideDuration = 0.55 / speed
            subtitle = nil; arrows = []; circles = []
            previewMoves = []
            await sleep(0.6)
            guard !Task.isCancelled else { return }
            excursionTitle = nil; frozenNode = nil; barDimmed = false
            put(node(atPly: c.ply))
            returnEpoch += 1
            await sleep(1.0)

        case .outro:
            put(nodes[nodes.count - 1]); card = .outro
            if !c.say.isEmpty { subtitle = c.say }
            let t0 = ContinuousClock.now
            await speak(c.say)
            guard !Task.isCancelled else { return }
            let spent = (ContinuousClock.now - t0).seconds
            if spent < 3.5 { await sleep(3.5 - spent) }
        }
        guard !Task.isCancelled else { return }
        // A segment ends when its commentary does.
        if i + 1 >= cues.count || cues[i + 1].segment != c.segment { await settleSpeech() }
        guard !Task.isCancelled else { return }
        let measured = (ContinuousClock.now - began).seconds * speed / Self.holdScale
        if measured > 0.2 { measure(i, measured) }
    }

    private func measure(_ i: Int, _ seconds: Double) {
        guard durations.indices.contains(i) else { return }
        durations[i] = seconds
        starts = VideoPlan.starts(durations)
    }

    // MARK: Questions

    private func performAsk(_ c: VideoCue) async {
        guard let app, let q = app.quiz(at: node(atPly: c.ply)) else { return }     // nothing to ask: on to the move
        await settleSpeech()
        slideDuration = 0.35 / speed
        subtitle = nil
        let mode = askMode
        askMode = .countdown
        quiz = q
        barDimmed = true
        replyUCI = nil
        previewMoves = []
        put(q.parentID)
        if mode == .skip { phase = .playing; quiz = nil; barDimmed = false; return }
        if mode == .countdown {
            phase = .asking
            let total = VideoPlan.askHold / speed * Self.holdScale
            countdown = (Date(), total)
            await sleep(VideoPlan.askHold)
            guard !Task.isCancelled else { return }
            countdown = nil
        }
        await reveal(q)
        guard !Task.isCancelled else { return }
        phase = .playing; quiz = nil; barDimmed = false
    }

    /// Shows the better move: its arrow, then the move itself on the board, with a line saying it.
    private func reveal(_ q: Quiz) async {
        phase = .reveal
        let before = app?.game.nodes[q.parentID].position
        let san = before.flatMap { p in Move(uci: q.best).map { p.san($0) } } ?? q.best
        let line = "The better move was \(san)."
        subtitle = line
        marksEpoch += 1
        async let spoken: Void = speak(line)
        await sleep(0.8)
        guard !Task.isCancelled else { return }
        previewMoves = [q.best]
        await sleep(VideoPlan.revealHold - 0.8)
        await spoken
        guard !Task.isCancelled else { return }
        previewMoves = []
        subtitle = nil
        await sleep(0.5)
    }

    /// "Show me" / "Skip the question" / a right answer: the video goes on from the question.
    func resolveQuestion(reveal showAnswer: Bool) {
        guard cue.kind == .ask else { return }
        judgeTask?.cancel(); judgeTask = nil
        askMode = showAnswer ? .reveal : .skip
        run(from: index)
    }

    /// "Try again": back to the question position.
    func clearAttempt() {
        guard quiz != nil else { return }
        if case .verdict(let v, _, _) = phase, !v.isCorrect { phase = .asking; replyUCI = nil; marksEpoch += 1 }
    }

    /// Judges a try at the question (see `BetterMove`). The move is never added to the game.
    func submit(_ move: Move) {
        guard acceptsMove, let q = quiz, let app else { return }
        // The viewer took over: the hands-free run stops where it is.
        stopRun()
        isPlaying = false
        countdown = nil
        phase = .judging(move)
        replyUCI = nil
        let history = app.game.engineHistory(to: q.parentID)
        let before = app.game.nodes[q.parentID].position
        judgeTask?.cancel()
        judgeTask = Task { [weak self] in
            var eval: Eval?, reply: String?
            if move.uci != q.best && move.uci != q.played, let after = try? before.applying(move) {
                if after.legalMoves().isEmpty {
                    eval = after.isCheck ? .checkmate(winner: q.side) : .cp(0)
                } else if let line = try? await ToolEngine.shared.evaluate(rootFEN: history.rootFEN, moves: history.moves + [move.uci],
                                                                           whiteToMove: after.turn == .white) {
                    eval = line.eval; reply = line.pv.first
                }
            }
            guard let self, !Task.isCancelled, self.phase == .judging(move) else { return }
            if move.uci == q.played { reply = q.refutation.first }
            let replyText: String? = reply.flatMap { r in (try? before.applying(move)).flatMap { StoryBeats.moveLabel(r, from: $0) } }
            let v = BetterMove.judge(tried: move.uci, side: q.side, best: q.best, bestEval: q.bestEval, played: q.played,
                                     triedEval: eval, reply: replyText)
            self.replyUCI = v.isCorrect ? nil : reply
            self.phase = .verdict(v, tried: move, reply: replyText)
            self.marksEpoch += 1
            // A right answer: a moment to enjoy it, then the video goes on.
            guard v.isCorrect else { self.judgeTask = nil; return }
            try? await Task.sleep(for: .seconds(VideoPlan.answerHold * Self.holdScale))
            guard !Task.isCancelled, self.phase == .verdict(v, tried: move, reply: replyText) else { return }
            self.judgeTask = nil
            self.resolveQuestion(reveal: false)
        }
    }

    // MARK: Board

    /// Puts `id` on the board (sliding the pieces there). Anything else that moves the board closes the video.
    private func put(_ id: Int, swing: Bool = false) {
        guard let app, app.game.nodes.indices.contains(id) else { return }
        nodeID = id
        app.goto(id)
        if swing, let cls = app.review.entries[id]?.cls, cls == .mistake || cls == .blunder {
            swingClass = cls
            swingEpoch += 1
        }
    }

    // MARK: Narration and timing

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds / speed * Self.holdScale))
    }

    private func beginSpeech(_ text: String) {
        pendingSpeech = Task { [weak self] in await self?.speak(text) }
    }

    /// Waits until the commentary that started earlier has been said.
    private func settleSpeech() async {
        guard let t = pendingSpeech else { return }
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        pendingSpeech = nil
    }

    /// Reads `text` aloud, or waits as long as reading it takes (also when the voice fails at once).
    private func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        let started = ContinuousClock.now
        if narrate && !Self.muted { await narrator.speak(text) }
        guard !Task.isCancelled else { return }
        let spoken = (ContinuousClock.now - started).seconds
        if !narrate || Self.muted || spoken < 0.3 {
            let left = VideoPlan.readingTime(text) / speed * Self.holdScale - spoken
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        }
    }

    // MARK: Caption placement

    private static func squares(plan: VideoPlan, nodes: [Int], firstPly: Int, app: AppModel) -> [Int: [Square]] {
        var out: [Int: [Square]] = [:]
        for c in plan.cues {
            var sq: [Square] = out[c.segment] ?? []
            if case .move(let ply) = c.kind {
                let i = ply - firstPly + 1
                if nodes.indices.contains(i), app.game.nodes.indices.contains(nodes[i]), let m = app.game.nodes[nodes[i]].move {
                    sq += [m.from, m.to]
                }
            }
            sq += c.arrows.flatMap { [$0.from, $0.to] } + c.circles
            for u in c.moves { if let m = Move(uci: u) { sq += [m.from, m.to] } }
            out[c.segment] = sq
        }
        return out
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
