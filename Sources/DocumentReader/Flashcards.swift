import Foundation

enum FlashcardParserError: LocalizedError, Equatable {
    case unreadable
    case empty
    case malformed(card: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The flashcard deck could not be read as text."
        case .empty:
            "No flashcards were found. Add paired “## Question” and “## Answer” headings."
        case .malformed(let card, let reason):
            "Card \(card): \(reason)"
        }
    }
}

enum FlashcardParser {
    static func parse(url: URL, defaultDelay: Int = 5) throws -> FlashcardDeck {
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
        else { throw FlashcardParserError.unreadable }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return try parse(
            source,
            sourceURL: url,
            defaultDelay: defaultDelay,
            modificationDate: modified
        )
    }

    static func parse(
        _ source: String,
        sourceURL: URL,
        defaultDelay: Int = 5,
        modificationDate: Date? = nil
    ) throws -> FlashcardDeck {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized
            .replacingOccurrences(
                of: #"(?m)^[ \t]*---[ \t]*$\n?"#,
                with: "\u{001E}",
                options: .regularExpression
            )
            .components(separatedBy: "\u{001E}")
        var cards: [Flashcard] = []
        var deckTitle: String?

        for line in normalized.components(separatedBy: .newlines) {
            if line.hasPrefix("# "), !line.hasPrefix("## ") {
                deckTitle = cleanMarkdown(String(line.dropFirst(2)))
                break
            }
        }

        for block in blocks {
            let meaningful = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard meaningful.contains("## Question") || meaningful.contains("## Answer") else {
                continue
            }
            let cardNumber = cards.count + 1
            guard let questionRange = meaningful.range(
                of: #"(?m)^##[ \t]+Question[ \t]*$"#,
                options: .regularExpression
            ) else {
                throw FlashcardParserError.malformed(
                    card: cardNumber,
                    reason: "missing the “## Question” heading."
                )
            }
            guard let answerRange = meaningful.range(
                of: #"(?m)^##[ \t]+Answer[ \t]*$"#,
                options: .regularExpression
            ) else {
                throw FlashcardParserError.malformed(
                    card: cardNumber,
                    reason: "missing the “## Answer” heading."
                )
            }
            guard questionRange.upperBound <= answerRange.lowerBound else {
                throw FlashcardParserError.malformed(
                    card: cardNumber,
                    reason: "the question must appear before the answer."
                )
            }
            let question = cleanMarkdown(String(meaningful[questionRange.upperBound..<answerRange.lowerBound]))
            let answer = cleanMarkdown(String(meaningful[answerRange.upperBound...]))
            guard !question.isEmpty else {
                throw FlashcardParserError.malformed(card: cardNumber, reason: "the question is empty.")
            }
            guard !answer.isEmpty else {
                throw FlashcardParserError.malformed(card: cardNumber, reason: "the answer is empty.")
            }
            cards.append(Flashcard(question: question, answer: answer))
        }

        guard !cards.isEmpty else { throw FlashcardParserError.empty }
        return FlashcardDeck(
            sourceURL: sourceURL,
            title: deckTitle?.isEmpty == false
                ? deckTitle!
                : sourceURL.deletingPathExtension().lastPathComponent,
            cards: cards,
            answerDelay: defaultDelay,
            modificationDate: modificationDate
        )
    }

    static func cleanMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*[-*+][ \t]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*>[ \t]?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"`{1,3}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_~]"#, with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class FlashcardController: ObservableObject {
    @Published private(set) var decks: [FlashcardDeck]
    @Published private(set) var playback = FlashcardPlaybackState()
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published var errorMessage: String?

    var deckFinishedHandler: (@MainActor () -> Void)?

    private let persistence: ReaderPersistence
    private weak var speech: SpeechController?
    private var countdownTask: Task<Void, Never>?
    private var generation = UUID()

    init(persistence: ReaderPersistence = .shared) {
        self.persistence = persistence
        decks = persistence.flashcardLibrary().decks
    }

    var activeDeck: FlashcardDeck? {
        guard let id = playback.deckID else { return nil }
        return decks.first { $0.id == id }
    }

    var currentCard: Flashcard? {
        guard let deck = activeDeck, deck.cards.indices.contains(playback.currentCardIndex) else {
            return nil
        }
        return deck.cards[playback.currentCardIndex]
    }

    var answerIsVisible: Bool {
        playback.phase == .answer || playback.phase == .finished
    }

    func configure(speech: SpeechController) {
        self.speech = speech
    }

