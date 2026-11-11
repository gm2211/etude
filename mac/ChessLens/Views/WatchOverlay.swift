import SwiftUI
import ChessCore

/// The guided review drawn over the board the way a video analysis looks: a chapter title card as each beat
/// starts, the narrator's line as a subtitle (on the edge of the board away from where the scene's action is),
/// "pause and think" when the scene stops on its question, the verdict on a try, the takeaway once the scene is
/// over, and the move's class glyph on the square it landed on. It never takes clicks: tries on the board go through.
struct WatchOverlay: View {
    @Environment(AppModel.self) private var app
    let walkthrough: BeatWalkthrough
    let side: CGFloat

    var body: some View {
        let w = walkthrough
        let g = BoardGeometry(side: side, flipped: app.flipped)
        ZStack(alignment: .topLeading) {
            glyph(g)
            subtitleLayer(w, g)
            if w.titleCard {
                ChapterTitleCard(number: w.index + 1, count: w.steps.count, beat: w.current.beat,
                                 move: beatMoveLabel(app.game, w.current), cls: app.review.entries[w.current.nodeID]?.cls,
                                 side: side)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: w.titleCard)
    }

    // MARK: Move glyph

    /// "??", "?", "?!", "!" or "!!" on the destination square of the game move on the board, like an annotation
    /// in a video. Not on scene previews: those moves aren't the game's.
    @ViewBuilder private func glyph(_ g: BoardGeometry) -> some View {
        let d = max(16, g.cell * 0.36)
        ZStack(alignment: .topLeading) {
            if app.lessonPreview == nil, let m = app.lastMove, let cls = app.review.entries[app.currentID]?.cls {
                let r = g.rect(m.to)
                ClassBadge(cls: cls, size: d)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
                    .position(x: min(r.maxX - d * 0.22, side - d * 0.5), y: max(r.minY + d * 0.22, d * 0.5))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .id(app.currentID)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: app.currentID)
        .animation(.easeOut(duration: 0.2), value: app.lessonPreview == nil)
    }

    // MARK: Subtitles

    private struct Line: Hashable {
        var kicker: String?
        var text: String
        var icon: String?
        var tint: Color
    }

    /// What the subtitle says now, if anything.
    private func line(_ w: BeatWalkthrough) -> Line? {
        if w.titleCard { return nil }
        let quiz = w.current.quiz
        switch w.phase {
        case .asking:
            return Line(kicker: "Pause and think", text: (quiz.map { BetterMove.prompt(side: $0.side) } ?? "Find a better move")
                        + ". Play it on the board.", icon: "questionmark.circle.fill", tint: Self.lessonOnDark)
        case .judging(let m):
            return Line(kicker: "Your move: \(san(m))", text: "Checking it\u{2026}", icon: "hourglass", tint: Self.lessonOnDark)
        case .verdict(let v, let m, _):
            return Line(kicker: "Your move: \(san(m))", text: BetterMove.text(v), icon: v.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill",
                        tint: v.isCorrect ? Theme.good : Theme.mist)
        case .scene:
            if w.finished, let r = w.current.beat.rule {
                return Line(kicker: "Key takeaway", text: r, icon: "checkmark.seal.fill", tint: Theme.good)
            }
            if w.holdingQuestion, let q = quiz {
                return Line(kicker: "Pause and think", text: BetterMove.prompt(side: q.side) + ".", icon: "pause.circle.fill",
                            tint: Self.lessonOnDark)
            }
            guard w.captions, let say = w.sceneStep?.say, !say.isEmpty else { return nil }
            return Line(kicker: nil, text: say, icon: nil, tint: .white)
        }
    }

    private func san(_ m: Move) -> String {
        guard let q = walkthrough.current.quiz, app.game.nodes.indices.contains(q.parentID) else { return m.uci }
        return app.game.nodes[q.parentID].position.san(m)
    }

    private func subtitleLayer(_ w: BeatWalkthrough, _ g: BoardGeometry) -> some View {
        let top = captionOnTop(w, g)
        let l = line(w)
        return VStack(spacing: 0) {
            if !top { Spacer(minLength: 0) }
            if let l {
                subtitle(l)
                    .id(l)
                    .transition(.opacity.combined(with: .offset(y: top ? -6 : 6)))
            }
            if top { Spacer(minLength: 0) }
        }
        .padding(.horizontal, side * 0.04)
        .padding(.vertical, side * 0.03)
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.22), value: l)
        .animation(.easeInOut(duration: 0.3), value: top)
    }

