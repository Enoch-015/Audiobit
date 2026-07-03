import Foundation

actor ContentCache {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        directory = base.appendingPathComponent("DocumentReader/Extracted", isDirectory: true)
    }

    func load(for url: URL) -> DocumentContent? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let file = cacheURL(for: url, modified: modified)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(DocumentContent.self, from: data)
    }

    func save(_ content: DocumentContent, for url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let data = try? JSONEncoder().encode(content) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(for: url, modified: modified), options: .atomic)
    }

    private func cacheURL(for url: URL, modified: Date) -> URL {
        let source = "\(url.standardizedFileURL.path)|\(modified.timeIntervalSince1970)"
        let safe = Data(source.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(safe + ".json")
    }
}

@MainActor
final class ReaderPersistence {
    static let shared = ReaderPersistence()
    private let defaults = UserDefaults.standard

    func recentDocuments() -> [RecentDocument] {
        guard let data = defaults.data(forKey: "recentDocuments") else { return [] }
        return (try? JSONDecoder().decode([RecentDocument].self, from: data)) ?? []
    }

    func saveRecents(_ recents: [RecentDocument]) {
        defaults.set(try? JSONEncoder().encode(recents), forKey: "recentDocuments")
    }

    func session(for url: URL) -> ReadingSession {
        guard let data = defaults.data(forKey: sessionKey(url)) else {
            return ReadingSession()
        }
        return (try? JSONDecoder().decode(ReadingSession.self, from: data)) ?? ReadingSession()
    }

    func save(_ session: ReadingSession, for url: URL) {
        defaults.set(try? JSONEncoder().encode(session), forKey: sessionKey(url))
    }

    private func sessionKey(_ url: URL) -> String {
        "session." + Data(url.standardizedFileURL.path.utf8).base64EncodedString()
    }
}
