import Foundation
import Observation
import ChessCore

/// The AI's video script for the whole reviewed game: one continuous commentary track (see `VideoScript`).
/// Owned by `ReviewModel` next to the lesson, so it is cleared whenever the review restarts or another game loads.
@Observable @MainActor
final class AIVideoScript {
    enum State: Equatable {
        case loading
        case done(VideoScript)
        case needsSignIn
        case failed(String)
    }

    private static let styleKey = "video.style"

    /// The presenter's style, saved across launches (calm unless chosen).
    static var style: VideoScript.Style {
        get { UserDefaults.standard.string(forKey: styleKey).flatMap(VideoScript.Style.init(rawValue:)) ?? .calm }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    private(set) var state: State?

    var phase: AIJobPhase {
        switch state {
        case nil: .idle
        case .loading?: .running
        case .failed?: .failed
        case .needsSignIn?: .needsSignIn
        case .done?: .done
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    private let hub: AIHub

    init(hub: AIHub = .shared) { self.hub = hub }

    func reset() {
        task?.cancel(); task = nil
        state = nil
    }

    /// A finished script given ready-made (the headless snapshot renderer).
    func inject(_ script: VideoScript) { state = .done(script) }

    /// Shown when a review finishes with no AI provider set up.
    func markNeedsSetup() { if state == nil { state = .needsSignIn } }

    /// Starts writing the script; the returned task finishes when it is done (or failed).
    @discardableResult
    func generate(game: Game, review: ReviewModel, force: Bool = false) -> Task<Void, Never>? {
        guard force || state != .loading, review.path.count > 1 else { return nil }
        task?.cancel()
        let input = AISummary.input(game: game, review: review)
        let line = LessonLine(start: input.facts.start, sans: input.facts.moves, firstPly: game.nodes[review.path[1]].ply)
        var questions = Set<Int>()
        for pick in review.momentPicks() {
            let id = review.path[pick.index]
            if review.entries[id]?.cls?.isError == true { questions.insert(game.nodes[id].ply) }
        }
        let style = Self.style
        state = .loading
        let t = Task { await run(input, line: line, questions: questions, style: style) }
        task = t
        return t
    }

    /// The provider or model changed: a script in flight, failed or waiting on a sign-in starts over with the new one.
    /// A finished script is left alone.
    func providerChanged(game: Game, review: ReviewModel) {
        guard AIRetry.restartsOnSwitch(phase), !review.running else { return }
        generate(game: game, review: review, force: true)
    }

    private func run(_ input: AISummary.Input, line: LessonLine, questions: Set<Int>, style: VideoScript.Style) async {
        do {
            if !hub.isReady { await hub.refresh(hub.selected) }
            guard hub.isReady else { state = .needsSignIn; return }
            let compactFirst = hub.selected == .apple
            let answer: GroundedAnswer
            do {
                answer = try await attempt(input, style: style, compact: compactFirst, tool: true)
            } catch where !compactFirst && AIToolLoop.isContextLimit(error) {
                answer = try await attempt(input, style: style, compact: true, tool: false)
            }
            if Task.isCancelled { return }
            guard let script = VideoScript.parse(answer.text, style: style) else { state = .failed("The model returned no script."); return }
            let allowed = input.allowed.union(answer.allowed)
            state = .done(VideoScript.grounded(script, line: line, allowed: allowed, questionPlies: questions))
        } catch {
            if Task.isCancelled { return }
            if error is CancellationError || (error as? LLMError) == .canceled {
                if state == .loading { state = nil }
            } else if let e = error as? LLMError, e.needsSignIn {
                state = .needsSignIn
                await hub.refresh(hub.selected)
            } else {
                state = .failed(hub.failureText(for: error))
            }
        }
    }

    private func attempt(_ input: AISummary.Input, style: VideoScript.Style, compact: Bool, tool: Bool) async throws -> GroundedAnswer {
        try await AIToolLoop.run(hub: hub, system: ScriptPrompt.system(style: style, tool: tool),
                                 prompt: ScriptPrompt.user(input.facts, compact: compact),
                                 maxTokens: 4000, allowed: input.allowed, tool: tool, timeout: .lesson)
    }
}
