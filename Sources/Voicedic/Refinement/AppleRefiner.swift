import Foundation
import FoundationModels

/// Cleanup with Apple's on-device Foundation Model. Fully local, no download.
actor AppleRefiner: Refiner {
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    /// A fresh, pre-warmed session for the next request. Sessions keep a transcript,
    /// so each dictation gets its own.
    private var spare: (session: LanguageModelSession, style: RefinementStyle)?

    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use on-device cleanup."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "Apple's on-device model is still downloading."
        case .unavailable:
            return "Apple's on-device model is unavailable."
        }
    }

    func prepare(style: RefinementStyle) async {
        guard model.availability == .available else { return }
        if spare?.style != style {
            spare = (makeSession(style: style), style)
        }
    }

    func refine(_ request: RefinementRequest, style: RefinementStyle) async throws -> String {
        if let message = Self.availabilityMessage {
            throw RefinementError.unavailable(message)
        }

        let session: LanguageModelSession
        if let spare, spare.style == style {
            session = spare.session
        } else {
            session = makeSession(style: style)
        }
        spare = (makeSession(style: style), style)

        let words = request.transcript.split(whereSeparator: \.isWhitespace).count
        let options = GenerationOptions(
            samplingMode: .greedy,
            maximumResponseTokens: max(256, words * 4)
        )
        let response = try await session.respond(to: RefinementPrompt.userMessage(for: request), options: options)
        return response.content
    }

    private func makeSession(style: RefinementStyle) -> LanguageModelSession {
        let session = LanguageModelSession(model: model, instructions: RefinementPrompt.instructions(style: style))
        session.prewarm()
        return session
    }
}
