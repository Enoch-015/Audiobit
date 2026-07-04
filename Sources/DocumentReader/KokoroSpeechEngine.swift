@preconcurrency import AVFoundation
import Foundation
@preconcurrency import KokoroSwift
@preconcurrency import MLX
@preconcurrency import MLXUtilsLibrary

private actor KokoroSynthesizer {
    private let tts: KokoroTTS
    private let voiceArrays: [String: MLXArray]

    init(modelURL: URL, voicesURL: URL) throws {
        tts = KokoroTTS(modelPath: modelURL)
        guard let voices = NpyzReader.read(fileFromPath: voicesURL), !voices.isEmpty else {
            throw SpeechEngineError.voiceUnavailable
        }
        voiceArrays = voices
    }

    func voiceNames() -> [String] {
        voiceArrays.keys
            .map { String($0.split(separator: ".")[0]) }
            .sorted()
    }

    func generate(text: String, voiceName: String, speed: Float) throws -> [Float] {
        guard let voice = voiceArrays[voiceName + ".npy"] else {
            throw SpeechEngineError.voiceUnavailable
        }
        let language: Language = voiceName.first == "a" ? .enUS : .enGB
        return try tts.generateAudio(
            voice: voice,
            language: language,
            text: text,
            speed: speed
        ).0
    }

    func benchmark(voiceName: String) throws -> Double {
        _ = try generate(
            text: "Preparing enhanced speech.",
            voiceName: voiceName,
            speed: 1
        )
        let start = Date()
        let samples = try generate(
            text: "This performance check confirms that enhanced speech can generate audio faster than it is played, keeping long documents smooth and responsive.",
            voiceName: voiceName,
            speed: 1
        )
        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        let audioDuration = Double(samples.count) / Double(KokoroTTS.Constants.samplingRate)
        return audioDuration / elapsed
    }
}

@MainActor
final class KokoroSpeechEngine: RollingSpeechEngine {
    let kind = SpeechEngineKind.kokoro
    var eventHandler: (@MainActor @Sendable (SpeechPlaybackEvent) -> Void)?
    private(set) var voices: [SpeechVoice] = []

    private let modelManager: KokoroModelManager
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var synthesizer: KokoroSynthesizer?
    private var generationTask: Task<Void, Never>?
    private var generationID = UUID()
    private var pendingItems: [SpeechQueueItem] = []
    private var producerFinished = false
    private var isRollingPlayback = false
    private var audioIsConfigured = false
    private let rollingBufferLimit = 6
    private let rollingStartThreshold = 2

    init(modelManager: KokoroModelManager = .shared) {
        self.modelManager = modelManager
        audioEngine.attach(playerNode)
    }

    func prepare() async throws {
        guard case .ready = modelManager.state else {
            throw SpeechEngineError.modelNotInstalled
        }
        guard synthesizer == nil else { return }
        #if arch(arm64)
        let modelURL = modelManager.modelURL
        let voicesURL = modelManager.voicesURL
        let created = try await Task.detached(priority: .userInitiated) {
            try KokoroSynthesizer(modelURL: modelURL, voicesURL: voicesURL)
        }.value
        let names = await created.voiceNames()
        guard let benchmarkVoice = names.first(where: { $0 == "af_heart" }) ?? names.first else {
            throw SpeechEngineError.voiceUnavailable
        }
        let realTimeFactor = try await created.benchmark(voiceName: benchmarkVoice)
        guard realTimeFactor > 1 else {
            throw SpeechEngineError.performanceBelowRealtime(realTimeFactor)
        }
        synthesizer = created
        voices = names.map {
            SpeechVoice(
                id: $0,
                name: Self.friendlyName($0),
                language: $0.first == "a" ? "en-US" : "en-GB"
            )
        }
        #else
        throw SpeechEngineError.unsupportedMac
        #endif
    }

    func play(text: String, voiceIdentifier: String?, rate: Float) async throws {
        try await startQueue(
            items: [SpeechQueueItem(id: 0, text: text)],
            voiceIdentifier: voiceIdentifier,
            rate: rate,
            rolling: false
        )
    }

    func playRolling(
        items: [SpeechQueueItem],
        voiceIdentifier: String?,
        rate: Float
    ) async throws {
        try await startQueue(
            items: items,
            voiceIdentifier: voiceIdentifier,
            rate: rate,
            rolling: true
        )
    }

    func preload(text: String, voiceIdentifier: String?, rate: Float) {}

    func renderForExport(
        chunks: [String],
        voiceIdentifier: String?,
        rate: Float,
        destination: URL,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        try await prepare()
        guard let synthesizer, let voice = resolvedVoice(voiceIdentifier) else {
            throw SpeechEngineError.voiceUnavailable
        }
        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else { throw SpeechEngineError.audioBuffer }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)

