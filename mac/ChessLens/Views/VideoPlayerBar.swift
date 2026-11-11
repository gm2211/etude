import SwiftUI
import ChessCore

/// The video's player bar under the board, in the caption's place: the chapter and move being shown, a scrubber
/// (a tick per game move, coloured where the review flagged one; chapters are separate stretches), elapsed and
/// total time, and the transport: chapters, steps, play, speed, captions, narrator, replay and close. At a
/// question the pills to answer or skip it appear beside the title. See `GameVideo`.
struct VideoPlayerBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.staticControls) private var staticControls
    let video: GameVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            VideoScrubber(video: video)
                .frame(height: 24)
            transport
        }
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 7)
        .frame(maxWidth: 680)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line2, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video player")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("CH \(video.chapterIndex + 1)").font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.surface)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Theme.lesson, in: RoundedRectangle(cornerRadius: 3))
            Text(video.chapterTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            Text(moveText).font(.mono(11.5, weight: .semibold)).foregroundStyle(Theme.ink3).lineLimit(1)
            Spacer(minLength: 6)
            answerControls
        }
        .frame(minHeight: 24)
    }

    private var moveText: String {
        switch video.cue.kind {
        case .intro: "Intro"
        case .outro: "Outro"
        default: video.excursionTitle != nil ? "What if" : moveLabel(app.game, video.nodeID)
        }
    }

    @ViewBuilder private var answerControls: some View {
        switch video.phase {
        case .asking:
            HStack(spacing: 6) {
                if video.countdown != nil { Text("Play your move on the board").font(.system(size: 12)).foregroundStyle(Theme.ink3) }
                pill("Show me", "eye", prominent: false) { video.resolveQuestion(reveal: true) }
                pill("Skip", "forward.fill", prominent: false) { video.resolveQuestion(reveal: false) }
            }
        case .judging:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking\u{2026}").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            }
        case .verdict(let v, _, _):
            HStack(spacing: 6) {
                if v.isCorrect {
                    pill("Continue", "play.fill", prominent: true) { video.resolveQuestion(reveal: false) }
                } else {
                    pill("Try again", "arrow.uturn.backward", prominent: true) { video.clearAttempt() }
                    pill("Show me", "eye", prominent: false) { video.resolveQuestion(reveal: true) }
                    pill("Skip", "forward.fill", prominent: false) { video.resolveQuestion(reveal: false) }
                }
            }
        default: EmptyView()
        }
    }

    private func pill(_ title: String, _ symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? Theme.surface : Theme.lesson)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(prominent ? Theme.lesson : Theme.lesson.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.lesson.opacity(prominent ? 1 : 0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 2) {
            button("backward.end.fill", "Previous chapter", enabled: video.chapterIndex > 0 || video.index > 0) { video.previousChapter() }
            button("chevron.left", "Previous step (\u{2190})", enabled: video.canGoBack) { video.previous() }
            button(video.finished ? "arrow.counterclockwise" : video.isPlaying ? "pause.fill" : "play.fill",
                   video.finished ? "Watch again" : video.isPlaying ? "Pause (Space)" : "Play (Space)", prominent: true) { video.togglePlay() }
            button("chevron.right", "Next step (\u{2192})", enabled: video.canGoForward) { video.next() }
            button("forward.end.fill", "Next chapter", enabled: video.chapters.contains { $0.seekCue > video.index }) { video.nextChapter() }
            timeLabel.padding(.leading, 8)
            Spacer(minLength: 6)
            speedMenu
            button("arrow.counterclockwise.circle", "Replay this chapter", enabled: true) { video.replayChapter() }
            button(video.captions ? "captions.bubble.fill" : "captions.bubble", video.captions ? "Hide captions" : "Show captions") {
                video.captions.toggle()
            }
            button(video.narrate ? "speaker.wave.2.fill" : "speaker.slash", video.narrate ? "Mute the narrator" : "Read it aloud") {
                video.narrate.toggle()
            }
            button("xmark", "Close the video (Esc)") { app.closeLesson() }
        }
    }

    private var timeLabel: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let t = video.time(at: ctx.date) / video.speed
            Text("\(VideoPlan.clock(t)) / \(VideoPlan.clock(video.totalTime / video.speed))")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink2)
        }
        .accessibilityLabel("Time")
    }

    @ViewBuilder private var speedMenu: some View {
        if staticControls {
            speedLabel
        } else {
            speedMenuControl
        }
    }

    private var speedLabel: some View {
        Text(speedText(video.speed)).font(.system(size: 11.5, weight: .bold).monospacedDigit()).foregroundStyle(Theme.ink2)
            .frame(minWidth: 34, minHeight: 24)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
    }

    private var speedMenuControl: some View {
        Menu {
            ForEach(GameVideo.speeds, id: \.self) { s in
                Button { video.speed = s } label: {
                    if video.speed == s { Label(speedText(s), systemImage: "checkmark") } else { Text(speedText(s)) }
                }
            }
        } label: {
            speedLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
        .accessibilityLabel("Playback speed")
    }

    private func speedText(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))\u{00D7}" : String(format: "%g\u{00D7}", s)
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool = true, prominent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(prominent ? Theme.surface : Theme.ink2)
                .frame(width: prominent ? 32 : 27, height: 26)
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

