import SwiftUI
import AppKit
import ChessCore

/// Headless rendering of the video views to PNG, so they can be looked at without opening a window:
///
///     Etude --render-snapshots <dir>
///
/// It runs before any scene exists, with the activation policy `.prohibited` (no window, no Dock icon, no focus
/// change), loads the Opera Game with a canned review (no engine) and a canned AI script, renders each view with
/// `ImageRenderer` at scale 2 in light and dark, prints the paths and exits. If the sandbox won't let it write to
/// `<dir>` it writes into its container's tmp instead and prints that path.
@MainActor
enum SnapshotRunner {
    static func run(into requested: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel(headless: true)
        Fixture.install(into: model)
        guard let plan = model.videoPlan() else { print("snapshot: no video plan"); return }
        let dir = outputDirectory(requested)
        print("snapshot: writing to \(dir.path)")

        let cues = plan.cues
        func firstCue(_ test: (VideoCue) -> Bool) -> Int { cues.firstIndex(where: test) ?? 0 }
        let quick = firstCue { c in if case .move(let p) = c.kind { return p == 5 }; return false }
        let marks = firstCue { $0.kind == .marks && $0.reaction != nil }
        let ask = firstCue { $0.kind == .ask }
        let step = firstCue { if case .excursionStep(let k) = $0.kind { return k == 0 }; return false }
        let step2 = firstCue { if case .excursionStep(let k) = $0.kind { return k == 1 }; return false }
        let outro = cues.count - 1
        let chapter = plan.chapters.count > 2 ? plan.chapters[2] : plan.chapters[plan.chapters.count - 1]
        let chapterNumber = (plan.chapters.firstIndex(of: chapter) ?? 0) + 1

        struct Shot { var name: String; var setup: (GameVideo) -> Void }
        let shots: [Shot] = [
            Shot(name: "intro") { $0.presentForSnapshot(cue: 0) },
            Shot(name: "quick-move") { $0.presentForSnapshot(cue: quick) },
            Shot(name: "chapter-title") { $0.presentForSnapshot(cue: chapter.cue, card: .chapter(number: chapterNumber, title: chapter.title)) },
            Shot(name: "marks-reaction") { $0.presentForSnapshot(cue: marks) },
            Shot(name: "whatif-step") { $0.presentForSnapshot(cue: step) },
            Shot(name: "whatif-step2") { $0.presentForSnapshot(cue: step2) },
            Shot(name: "ask") { $0.presentForSnapshot(cue: ask, countdownLeft: 3.2) },
            Shot(name: "ask-waiting") { $0.presentForSnapshot(cue: ask) },
            Shot(name: "verdict") { v in
                v.presentForSnapshot(cue: ask)
                let tried = Move(uci: "a7a6")!
                v.presentForSnapshot(cue: ask, phase: .verdict(.notQuite(reply: "10. Nxb5", loss: 31), tried: tried, reply: "10. Nxb5"))
            },
            Shot(name: "reveal") { v in
                v.presentForSnapshot(cue: ask, phase: .reveal)
            },
            Shot(name: "outro") { $0.presentForSnapshot(cue: outro) },
        ]

        var written: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for shot in shots {
                let video = makeVideo(model, plan)
                shot.setup(video)
                model.installForSnapshot(video)
                write(Stage(side: 640, bar: true, model: model, video: video, scheme: scheme), "\(shot.name)-\(name)", dir, &written, width: 760)
            }
            // The return flash after an excursion, on the game position.
            do {
                let video = makeVideo(model, plan)
                let exit = firstCue { $0.kind == .excursionExit }
                video.presentForSnapshot(cue: exit)
                model.installForSnapshot(video)
                write(Stage(side: 640, bar: true, model: model, video: video, scheme: scheme, returnFlash: true), "return-flash-\(name)", dir, &written, width: 760)
            }
            // The player bar alone, mid-video.
            do {
                let video = makeVideo(model, plan)
                video.presentForSnapshot(cue: step)
                model.installForSnapshot(video)
                let bar = VideoPlayerBar(video: video).padding(18).frame(width: 720).background(Theme.bg)
                    .environment(model).environment(\.colorScheme, scheme).environment(\.staticControls, true)
                write(bar, "player-bar-\(name)", dir, &written, width: 720)
            }
            // The summary's video card.
            do {
                let card = VideoCard().padding(18).frame(width: 420).background(Theme.surface)
                    .environment(model).environment(\.colorScheme, scheme).environment(\.staticControls, true)
                write(card, "summary-card-\(name)", dir, &written, width: 420)
            }
        }
        written.forEach { print($0) }
    }

    private static func makeVideo(_ model: AppModel, _ plan: VideoPlan) -> GameVideo {
        let path = model.review.path
        let v = GameVideo(plan: plan, nodes: path, firstPly: model.game.nodes[path[1]].ply, facts: model.videoFacts(plan.script), app: model)
        return v
    }

    /// The board, eval bar and player bar as the board column lays them out.
    private struct Stage: View {
        let side: CGFloat
        let bar: Bool
        let model: AppModel
        let video: GameVideo
        let scheme: ColorScheme
        var returnFlash = false

        var body: some View {
            VStack(spacing: 12) {
                BoardStage(side: side)
                if bar { VideoPlayerBar(video: video) }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(width: 760)
            .background(Theme.bg)
            .environment(model)
            .environment(\.colorScheme, scheme)
            .environment(\.staticControls, true)
        }
    }

    private static func write<V: View>(_ view: V, _ name: String, _ dir: URL, _ out: inout [String], width: CGFloat) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        r.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot: could not render \(name)"); return
        }
        let url = dir.appendingPathComponent("\(name).png")
        do { try png.write(to: url); out.append(url.path) } catch { print("snapshot: could not write \(url.path): \(error)") }
    }

    private static func outputDirectory(_ requested: String) -> URL {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: requested, isDirectory: true)
        if (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil, fm.isWritableFile(atPath: url.path) {
            let probe = url.appendingPathComponent(".probe")
            if fm.createFile(atPath: probe.path, contents: Data()) { try? fm.removeItem(at: probe); return url }
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("etude-shots", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}

extension AppModel {
    /// Snapshot renderer only: makes `video` the open video without starting it.
    func installForSnapshot(_ v: GameVideo) { if video !== v { video = v } }
}

// MARK: - Fixture

/// The Opera Game with a made-up review and a made-up AI script, so no engine or provider is needed.
@MainActor
enum Fixture {
    static func install(into model: AppModel) {
        let game = model.game
        let path = game.fullLine(through: game.mainline().last ?? 0)
        model.review.loadCanned(path: path, entries: entries(game, path))
        model.review.video.inject(script(game, path))
    }

    /// White's eval (centipawns) after each ply, 0 = the start.
    private static let cp: [Int] = [20, 30, 25, 30, 20, 35, 30, 40, 55, 50, 45, 55, 45, 110, 100, 105, 95, 60, 480, 430, 440, 520,
                                    510, 560, 720, 700, 690, 720, 1000, 1050, 1100, 1500, 2000, 0]
    /// Plies the review flagged, with the loss in win-% points.
    private static let flagged: [Int: (MoveClass, Double)] = [
        8: (.inaccuracy, 6), 18: (.blunder, 31), 19: (.brilliant, 0), 24: (.mistake, 12), 28: (.blunder, 24), 31: (.great, 0),
    ]
    /// The better move before a flagged ply (UCI), where the engine disagreed with the game.
    private static let alternatives: [Int: [String]] = [8: ["g8f6"], 18: ["b8d7"], 24: ["f8e7", "e7d8", "d7d1"], 28: ["e7d8", "f8e7", "d7d1"]]

    private static func entries(_ game: Game, _ path: [Int]) -> [Int: ReviewEntry] {
        var out: [Int: ReviewEntry] = [:]
        let last = path.count - 1
        for (i, id) in path.enumerated() {
            let pos = game.nodes[id].position
            let eval: Eval = i == last ? .checkmate(winner: .white) : .cp(cp[min(i, cp.count - 1)])
            var best: String?
            var pv: [String] = []
            if i < last {
                let played = (i + 1...min(last, i + 5)).compactMap { game.nodes[path[$0]].move?.uci }
                best = played.first
                pv = played
                if let alts = alternatives[i + 1], let alt = alts.first(where: { pos.move(fromUCI: $0) != nil }) {
                    best = alt; pv = [alt]
                }
            }
            var e = ReviewEntry(eval: eval, best: best, depth: 18, pv: pv)
            if i > 0, let f = flagged[i] { e.cls = f.0; e.loss = f.1 } else if i > 0 { e.loss = 0 }
            out[id] = e
        }
        return out
    }

    private static func script(_ game: Game, _ path: [Int]) -> VideoScript {
        let json = """
        {"title": "Morphy's Opera Box: never leave the king in the middle",
         "intro": "Paris, 1858. Paul Morphy sits in a box at the opera against a duke and a count, playing a Philidor Defense. What happens next is one of the most famous games ever played.",
         "segments": [
          {"until": "5...dxe5", "pace": "quick", "chapter": "The opening",
           "say": "Morphy opens with the king's pawn and the Duke answers with the Philidor. A few early trades, and the queens come out."},
          {"until": "7...Qe7", "pace": "normal", "chapter": "Pressure",
           "say": "White pins the knight, eyes f7 and b7 at the same time, and Black can only defend.",
           "arrows": ["b3b7", "c4f7"], "circles": ["f7", "b7"]},
          {"until": "9...b5", "pace": "slow", "ask": true, "chapter": "The blunder",
           "say": "And here Black grabs space with b5, walking straight into a sacrifice. Developing the knight was the safe way.",
           "reaction": "Oof.", "arrows": ["c3b5"], "circles": ["e8"],
           "whatIf": {"from": "before", "title": "Instead: knight d7", "steps": [
             {"say": "Knight d7 brings a piece into the game and covers b6 and f6.", "play": ["Nbd7"], "arrows": ["b8d7"]},
             {"say": "Now White has nothing quick, and Black can castle soon.", "play": ["Rd1"], "circles": ["e8"]}]}},
          {"until": "11. Bxb5+", "pace": "slow", "chapter": "The sacrifice",
           "say": "Morphy gives up a whole knight to tear open the b-file. Black takes, and the bishop comes with check.",
           "reaction": "Brilliant!", "arrows": ["c4b5"], "circles": ["e8"]},
          {"until": "13...Rxd7", "pace": "normal",
           "say": "Black blocks, but every white piece is attacking and every black piece is stuck at home."},
          {"until": "14...Qe6", "pace": "slow", "ask": true, "reaction": "Doomed.",
           "say": "Offering a queen trade only speeds up the end."},
          {"until": "17. Rd8#", "pace": "quick", "chapter": "The finish", "reaction": "Checkmate!",
           "say": "The queen sacrifice drags the knight away, and the rook delivers a beautiful mate."}
         ],
         "outro": "A masterclass in development, tempo and attack. Count your developed pieces before you grab a pawn.",
         "takeaways": ["Develop every piece before grabbing space.", "Open lines are worth a piece when the enemy king is in the middle.", "Trade pieces only when it helps your plan, not to relieve pressure."]}
        """
        let parsed = VideoScript.parse(json, style: .calm)!
        let sans = path.dropFirst().map { game.nodes[$0].san }
        let line = LessonLine(start: game.nodes[path[0]].position, sans: Array(sans), firstPly: game.nodes[path[1]].ply)
        return VideoScript.grounded(parsed, line: line, allowed: Grounding.allowed(sans), questionPlies: [18, 28])
    }
}
