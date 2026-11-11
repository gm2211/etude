import SwiftUI
import ChessCore

extension GameLesson.Beat.Kind {
    /// The dot colour of a beat in the story timeline and on the beat card.
    var color: Color {
        switch self {
        case .setup: Theme.great
        case .slip: Theme.inacc
        case .turning: Theme.blund
        case .punish: Theme.mist
        case .finish: Theme.good
        case .idea: Theme.lesson
        }
    }
}

/// The guided review's player under the board, like a video's controls: the chapter (number, title, move, glyph),
/// a chapter timeline whose segments are as long as each chapter plays (click one to jump there), the transport
/// with the running time, and the buttons a question needs. The scene itself (title cards, subtitles, glyphs) is
/// drawn over the board by `WatchOverlay`. See `BeatWalkthrough`.
struct BeatCard: View {
    @Environment(AppModel.self) private var app
    let walkthrough: BeatWalkthrough

    var body: some View {
        let w = walkthrough
        let step = w.current
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(step.beat.kind.color).frame(width: 8, height: 8)
                Text("\(w.index + 1)/\(w.steps.count)").font(.mono(11.5, weight: .semibold)).foregroundStyle(Theme.ink3)
                Text(step.beat.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(beatMoveLabel(app.game, step)).font(.mono(12, weight: .semibold)).foregroundStyle(Theme.ink2)
                if let cls = app.review.entries[step.nodeID]?.cls { ClassBadge(cls: cls, size: 15) }
                Spacer(minLength: 6)
                closeButton
            }

            ChapterTimeline(walkthrough: w) { i in
                let s = w.steps[i]
                return "\(BeatWalkthrough.clock(w.durations.prefix(i).reduce(0, +)))  \(s.beat.title) \u{00B7} \(beatMoveLabel(app.game, s))"
            }

            HStack(spacing: 4) {
                transport("backward.end.fill", "Previous chapter (\u{2190})", enabled: w.canGoBack) { w.previous() }
                transport(w.isPlaying || w.isRunning ? "pause.fill" : "play.fill",
                          w.isPlaying || w.isRunning ? "Pause (Space)" : "Play every chapter hands-free (Space)",
                          enabled: true, prominent: true) { w.togglePlay() }
                transport("forward.end.fill", "Next chapter (\u{2192})", enabled: w.canGoForward) { w.next() }
                Text("\(BeatWalkthrough.clock(w.elapsedSeconds)) / \(BeatWalkthrough.clock(w.totalSeconds))")
                    .font(.mono(11.5)).foregroundStyle(Theme.ink3)
                    .padding(.leading, 6)
                    .help("Running time, estimated from the length of the narration")
                Spacer(minLength: 8)
                actions(w)
                Spacer(minLength: 8)
                transport("arrow.counterclockwise", "Replay this chapter", enabled: !step.scene.isEmpty) { w.replayScene() }
                transport(w.captions ? "captions.bubble.fill" : "captions.bubble", w.captions ? "Hide subtitles" : "Show subtitles",
                          enabled: true) { w.captions.toggle() }
                transport(w.narrate ? "speaker.wave.2.fill" : "speaker.slash", w.narrate ? "Mute the narrator" : "Read the scene aloud",
                          enabled: true) { w.narrate.toggle() }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 9).padding(.bottom, 6)
        .frame(maxWidth: 520 + 36, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.lesson.opacity(0.45), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: w.index)
        .animation(.easeOut(duration: 0.2), value: phaseKey(w.phase))
        .animation(.easeOut(duration: 0.2), value: w.finished)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided review, chapter \(w.index + 1) of \(w.steps.count): \(step.beat.title)")
    }

    /// What the scene needs from the player now: the question's buttons, or "Next chapter" once a scene is over.
    @ViewBuilder private func actions(_ w: BeatWalkthrough) -> some View {
        switch w.phase {
        case .asking:
            pill("Skip the question", "forward", prominent: false) { w.continueScene() }
        case .judging:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking\u{2026}").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            }
        case .verdict(let v, _, _):
            HStack(spacing: 6) {
                if v.isCorrect {
                    pill("Continue", "play.fill", prominent: true) { w.continueScene() }
                } else {
                    pill("Try again", "arrow.uturn.backward", prominent: true) { w.clearAttempt() }
                    pill("Show me", "eye", prominent: false) { w.continueScene() }
                }
            }
        case .scene:
            if w.finished, !w.isPlaying, w.canGoForward {
                pill("Next: \(w.steps[w.index + 1].beat.title)", "forward.fill", prominent: true) { w.next() }
            }
        }
    }

    private func phaseKey(_ p: BeatWalkthrough.Phase) -> String {
        switch p {
        case .asking: "ask"
        case .judging: "judge"
        case .verdict(let v, let m, _): "verdict-\(m.uci)-\(v.isCorrect)"
        case .scene: "scene"
        }
    }

    // MARK: Controls

    private func pill(_ title: String, _ symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Theme.surface : Theme.lesson)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(prominent ? Theme.lesson : Theme.lesson.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.lesson.opacity(prominent ? 1 : 0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button { app.closeLesson() } label: {
            Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ink3)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close the walkthrough (Esc)")
        .accessibilityLabel("Close the walkthrough")
    }

    private func transport(_ symbol: String, _ help: String, enabled: Bool, prominent: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(prominent ? Theme.surface : Theme.ink2)
                .frame(width: prominent ? 30 : 26, height: 26)
                .background(prominent ? Theme.lesson : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The chapters as a video timeline: one segment per beat, as wide as its share of the running time, filled up
/// to where the walkthrough is. The current chapter is thicker with a playhead; a dot in each segment's kind
/// colour marks where it starts. Click a segment to jump to that chapter.
struct ChapterTimeline: View {
    let walkthrough: BeatWalkthrough
    let label: (Int) -> String

    var body: some View {
        let w = walkthrough
        let total = max(1, w.totalSeconds)
        GeometryReader { geo in
            let gap: CGFloat = 3
            let avail = max(0, geo.size.width - gap * CGFloat(max(0, w.steps.count - 1)))
            HStack(spacing: gap) {
                ForEach(w.steps.indices, id: \.self) { i in
                    let width = avail * CGFloat(w.durations[i] / total)
                    let fill: Double = i < w.index ? 1 : i == w.index ? w.chapterProgress : 0
                    let current = i == w.index
                    Button { w.go(to: i) } label: {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.line2)
                            Capsule().fill(Theme.lesson.opacity(current ? 1 : 0.7)).frame(width: width * CGFloat(fill))
                            Circle().fill(w.steps[i].beat.kind.color).frame(width: 5, height: 5).padding(.leading, 2)
                                .opacity(current ? 0 : 1)
                        }
                        .frame(width: width, height: current ? 7 : 5)
                        .overlay(alignment: .leading) {
                            if current {
                                Circle().fill(Theme.lesson).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                                    .offset(x: max(0, width * CGFloat(fill) - 6))
                            }
                        }
                        .frame(height: 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(label(i))
                    .accessibilityLabel("Chapter \(i + 1): \(w.steps[i].beat.title)")
                }
            }
        }
        .frame(height: 16)
        .animation(.easeInOut(duration: 0.45), value: w.elapsedSeconds)
        .animation(.easeOut(duration: 0.2), value: w.index)
    }
}
