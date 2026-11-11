import SwiftUI
import ChessCore

/// "Watch the game review": the summary's video card. A thumbnail (the turning point on a mini board, a play glyph,
/// the length), the script's title, who is presenting (Calm or High energy) and whether the AI wrote it, and the
/// chapters with real timestamps; clicking one starts the video there. The lesson text below reads like the
/// video's description. See `GameVideo`.
struct VideoCard: View {
    @Environment(AppModel.self) private var app
    @AppStorage("video.style") private var styleRaw = VideoScript.Style.calm.rawValue
    @Environment(\.staticControls) private var staticControls

    var body: some View {
        if let plan = app.videoPlan() {
            let active = app.video != nil
            VStack(alignment: .leading, spacing: 10) {
                thumbnail(plan, active: active)
                Text(plan.script.title).font(.display(20)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                presenter
                stateLine
                chapterList(plan)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Video review: \(plan.script.title)")
        }
    }

    // MARK: Thumbnail

    private func thumbnail(_ plan: VideoPlan, active: Bool) -> some View {
        let id = app.videoThumbnailNode(plan)
        return Button { active ? app.closeLesson() : app.startVideo() } label: {
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.15, blue: 0.14), Color(red: 0.05, green: 0.07, blue: 0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let id, app.game.nodes.indices.contains(id) {
                    MiniBoard(board: app.game.nodes[id].position.board, flipped: app.flipped)
                        .frame(width: 136, height: 136)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        .opacity(0.9)
                }
                Image(systemName: active ? "stop.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.black.opacity(0.62), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            }
            .frame(height: 170)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomTrailing) {
                Text(VideoPlan.clock(plan.total)).font(.system(size: 11.5, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                let asks = plan.script.segments.filter(\.ask).count
                if asks > 0 {
                    Label("\(asks) to solve", systemImage: "questionmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.lesson.opacity(0.9), in: Capsule())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!app.canPlayLessons)
        .help(app.canPlayLessons ? "Watch the game review" : "The video is paused while you play the engine")
        .accessibilityLabel(active ? "Close the video" : "Watch the game review, \(VideoPlan.clock(plan.total))")
    }

    // MARK: Presenter and state

    private var presenter: some View {
        HStack(spacing: 8) {
            Text("PRESENTER").font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
            if staticControls {
                HStack(spacing: 0) {
                    ForEach([("Calm", VideoScript.Style.calm), ("High energy", .hype)], id: \.1) { name, style in
                        Text(name).font(.system(size: 12)).foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(styleRaw == style.rawValue ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(2).frame(maxWidth: 190)
                .background(Theme.line, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Picker("Presenter", selection: Binding(get: { styleRaw }, set: { choose($0) })) {
                    Text("Calm").tag(VideoScript.Style.calm.rawValue)
                    Text("High energy").tag(VideoScript.Style.hype.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 190)
            }
            Spacer(minLength: 0)
        }
    }

    /// Picking a presenter rewrites the script in that style: the AI's when a provider is ready, else the built-in one.
    private func choose(_ raw: String) {
        guard raw != styleRaw, let style = VideoScript.Style(rawValue: raw) else { return }
        styleRaw = raw
        AIVideoScript.style = style
        if AIHub.shared.isReady, app.review.hasResults, !app.review.running {
            app.review.video.generate(game: app.game, review: app.review, force: true)
        }
    }

    @ViewBuilder private var stateLine: some View {
        let ai = app.review.video
        switch ai.state {
        case .loading?:
            AIWaitingLabel(size: 12.5)
        case .done?:
            Label("Script written by AI", systemImage: "sparkles").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
        case .failed(let m)?:
            AIFailureView(message: m) { ai.generate(game: app.game, review: app.review, force: true) }
        default:
            HStack(spacing: 8) {
                Label("Using the built-in commentary", systemImage: "text.bubble").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                if AIHub.shared.isReady {
                    Button("Write with AI") { ai.generate(game: app.game, review: app.review, force: true) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    // MARK: Chapters

    private func chapterList(_ plan: VideoPlan) -> some View {
        let starts = plan.starts
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.chapters.enumerated()), id: \.offset) { i, ch in
                let active = app.video?.chapterIndex == i
                Button { app.startVideo(atChapter: i) } label: {
                    HStack(spacing: 9) {
                        Text(VideoPlan.clock(i == 0 ? 0 : starts[ch.cue]))
                            .font(.mono(11.5, weight: .semibold)).foregroundStyle(active ? Theme.lesson : Theme.ink3)
                            .frame(width: 38, alignment: .leading)
                        Text(ch.title).font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Theme.lesson : Theme.ink).lineLimit(1)
                        if hasAsk(plan, chapter: i) {
                            Image(systemName: "questionmark.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.lesson)
                                .help("Find the better move here")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!app.canPlayLessons)
                .help("Watch from here")
                .accessibilityLabel("Chapter \(i + 1), \(ch.title), at \(VideoPlan.clock(i == 0 ? 0 : starts[ch.cue]))")
                .accessibilityAddTraits(active ? .isSelected : [])
                if i < plan.chapters.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
    }

    private func hasAsk(_ plan: VideoPlan, chapter i: Int) -> Bool {
        let first = plan.chapters[i].segment
        let end = i + 1 < plan.chapters.count ? plan.chapters[i + 1].segment : plan.script.segments.count
        return plan.script.segments.indices.contains(first) && (first..<end).contains { plan.script.segments[$0].ask }
    }
}
