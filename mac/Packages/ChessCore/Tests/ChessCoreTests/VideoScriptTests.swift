import XCTest
@testable import ChessCore

final class VideoScriptTests: XCTestCase {
    typealias S = VideoScript
    let opera = PGN.parse(MomentPickerTests.opera)[0].game.mainlineSAN
    var operaLine: LessonLine { LessonLine(start: .start, sans: opera) }
    let scholar = ["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#"]
    var scholarLine: LessonLine { LessonLine(start: .start, sans: scholar) }

    func testParseLenient() {
        let text = """
        Sure!
        ```json
        {"title": "T", "intro": "Hi.", "outro": "Bye.", "takeaways": "One rule.",
         "segments": [
          {"until": "2.Nf3", "say": "Opening.", "pace": "fast", "chapter": "The opening", "ask": "true"},
          {"move": "6...Nf6", "say": "Slow.", "pace": "slow", "circles": ["f6", "zz"], "arrows": ["b5e8"],
           "whatIf": {"rewind": "after", "title": "But", "steps": [{"say": "Look.", "line": ["7. Qb3 Qe7"]}, {"text": ""}]}},
          {"say": "no until"}
         ]}
        ```
        """
        let v = S.parse(text, style: .hype)!
        XCTAssertEqual(v.style, .hype)
        XCTAssertEqual(v.segments.count, 2)
        XCTAssertEqual(v.segments[0].pace, .quick)
        XCTAssertTrue(v.segments[0].ask)
        XCTAssertEqual(v.segments[0].until, "2.Nf3")
        XCTAssertEqual(v.segments[1].until, "6...Nf6")
        XCTAssertEqual(v.segments[1].circles, [Sq.parse("f6")!])
        XCTAssertEqual(v.segments[1].whatIf?.root, .after)
        XCTAssertEqual(v.segments[1].whatIf?.steps.count, 1)
        XCTAssertEqual(v.segments[1].whatIf?.steps[0].moves, ["Qb3", "Qe7"])
        XCTAssertEqual(v.takeaways, ["One rule."])
        XCTAssertNil(S.parse("no json", style: .calm))
        XCTAssertNil(S.parse(#"{"segments": []}"#, style: .calm))
    }

    func testGroundingResolvesOrdersAndAppendsTail() {
        let segs = [S.Segment(say: "a", until: "2. Nf3"), S.Segment(say: "dup", until: "1. e4"),
                    S.Segment(say: "bad", until: "99. Qa1"), S.Segment(say: "b", until: "6...Nf6")]
        let g = S.grounded(S(style: .calm, title: "", intro: "", segments: segs, outro: "", takeaways: []),
                           line: operaLine, allowed: [], questionPlies: [])
        XCTAssertEqual(g.segments.map(\.from), [1, 4, 13])
        XCTAssertEqual(g.segments.map(\.to), [3, 12, 33])          // the tail is appended; 17. Rd8# is ply 33
        XCTAssertEqual(g.segments[2].pace, .quick)
        XCTAssertEqual(g.title, "Game review")
        XCTAssertTrue(g.segments.allSatisfy { $0.until == nil })
    }

    func testAskFilteringAndCap() {
        let segs = (1...5).map { S.Segment(say: "", pace: .slow, ask: true, until: "\($0 * 4)") }
        let g = S.grounded(S(style: .calm, title: "t", intro: "", segments: segs, outro: "", takeaways: []),
                           line: operaLine, allowed: [], questionPlies: [8, 12, 16, 20])
        XCTAssertEqual(g.segments.map(\.ask), [false, true, true, true, false, false])
        XCTAssertEqual(g.segments[1].pace, .slow)                 // 4 plies stay slow
    }

    func testLongSlowSegmentBecomesNormal() {
        let g = S.grounded(S(style: .calm, title: "t", intro: "", segments: [S.Segment(pace: .slow, until: "14")], outro: "", takeaways: []),
                           line: operaLine, allowed: [], questionPlies: [])
        XCTAssertEqual(g.segments[0].pace, .normal)
    }

    func testExcursionTruncatesAtIllegalMoveAndUsesUCI() {
        // Root "before" ply 12 (6...Nf6): Black to move.
        let steps = [S.Step(say: "Better.", moves: ["Qf6", "Bxf7+"]), S.Step(say: "Bad.", moves: ["Qh8"]), S.Step(say: "Never.", moves: ["a6"])]
        let seg = S.Segment(say: "x", pace: .slow, whatIf: .init(root: .before, title: "Instead: 6...Qf6", steps: steps), until: "6...Nf6")
        let g = S.grounded(S(style: .calm, title: "t", intro: "", segments: [seg], outro: "", takeaways: []),
                           line: operaLine, allowed: [], questionPlies: [])
        let e = g.segments[0].whatIf!
        XCTAssertEqual(e.steps.count, 1)
        XCTAssertEqual(e.steps[0].moves, ["d8f6", "c4f7"])
        XCTAssertEqual(e.title, "Instead: 6...Qf6")                 // own move cited, so kept
        let none = S.Segment(say: "x", whatIf: .init(root: .after, title: "t", steps: [S.Step(say: "z", moves: ["Qh8"])]), until: "6...Nf6")
        let g2 = S.grounded(S(style: .calm, title: "t", intro: "", segments: [none], outro: "", takeaways: []),
                            line: operaLine, allowed: [], questionPlies: [])
        XCTAssertNil(g2.segments[0].whatIf)
    }

    func testProsePruningKeepsSpokenMoves() {
        let seg = S.Segment(say: "Queen b3 hits f7. Then 9. Qxh7 wins. Black plays Nf6.", until: "6...Nf6")
        let g = S.grounded(S(style: .calm, title: "Qa4 here", intro: "Try 12. Qh5 now. Welcome.", segments: [seg], outro: "", takeaways: ["See Qxh7", "Keep calm."]),
                           line: operaLine, allowed: [], questionPlies: [])
        XCTAssertEqual(g.segments[0].say, "Queen b3 hits f7. Black plays Nf6.")   // Nf6 is the segment's own move
        XCTAssertEqual(g.intro, "Welcome.")
        XCTAssertEqual(g.takeaways, ["Keep calm."])
        XCTAssertEqual(g.title, "Game review")
    }

    func testScriptWriterOnScholarsMateBlunder() {
        let moment = ScriptMoment(ply: 6, side: .black, severity: 3, classification: "blunder", best: ["g7g6"], refutation: ["h5f7"])
        for style in S.Style.allCases {
            let s = ScriptWriter.script(line: scholarLine, moments: [moment], white: "Ann", black: "Bob",
                                        opening: "Bishop's Opening (C23)", result: "1-0", style: style)
            var next = 1
            for seg in s.segments { XCTAssertEqual(seg.from, next); XCTAssertGreaterThanOrEqual(seg.to, seg.from); next = seg.to + 1 }
            XCTAssertEqual(next, 8)
            XCTAssertEqual(s.chapters.first?.title, "The opening")
            XCTAssertEqual(s.chapters.last?.title, "The finish")
            let ask = s.segments.first { $0.ask }
            XCTAssertEqual(ask?.to, 6)
            XCTAssertEqual(ask?.pace, .slow)
            XCTAssertEqual(ask?.chapter, "The turning point")
            XCTAssertEqual(ask?.whatIf?.root, .after)
            XCTAssertEqual(s.segments.last?.reaction, "Checkmate!")
            XCTAssertTrue(s.intro.contains("Ann") && s.intro.contains("Bishop's Opening"))
            XCTAssertFalse(s.intro.contains("C23"))
            let g = S.grounded(s, line: scholarLine, allowed: [], questionPlies: [6])
            XCTAssertEqual(g, s, "\(style)")
        }
    }

    func testScriptWriterOnOperaGameIsFixedPoint() {
        let ms = [ScriptMoment(ply: 12, side: .black, severity: 1, classification: "inaccuracy", best: ["d8f6"], refutation: ["f3b3", "d8e7", "b1c3", "c7c6"]),
                  ScriptMoment(ply: 17, side: .white, severity: 0, classification: "ok", best: [], refutation: [])]
        let s = ScriptWriter.script(line: operaLine, moments: ms, white: nil, black: nil, opening: nil, result: "1-0", style: .calm)
        var next = 1
        for seg in s.segments { XCTAssertEqual(seg.from, next); next = seg.to + 1 }
        XCTAssertEqual(next, 34)
        XCTAssertEqual(s.segments.filter(\.ask).count, 1)
        XCTAssertTrue(s.segments.count <= S.maxSegments)
        XCTAssertEqual(S.grounded(s, line: operaLine, allowed: [], questionPlies: [12]), s)
    }

    func testPromptsNameNobody() {
        for style in S.Style.allCases {
            for tool in [true, false] {
                let t = ScriptPrompt.system(style: style, tool: tool).lowercased()
                for bad in ["agadmator", "gotham", "levy", "eisingerich"] { XCTAssertFalse(t.contains(bad)) }
                XCTAssertLessThan(t.split(separator: " ").count, 1800)
            }
        }
        let f = SummaryFacts(moves: scholar, evals: [], moments: [SummaryMoment(ply: 6, label: "3\u{2026}Nf6", side: .black, classification: "blunder", phase: nil, evalBefore: .cp(0), evalAfter: .cp(-900), tags: [], fenBefore: Position.startFEN, refutation: "", best: "")])
        XCTAssertTrue(ScriptPrompt.user(f, compact: false).contains("Questions may only be asked at: 3\u{2026}Nf6"))
    }
}

final class VideoCuesTests: XCTestCase {
    typealias S = VideoScript

    private func script(_ segs: [S.Segment]) -> S {
        S(style: .calm, title: "T", intro: "Hello.", segments: segs, outro: "Bye.", takeaways: [])
    }

    func testIntroOutroAndQuickSegment() {
        let v = script([S.Segment(from: 1, to: 3, say: "Quick.", pace: .quick, chapter: "The opening")])
        let c = VideoCues.compile(v)
        XCTAssertEqual(c.cues.map(\.kind), [.intro, .move(ply: 1), .move(ply: 2), .move(ply: 3), .outro])
        XCTAssertEqual(c.cues[1].say, "Quick.")                      // said from the first move
        XCTAssertEqual(c.cues[2].say, "")
        XCTAssertEqual(c.cues[0].say, "Hello.")
        XCTAssertEqual(c.cues[4].say, "Bye.")
        XCTAssertEqual(c.chapters.map(\.title), ["The opening"])
        XCTAssertEqual(c.chapters[0].cue, 1)
        XCTAssertEqual(c.chapters[0].seekCue, 0)
        XCTAssertEqual(c.cues[1].chapterStart, 0)
    }

    func testNormalSaysAfterMovesWithMarks() {
        let arrow = GameLesson.Example.Arrow(from: Sq.parse("e2")!, to: Sq.parse("e4")!)
        let v = script([S.Segment(from: 4, to: 5, say: "Said late.", pace: .normal, reaction: "Oof.", arrows: [arrow])])
        let c = VideoCues.compile(v)
        XCTAssertEqual(c.cues.map(\.kind), [.intro, .move(ply: 4), .move(ply: 5), .marks, .outro])
        XCTAssertEqual(c.cues[1].say, "")
        XCTAssertEqual(c.cues[3].say, "Said late.")
        XCTAssertEqual(c.cues[3].reaction, "Oof.")
        XCTAssertEqual(c.cues[3].arrows, [arrow])
        XCTAssertEqual(c.chapters.map(\.title), ["The opening"])      // the first segment always starts a chapter
    }

    func testAskOrder() {
        let v = script([S.Segment(from: 10, to: 12, say: "Blunder.", pace: .slow, ask: true)])
        let c = VideoCues.compile(v)
        XCTAssertEqual(c.cues.map(\.kind), [.intro, .move(ply: 10), .move(ply: 11), .ask, .move(ply: 12), .marks, .outro])
        XCTAssertEqual(c.cues[3].ply, 12)                              // the question is about move 12
        XCTAssertEqual(c.cues[5].say, "Blunder.")
    }

    func testAskOnSinglePlySegmentHasNoMovesBeforeQuestion() {
        let v = script([S.Segment(from: 7, to: 7, say: "x", pace: .normal, ask: true)])
        XCTAssertEqual(VideoCues.compile(v).cues.map(\.kind), [.intro, .ask, .move(ply: 7), .marks, .outro])
    }

    func testWhatIfOrderAndChapters() {
        let exc = S.Excursion(root: .before, title: "Instead", steps: [
            S.Step(say: "One.", moves: ["e2e4"]), S.Step(say: "Two.", moves: ["e7e5", "g1f3"])])
        let v = script([
            S.Segment(from: 1, to: 2, say: "Open.", pace: .quick, chapter: "The opening"),
            S.Segment(from: 3, to: 4, say: "But wait.", pace: .slow, chapter: "The blunder", whatIf: exc),
            S.Segment(from: 5, to: 6, say: "End.", pace: .quick)])
        let c = VideoCues.compile(v)
        XCTAssertEqual(c.cues.map(\.kind), [
            .intro, .move(ply: 1), .move(ply: 2),
            .move(ply: 3), .move(ply: 4), .marks,
            .excursionEnter(root: .before), .excursionStep(index: 0), .excursionStep(index: 1), .excursionExit,
            .move(ply: 5), .move(ply: 6), .outro])
        XCTAssertEqual(c.cues[6].title, "Instead")
        XCTAssertEqual(c.cues[8].moves, ["e7e5", "g1f3"])
        XCTAssertEqual(c.chapters.map(\.title), ["The opening", "The blunder"])
        XCTAssertEqual(c.chapters.map(\.cue), [1, 3])
        XCTAssertEqual(c.chapters.map(\.seekCue), [0, 3])
        XCTAssertEqual(c.chapter(at: 0), 0)
        XCTAssertEqual(c.chapter(at: 2), 0)
        XCTAssertEqual(c.chapter(at: 5), 1)
        XCTAssertEqual(c.chapter(at: 12), 1)
    }
}
