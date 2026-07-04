import Foundation
import CryptoKit
import AVFoundation
import Testing
@testable import DocumentReader
import ZIPFoundation

@Test func supportedTypeDetection() {
    #expect(SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/report.pdf")))
    #expect(SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/notes.md")))
    #expect(SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/deck.pptx")))
    #expect(SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/scan.heic")))
    #expect(!SupportedTypes.isSupported(URL(fileURLWithPath: "/tmp/archive.zip")))
}

@Test func textCleaning() {
    let cleaned = TextUtilities.clean("Hello   world\n\n\n\nNext")
    #expect(cleaned == "Hello world\n\nNext")
}

@Test func paragraphParsingPreservesExplicitLines() {
    let paragraphs = TextUtilities.paragraphs(from: "First line\nsecond line\n\nThird line")
    #expect(paragraphs == ["First line", "second line", "Third line"])
}

@Test func pdfSectionsPreserveExplicitLines() {
    let sections = PDFDocumentExtractor.sections(
        from: "Heading\nFirst paragraph line\nSecond paragraph line",
        pageIndex: 2
    )
    #expect(sections.count == 1)
    #expect(sections[0].title == "Page 3")
    #expect(sections[0].text == "Heading\nFirst paragraph line\nSecond paragraph line")
    #expect(sections[0].pageIndex == 2)
}

@Test func pdfLayoutJoinsWrappedLinesAndPreservesVisualGaps() {
    let lines = [
        PDFDocumentExtractor.TextLine(
            text: "A paragraph wraps naturally onto",
            bounds: CGRect(x: 20, y: 700, width: 240, height: 12)
        ),
        PDFDocumentExtractor.TextLine(
            text: "the next line in the PDF.",
            bounds: CGRect(x: 20, y: 686, width: 210, height: 12)
        ),
        PDFDocumentExtractor.TextLine(
            text: "A new paragraph starts after whitespace.",
            bounds: CGRect(x: 20, y: 650, width: 280, height: 12)
        )
    ]

    #expect(
        PDFDocumentExtractor.text(from: lines)
            == "A paragraph wraps naturally onto the next line in the PDF.\n\nA new paragraph starts after whitespace."
    )
}

@Test func pdfLayoutJoinsHyphenatedWrappedWords() {
    let lines = [
        PDFDocumentExtractor.TextLine(
            text: "program-",
            bounds: CGRect(x: 20, y: 700, width: 80, height: 12)
        ),
        PDFDocumentExtractor.TextLine(
            text: "ming languages",
            bounds: CGRect(x: 20, y: 686, width: 120, height: 12)
        )
    ]

    #expect(PDFDocumentExtractor.text(from: lines) == "program-ming languages")
}

@Test func audioExportUsesUniqueMP3Names() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = ExportTestFileManager(documentsURL: root)
    let exportDirectory = try AudioExportController.exportDirectory(fileManager: manager)
    let first = exportDirectory.appendingPathComponent("Notes.mp3")
    FileManager.default.createFile(atPath: first.path, contents: Data())

    let candidate = try AudioExportController.destinationURL(
        for: "Notes",
        fileManager: manager
    )
    #expect(candidate.lastPathComponent == "Notes 2.mp3")
}

private final class ExportTestFileManager: FileManager, @unchecked Sendable {
    let documentsURL: URL

    init(documentsURL: URL) {
        self.documentsURL = documentsURL
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        directory == .documentDirectory ? [documentsURL] : super.urls(for: directory, in: domainMask)
    }
}

@Test func mp3EncoderProducesPlayableMP3() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.wav")
    let destination = root.appendingPathComponent("result.mp3")
    try waveFixture().write(to: source)

    try await MP3Encoder.encode(source: source, destination: destination)

    let data = try Data(contentsOf: destination)
    #expect(data.count > 100)
    #expect(data.starts(with: [0xFF, 0xF3]) || data.starts(with: [0xFF, 0xFB]))
}

private func waveFixture() -> Data {
    let sampleRate: UInt32 = 24_000
    let sampleCount = 4_800
    var samples = Data(capacity: sampleCount * 2)
    for index in 0..<sampleCount {
        var sample = Int16(
            sin(Float(index) * 2 * .pi * 440 / Float(sampleRate))
                * Float(Int16.max) * 0.2
        ).littleEndian
        withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
    }
    var wave = Data("RIFF".utf8)
    append(UInt32(36 + samples.count), to: &wave)
    wave.append(Data("WAVEfmt ".utf8))
    append(UInt32(16), to: &wave)
    append(UInt16(1), to: &wave)
    append(UInt16(1), to: &wave)
    append(sampleRate, to: &wave)
    append(sampleRate * 2, to: &wave)
    append(UInt16(2), to: &wave)
    append(UInt16(16), to: &wave)
    wave.append(Data("data".utf8))
    append(UInt32(samples.count), to: &wave)
    wave.append(samples)
    return wave
}

