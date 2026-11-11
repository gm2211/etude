import SwiftUI
import AppKit
import ChessCore

/// Headless playback simulation: `Etude --simulate-video` drives a real `GameVideo` over the snapshot fixture with the
/// narrator muted and every wait scaled down, and checks what a viewer would see. Prints PASS/FAIL per check.
@MainActor
enum SimulationRunner {
    static var results: [(String, Bool, String)] = []

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append((name, ok, detail))
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var done = false
        Task { @MainActor in
            await simulate()
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        let failed = results.filter { !$0.1 }
        print("\nSUMMARY: \(results.count - failed.count)/\(results.count) passed" + (failed.isEmpty ? "" : ", FAILED: " + failed.map(\.0).joined(separator: "; ")))
        return failed.isEmpty
    }

    private static func wait(until cond: () -> Bool, timeout: Double = 20) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private static func simulate() async {
        GameVideo.holdScale = 0.02
        GameVideo.muted = true
        let model = AppModel(headless: true)
        Fixture.install(into: model)
        model.showInspector = true
        guard let plan = model.videoPlan() else { check("plan builds", false); return }
        check("plan builds", plan.cues.count > 20, "\(plan.cues.count) cues, \(plan.chapters.count) chapters")

        // 1. Full hands-free play.
        var finished: [Int] = []
        var failures: [String] = []
        var phases: [Int: [String]] = [:]
        var asksVisited: [Int] = []
        model.startVideo()
        guard let v = model.video else { check("startVideo opens the video", false); return }
        check("startVideo opens the video and puts the side panel away", !model.showInspector && model.inspectorHiddenForWatch && v.isPlaying)
        let cues = v.cues
        v.onCueFinished = { i in
            finished.append(i)
            if let f = expectation(model, v, i) { failures.append("cue \(i) \(cues[i].kind): \(f)") }
        }
        // `onCueFinished` is set after the first cue may have started; replay from the start for a clean run.
        v.start(atChapter: 0)
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                let i = v.index
                if cues.indices.contains(i), cues[i].kind == .ask {
                    var tag = "\(v.phase)"
                    if v.countdown != nil { tag += "+countdown" }
                    if !v.previewMoves.isEmpty { tag += "+preview" }
                    if phases[i]?.last != tag { phases[i, default: []].append(tag) }
                    if !asksVisited.contains(i) { asksVisited.append(i) }
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        let reachedEnd = await wait(until: { v.finished })
        poller.cancel()
        check("hands-free run reaches the end", reachedEnd, "visited \(finished.count) of \(cues.count)")
        check("every cue visited in order", finished == Array(0..<cues.count), finished == Array(0..<cues.count) ? "" : "got \(finished.prefix(12))")
        check("board and overlay match every cue as it ends", failures.isEmpty, failures.prefix(3).joined(separator: " | "))
        check("finishing the last cue stops playing", !v.isPlaying && v.finished)
        let askIdx = cues.indices.filter { cues[$0].kind == .ask }
        for i in askIdx {
            let p = phases[i] ?? []
            let counts = p.contains { $0.contains("asking") && $0.contains("countdown") }
            let reveal = p.contains { $0.contains("reveal") && $0.contains("preview") }
            check("ask at cue \(i): hands-free counts down, reveals, continues", counts && reveal && finished.contains(i + 1), p.joined(separator: " > "))
        }
        let excEnters = cues.indices.filter { if case .excursionEnter = cues[$0].kind { true } else { false } }
        check("fixture has what-if excursions", !excEnters.isEmpty, "\(excEnters.count)")

        // 2. Ask, not hands-free: stops and waits.
        v.onCueFinished = nil
        if let a = askIdx.first {
            v.show(a)
            let idxBefore = v.index
            try? await Task.sleep(for: .milliseconds(400))
            check("paused on an ask: question stays open, no countdown, stays put",
                  v.index == idxBefore && v.phase == .asking && v.countdown == nil && !v.isPlaying && v.quiz != nil)
            check("ask accepts a try on the board", v.acceptsMove && model.currentID == v.quiz?.parentID)
            check("eval bar shows the position before the error while asking", v.barDimmed && v.barEval == model.review.entries[v.quiz!.parentID]?.eval)
            // Skip
            v.resolveQuestion(reveal: false)
            let moved = await wait(until: { v.index > a })
            check("Skip continues past the question", moved && v.isPlaying)
            v.pause()
            check("pause stops playing", !v.isPlaying)
            // Show me
            v.show(a)
            v.resolveQuestion(reveal: true)
            let revealed = await wait(until: { v.phase == .reveal }, timeout: 2)
            let past = await wait(until: { v.index > a })
            check("Show me reveals the better move then continues", revealed && past)
            v.pause()
        }

        // 3. Seeking and chapters.
        var seekOK = true
        for (i, c) in v.chapters.enumerated() {
            v.seek(toCue: c.seekCue)
            if v.index != c.seekCue || v.chapterIndex != i { seekOK = false; print("   chapter \(i): index \(v.index) chapterIndex \(v.chapterIndex), wanted \(c.seekCue)") }
        }
        check("seek to each chapter lands on its cue", seekOK)
        v.seek(toCue: 0)
        var nextOK = true
        for i in 1..<v.chapters.count {
            v.nextChapter()
            if v.index != v.chapters[i].seekCue { nextOK = false }
        }
        v.nextChapter()
        check("next chapter walks the chapters and stops at the last", nextOK && v.chapterIndex == v.chapters.count - 1)
        let last = v.chapters.count - 1
        v.seek(toCue: v.chapters[last].seekCue + 4)
        v.previousChapter()
        let restart = v.index == v.chapters[last].seekCue
        v.previousChapter()
        check("previous chapter restarts the chapter, then goes back", restart && v.index == v.chapters[last - 1].seekCue)
        v.start(atChapter: 2)
        check("start(atChapter:) while open plays from that chapter", v.index == v.chapters[2].seekCue && v.isPlaying)
        v.pause()

        // 4. Step with the arrows; scrubbing.
        v.show(5)
        v.next(); let n = v.index == 6
        v.previous()
        check("next/previous step one cue", n && v.index == 5 && !v.isPlaying)
        v.beginScrub(); v.scrub(toTime: v.totalTime * 0.5); v.endScrub()
        check("scrubbing lands on the cue at that time", abs(v.starts[v.index] - v.totalTime * 0.5) < v.durations[v.index] + 0.001 && !v.isPlaying)

        // 5. Speed.
        v.cycleSpeed(); let s1 = v.speed
        v.cycleSpeed(); v.cycleSpeed(); v.cycleSpeed()
        check("speed cycles 1x > 1.25x > 1.5x > 2x > 1x", s1 == 1.25 && v.speed == 1)
        GameVideo.holdScale = 0.06
        func timeCues(speed: Double) async -> Double {
            v.speed = speed
            v.start(atChapter: 0)
            v.pause()
            v.seek(toCue: 1)
            let t0 = ContinuousClock.now
            v.play()
            _ = await wait(until: { v.index >= 5 || v.finished })
            let d = ContinuousClock.now - t0
            v.pause()
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let t1 = await timeCues(speed: 1), t2 = await timeCues(speed: 2)
        v.speed = 1
        check("2x plays the same cues in under 70% of the time", t2 < t1 * 0.7, String(format: "1x %.3fs, 2x %.3fs", t1, t2))
        GameVideo.holdScale = 0.02

        // 6. Navigating away closes the video; closing restores the inspector.
        v.show(3)
        let node = model.currentID
        model.goto(model.game.nodes[node].parent ?? 0)
        check("navigating elsewhere closes the video", model.video == nil)
        check("... and brings the side panel back", model.showInspector)
        model.startVideo(atChapter: 1)
        let open = model.video != nil && !model.showInspector
        let idx = model.video?.index ?? -1
        model.closeLesson()
        try? await Task.sleep(for: .milliseconds(150))
        check("closeLesson closes the video and restores the inspector", open && model.video == nil && model.showInspector && !model.inspectorHiddenForWatch)
        _ = idx
    }

    /// What the board and overlay must look like once cue `i` has played; nil when they do.
    private static func expectation(_ model: AppModel, _ v: GameVideo, _ i: Int) -> String? {
        let c = v.cues[i]
        let cur = model.currentID
        switch c.kind {
        case .intro:
            return cur == v.nodes[0] ? nil : "board not at the start"
        case .move(let ply):
            if cur != v.node(atPly: ply) { return "board at \(cur), wanted \(v.node(atPly: ply))" }
            if !v.previewMoves.isEmpty || v.excursionTitle != nil { return "left over preview/excursion" }
        case .marks:
            if cur != v.node(atPly: c.ply) { return "board not on the game position" }
            if v.arrows.count != c.arrows.count || v.circles != c.circles { return "marks missing" }
        case .ask:
            let want = model.quiz(at: v.node(atPly: c.ply))?.parentID ?? cur
            if cur != want { return "board not on the question position" }
            if v.phase != .playing || !v.previewMoves.isEmpty { return "question still open" }
        case .excursionEnter(let root):
            let want = root == .before ? v.node(atPly: c.ply - 1) : v.node(atPly: c.ply)
            if cur != want || v.excursionTitle != c.title || !v.previewMoves.isEmpty { return "not at the excursion root" }
        case .excursionStep:
            var j = i
            while j > 0, !{ if case .excursionEnter = v.cues[j].kind { return true } else { return false } }() { j -= 1 }
            let want = v.cues[j...i].flatMap(\.moves)
            if v.previewMoves != want || v.excursionTitle == nil { return "preview \(v.previewMoves) wanted \(want)" }
        case .excursionExit:
            if cur != v.node(atPly: c.ply) { return "board did not return to the game node" }
            if !v.previewMoves.isEmpty || v.excursionTitle != nil || v.barDimmed { return "excursion state left over" }
        case .outro:
            if v.card != .outro || cur != v.nodes[v.nodes.count - 1] { return "outro card/board" }
        }
        return nil
    }
}