        for (index, text) in chunks.enumerated() {
            try Task.checkCancellation()
            let samples = try await synthesizer.generate(
                text: text,
                voiceName: voice.id,
                speed: Self.kokoroSpeed(from: rate)
            )
            try Task.checkCancellation()
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ),
                let channel = buffer.floatChannelData?[0]
            else { throw SpeechEngineError.audioBuffer }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { source in
                if let address = source.baseAddress {
                    channel.update(from: address, count: source.count)
                }
            }
            try output.write(from: buffer)
            progress(index + 1, chunks.count)
        }
    }

    func pause() {
        playerNode.pause()
    }

    func resume() {
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        playerNode.play()
    }

    func stop() {
        generationID = UUID()
        generationTask?.cancel()
        generationTask = nil
        pendingItems.removeAll()
        producerFinished = false
        isRollingPlayback = false
        stopPlaybackOnly()
    }

    private func startQueue(
        items: [SpeechQueueItem],
        voiceIdentifier: String?,
        rate: Float,
        rolling: Bool
    ) async throws {
        try await prepare()
        stop()
        guard !items.isEmpty else {
            eventHandler?(.finished)
            return
        }
        guard let synthesizer, let voice = resolvedVoice(voiceIdentifier) else {
            throw SpeechEngineError.voiceUnavailable
        }

        try configureAudioIfNeeded()
        let speed = Self.kokoroSpeed(from: rate)
        let id = UUID()
        generationID = id
        isRollingPlayback = rolling

        generationTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.generationTask = nil
                }
            }

            do {
                for item in items {
                    guard let self else { return }
                    while self.pendingItems.count >= self.rollingBufferLimit {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(20))
                    }

                    let samples = try await synthesizer.generate(
                        text: item.text,
                        voiceName: voice.id,
                        speed: speed
                    )
                    try Task.checkCancellation()
                    guard self.generationID == id else { return }
                    try self.schedule(samples, for: item, generationID: id)
                }

                guard let self, self.generationID == id else { return }
                self.producerFinished = true
                self.startRollingPlaybackIfNeeded()
                if self.pendingItems.isEmpty {
                    self.eventHandler?(.finished)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.eventHandler?(.failed(error.localizedDescription))
            }
        }
    }

    private func configureAudioIfNeeded() throws {
        guard !audioIsConfigured else {
            if !audioEngine.isRunning { try audioEngine.start() }
            return
        }
        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else { throw SpeechEngineError.audioBuffer }
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        try audioEngine.start()
        audioIsConfigured = true
    }

    private func schedule(
        _ samples: [Float],
        for item: SpeechQueueItem,
        generationID: UUID
    ) throws {
        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard
            !samples.isEmpty,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let destination = buffer.floatChannelData?[0]
        else { throw SpeechEngineError.audioBuffer }

        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: source.count)
        }

        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        let queueWasEmpty = pendingItems.isEmpty
        pendingItems.append(item)
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.generationID == generationID else { return }
                self.bufferFinished(itemID: item.id, generationID: generationID)
            }
        }
        if isRollingPlayback {
            if queueWasEmpty {
                eventHandler?(.chunkStarted(item.id))
            }
            startRollingPlaybackIfNeeded()
        } else if queueWasEmpty {
            eventHandler?(.started)
            playerNode.play()
        }
    }

    private func bufferFinished(itemID: Int, generationID: UUID) {
        guard self.generationID == generationID else { return }
        if pendingItems.first?.id == itemID {
            pendingItems.removeFirst()
        } else {
            pendingItems.removeAll { $0.id == itemID }
        }

        if let next = pendingItems.first {
            if isRollingPlayback {
                eventHandler?(.chunkStarted(next.id))
            }
        } else if producerFinished {
            eventHandler?(.finished)
        }
    }

    private func stopPlaybackOnly() {
        playerNode.stop()
        audioEngine.stop()
    }

    private func startRollingPlaybackIfNeeded() {
        guard isRollingPlayback, !playerNode.isPlaying else { return }
        guard producerFinished || pendingItems.count >= rollingStartThreshold else { return }
        playerNode.play()
    }

    private func resolvedVoice(_ identifier: String?) -> SpeechVoice? {
        if let identifier, let selected = voices.first(where: { $0.id == identifier }) {
            return selected
        }
        return voices.first(where: { $0.id == "af_heart" }) ?? voices.first
    }

    private static func kokoroSpeed(from appleStyleRate: Float) -> Float {
        min(1.5, max(0.7, appleStyleRate / 0.5))
    }

    private static func friendlyName(_ identifier: String) -> String {
        identifier
            .split(separator: "_")
            .dropFirst()
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