    @discardableResult
    func importDeck(_ url: URL) -> UUID? {
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "Flashcard decks must be Markdown files."
            return nil
        }
        do {
            let existing = decks.firstIndex {
                $0.sourceURL.standardizedFileURL == url.standardizedFileURL
            }
            let previous = existing.map { decks[$0] }
            var deck = try FlashcardParser.parse(
                url: url,
                defaultDelay: previous?.answerDelay ?? persistence.flashcardLibrary().defaultAnswerDelay
            )
            if let previous {
                deck.id = previous.id
                decks[existing!] = deck
            } else {
                decks.append(deck)
            }
            persist()
            errorMessage = nil
            return deck.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func removeDeck(_ id: UUID) {
        if playback.deckID == id { stop() }
        decks.removeAll { $0.id == id }
        persist()
    }

    func setDelay(_ seconds: Int, for id: UUID) {
        guard let index = decks.firstIndex(where: { $0.id == id }) else { return }
        decks[index].answerDelay = min(max(seconds, 1), 60)
        persist()
    }

    func refreshAndPlay(deckID: UUID, cardIndex: Int = 0) throws {
        try refreshDeck(deckID)
        play(deckID: deckID, cardIndex: cardIndex)
    }

    func refreshDeck(_ deckID: UUID) throws {
        guard let index = decks.firstIndex(where: { $0.id == deckID }) else {
            throw FlashcardParserError.unreadable
        }
        let saved = decks[index]
        var refreshed = try FlashcardParser.parse(
            url: saved.sourceURL,
            defaultDelay: saved.answerDelay
        )
        refreshed.id = saved.id
        refreshed.answerDelay = saved.answerDelay
        decks[index] = refreshed
        persist()
    }

    func play(deckID: UUID, cardIndex: Int = 0) {
        stop(clearDeck: false)
        guard let deck = decks.first(where: { $0.id == deckID }), !deck.cards.isEmpty else { return }
        playback.deckID = deckID
        playback.currentCardIndex = min(max(cardIndex, 0), deck.cards.count - 1)
        isPlaying = true
        isPaused = false
        speakQuestion()
    }

    func selectDeck(_ id: UUID) {
        guard decks.contains(where: { $0.id == id }) else { return }
        if playback.deckID != id {
            stop(clearDeck: false)
            playback.deckID = id
            playback.currentCardIndex = 0
            playback.phase = .idle
        }
    }

    func togglePlayback() {
        guard isPlaying else {
            if let id = playback.deckID { play(deckID: id, cardIndex: playback.currentCardIndex) }
            return
        }
        if isPaused {
            isPaused = false
            if playback.phase == .waiting {
                startCountdown()
            } else {
                speech?.resumeSegment()
            }
        } else {
            isPaused = true
            if playback.phase == .waiting {
                countdownTask?.cancel()
                countdownTask = nil
            } else {
                speech?.pauseSegment()
            }
        }
    }

    func stop(clearDeck: Bool = false) {
        generation = UUID()
        countdownTask?.cancel()
        countdownTask = nil
        speech?.stopSegment()
        isPlaying = false
        isPaused = false
        playback.phase = .idle
        playback.remainingDelay = 0
        if clearDeck {
            playback.deckID = nil
            playback.currentCardIndex = 0
        }
    }

    func moveToCard(_ index: Int, autoplay: Bool = false) {
        guard let deck = activeDeck, deck.cards.indices.contains(index) else { return }
        stop(clearDeck: false)
        playback.currentCardIndex = index
        playback.phase = .idle
        if autoplay {
            isPlaying = true
            speakQuestion()
        }
    }

    func previousCard() {
        moveToCard(max(0, playback.currentCardIndex - 1), autoplay: isPlaying)
    }

    func nextCard() {
        guard let deck = activeDeck else { return }
        moveToCard(min(deck.cards.count - 1, playback.currentCardIndex + 1), autoplay: isPlaying)
    }

    private func speakQuestion() {
        guard let card = currentCard else { return }
        let token = generation
        playback.phase = .question
        playback.remainingDelay = activeDeck?.answerDelay ?? 5
        speech?.playSegment(card.question) { [weak self] in
            guard let self, self.generation == token, self.isPlaying else { return }
            self.playback.phase = .waiting
            self.startCountdown()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        guard playback.remainingDelay > 0 else {
            speakAnswer()
            return
        }
        let token = generation
        countdownTask = Task { [weak self] in
            while let self, self.playback.remainingDelay > 0 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard self.generation == token, !self.isPaused else { return }
                self.playback.remainingDelay -= 1
            }
            guard let self, self.generation == token else { return }
            self.countdownTask = nil
            self.speakAnswer()
        }
    }

    private func speakAnswer() {
        guard let card = currentCard else { return }
        let token = generation
        speech?.playSegment(card.answer, onStarted: { [weak self] in
            guard let self, self.generation == token else { return }
            self.playback.phase = .answer
        }) { [weak self] in
            guard let self, self.generation == token, self.isPlaying,
                  let deck = self.activeDeck else { return }
            let next = self.playback.currentCardIndex + 1
            if deck.cards.indices.contains(next) {
                self.playback.currentCardIndex = next
                self.speakQuestion()
            } else {
                self.isPlaying = false
                self.playback.phase = .finished
                self.deckFinishedHandler?()
            }
        }
    }

    private func persist() {
        var library = persistence.flashcardLibrary()
        library.decks = decks
        persistence.saveFlashcardLibrary(library)
    }
}