private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

@Test func sentenceAwareChunking() {
    let chunks = SpeechChunker.chunks(
        from: "First sentence. Second sentence is here. Third sentence.",
        maximumLength: 35
    )
    #expect(chunks.count >= 2)
    #expect(chunks.joined(separator: " ").contains("Third sentence."))
}

@Test func chunkingFallsBackForLongNoStopParagraph() {
    let chunks = SpeechChunker.chunks(
        from: "This paragraph has no full stop and should remain intact until the paragraph ends",
        maximumLength: 20
    )
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 20 })
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

@Test func singleNewlineCreatesSeparateSpeechChunks() {
    let chunks = SpeechChunker.chunks(
        from: "First entered line\nSecond entered line",
        maximumLength: 200
    )
    #expect(chunks == ["First entered line", "Second entered line"])
}

@Test func oversizedSentenceStaysIntact() {
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

@MainActor
@Test func pptxExtractorReadsSlidesAndImages() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = tempDirectory.appendingPathComponent("source", isDirectory: true)
    let pptDirectory = sourceDirectory.appendingPathComponent("ppt", isDirectory: true)
    let relsDirectory = pptDirectory.appendingPathComponent("_rels", isDirectory: true)
    let mediaDirectory = pptDirectory.appendingPathComponent("media", isDirectory: true)
    let slidesDirectory = pptDirectory.appendingPathComponent("slides", isDirectory: true)
    let slideRelsDirectory = slidesDirectory.appendingPathComponent("_rels", isDirectory: true)
    try FileManager.default.createDirectory(at: relsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: slidesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: slideRelsDirectory, withIntermediateDirectories: true)

    let presentationXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:sldIdLst>
            <p:sldId id="256" r:id="rId1"/>
            <p:sldId id="257" r:id="rId2"/>
            <p:sldId id="258" r:id="rId3"/>
        </p:sldIdLst>
    </p:presentation>
    """
    let relationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide3.xml"/>
    </Relationships>
    """
    let slide1XML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
            <p:spTree>
                <p:sp>
                    <p:txBody>
                        <a:p><a:r><a:t>First slide text.</a:t></a:r></a:p>
                    </p:txBody>
                </p:sp>
            </p:spTree>
        </p:cSld>
    </p:sld>
    """
    let slide2XML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:cSld>
            <p:spTree>
                <p:pic>
                    <p:blipFill>
                        <a:blip r:embed="rId9"/>
                    </p:blipFill>
                </p:pic>
            </p:spTree>
        </p:cSld>
    </p:sld>
    """
    let slide2RelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
    </Relationships>
    """
    let slide3XML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
            <p:spTree>
                <p:sp>
                    <p:txBody>
                        <a:p><a:r><a:t>Third slide wraps</a:t></a:r></a:p>
                        <a:p><a:br/></a:p>
                        <a:p><a:r><a:t>across lines.</a:t></a:r></a:p>
                    </p:txBody>
                </p:sp>
            </p:spTree>
        </p:cSld>
    </p:sld>
    """
    let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO2tX0cAAAAASUVORK5CYII="
    let pngData = Data(base64Encoded: pngBase64)!

    try presentationXML.data(using: .utf8)!.write(to: pptDirectory.appendingPathComponent("presentation.xml"))
    try relationshipsXML.data(using: .utf8)!.write(to: relsDirectory.appendingPathComponent("presentation.xml.rels"))
    try slide1XML.data(using: .utf8)!.write(to: slidesDirectory.appendingPathComponent("slide1.xml"))
    try slide2XML.data(using: .utf8)!.write(to: slidesDirectory.appendingPathComponent("slide2.xml"))
    try slide2RelsXML.data(using: .utf8)!.write(to: slideRelsDirectory.appendingPathComponent("slide2.xml.rels"))
    try slide3XML.data(using: .utf8)!.write(to: slidesDirectory.appendingPathComponent("slide3.xml"))
    try pngData.write(to: mediaDirectory.appendingPathComponent("image1.png"))

    let pptxURL = tempDirectory.appendingPathComponent("deck.pptx")
    try FileManager.default.zipItem(at: sourceDirectory, to: pptxURL, shouldKeepParent: false)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let extractor = PresentationDocumentExtractor()
    #expect(extractor.canHandle(pptxURL))

    let content = try await extractor.extract(from: pptxURL) { _, _ in }
    #expect(content.sections.count == 3)
    #expect(content.sections[0].text.contains("First slide text."))
    #expect(content.sections[1].text.contains("Image on this slide."))
    #expect(content.sections[1].imageData != nil)
    #expect(content.sections[1].displayText.isEmpty)
    #expect(content.sections[2].text.contains("Third slide wraps"))
    #expect(content.sections[2].text.contains("across lines."))
    #expect(content.sections[2].text.contains("Third slide wraps\nacross lines."))
    #expect(!content.sections[2].text.contains("<a:"))
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
