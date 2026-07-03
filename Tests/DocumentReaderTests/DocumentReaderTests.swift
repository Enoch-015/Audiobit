import Foundation
import CryptoKit
import Testing
@testable import DocumentReader

@Test func supportedTypeDetection() {
    #expect(SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/report.pdf")))
    #expect(SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/notes.md")))
    #expect(SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/scan.heic")))
    #expect(!SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/archive.zip")))
}

@Test func textCleaning() {
    let cleaned = TextUtilities.clean("Hello   world\n\n\n\nNext")
    #expect(cleaned == "Hello world\n\nNext")
}

@Test func sentenceAwareChunking() {
    let chunks = SpeechChunker.chunks(
        from: "First sentence. Second sentence is here. Third sentence.",
        maximumLength: 35
    )
    #expect(chunks.count >= 2)
    #expect(chunks.joined(separator: " ").contains("Third sentence."))
}

@Test func paragraphBoundariesArePreserved() {
    let chunks = SpeechChunker.chunks(
        from: "First paragraph ends here.\n\nSecond paragraph has no final stop but should stay separate",
        maximumLength: 200
    )
    #expect(chunks.count == 2)
    #expect(chunks[0].contains("First paragraph ends here."))
    #expect(chunks[1].hasPrefix("Second paragraph"))
}

@Test func oversizedSentenceIsSplit() {
    let text = Array(repeating: "lengthy", count: 40).joined(separator: " ") + "."
    let chunks = SpeechChunker.chunks(from: text, maximumLength: 50)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 50 })
}

@Test func plainTextContentPreservesOrder() {
    let content = PlainTextExtractor.content(
        url: URL(fileURLWithPath: "/tmp/notes.txt"),
        text: "First paragraph.\n\nSecond paragraph."
    )
    #expect(content.sections.count == 2)
    #expect(content.sections[0].text == "First paragraph.")
    #expect(content.sections[1].text == "Second paragraph.")
}

@Test func readingSessionRoundTrip() throws {
    let original = ReadingSession(
        sectionIndex: 4,
        speechRate: 0.57,
        voiceIdentifier: "voice.example",
        speechEngine: .kokoro,
        sidebarVisible: false
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ReadingSession.self, from: data)
    #expect(decoded.sectionIndex == 4)
    #expect(decoded.voiceIdentifier == "voice.example")
    #expect(decoded.speechEngine == .kokoro)
}

@Test func legacySessionDefaultsToAppleSpeech() throws {
    let data = Data(
        #"{"sectionIndex":2,"speechRate":0.5,"voiceIdentifier":"old.voice","sidebarVisible":true}"#
            .utf8
    )
    let decoded = try JSONDecoder().decode(ReadingSession.self, from: data)
    #expect(decoded.speechEngine == .apple)
    #expect(decoded.sectionIndex == 2)
}

@Test func bundledKokoroManifestHasPinnedAssets() throws {
    let manifest = try KokoroModelManifest.bundled()
    #expect(manifest.assets.count == 2)
    #expect(manifest.assets.allSatisfy { $0.url.scheme == "https" })
    #expect(manifest.assets.allSatisfy { $0.sha256.count == 64 })
}

@Test func kokoroAssetVerificationAcceptsMatchingHash() async throws {
    let data = Data("verified model fixture".utf8)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let asset = KokoroModelManifest.Asset(
        name: "fixture",
        url: URL(string: "https://example.invalid/fixture")!,
        size: Int64(data.count),
        sha256: hash
    )
    #expect(try await KokoroAssetVerifier.verify(asset: asset, at: url))
}

@Test func kokoroAssetVerificationRejectsCorruption() async throws {
    let data = Data("corrupt fixture".utf8)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let asset = KokoroModelManifest.Asset(
        name: "fixture",
        url: URL(string: "https://example.invalid/fixture")!,
        size: Int64(data.count),
        sha256: String(repeating: "0", count: 64)
    )
    #expect(try await !KokoroAssetVerifier.verify(asset: asset, at: url))
}

@MainActor
@Test func kokoroInstalledSmoke() async throws {
    guard ProcessInfo.processInfo.environment["KOKORO_SMOKE"] == "1" else { return }
    let manager = KokoroModelManager.shared
    #expect(manager.state == .ready)
    let engine = KokoroSpeechEngine(modelManager: manager)
    try await engine.prepare()
    #expect(!engine.voices.isEmpty)

    var startedChunks: [Int] = []
    var playbackFinished = false
    var playbackFailure: String?
    engine.eventHandler = { event in
        switch event {
        case .chunkStarted(let index):
            startedChunks.append(index)
        case .finished:
            playbackFinished = true
        case .failed(let message):
            playbackFailure = message
        case .started:
            break
        }
    }
    try await engine.playRolling(
        items: [
            SpeechQueueItem(id: 10, text: "The first rolling buffer is playing."),
            SpeechQueueItem(id: 11, text: "The second buffer is already prepared."),
            SpeechQueueItem(id: 12, text: "The third buffer completes the sequence.")
        ],
        voiceIdentifier: "af_heart",
        rate: 0.5
    )
    for _ in 0..<300 where !playbackFinished && playbackFailure == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(playbackFailure == nil)
    #expect(playbackFinished)
    #expect(startedChunks == [10, 11, 12])
}
