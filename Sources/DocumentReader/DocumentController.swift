import Foundation
import UniformTypeIdentifiers

@MainActor
final class DocumentController: ObservableObject {
    enum State: Equatable {
        case empty
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .empty
    @Published private(set) var content: DocumentContent?
    @Published private(set) var progress = 0.0
    @Published private(set) var progressMessage = ""
    @Published private(set) var recentDocuments: [RecentDocument]
    @Published var selectedSectionIndex = 0 {
        didSet { persistSession() }
    }

    private let extractors: [any DocumentExtractor] = [
        PDFDocumentExtractor(),
        PresentationDocumentExtractor(),
        RichTextExtractor(),
        PlainTextExtractor(),
        ImageDocumentExtractor()
    ]
    private let cache = ContentCache()
    private var loadTask: Task<Void, Never>?

    init() {
        recentDocuments = ReaderPersistence.shared.recentDocuments()
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func open(_ url: URL) {
        loadTask?.cancel()
        state = .loading
        content = nil
        progress = 0
        progressMessage = "Opening \(url.lastPathComponent)…"

        loadTask = Task {
            do {
                guard SupportedTypes.isSupported(url),
                      let extractor = extractors.first(where: { $0.canHandle(url) })
                else { throw ReaderError.unsupported }

                let loaded: DocumentContent
                if let cached = await cache.load(for: url) {
                    loaded = cached
                    progress = 1
                    progressMessage = "Ready"
                } else {
                    loaded = try await extractor.extract(from: url) { [weak self] fraction, message in
                        await MainActor.run {
                            self?.progress = fraction
                            self?.progressMessage = message
                        }
                    }
                    await cache.save(loaded, for: url)
                }

                try Task.checkCancellation()
                content = loaded
                selectedSectionIndex = min(
                    ReaderPersistence.shared.session(for: url).sectionIndex,
                    max(0, loaded.sections.count - 1)
                )
                addRecent(url)
                state = .ready
            } catch is CancellationError {
                if content == nil { state = .empty }
            } catch {
                state = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        state = .empty
        content = nil
    }

    func clearDocument() {
        loadTask?.cancel()
        state = .empty
        content = nil
        selectedSectionIndex = 0
    }

    func removeDocumentFromCache(_ url: URL) async {
        loadTask?.cancel()
        await cache.removeAll(for: url)
        ReaderPersistence.shared.removeSession(for: url)
        ReaderPersistence.shared.removeRecentDocument(for: url)

        if content?.sourceURL.standardizedFileURL == url.standardizedFileURL {
            state = .empty
            content = nil
            selectedSectionIndex = 0
        }

        recentDocuments = ReaderPersistence.shared.recentDocuments()
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func resetToStart() {
        loadTask?.cancel()
        state = .empty
        content = nil
        progress = 0
        progressMessage = ""
        selectedSectionIndex = 0
    }

    private func addRecent(_ url: URL) {
        recentDocuments.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        recentDocuments.insert(RecentDocument(url: url, lastOpened: Date()), at: 0)
        recentDocuments = Array(recentDocuments.prefix(12))
        ReaderPersistence.shared.saveRecents(recentDocuments)
    }

    private func persistSession() {
        guard let content else { return }
        var session = ReaderPersistence.shared.session(for: content.sourceURL)
        session.sectionIndex = selectedSectionIndex
        ReaderPersistence.shared.save(session, for: content.sourceURL)
    }
}
