@preconcurrency import AppKit
import Foundation
import ImageIO
@preconcurrency import PDFKit
import ZIPFoundation
import UniformTypeIdentifiers
@preconcurrency import Vision

typealias ExtractionProgress = @Sendable (_ fraction: Double, _ message: String) async -> Void

protocol DocumentExtractor: Sendable {
    func canHandle(_ url: URL) -> Bool
    func extract(from url: URL, progress: @escaping ExtractionProgress) async throws -> DocumentContent
}

struct PDFDocumentExtractor: DocumentExtractor {
    func canHandle(_ url: URL) -> Bool {
        SupportedTypes.type(for: url)?.conforms(to: .pdf) == true
    }

    func extract(from url: URL, progress: @escaping ExtractionProgress) async throws -> DocumentContent {
        try await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(url: url) else { throw ReaderError.unreadable }
            guard !pdf.isLocked else { throw ReaderError.lockedPDF }

            var sections: [ReadingSection] = []
            var usedOCR = false
            let count = pdf.pageCount
            guard count > 0 else { throw ReaderError.empty }

            for index in 0..<count {
                try Task.checkCancellation()
                await progress(
                    Double(index) / Double(count),
                    "Reading page \(index + 1) of \(count)…"
                )
                guard let page = pdf.page(at: index) else { continue }
                var text = TextUtilities.clean(page.string ?? "")

                if text.count < 24 {
                    await progress(
                        Double(index) / Double(count),
                        "Recognizing page \(index + 1) of \(count)…"
                    )
                    text = try Self.recognize(page: page)
                    usedOCR = usedOCR || !text.isEmpty
                }

                if !text.isEmpty {
                    let paragraphs = TextUtilities.paragraphs(from: text)
                    sections.append(contentsOf:
                        paragraphs.enumerated().map { paragraphIndex, paragraph in
                            ReadingSection(
                                title: paragraphs.count == 1
                                    ? "Page \(index + 1)"
                                    : "Page \(index + 1) · \(paragraphIndex + 1)",
                                text: paragraph,
                                pageIndex: index
                            )
                        }
                    )
                }
            }

            guard !sections.isEmpty else { throw ReaderError.empty }
            await progress(1, "Ready")
            return DocumentContent(
                title: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                typeIdentifier: UTType.pdf.identifier,
                sections: sections,
                usedOCR: usedOCR
            )
        }.value
    }

    private static func recognize(page: PDFPage) throws -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2.5, max(1.5, 1800 / max(bounds.width, 1)))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw ReaderError.imageDecode
        }
        return try OCR.recognize(cgImage)
    }
}

struct PresentationDocumentExtractor: DocumentExtractor {
    func canHandle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pptx"
    }

    func extract(from url: URL, progress: @escaping ExtractionProgress) async throws -> DocumentContent {
        try await Task.detached(priority: .userInitiated) {
            await progress(0.05, "Opening presentation…")

            let fileManager = FileManager.default
            let stagingDirectory = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: stagingDirectory) }

            try fileManager.unzipItem(at: url, to: stagingDirectory)

            let parser = PPTXParser(rootDirectory: stagingDirectory)
            let slides = try parser.extractSlides()
            guard !slides.isEmpty else { throw ReaderError.empty }

            await progress(1, "Ready")
            return DocumentContent(
                title: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                typeIdentifier: UTType(filenameExtension: "pptx")?.identifier ?? "org.openxmlformats.presentationml.presentation",
                sections: slides.enumerated().map { index, slide in
                    ReadingSection(
                        title: slide.title ?? "Slide \(index + 1)",
                        text: slide.text,
                        pageIndex: index
                    )
                },
                usedOCR: false
            )
        }.value
    }
}

private struct PPTXSlide {
    let title: String?
    let text: String
}

private struct PPTXParser {
    let rootDirectory: URL

    func extractSlides() throws -> [PPTXSlide] {
        let orderedSlidePaths = try orderedSlidePaths()
        return try orderedSlidePaths.enumerated().map { index, slidePath in
            let slideURL = rootDirectory
                .appendingPathComponent("ppt", isDirectory: true)
                .appendingPathComponent(slidePath)
            let xml = try String(contentsOf: slideURL, encoding: .utf8)
            let extractedText = slideText(from: xml)
            let imageCount = imageCount(in: xml)
            let slideText: String

            if extractedText.isEmpty {
                slideText = imageCount > 0 ? "Image on this slide." : "No readable text on this slide."
            } else if imageCount > 0 {
                slideText = extractedText + "\n\nImage on this slide."
            } else {
                slideText = extractedText
            }

            return PPTXSlide(title: "Slide \(index + 1)", text: slideText)
        }
    }

