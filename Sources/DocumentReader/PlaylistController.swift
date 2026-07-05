import Foundation
import SwiftUI

enum PlaylistNavigator {
    static func destinationAfterCompletion(
        currentIndex: Int,
        itemCount: Int,
        repeatMode: RepeatMode
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        if repeatMode == .document {
            return min(max(currentIndex, 0), itemCount - 1)
        }
        let next = currentIndex + 1
        if next < itemCount { return next }
        return repeatMode == .playlist ? 0 : nil
    }
}

@MainActor
final class PlaylistController: ObservableObject {
    @Published private(set) var playlists: [DocumentPlaylist]
    @Published private(set) var playbackState: PlaylistPlaybackState
    @Published private(set) var isPlaying = false
    @Published var skippedMessage: String?

    private let persistence: ReaderPersistence
    private var playbackTask: Task<Void, Never>?
    private weak var documents: DocumentController?
    private weak var speech: SpeechController?
    private weak var flashcards: FlashcardController?

    init(persistence: ReaderPersistence = .shared) {
        self.persistence = persistence
        let library = persistence.playlistLibrary()
        playlists = library.playlists
        playbackState = library.playback
        normalizePlaybackState()
    }

    var activePlaylist: DocumentPlaylist? {
        guard let id = playbackState.activePlaylistID else { return nil }
        return playlists.first { $0.id == id }
    }

    var currentItem: PlaylistItem? {
        guard let items = activePlaylist?.items,
              items.indices.contains(playbackState.currentItemIndex)
        else { return nil }
        return items[playbackState.currentItemIndex]
    }

    func configure(
        documents: DocumentController,
        speech: SpeechController,
        flashcards: FlashcardController
    ) {
        self.documents = documents
        self.speech = speech
        self.flashcards = flashcards
        speech.documentFinishedHandler = { [weak self] in
            self?.documentDidFinishNaturally()
        }
        flashcards.deckFinishedHandler = { [weak self] in
            self?.documentDidFinishNaturally()
        }
    }

