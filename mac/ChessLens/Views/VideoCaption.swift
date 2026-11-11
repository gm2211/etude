import SwiftUI
import ChessCore

/// Height of the caption strip (two lines of text) and of the banner above the board. Reserved whenever a video is
/// open, so nothing shifts as lines come and go.
enum VideoChrome {
    static let captionHeight: CGFloat = 60
    static let bannerHeight: CGFloat = 26
}

/// The lesson colour, lifted to read on the dark caption plate.
let videoAccentOnDark = Color(red: 0.76, green: 0.68, blue: 1.0)

/// The narrator's line as a subtitle, in a strip between the board and the player bar so it never covers a piece.
/// The question ("pause and think", with its countdown), "Checking\u{2026}" and the verdict take its place.
struct VideoCaptionStrip: View {
    @Environment(AppModel.self) private var app
    let video: GameVideo

    struct Line: Hashable {
        var kicker: String?
        var text: String
        var icon: String?
        var tint: Color
        var ring = false
    }

    private func san(_ m: Move) -> String {
        guard let q = video.quiz, app.game.nodes.indices.contains(q.parentID) else { return m.uci }
        return app.game.nodes[q.parentID].position.san(m)
    }

    var line: Line? {
        if case .chapter = video.card { return nil }
        switch video.phase {
        case .asking:
            let q = video.quiz.map { BetterMove.prompt(side: $0.side) } ?? "Find a better move"
            let tail = video.countdown != nil ? "" : " Play it on the board."
            return Line(kicker: "PAUSE AND THINK", text: q + "." + tail, icon: nil, tint: videoAccentOnDark, ring: true)
        case .judging(let m):
            return Line(kicker: "YOUR MOVE: \(san(m))", text: "Checking it\u{2026}", icon: "hourglass", tint: videoAccentOnDark)
        case .verdict(let v, let m, _):
            return Line(kicker: "YOUR MOVE: \(san(m))", text: BetterMove.text(v),
                        icon: v.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill", tint: v.isCorrect ? Theme.good : Theme.mist)
        case .reveal:
            guard let s = video.subtitle else { return nil }
            return Line(kicker: "THE ANSWER", text: s, icon: "lightbulb.fill", tint: videoAccentOnDark)
        case .playing:
            guard video.captions, let s = video.subtitle, !s.isEmpty else { return nil }
            return Line(kicker: nil, text: s, icon: nil, tint: .white)
        }
    }

    var body: some View {
        let l = line
        ZStack {
            if let l {
                plate(l).id(l).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: VideoChrome.captionHeight)
        .animation(.easeOut(duration: 0.2), value: l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Captions")
    }

    private func plate(_ l: Line) -> some View {
        let fs: CGFloat = 15
        return HStack(alignment: .center, spacing: 12) {
            if l.ring, let c = video.countdown { CountdownRing(start: c.start, duration: c.duration, size: 34, tint: l.tint) }
            VStack(spacing: 2) {
                if let k = l.kicker {
                    Text(k).font(.system(size: 9.5, weight: .bold)).tracking(0.9).foregroundStyle(l.tint).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let i = l.icon {
                        Image(systemName: i).font(.system(size: fs * 0.9, weight: .semibold)).foregroundStyle(l.tint)
                    }
                    Text(l.text).font(.system(size: fs, weight: .semibold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(l.kicker == nil ? 2 : 2)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.1, green: 0.11, blue: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

/// A thin banner directly above the board while the video is off the game: "WHAT IF \u{00B7} Instead: knight d7", and
/// "Back to the game" for a moment when it returns. Its height is always reserved.
struct VideoBanner: View {
    let video: GameVideo
    @Environment(\.forceReturnFlash) private var forceReturnFlash
    @State private var returning = false

    var body: some View {
        ZStack(alignment: .leading) {
            if let title = video.excursionTitle {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .bold))
                    Text("WHAT IF").font(.system(size: 10.5, weight: .heavy)).tracking(1.1)
                    if !title.isEmpty {
                        Text("\u{00B7}").opacity(0.6)
                        Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.33, green: 0.24, blue: 0.62), in: RoundedRectangle(cornerRadius: 4))
                .transition(.opacity)
            } else if returning || forceReturnFlash {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .bold))
                    Text("Back to the game").font(.system(size: 12.5, weight: .bold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.12, green: 0.5, blue: 0.32), in: RoundedRectangle(cornerRadius: 4))
                .transition(.opacity)
            }
        }
        .frame(height: VideoChrome.bannerHeight)
        .animation(.easeInOut(duration: 0.25), value: video.excursionTitle)
        .animation(.easeInOut(duration: 0.25), value: returning)
        .onChange(of: video.returnEpoch) { _, _ in
            returning = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                returning = false
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ForceReturnFlashKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var forceReturnFlash: Bool {
        get { self[ForceReturnFlashKey.self] }
        set { self[ForceReturnFlashKey.self] = newValue }
    }
}
