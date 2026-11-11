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
}
