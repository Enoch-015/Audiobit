import Foundation

enum SpeechEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case kokoro

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .apple: "Mac Voices"
        case .kokoro: "Enhanced Voice — Kokoro"
        }
    }
}

struct SpeechVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let language: String
}

struct SpeechQueueItem: Identifiable, Hashable, Sendable {
    let id: Int
    let text: String
}

enum SpeechPlaybackEvent: Sendable {
    case started
    case chunkStarted(Int)
    case finished
    case failed(String)
}

@MainActor
protocol SpeechEngine: AnyObject {
    var kind: SpeechEngineKind { get }
    var voices: [SpeechVoice] { get }
    var eventHandler: (@MainActor @Sendable (SpeechPlaybackEvent) -> Void)? { get set }

    func prepare() async throws
    func play(text: String, voiceIdentifier: String?, rate: Float) async throws
    func preload(text: String, voiceIdentifier: String?, rate: Float)
    func pause()
    func resume()
    func stop()
}

@MainActor
protocol RollingSpeechEngine: SpeechEngine {
    func playRolling(
        items: [SpeechQueueItem],
        voiceIdentifier: String?,
        rate: Float
    ) async throws
}

enum SpeechEngineError: LocalizedError {
    case modelNotInstalled
    case voiceUnavailable
    case audioBuffer
    case unsupportedMac
    case performanceBelowRealtime(Double)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: "Kokoro Enhanced Voice is not installed."
        case .voiceUnavailable: "The selected enhanced voice is unavailable."
        case .audioBuffer: "Enhanced Voice could not prepare an audio buffer."
        case .unsupportedMac: "Kokoro requires an Apple Silicon Mac."
        case .performanceBelowRealtime(let factor):
            "Kokoro generated audio at \(String(format: "%.2f", factor))× real time, which is too slow for reliable reading."
        }
    }
}
