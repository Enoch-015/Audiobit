import Foundation

@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isPreparing = false
    @Published private(set) var currentSectionIndex = 0
    @Published private(set) var voices: [SpeechVoice] = []
    @Published var rate: Float = 0.5 {
        didSet {
            handleRateChange(from: oldValue)
        }
    }
    @Published var voiceIdentifier: String? {
        didSet {
            handleVoiceChange(from: oldValue)
        }
    }
    @Published private(set) var engineKind: SpeechEngineKind = .apple
    @Published var fallbackMessage: String?
    var documentFinishedHandler: (@MainActor () -> Void)?

    private let modelManager: KokoroModelManager
    private let appleEngine: AppleSpeechEngine
    private lazy var kokoroEngine = KokoroSpeechEngine(modelManager: modelManager)
    private var activeEngine: any SpeechEngine
    private var content: DocumentContent?
    private var chunks: [(section: Int, text: String)] = []
    private var chunkIndex = 0
    private var manualStop = false
    private var rollingPlaybackActive = false
    private var isPreviewing = false
    private var switchTask: Task<Void, Never>?
    private var exportRenderer: AppleOfflineRenderer?
    private var segmentText: String?
    private var segmentCompletion: (@MainActor () -> Void)?
    private var segmentStarted: (@MainActor () -> Void)?
    private var segmentTask: Task<Void, Never>?
    private var fallbackSegmentText: String?
    private var fallbackSegmentCompletion: (@MainActor () -> Void)?
    private var fallbackSegmentStarted: (@MainActor () -> Void)?

    init(modelManager: KokoroModelManager = .shared) {
        self.modelManager = modelManager
        let apple = AppleSpeechEngine()
        appleEngine = apple
        activeEngine = apple
        configure(apple)
        voices = apple.voices
    }

    func load(
        _ content: DocumentContent,
        sectionIndex: Int,
        session: ReadingSession,
        autoplay: Bool = false
    ) {
        stop()
        self.content = content
        rate = session.speechRate
        rebuildChunks(startingAt: sectionIndex)
        currentSectionIndex = sectionIndex
        switchEngine(
            to: session.speechEngine,
            preferredVoice: session.voiceIdentifier
        ) { [weak self] in
            if autoplay {
                self?.speakCurrent()
            }
        }
    }

    func switchEngine(
        to kind: SpeechEngineKind,
        preferredVoice: String? = nil,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let interruptedSegmentText = segmentText
        let interruptedSegmentStarted = segmentStarted
        let interruptedSegmentCompletion = segmentCompletion
        switchTask?.cancel()
        stop()
        isPreparing = true
        switchTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.switchTask = nil
                    self?.isPreparing = false
                }
            }

            guard let self else { return }
            let requested: any SpeechEngine = kind == .apple ? appleEngine : kokoroEngine
            do {
                try await requested.prepare()
                try Task.checkCancellation()
                activeEngine = requested
                engineKind = kind
                voices = requested.voices
                if let preferredVoice, voices.contains(where: { $0.id == preferredVoice }) {
                    voiceIdentifier = preferredVoice
                } else if !voices.contains(where: { $0.id == voiceIdentifier }) {
                    voiceIdentifier = kind == .kokoro
                        ? voices.first(where: { $0.id == "af_heart" })?.id ?? voices.first?.id
                        : nil
                }
                configure(requested)
                // Autoplay must observe the engine as ready. Calling the
                // completion while `isPreparing` is still true causes
                // speakCurrent() to reject playlist and repeat transitions.
                isPreparing = false
                if let interruptedSegmentText, let interruptedSegmentCompletion {
                    playSegment(
                        interruptedSegmentText,
                        onStarted: interruptedSegmentStarted,
                        completion: interruptedSegmentCompletion
                    )
                } else {
                    completion?()
                }
            } catch is CancellationError {
            } catch {
                activeEngine = appleEngine
                engineKind = .apple
                voices = appleEngine.voices
                voiceIdentifier = nil
                configure(appleEngine)
                fallbackMessage = "\(error.localizedDescription) Mac Voices will be used instead."
            }
        }
    }

    func togglePlayback() {
        if isPaused {
            activeEngine.resume()
            isPaused = false
            isSpeaking = true
        } else if isSpeaking {
            activeEngine.pause()
            isPaused = true
        } else {
            speakCurrent()
        }
    }

    func stop() {
        segmentTask?.cancel()
        segmentTask = nil
        manualStop = true
        rollingPlaybackActive = false
        isPreviewing = false
        activeEngine.stop()
        isSpeaking = false
        isPaused = false
        segmentText = nil
        segmentCompletion = nil
        segmentStarted = nil
    }

    func playSegment(
        _ text: String,
        onStarted: (@MainActor () -> Void)? = nil,
        completion: @escaping @MainActor () -> Void
    ) {
        stop()
        segmentText = text
        segmentStarted = onStarted
        segmentCompletion = completion
        manualStop = false
        segmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.activeEngine.prepare()
                try Task.checkCancellation()
                try await self.activeEngine.play(
                    text: text,
                    voiceIdentifier: self.voiceIdentifier,
                    rate: self.rate
                )
            } catch is CancellationError {
            } catch {
                self.handleEngineFailure(error.localizedDescription)
            }
        }
    }

    func pauseSegment() {
        activeEngine.pause()
        isPaused = true
    }

    func resumeSegment() {
        activeEngine.resume()
        isPaused = false
        isSpeaking = true
    }

    func stopSegment() {
        stop()
    }

    func moveToSection(_ index: Int, autoplay: Bool = false) {
        guard let content, content.sections.indices.contains(index) else { return }
        stop()
        rebuildChunks(startingAt: index)
        currentSectionIndex = index
        if autoplay { speakCurrent() }
    }

    func previousSection() {
        moveToSection(max(0, currentSectionIndex - 1))
    }

    func nextSection() {
        guard let content else { return }
        moveToSection(min(content.sections.count - 1, currentSectionIndex + 1))
    }

    func previewVoice() {
        stop()
        isPreviewing = true
        let sample = engineKind == .kokoro
            ? "Enhanced Voice is ready to read with you."
            : "This is the selected Mac voice."
        Task {
            do {
                try await activeEngine.play(
                    text: sample,
                    voiceIdentifier: voiceIdentifier,
                    rate: rate
                )
            } catch {
                handleEngineFailure(error.localizedDescription)
            }
        }
    }

    func continueWithAppleVoice() {
        switchEngine(to: .apple) { [weak self] in
            guard let self else { return }
            if let text = self.fallbackSegmentText,
               let completion = self.fallbackSegmentCompletion {
                let started = self.fallbackSegmentStarted
                self.fallbackSegmentText = nil
                self.fallbackSegmentCompletion = nil
                self.fallbackSegmentStarted = nil
                self.playSegment(text, onStarted: started, completion: completion)
            } else {
                self.speakCurrent()
            }
        }
        fallbackMessage = nil
    }

    func renderForExport(
        chunks: [String],
        to destination: URL,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws {
        let selectedEngine = engineKind
        let selectedVoice = voiceIdentifier
        let selectedRate = rate
        if selectedEngine == .kokoro {
            try await kokoroEngine.renderForExport(
                chunks: chunks,
                voiceIdentifier: selectedVoice,
                rate: selectedRate,
                destination: destination,
                progress: progress
            )
        } else {
            let renderer = AppleOfflineRenderer()
            exportRenderer = renderer
            defer { exportRenderer = nil }
            try await withTaskCancellationHandler {
                try await renderer.render(
                    chunks: chunks,
                    voiceIdentifier: selectedVoice,
                    rate: selectedRate,
                    destination: destination,
                    progress: progress
                )
            } onCancel: {
                Task { @MainActor in renderer.stop() }
            }
        }
    }

    private func rebuildChunks(startingAt sectionIndex: Int) {
        guard let content else { chunks = []; return }
        chunks = content.sections.enumerated().flatMap { index, section in
            SpeechChunker.chunks(from: section.text).map { (index, $0) }
        }
        chunkIndex = chunks.firstIndex(where: { $0.section >= sectionIndex }) ?? 0
    }

    private func speakCurrent() {
        guard chunks.indices.contains(chunkIndex), !isPreparing else {
            isSpeaking = false
            return
        }
        manualStop = false
        currentSectionIndex = chunks[chunkIndex].section
        if let rollingEngine = activeEngine as? any RollingSpeechEngine {
            rollingPlaybackActive = true
            let queue = chunks.indices.suffix(from: chunkIndex).map {
                SpeechQueueItem(id: $0, text: chunks[$0].text)
            }
            Task {
                do {
                    try await rollingEngine.playRolling(
                        items: queue,
                        voiceIdentifier: voiceIdentifier,
                        rate: rate
                    )
                } catch {
                    handleEngineFailure(error.localizedDescription)
                }
            }
            return
        }

        rollingPlaybackActive = false
        let chunk = chunks[chunkIndex]
        Task {
            do {
                try await activeEngine.play(
                    text: chunk.text,
                    voiceIdentifier: voiceIdentifier,
                    rate: rate
                )
            } catch {
                handleEngineFailure(error.localizedDescription)
            }
        }
    }

    private func finishedChunk() {
        if segmentText != nil {
            let completion = segmentCompletion
            segmentTask = nil
            segmentText = nil
            segmentCompletion = nil
            segmentStarted = nil
            isSpeaking = false
            isPaused = false
            completion?()
            return
        }
        if isPreviewing {
            isPreviewing = false
            isSpeaking = false
            isPaused = false
            return
        }
        if rollingPlaybackActive {
            rollingPlaybackActive = false
            isSpeaking = false
            isPaused = false
            documentFinishedHandler?()
            return
        }
        guard !manualStop else {
            manualStop = false
            return
        }
        chunkIndex += 1
        if chunks.indices.contains(chunkIndex) {
            speakCurrent()
        } else {
            isSpeaking = false
            isPaused = false
            documentFinishedHandler?()
        }
    }

    private func handleEngineFailure(_ message: String) {
        let failedKind = engineKind
        let interruptedText = segmentText
        let interruptedCompletion = segmentCompletion
        let interruptedStarted = segmentStarted
        stop()
        if failedKind == .kokoro {
            fallbackSegmentText = interruptedText
            fallbackSegmentCompletion = interruptedCompletion
            fallbackSegmentStarted = interruptedStarted
            activeEngine = appleEngine
            engineKind = .apple
            voices = appleEngine.voices
            voiceIdentifier = nil
            configure(appleEngine)
            fallbackMessage = "\(message) Continue from here with Mac Voices?"
        } else {
            fallbackMessage = message
        }
    }

    private func configure(_ engine: any SpeechEngine) {
        engine.eventHandler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                self.isSpeaking = true
                self.isPaused = false
                let started = self.segmentStarted
                self.segmentStarted = nil
                started?()
            case .chunkStarted(let index):
                guard self.chunks.indices.contains(index) else { return }
                self.chunkIndex = index
                self.currentSectionIndex = self.chunks[index].section
                self.isSpeaking = true
                self.isPaused = false
            case .finished:
                self.finishedChunk()
            case .failed(let message):
                self.handleEngineFailure(message)
            }
        }
    }

    private func handleRateChange(from previousValue: Float) {
        guard previousValue != rate else { return }
        guard shouldRestartPlayback else { return }

        if let segmentText, let segmentCompletion {
            let segmentStarted = self.segmentStarted
            activeEngine.stop()
            isSpeaking = false
            isPaused = false
            self.segmentText = nil
            self.segmentCompletion = nil
            self.segmentStarted = nil
            playSegment(
                segmentText,
                onStarted: segmentStarted,
                completion: segmentCompletion
            )
            return
        }
        stop()
        speakCurrent()
    }

    private func handleVoiceChange(from previousValue: String?) {
        guard previousValue != voiceIdentifier else { return }
        guard shouldRestartPlayback else { return }

        if let segmentText, let segmentCompletion {
            let segmentStarted = self.segmentStarted
            activeEngine.stop()
            isSpeaking = false
            isPaused = false
            self.segmentText = nil
            self.segmentCompletion = nil
            self.segmentStarted = nil
            playSegment(
                segmentText,
                onStarted: segmentStarted,
                completion: segmentCompletion
            )
            return
        }
        stop()
        speakCurrent()
    }

    private var shouldRestartPlayback: Bool {
        isSpeaking && !isPaused && !isPreparing && !isPreviewing
    }
}