    private func subtitle(_ l: Line) -> some View {
        let fs = min(22, max(14, side * 0.031))
        return VStack(spacing: 3) {
            if let k = l.kicker {
                Text(k.uppercased()).font(.system(size: fs * 0.56, weight: .bold)).tracking(0.9).foregroundStyle(l.tint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let i = l.icon {
                    Image(systemName: i).font(.system(size: fs * 0.9, weight: .semibold)).foregroundStyle(l.tint)
                }
                Text(l.text).font(.system(size: fs, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, fs * 0.8).padding(.vertical, fs * 0.5)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: fs * 0.45))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .frame(maxWidth: side * 0.92)
    }

    /// The subtitle goes on the edge of the board with less going on: it starts at the bottom, like a video's, and
    /// moves to the top when the chapter's moves, arrows and circles crowd the two ranks it would cover. Decided
    /// per chapter, so it doesn't jump around while a scene plays.
    private func captionOnTop(_ w: BeatWalkthrough, _ g: BoardGeometry) -> Bool {
        var squares: [Square] = []
        let step = w.current
        if app.game.nodes.indices.contains(step.nodeID), let m = app.game.nodes[step.nodeID].move { squares += [m.from, m.to] }
        for s in step.scene {
            squares += s.arrows.flatMap { [$0.from, $0.to] } + s.circles
            for u in s.moves { if let m = Move(uci: u) { squares += [m.from, m.to] } }
        }
        let rows = squares.map { Int((g.rect($0).midY / g.cell).rounded(.down)) }
        return rows.filter { $0 >= 6 }.count > rows.filter { $0 <= 1 }.count
    }

    /// The lesson colour, lifted to read on the dark subtitle plate.
    static let lessonOnDark = Color(red: 0.76, green: 0.68, blue: 1.0)
}

/// The card on the board as a chapter starts: "CHAPTER 2 OF 5", the beat's title, its move and glyph, and the
/// headline, over a dimmed board that fast-forwards to the scene underneath.
struct ChapterTitleCard: View {
    let number: Int
    let count: Int
    let beat: GameLesson.Beat
    let move: String
    let cls: MoveClass?
    let side: CGFloat

    var body: some View {
        let s = side / 600
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 10 * s) {
                Text("CHAPTER \(number) OF \(count)")
                    .font(.system(size: max(10, 13 * s), weight: .bold)).tracking(1.6)
                    .foregroundStyle(.white.opacity(0.7))
                Text(beat.title)
                    .font(.display(max(24, 42 * s))).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2)
                HStack(spacing: 7) {
                    Circle().fill(beat.kind.color).frame(width: max(7, 10 * s), height: max(7, 10 * s))
                    Text(move).font(.mono(max(12, 17 * s), weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                    if let cls { ClassBadge(cls: cls, size: max(16, 22 * s)) }
                }
                Text(beat.headline)
                    .font(.system(size: max(12, 16.5 * s), weight: .medium)).foregroundStyle(.white.opacity(0.86))
                    .multilineTextAlignment(.center).lineLimit(3)
                    .frame(maxWidth: side * 0.78)
                    .fixedSize(horizontal: false, vertical: true)
                Capsule().fill(beat.kind.color).frame(width: 46 * max(0.6, s), height: 3)
                    .padding(.top, 2)
            }
            .padding(24 * s)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chapter \(number) of \(count): \(beat.title). \(beat.headline)")
    }
}

/// "14\u{2026} Nxe4" for a beat's move, or "Start" for the opening position.
@MainActor func beatMoveLabel(_ game: Game, _ step: BeatWalkthrough.Step) -> String {
    step.beat.ply == 0 || step.beat.at.lowercased() == "start" ? "Start" : moveLabel(game, step.nodeID)
}
