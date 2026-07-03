@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    let kind = SpeechEngineKind.apple
    var eventHandler: (@MainActor @Sendable (SpeechPlaybackEvent) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var stoppedManually = false

    var voices: [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { SpeechVoice(id: $0.identifier, name: $0.name, language: $0.language) }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare() async throws {}

    func play(text: String, voiceIdentifier: String?, rate: Float) async throws {
        stoppedManually = false
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        }
        eventHandler?(.started)
        synthesizer.speak(utterance)
    }

    func preload(text: String, voiceIdentifier: String?, rate: Float) {}

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        stoppedManually = true
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension AppleSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.stoppedManually else { return }
            self.eventHandler?(.finished)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.stoppedManually = false
        }
    }
}