    @discardableResult
    func createPlaylist(name: String? = nil) -> UUID {
        let base = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = base?.isEmpty == false ? base! : uniquePlaylistName()
        let playlist = DocumentPlaylist(name: resolved)
        playlists.append(playlist)
        persist()
        return playlist.id
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: id) else { return }
        playlists[index].name = trimmed
        playlists[index].updatedAt = .now
        persist()
    }

    func deletePlaylist(_ id: UUID) {
        if playbackState.activePlaylistID == id {
            stopPlayback(clearActivePlaylist: true)
        }
        playlists.removeAll { $0.id == id }
        normalizePlaybackState()
        persist()
    }

    @discardableResult
    func addDocuments(_ urls: [URL], to playlistID: UUID) -> Int {
        guard let playlistIndex = index(of: playlistID) else { return 0 }
        let existing = Set(
            playlists[playlistIndex].items.map { $0.fileURL.standardizedFileURL.path }
        )
        var seen = existing
        let additions = urls.compactMap { url -> PlaylistItem? in
            let standardized = url.standardizedFileURL
            guard SupportedTypes.isSupported(standardized),
                  !seen.contains(standardized.path)
            else { return nil }
            seen.insert(standardized.path)
            return PlaylistItem(fileURL: standardized)
        }
        guard !additions.isEmpty else { return 0 }
        playlists[playlistIndex].items.append(contentsOf: additions)
        playlists[playlistIndex].updatedAt = .now
        persist()
        return additions.count
    }

    @discardableResult
    func addFlashcardDeck(_ deck: FlashcardDeck, to playlistID: UUID) -> Bool {
        guard let playlistIndex = index(of: playlistID) else { return false }
        let path = deck.sourceURL.standardizedFileURL.path
        guard !playlists[playlistIndex].items.contains(where: {
            $0.kind == .flashcardDeck && $0.fileURL.standardizedFileURL.path == path
        }) else { return false }
        playlists[playlistIndex].items.append(
            PlaylistItem(
                fileURL: deck.sourceURL,
                displayName: deck.title,
                kind: .flashcardDeck
            )
        )
        playlists[playlistIndex].updatedAt = .now
        persist()
        return true
    }

    func moveItems(in playlistID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let playlistIndex = index(of: playlistID) else { return }
        playlists[playlistIndex].items.move(fromOffsets: offsets, toOffset: destination)
        playlists[playlistIndex].updatedAt = .now
        persist()
    }

    func removeItems(in playlistID: UUID, at offsets: IndexSet) {
        guard let playlistIndex = index(of: playlistID) else { return }
        let oldCurrentIndex = playbackState.currentItemIndex
        playlists[playlistIndex].items.remove(atOffsets: offsets)
        playlists[playlistIndex].updatedAt = .now
        if playbackState.activePlaylistID == playlistID {
            let removedBeforeCurrent = offsets.filter { $0 < oldCurrentIndex }.count
            playbackState.currentItemIndex = min(
                max(0, oldCurrentIndex - removedBeforeCurrent),
                max(0, playlists[playlistIndex].items.count - 1)
            )
        }
        persist()
    }

    func play(playlistID: UUID, itemIndex: Int? = nil) {
        guard let playlist = playlists.first(where: { $0.id == playlistID }),
              !playlist.items.isEmpty
        else { return }
        let rememberedIndex = playbackState.activePlaylistID == playlistID
            ? playbackState.currentItemIndex
            : 0
        playbackState.activePlaylistID = playlistID
        playbackState.currentItemIndex = min(
            max(itemIndex ?? rememberedIndex, 0),
            playlist.items.count - 1
        )
        isPlaying = true
        skippedMessage = nil
        persist()
        playAvailableItem(startingAt: playbackState.currentItemIndex, mayWrap: false)
    }

    func playItem(at index: Int) {
        guard let id = playbackState.activePlaylistID else { return }
        play(playlistID: id, itemIndex: index)
    }

    func playPreviousDocument() {
        guard let playlist = activePlaylist, !playlist.items.isEmpty else { return }
        let previous = max(0, playbackState.currentItemIndex - 1)
        play(playlistID: playlist.id, itemIndex: previous)
    }

    func playNextDocument() {
        guard let playlist = activePlaylist, !playlist.items.isEmpty else { return }
        let next = playbackState.currentItemIndex + 1
        if next < playlist.items.count {
            play(playlistID: playlist.id, itemIndex: next)
        } else if playbackState.repeatMode == .playlist {
            play(playlistID: playlist.id, itemIndex: 0)
        } else {
            stopPlayback(clearActivePlaylist: false)
        }
    }

    func cycleRepeatMode() {
        playbackState.repeatMode = playbackState.repeatMode.next
        persist()
    }

    func stopPlayback(clearActivePlaylist: Bool = false) {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        speech?.stop()
        flashcards?.stop()
        if clearActivePlaylist {
            playbackState.activePlaylistID = nil
            playbackState.currentItemIndex = 0
        }
        persist()
    }

    private func documentDidFinishNaturally() {
        guard isPlaying, let playlist = activePlaylist else { return }
        guard let destination = PlaylistNavigator.destinationAfterCompletion(
            currentIndex: playbackState.currentItemIndex,
            itemCount: playlist.items.count,
            repeatMode: playbackState.repeatMode
        ) else {
            stopPlayback(clearActivePlaylist: false)
            return
        }
        playAvailableItem(
            startingAt: destination,
            mayWrap: playbackState.repeatMode == .playlist
        )
    }

    private func playAvailableItem(startingAt start: Int, mayWrap: Bool) {
        playbackTask?.cancel()
        guard let documents, let speech, let flashcards, let playlist = activePlaylist else {
            isPlaying = false
            return
        }
        let playlistID = playlist.id
        let itemCount = playlist.items.count
        playbackTask = Task { [weak self, weak documents, weak speech, weak flashcards] in
            guard let self, let documents, let speech, let flashcards else { return }
            var index = start
            var attempted = 0
            var skipped: [String] = []

            while attempted < itemCount {
                try? Task.checkCancellation()
                guard !Task.isCancelled,
                      let currentPlaylist = self.playlists.first(where: { $0.id == playlistID }),
                      currentPlaylist.items.indices.contains(index)
                else { return }
                let item = currentPlaylist.items[index]
                do {
                    self.playbackState.currentItemIndex = index
                    self.isPlaying = true
                    self.persist()
                    if item.kind == .flashcardDeck {
                        speech.stop()
                        let deckID = flashcards.decks.first {
                            $0.sourceURL.standardizedFileURL == item.fileURL.standardizedFileURL
                        }?.id ?? flashcards.importDeck(item.fileURL)
                        guard let deckID else { throw FlashcardParserError.unreadable }
                        try flashcards.refreshAndPlay(deckID: deckID)
                    } else {
                        flashcards.stop()
                        let content = try await documents.openForPlaylist(item.fileURL)
                        try Task.checkCancellation()
                        let session = ReadingSession(
                            sectionIndex: 0,
                            speechRate: speech.rate,
                            voiceIdentifier: speech.voiceIdentifier,
                            speechEngine: speech.engineKind
                        )
                        speech.load(
                            content,
                            sectionIndex: 0,
                            session: session,
                            autoplay: true
                        )
                    }
                    if !skipped.isEmpty {
                        self.skippedMessage = Self.skippedSummary(skipped)
                    }
                    self.playbackTask = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    skipped.append(item.displayName)
                    attempted += 1
                    index += 1
                    if index >= itemCount {
                        guard mayWrap else { break }
                        index = 0
                    }
                }
            }

            self.isPlaying = false
            self.playbackTask = nil
            if !skipped.isEmpty {
                self.skippedMessage = Self.skippedSummary(skipped)
            }
        }
    }

    private static func skippedSummary(_ names: [String]) -> String {
        let list = names.prefix(4).joined(separator: ", ")
        let remainder = names.count > 4 ? " and \(names.count - 4) more" : ""
        return "Skipped unavailable documents: \(list)\(remainder)."
    }

    private func index(of id: UUID) -> Int? {
        playlists.firstIndex { $0.id == id }
    }

    private func uniquePlaylistName() -> String {
        let names = Set(playlists.map(\.name))
        if !names.contains("New Playlist") { return "New Playlist" }
        var number = 2
        while names.contains("New Playlist \(number)") { number += 1 }
        return "New Playlist \(number)"
    }

    private func normalizePlaybackState() {
        guard let id = playbackState.activePlaylistID,
              let playlist = playlists.first(where: { $0.id == id })
        else {
            playbackState.activePlaylistID = nil
            playbackState.currentItemIndex = 0
            return
        }
        playbackState.currentItemIndex = min(
            playbackState.currentItemIndex,
            max(0, playlist.items.count - 1)
        )
    }

    private func persist() {
        persistence.savePlaylistLibrary(
            PlaylistLibrary(
                playlists: playlists,
                playback: playbackState
            )
        )
    }
}
