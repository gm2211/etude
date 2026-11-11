import Foundation
import ChessCore

/// The game's video script: the AI's when it is done, else one written from the review.
extension AppModel {
    /// The grounded AI script, or `ScriptWriter`'s from the review. Nil without a finished review.
    func videoScript() -> VideoScript? {
        guard review.hasResults, !review.running else { return nil }
        if case .done(let s)? = review.video.state { return s }
        let path = review.path.filter { game.nodes.indices.contains($0) }
        guard path.count > 1 else { return nil }
        let line = LessonLine(start: game.nodes[path[0]].position, sans: path.dropFirst().map { game.nodes[$0].san },
                              firstPly: game.nodes[path[1]].ply)
        let moments: [ScriptMoment] = review.momentPicks().compactMap { pick in
            let id = review.path[pick.index]
            guard game.nodes.indices.contains(id), let pid = game.nodes[id].parent, let move = game.nodes[id].move,
                  let e = review.entries[id] else { return nil }
            let prev = review.entries[pid]
            return ScriptMoment(ply: game.nodes[id].ply, side: game.nodes[pid].position.turn, severity: e.cls?.severity ?? 0,
                                classification: e.cls?.name ?? "turning point",
                                best: prev?.best == move.uci ? [] : (prev?.pv ?? []), refutation: e.pv)
        }
        var h = SummaryFacts(moves: [], evals: [])
        h.setHeaders(from: game)
        return ScriptWriter.script(line: line, moments: moments, white: h.white, black: h.black, opening: h.opening,
                                   result: h.result, style: AIVideoScript.style)
    }

    /// The script compiled to cues with estimated timings, for the summary card and the player.
    func videoPlan() -> VideoPlan? { videoScript().map(VideoPlan.init(script:)) }

    /// "Find a better move" at `id` when the move leading there was an error by the side that played it.
    func quiz(at id: Int) -> GameVideo.Quiz? {
        guard game.nodes.indices.contains(id), let e = review.entries[id], e.cls?.isError == true, let pid = game.nodes[id].parent,
              let move = game.nodes[id].move, let prev = review.entries[pid], let best = prev.best, best != move.uci,
              game.nodes[pid].position.move(fromUCI: best) != nil else { return nil }
        return GameVideo.Quiz(parentID: pid, side: game.nodes[pid].position.turn, best: best, bestEval: prev.eval,
                              bestLine: prev.pv, played: move.uci, refutation: e.pv)
    }

    /// The names, ratings, event and opening for the intro card, and the takeaways and accuracies for the outro.
    func videoFacts(_ script: VideoScript) -> GameVideo.Facts {
        var h = SummaryFacts(moves: [], evals: [])
        h.setHeaders(from: game)
        let s = review.summary(game: game)
        return GameVideo.Facts(title: script.title, white: h.white ?? "White", black: h.black ?? "Black",
                               whiteElo: h.whiteElo, blackElo: h.blackElo, event: h.event, opening: h.opening,
                               result: h.result, takeaways: script.takeaways,
                               whiteAccuracy: s.white.accuracy, blackAccuracy: s.black.accuracy)
    }

    /// The node the video card's thumbnail shows: the position after the first question's move, else the middle.
    func videoThumbnailNode(_ plan: VideoPlan) -> Int? {
        let path = review.path.filter { game.nodes.indices.contains($0) }
        guard path.count > 1 else { return nil }
        let firstPly = game.nodes[path[1]].ply
        let ply = plan.script.segments.first { $0.ask }?.to ?? (firstPly + path.count / 2)
        return path[min(max(ply - firstPly + 1, 0), path.count - 1)]
    }

    /// Opens the video at chapter `chapter` (clicking a chapter while it is open jumps there).
    func startVideo(atChapter chapter: Int = 0) {
        guard canPlayLessons, !hidesEvaluation else { return }
        if let v = video {
            v.start(atChapter: chapter)
            return
        }
        guard let plan = videoPlan() else { return }
        let path = review.path.filter { game.nodes.indices.contains($0) }
        guard path.count > 1 else { return }
        clearLessonFocus()
        lessonPlayer = nil
        let v = GameVideo(plan: plan, nodes: path, firstPly: game.nodes[path[1]].ply, facts: videoFacts(plan.script), app: self)
        video = v
        if showInspector { inspectorHiddenForWatch = true; showInspector = false }
        v.start(atChapter: chapter)
    }

    /// A move made on the board: a try at the open question, otherwise a real move.
    func boardMove(_ m: Move) {
        if let v = video, v.acceptsMove { v.submit(m); return }
        play(m)
    }

    /// The video owns the board; engine lines and arrows stay away so they can't give a question's answer away.
    var quizHidesEngine: Bool { video != nil }
}
