import Foundation
import UniformTypeIdentifiers

struct ReadingSection: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var text: String
    var imageData: Data?
    var pageIndex: Int?

    init(
        id: UUID = UUID(),
        title: String,
        text: String,
        imageData: Data? = nil,
        pageIndex: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.imageData = imageData
        self.pageIndex = pageIndex
    }

    var displayText: String {
        guard imageData != nil else { return text }
        return text
            .components(separatedBy: .newlines)
            .filter {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("Image on this slide.") != .orderedSame
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DocumentContent: Codable, Hashable, Sendable {
    var title: String
    var sourceURL: URL
    var typeIdentifier: String
    var sections: [ReadingSection]
    var usedOCR: Bool

    var fullText: String {
        sections.map(\.text).joined(separator: "\n\n")
    }
}

struct RecentDocument: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    var lastOpened: Date
}

struct PlaylistItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var fileURL: URL
    var displayName: String

    init(id: UUID = UUID(), fileURL: URL, displayName: String? = nil) {
        self.id = id
        self.fileURL = fileURL.standardizedFileURL
        self.displayName = displayName ?? fileURL.deletingPathExtension().lastPathComponent
    }
}

struct DocumentPlaylist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var items: [PlaylistItem]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        items: [PlaylistItem] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case document
    case playlist

    var next: RepeatMode {
        switch self {
        case .off: .document
        case .document: .playlist
        case .playlist: .off
        }
    }

    var label: String {
        switch self {
        case .off: "Repeat Off"
        case .document: "Repeat Document"
        case .playlist: "Repeat Playlist"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "repeat"
        case .document: "repeat.1"
        case .playlist: "repeat"
        }
    }
}

struct PlaylistPlaybackState: Codable, Equatable, Sendable {
    var activePlaylistID: UUID?
    var currentItemIndex: Int
    var repeatMode: RepeatMode

    init(
        activePlaylistID: UUID? = nil,
        currentItemIndex: Int = 0,
        repeatMode: RepeatMode = .off
    ) {
        self.activePlaylistID = activePlaylistID
        self.currentItemIndex = currentItemIndex
        self.repeatMode = repeatMode
    }
}

struct PlaylistLibrary: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var playlists: [DocumentPlaylist] = []
    var playback = PlaylistPlaybackState()
}

struct ReadingSession: Codable, Sendable {
    var sectionIndex: Int = 0
    var speechRate: Float = 0.5
    var voiceIdentifier: String?
    var speechEngine: SpeechEngineKind = .apple
    var sidebarVisible: Bool = true

    init(
        sectionIndex: Int = 0,
        speechRate: Float = 0.5,
        voiceIdentifier: String? = nil,
        speechEngine: SpeechEngineKind = .apple,
        sidebarVisible: Bool = true
    ) {
        self.sectionIndex = sectionIndex
        self.speechRate = speechRate
        self.voiceIdentifier = voiceIdentifier
        self.speechEngine = speechEngine
        self.sidebarVisible = sidebarVisible
    }

    private enum CodingKeys: String, CodingKey {
        case sectionIndex, speechRate, voiceIdentifier, speechEngine, sidebarVisible
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sectionIndex = try values.decodeIfPresent(Int.self, forKey: .sectionIndex) ?? 0
        speechRate = try values.decodeIfPresent(Float.self, forKey: .speechRate) ?? 0.5
        voiceIdentifier = try values.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        speechEngine = try values.decodeIfPresent(SpeechEngineKind.self, forKey: .speechEngine) ?? .apple
        sidebarVisible = try values.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
    }
}

enum ReaderError: LocalizedError {
    case unsupported
    case unreadable
    case empty
    case lockedPDF
    case imageDecode

    var errorDescription: String? {
        switch self {
        case .unsupported: "This file type is not supported yet."
        case .unreadable: "The document could not be read."
        case .empty: "No readable text was found in this document."
        case .lockedPDF: "This PDF is encrypted and must be unlocked first."
        case .imageDecode: "The image could not be decoded."
        }
    }
}

enum SupportedTypes {
    static let all: [UTType] = {
        var types: [UTType] = [
            .pdf, .plainText, .utf8PlainText, .rtf,
            .png, .jpeg, .tiff, .heic
        ]
        if let pptx = UTType(filenameExtension: "pptx") {
            types.append(pptx)
        }
        return types
    }()

    static func type(for url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension)
    }

    static func isSupported(_ url: URL) -> Bool {
        guard let type = type(for: url) else { return false }
        return all.contains { type.conforms(to: $0) } ||
            ["md", "markdown", "pptx"].contains(url.pathExtension.lowercased())
    }
}