    private func orderedSlidePaths() throws -> [String] {
        let presentationURL = rootDirectory.appendingPathComponent("ppt/presentation.xml")
        let relationshipsURL = rootDirectory.appendingPathComponent("ppt/_rels/presentation.xml.rels")
        let presentationXML = try String(contentsOf: presentationURL, encoding: .utf8)
        let relationshipsXML = try String(contentsOf: relationshipsURL, encoding: .utf8)
        let relationshipMap = relationshipTargets(from: relationshipsXML)

        let slideReferencePattern = #"<p:sldId\b[^>]*r:id="([^"]+)"[^>]*/?>"#
        let slideIDs = captureGroups(in: presentationXML, pattern: slideReferencePattern)
        if !slideIDs.isEmpty {
            let slides = slideIDs.compactMap { relationshipMap[$0] }
            if !slides.isEmpty { return slides }
        }

        let slideDirectory = rootDirectory.appendingPathComponent("ppt/slides", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: slideDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .map(
                \.lastPathComponent
            )
            .filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
            .sorted { lhs, rhs in
                slideNumber(in: lhs) < slideNumber(in: rhs)
            }
    }

    private func relationshipTargets(from xml: String) -> [String: String] {
        let pattern = #"<Relationship\b[^>]*Id="([^"]+)"[^>]*Type="[^"]*/slide"[^>]*Target="([^"]+)"[^>]*/?>"#
        return Dictionary(uniqueKeysWithValues: capturePairs(in: xml, pattern: pattern))
    }

    private func slideText(from xml: String) -> String {
        SlideTextExtractor.extract(from: xml)
    }

    private func imageCount(in xml: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"<a:blip\b"#, options: []) else { return 0 }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.numberOfMatches(in: xml, options: [], range: range)
    }

    private func slideNumber(in fileName: String) -> Int {
        let digits = fileName.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits) ?? .max
    }

    private func captureGroups(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[groupRange])
        }
    }

    private func capturePairs(in text: String, pattern: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 2,
                  let firstRange = Range(match.range(at: 1), in: text),
                  let secondRange = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[firstRange]), String(text[secondRange]))
        }
    }

    private func unescapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

private final class SlideTextExtractor: NSObject, XMLParserDelegate {
    private var result = ""
    private var collectingText = false
    private var lastWasNewline = false

    static func extract(from xml: String) -> String {
        guard let data = xml.data(using: .utf8) else { return "" }
        let extractor = SlideTextExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        _ = parser.parse()
        return extractor.result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String : String] = [:]) {
        if elementName == "t" {
            collectingText = true
        } else if elementName == "br" {
            appendNewline()
        } else if elementName == "p" {
            if !result.isEmpty && !lastWasNewline {
                result += " "
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collectingText else { return }
        result += string
        lastWasNewline = false
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "t" {
            collectingText = false
        }
    }

    private func appendNewline() {
        guard !lastWasNewline else { return }
        result += "\n"
        lastWasNewline = true
    }
}

struct PlainTextExtractor: DocumentExtractor {
    func canHandle(_ url: URL) -> Bool {
        guard let type = SupportedTypes.type(for: url) else {
            return ["md", "markdown"].contains(url.pathExtension.lowercased())
        }
        return type.conforms(to: .plainText) ||
            ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    func extract(from url: URL, progress: @escaping ExtractionProgress) async throws -> DocumentContent {
        try await Task.detached(priority: .userInitiated) {
            await progress(0.2, "Reading document…")
            let data = try Data(contentsOf: url)
            let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
            guard let raw else { throw ReaderError.unreadable }
            let text = TextUtilities.clean(raw)
            guard !text.isEmpty else { throw ReaderError.empty }
            await progress(1, "Ready")
            return Self.content(url: url, text: text)
        }.value
    }

    static func content(url: URL, text: String) -> DocumentContent {
        let parts = TextUtilities.paragraphs(from: text)
        let sections = parts.enumerated().map {
            ReadingSection(title: "Section \($0.offset + 1)", text: $0.element)
        }
        return DocumentContent(
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            typeIdentifier: SupportedTypes.type(for: url)?.identifier ?? UTType.plainText.identifier,
            sections: sections,
            usedOCR: false
        )
    }
}

struct RichTextExtractor: DocumentExtractor {
    func canHandle(_ url: URL) -> Bool {
        SupportedTypes.type(for: url)?.conforms(to: .rtf) == true
    }

    func extract(from url: URL, progress: @escaping ExtractionProgress) async throws -> DocumentContent {
        try await Task.detached(priority: .userInitiated) {
            await progress(0.2, "Reading rich text…")
            let attributed = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            let text = TextUtilities.clean(attributed.string)
            guard !text.isEmpty else { throw ReaderError.empty }
            await progress(1, "Ready")
            return PlainTextExtractor.content(url: url, text: text)
        }.value
    }
}

struct ImageDocumentExtractor: DocumentExtractor {
    func canHandle(_ url: URL) -> Bool {
        guard let type = SupportedTypes.type(for: url) else { return false }
        return type.conforms(to: .image)
    }

    func extract(from url: URL, progress: @escaping ExtractionProgress) async throws -> DocumentContent {
        try await Task.detached(priority: .userInitiated) {
            await progress(0.1, "Loading image…")
            guard
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ReaderError.imageDecode }
            await progress(0.35, "Recognizing text…")
            let text = try OCR.recognize(image)
            guard !text.isEmpty else { throw ReaderError.empty }
            await progress(1, "Ready")
            return DocumentContent(
                title: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                typeIdentifier: SupportedTypes.type(for: url)?.identifier ?? UTType.image.identifier,
                sections: [ReadingSection(title: "Recognized text", text: text)],
                usedOCR: true
            )
        }.value
    }
}

private enum OCR {
    static func recognize(_ image: CGImage) throws -> String {
        var result: [String] = []
        let request = VNRecognizeTextRequest { request, _ in
            result = (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return TextUtilities.clean(result.joined(separator: "\n"))
    }
}
