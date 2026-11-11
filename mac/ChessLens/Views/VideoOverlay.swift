import SwiftUI
import ChessCore

/// The video drawn over the board the way a video analysis looks: the narrator's line as a subtitle plate (on the
/// edge of the board away from the action), a reaction ("??", "Oof.") popping out by the piece that moved, the
/// move's class glyph on its square, a cool tint and a "WHAT IF" badge while the board is off the game, "pause
/// and think" with its countdown, the verdict on a try, and the intro, chapter and outro cards. It never takes
/// clicks: moves made on the board go through.
struct VideoOverlay: View {
    @Environment(AppModel.self) private var app
    let video: GameVideo
    let side: CGFloat
    /// Draws the "Back to the game" flash (it normally appears for a moment when an excursion ends).
    var forceReturnFlash = false
    @State private var returning = false

    private var scale: CGFloat { side / 640 }

    var body: some View {
        let g = BoardGeometry(side: side, flipped: app.flipped)
        ZStack(alignment: .topLeading) {
            tint
            glyph(g)
            reactionPop(g)
            badges
            cards
            subtitleLayer(g)
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.5), value: video.excursionTitle)
        .animation(.easeOut(duration: 0.3), value: video.card)
        .onChange(of: video.returnEpoch) { _, _ in
            returning = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1300))
                returning = false
            }
        }
    }

    // MARK: Excursion

    /// A subtle cool tint and a vignette while the board is off the game.
    @ViewBuilder private var tint: some View {
        if video.excursionTitle != nil {
            ZStack {
                Color(red: 0.25, green: 0.42, blue: 0.85).opacity(0.12)
                RadialGradient(colors: [.clear, Color(red: 0.08, green: 0.14, blue: 0.42).opacity(0.42)],
                               center: .center, startRadius: side * 0.32, endRadius: side * 0.78)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var badges: some View {
        let fs = max(11, 15 * scale)
        VStack(alignment: .leading, spacing: 6) {
            if let title = video.excursionTitle {
                HStack(spacing: fs * 0.45) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: fs, weight: .bold))
                    Text("WHAT IF").font(.system(size: fs * 0.82, weight: .heavy)).tracking(1.2)
                    if !title.isEmpty {
                        Text("\u{00B7}").opacity(0.6)
                        Text(title).font(.system(size: fs, weight: .semibold)).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, fs * 0.8).padding(.vertical, fs * 0.45)
                .background(Color(red: 0.16, green: 0.22, blue: 0.52).opacity(0.94), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
            } else if returning || forceReturnFlash {
                HStack(spacing: fs * 0.45) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: fs, weight: .bold))
                    Text("Back to the game").font(.system(size: fs, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, fs * 0.8).padding(.vertical, fs * 0.45)
                .background(Color(red: 0.12, green: 0.5, blue: 0.32).opacity(0.95), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .padding(side * 0.03)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: video.excursionTitle)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: returning)
    }

    // MARK: Glyph and reaction

    /// "??", "?", "?!", "!" or "!!" on the destination square of the game move on the board, like an annotation
    /// in a video. Not on excursion moves: those aren't the game's.
    @ViewBuilder private func glyph(_ g: BoardGeometry) -> some View {
        let d = max(16, g.cell * 0.36)
        ZStack(alignment: .topLeading) {
            if app.lessonPreview == nil, video.excursionTitle == nil, video.card == .none, let m = app.lastMove,
               let cls = app.review.entries[app.currentID]?.cls {
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

    /// The reaction pops out beside the square that moved, with a spring.
    @ViewBuilder private func reactionPop(_ g: BoardGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            if let r = video.reaction, video.card == .none {
                let fs = max(15, 26 * scale)
                let w = CGFloat(r.text.count) * fs * 0.62 + fs * 1.3
                let c = g.center(r.square)
                let x = min(max(c.x + g.cell * 0.55 + w * 0.35, w / 2 + 6), side - w / 2 - 6)
                let y = min(max(c.y - g.cell * 0.85, fs), side - fs)
                let cls = app.review.entries[app.currentID]?.cls
                Text(r.text)
                    .font(.system(size: fs, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, fs * 0.55).padding(.vertical, fs * 0.22)
                    .background(cls.map { Theme.color(for: $0) } ?? Color.black.opacity(0.82), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .rotationEffect(.degrees(-4))
                    .position(x: x, y: y)
                    .id(r.epoch)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .animation(.spring(response: 0.38, dampingFraction: 0.5), value: video.reaction)
    }

    // MARK: Subtitles

    struct Line: Hashable {
        var kicker: String?
        var text: String
        var icon: String?
        var tint: Color
        var ring = false
    }

    /// The lesson colour, lifted to read on the dark subtitle plate.
    static let accentOnDark = Color(red: 0.76, green: 0.68, blue: 1.0)

    private func san(_ m: Move) -> String {
        guard let q = video.quiz, app.game.nodes.indices.contains(q.parentID) else { return m.uci }
        return app.game.nodes[q.parentID].position.san(m)
    }

    /// What the subtitle says now, if anything.
    private var line: Line? {
        switch video.phase {
        case .asking:
            let q = video.quiz.map { BetterMove.prompt(side: $0.side) } ?? "Find a better move"
            let tail = video.countdown != nil ? "" : " Play it on the board."
            return Line(kicker: "Pause and think", text: q + "." + tail, icon: nil, tint: Self.accentOnDark, ring: true)
        case .judging(let m):
            return Line(kicker: "Your move: \(san(m))", text: "Checking it\u{2026}", icon: "hourglass", tint: Self.accentOnDark)
        case .verdict(let v, let m, _):
            return Line(kicker: "Your move: \(san(m))", text: BetterMove.text(v),
                        icon: v.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill", tint: v.isCorrect ? Theme.good : Theme.mist)
        case .reveal:
            guard let s = video.subtitle else { return nil }
            return Line(kicker: "The answer", text: s, icon: "lightbulb.fill", tint: Self.accentOnDark)
        case .playing:
            guard video.captions, let s = video.subtitle, !s.isEmpty else { return nil }
            return Line(kicker: nil, text: s, icon: nil, tint: .white)
        }
    }

    private func subtitleLayer(_ g: BoardGeometry) -> some View {
        let top = captionOnTop(g)
        let l = line
        return VStack(spacing: 0) {
            if !top { Spacer(minLength: 0) }
            if let l {
                plate(l)
                    .id(l)
                    .transition(.opacity.combined(with: .offset(y: top ? -6 : 6)))
            }
            if top { Spacer(minLength: 0) }
        }
        .padding(.horizontal, side * 0.04)
        .padding(.vertical, side * 0.03)
        // The excursion badge sits at the top-left, so captions go below it.
        .padding(.top, top && video.excursionTitle != nil ? 34 * scale : 0)
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.22), value: l)
        .animation(.easeInOut(duration: 0.3), value: top)
    }

    private func plate(_ l: Line) -> some View {
        let fs = min(22, max(13, side * 0.031))
        return HStack(alignment: .center, spacing: fs * 0.8) {
            if l.ring, let c = video.countdown { CountdownRing(start: c.start, duration: c.duration, size: fs * 2.1, tint: l.tint) }
            VStack(spacing: 3) {
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
        }
        .padding(.horizontal, fs * 0.8).padding(.vertical, fs * 0.5)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: fs * 0.45))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .frame(maxWidth: side * 0.92)
    }

    /// The subtitle goes on the edge of the board with less going on: it starts at the bottom, like a video's, and
    /// moves to the top when the segment's moves, arrows and circles crowd the two ranks it would cover. Decided
    /// per segment, so it doesn't jump around while one plays.
    private func captionOnTop(_ g: BoardGeometry) -> Bool {
        let squares = video.activity(ofSegment: video.cue.segment)
        var extra: [Square] = []
        if let q = video.quiz, video.phase != .playing { extra = Move(uci: q.best).map { [$0.from, $0.to] } ?? [] }
        let rows = (squares + extra).map { Int((g.rect($0).midY / g.cell).rounded(.down)) }
        return rows.filter { $0 >= 6 }.count > rows.filter { $0 <= 1 }.count
    }

    // MARK: Cards

    @ViewBuilder private var cards: some View {
        switch video.card {
        case .none: EmptyView()
        case .intro:
            IntroCard(facts: video.facts, side: side).transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .chapter(let n, let title):
            ChapterCard(number: n, title: title, side: side).transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .outro:
            OutroCard(facts: video.facts, side: side).transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

/// The hands-free countdown on a question: a ring that empties.
struct CountdownRing: View {
    let start: Date
    let duration: Double
    let size: CGFloat
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let left = max(0, min(1, 1 - ctx.date.timeIntervalSince(start) / max(duration, 0.01)))
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: size * 0.12)
                Circle().trim(from: 0, to: left)
                    .stroke(tint, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(ceil(left * duration)))")
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Countdown")
    }
}

// MARK: - Cards

private enum CardStyle {
    static let kicker = Color.white.opacity(0.72)
}

/// The opening title card: the script's title, White against Black with ratings, the event and the opening.
struct IntroCard: View {
    let facts: GameVideo.Facts
    let side: CGFloat

    var body: some View {
        let s = side / 640
        ZStack {
            Color.black.opacity(0.64)
            VStack(spacing: 14 * s) {
                Text("GAME REVIEW").font(.system(size: max(10, 13 * s), weight: .bold)).tracking(2).foregroundStyle(CardStyle.kicker)
                Text(facts.title).font(.display(max(24, 40 * s))).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                    .frame(maxWidth: side * 0.8)
                HStack(alignment: .top, spacing: 16 * s) {
                    player(facts.white, facts.whiteElo, dark: false, s: s)
                    Text("vs").font(.display(max(14, 20 * s))).italic().foregroundStyle(.white.opacity(0.6)).padding(.top, 2 * s)
                    player(facts.black, facts.blackElo, dark: true, s: s)
                }
                .frame(maxWidth: side * 0.86)
                let meta = [facts.event, facts.opening].compactMap { $0 }.joined(separator: "  \u{00B7}  ")
                if !meta.isEmpty {
                    Text(meta).font(.system(size: max(11, 14.5 * s), weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: side * 0.8)
                }
                if let r = facts.result {
                    Text(r).font(.mono(max(11, 14 * s), weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10 * s).padding(.vertical, 3 * s)
                        .background(.white.opacity(0.16), in: Capsule())
                }
            }
            .padding(24 * s)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(facts.title). \(facts.white) against \(facts.black).")
    }

    private func player(_ name: String, _ elo: String?, dark: Bool, s: CGFloat) -> some View {
        VStack(spacing: 4 * s) {
            Circle().fill(dark ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.96, green: 0.96, blue: 0.94))
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                .frame(width: max(10, 14 * s), height: max(10, 14 * s))
            Text(name).font(.system(size: max(13, 19 * s), weight: .semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
            if let elo {
                Text(elo).font(.mono(max(11, 14 * s), weight: .medium)).foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The card on the board as a chapter starts: "CHAPTER 2" and its title over a dimmed board.
struct ChapterCard: View {
    let number: Int
    let title: String
    let side: CGFloat

    var body: some View {
        let s = side / 640
        ZStack {
            Color.black.opacity(0.52)
            VStack(spacing: 10 * s) {
                Text("CHAPTER \(number)").font(.system(size: max(10, 13 * s), weight: .bold)).tracking(2).foregroundStyle(CardStyle.kicker)
                Text(title).font(.display(max(26, 46 * s))).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                    .frame(maxWidth: side * 0.8)
                Capsule().fill(Color(red: 0.76, green: 0.68, blue: 1.0)).frame(width: 52 * max(0.6, s), height: 3)
            }
            .padding(24 * s)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chapter \(number): \(title)")
    }
}

/// The closing card: the takeaways and how each side played.
struct OutroCard: View {
    let facts: GameVideo.Facts
    let side: CGFloat

    var body: some View {
        let s = side / 640
        ZStack {
            Color.black.opacity(0.68)
            VStack(spacing: 16 * s) {
                Text(facts.takeaways.isEmpty ? "THANKS FOR WATCHING" : "THE TAKEAWAYS")
                    .font(.system(size: max(10, 13 * s), weight: .bold)).tracking(2).foregroundStyle(CardStyle.kicker)
                if !facts.takeaways.isEmpty {
                    VStack(alignment: .leading, spacing: 10 * s) {
                        ForEach(Array(facts.takeaways.enumerated()), id: \.offset) { _, t in
                            HStack(alignment: .firstTextBaseline, spacing: 9 * s) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: max(12, 18 * s)))
                                    .foregroundStyle(Color(red: 0.42, green: 0.82, blue: 0.6))
                                Text(t).font(.system(size: max(13, 19 * s), weight: .medium)).foregroundStyle(.white)
                                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: side * 0.78, alignment: .leading)
                }
                HStack(spacing: 12 * s) {
                    accuracy("White", facts.whiteAccuracy, dark: false, s: s)
                    accuracy("Black", facts.blackAccuracy, dark: true, s: s)
                }
            }
            .padding(24 * s)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Takeaways. " + facts.takeaways.joined(separator: " "))
    }

    private func accuracy(_ name: String, _ a: Double?, dark: Bool, s: CGFloat) -> some View {
        HStack(spacing: 7 * s) {
            Circle().fill(dark ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.96, green: 0.96, blue: 0.94))
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                .frame(width: max(9, 12 * s), height: max(9, 12 * s))
            Text(name).font(.system(size: max(12, 16 * s), weight: .semibold)).foregroundStyle(.white)
            Text(a.map { "\(Int($0.rounded()))%" } ?? "\u{2013}").font(.mono(max(12, 17 * s), weight: .bold)).foregroundStyle(.white)
            Text("accuracy").font(.system(size: max(10, 12 * s))).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12 * s).padding(.vertical, 7 * s)
        .background(.white.opacity(0.13), in: Capsule())
    }
}
