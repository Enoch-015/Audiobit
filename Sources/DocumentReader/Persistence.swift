import Foundation

actor ContentCache {
    private static let cacheVersion = 2
    private static let versionKey = "contentCacheVersion"
    private let directory: URL

    init() {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        directory = base.appendingPathComponent("DocumentReader/Extracted", isDirectory: true)
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.versionKey) != Self.cacheVersion {
            try? FileManager.default.removeItem(at: directory)
            defaults.set(Self.cacheVersion, forKey: Self.versionKey)
        }
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

    func removeAll(for url: URL) {
        let standardized = url.standardizedFileURL
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let content = try? JSONDecoder().decode(DocumentContent.self, from: data),
                  content.sourceURL.standardizedFileURL == standardized else {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func cacheURL(for url: URL, modified: Date) -> URL {
        let source = "\(Self.cacheVersion)|\(url.standardizedFileURL.path)|\(modified.timeIntervalSince1970)"
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

    func removeSession(for url: URL) {
        defaults.removeObject(forKey: sessionKey(url))
    }

    func removeRecentDocument(for url: URL) {
        var recents = recentDocuments()
        recents.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        saveRecents(recents)
    }

    private func sessionKey(_ url: URL) -> String {
        "session." + Data(url.standardizedFileURL.path.utf8).base64EncodedString()
    }
}
