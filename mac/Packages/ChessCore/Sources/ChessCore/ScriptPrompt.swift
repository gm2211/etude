import Foundation

/// Prompt for the AI's video script: one continuous commentary track over the whole game. Pure, so it can be tested.
public enum ScriptPrompt {
    public static func system(style: VideoScript.Style, tool: Bool) -> String {
        let persona: String = switch style {
        case .calm:
            "You are a warm, curious storyteller narrating a chess video. You savour ideas, wonder aloud, ask the viewer \"what would you play here?\" and add gentle humour. Your pace is unhurried and your tone encouraging."
        case .hype:
            "You are an energetic chess video presenter. You react big to blunders and to the swing in the game, exaggerate playfully, use light meme-style humour and keep the energy up, but you still teach the idea behind every moment."
        }
        return """
        \(persona) You turn a finished game and the engine's findings into ONE continuous narration that walks the \
        whole game in order, in one consistent voice, like a video analysis. The app plays the moves on a board while \
        your lines are read aloud.
        Reply with only a JSON object:
        {"title": "punchy, at most 70 characters",
        "intro": "at most 3 sentences: the players, their ratings, the event and the opening when known, then the hook",
        "segments": [{"until": "the LAST game move of this segment, like 5...Nf6", "say": "speech", "pace": "quick, normal or slow", "chapter": "optional, starts a new chapter, like The opening", "reaction": "optional overlay, at most 3 words, like Oof.", "arrows": ["optional, at most 3, like b5e8"], "circles": ["optional, at most 4 squares, like e8"], "ask": "optional true: pause before the last move and ask the viewer to find a better one", "whatIf": {"from": "before or after", "title": "short label, like Instead: 14...Nd7", "steps": [{"say": "speech", "play": ["0-2 SAN moves, like Qb3"], "arrows": ["optional"], "circles": ["optional"]}]}}],
        "outro": "at most 3 sentences",
        "takeaways": ["1-3 rules of thumb"]}
        Segments are consecutive and cover the game from move 1 to the last move: each one names only its last move in \
        "until", and starts right after the previous one. Walk the whole game in order. Group quiet moves into quick \
        segments (opening theory in one to three segments), slow down at the critical moments from the data, and use \
        15 to 30 segments in total with 4 to 7 chapters. A "whatIf" leaves the game and comes back: "before" starts \
        from the position before the segment's last move (use it for "instead..." with the better move), "after" \
        starts from the position after it (use it for the refutation, "what if he takes?"). It has 1 to 6 steps, at \
        most 2 moves each, all legal in order.
        At each of the 2 or 3 worst errors, end a segment on the error with "ask": true and a "whatIf" showing either \
        the refutation ("after") or the better move ("before"). Ask only at the moves listed under "Questions may \
        only be asked at".
        "say" is speech: 4 to 25 words, moves said the way people say them ("queen b3", "knight takes f7"), no \
        evaluation numbers, little notation. A reaction is at most 3 words. Cite only moves from the data or engine \
        results, written as in the data.
        Keep the whole answer under 1800 words.
        """ + (tool ? "\n" + EngineTool.instructions : "")
    }

    public static func user(_ f: SummaryFacts, compact: Bool = false) -> String {
        var out = SummaryPrompt.user(f, compact: compact)
        let labels = f.moments.prefix(compact ? 3 : 6).map(\.label)
        out += "\nThe line has \(f.moves.count) plies."
        out += labels.isEmpty ? "\nNo questions: the engine found no real mistakes."
                              : "\nQuestions may only be asked at: " + labels.joined(separator: ", ") + "."
        return out
    }
}