/// The scrubber: one stretch of track per chapter (a gap between), a tick per game move (coloured by class where
/// the review flagged one), the playhead. Click or drag to seek; hovering names the chapter and time.
struct VideoScrubber: View {
    @Environment(AppModel.self) private var app
    let video: GameVideo
    @State private var hoverX: CGFloat?

    private struct Tick { var x: Double; var cls: MoveClass? }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let total = max(video.totalTime, 1)
            TimelineView(.animation(minimumInterval: 0.1, paused: !video.isPlaying)) { ctx in
                let now = video.time(at: ctx.date)
                ZStack(alignment: .topLeading) {
                    Canvas { c, size in draw(&c, size: size, total: total, now: now) }
                    playhead(x: now / total * w, h: h)
                    if let hx = hoverX { hoverLabel(x: hx, w: w, total: total) }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    video.beginScrub()
                    video.scrub(toTime: max(0, min(total, v.location.x / w * total)))
                }
                .onEnded { _ in video.endScrub() })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended: hoverX = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Scrubber")
        .accessibilityValue("\(VideoPlan.clock(video.time(at: Date()))) of \(VideoPlan.clock(video.totalTime))")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: video.next()
            case .decrement: video.previous()
            @unknown default: break
            }
        }
    }

    private func bounds(total: Double, w: Double) -> [(x0: Double, x1: Double)] {
        let starts = video.chapters.enumerated().map { i, c in i == 0 ? 0 : video.starts[c.cue] }
        return starts.enumerated().map { i, s in
            (s / total * w, (i + 1 < starts.count ? starts[i + 1] : total) / total * w)
        }
    }

    private func draw(_ c: inout GraphicsContext, size: CGSize, total: Double, now: Double) {
        let w = size.width, mid = size.height / 2 + 2
        let gap = 3.0
        let head = now / total * w
        for (i, b) in bounds(total: total, w: w).enumerated() {
            let r = CGRect(x: b.x0 + (i == 0 ? 0 : gap / 2), y: mid - 2.5, width: max(2, b.x1 - b.x0 - (i == 0 ? gap / 2 : gap)), height: 5)
            c.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(Theme.line2))
            let done = min(r.maxX, head) - r.minX
            if done > 0 { c.fill(Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: done, height: r.height), cornerRadius: 2.5),
                                with: .color(Theme.lesson)) }
        }
        // A tick for every game move; flagged moves stand taller, in their class colour.
        for (i, cue) in video.cues.enumerated() {
            guard case .move(let ply) = cue.kind else { continue }
            let x = video.starts[i] / total * w
            let cls = app.review.entries[video.node(atPly: ply)]?.cls
            if let cls {
                let r = CGRect(x: x - 1.5, y: mid - 9, width: 3, height: 18)
                c.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(Theme.color(for: cls)))
                c.stroke(Path(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 2), with: .color(Theme.surface), lineWidth: 1)
            } else {
                c.fill(Path(CGRect(x: x - 0.5, y: mid - 4.5, width: 1, height: 9)), with: .color(Theme.ink3.opacity(0.4)))
            }
        }
    }

    private func playhead(x: Double, h: Double) -> some View {
        Circle().fill(Theme.ink)
            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
            .frame(width: 13, height: 13)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .position(x: min(max(x, 0), 100_000), y: h / 2 + 2)
            .allowsHitTesting(false)
    }

    private func hoverLabel(x: CGFloat, w: CGFloat, total: Double) -> some View {
        let t = Double(x / w) * total
        let ch = video.plan.compiled.chapter(at: video.cueIndex(atTime: t))
        let title = video.chapters.indices.contains(ch) ? video.chapters[ch].title : ""
        return Text("\(title)  \(VideoPlan.clock(t / video.speed))")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.surface)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .position(x: min(max(x, 70), max(70, w - 70)), y: -8)
            .allowsHitTesting(false)
    }
}

private struct StaticControlsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set by the headless snapshot renderer: AppKit-backed controls (menus, segmented pickers) don't render into
    /// an image, so views draw plain stand-ins for them.
    var staticControls: Bool {
        get { self[StaticControlsKey.self] }
        set { self[StaticControlsKey.self] = newValue }
    }
}
