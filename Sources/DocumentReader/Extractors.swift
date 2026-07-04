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
    struct TextLine: Sendable {
        var text: String
        var bounds: CGRect
    }

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
                var text = Self.layoutAwareText(from: page)

                if text.count < 24 {
                    await progress(
                        Double(index) / Double(count),
                        "Recognizing page \(index + 1) of \(count)…"
                    )
                    text = try Self.recognize(page: page)
                    usedOCR = usedOCR || !text.isEmpty
                }

                if !text.isEmpty {
                    sections.append(contentsOf: Self.sections(from: text, pageIndex: index))
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

    static func sections(from text: String, pageIndex: Int) -> [ReadingSection] {
        let cleaned = TextUtilities.clean(text)
        guard !cleaned.isEmpty else { return [] }
        return [
            ReadingSection(
                title: "Page \(pageIndex + 1)",
                text: cleaned,
                pageIndex: pageIndex
            )
        ]
    }

    private static func layoutAwareText(from page: PDFPage) -> String {
        let pageBounds = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: pageBounds) else {
            return TextUtilities.clean(page.string ?? "")
        }

        let lines = selection.selectionsByLine().compactMap { line -> TextLine? in
            let text = TextUtilities.clean(line.string ?? "")
            guard !text.isEmpty else { return nil }
            return TextLine(text: text, bounds: line.bounds(for: page))
        }

        guard !lines.isEmpty else {
            return TextUtilities.clean(page.string ?? "")
        }
        return text(from: lines)
    }

    static func text(from lines: [TextLine]) -> String {
        guard let first = lines.first else { return "" }

        let typicalHeight = median(
            lines.map(\.bounds.height).filter { $0 > 0 }
        )
        var result = first.text

        for (previous, current) in zip(lines, lines.dropFirst()) {
            let centerDistance = abs(previous.bounds.midY - current.bounds.midY)
            let edgeGap = max(
                0,
                centerDistance - ((previous.bounds.height + current.bounds.height) / 2)
            )
            let sameVisualLine = centerDistance < max(previous.bounds.height, current.bounds.height) * 0.45
            let changedColumn = sameVisualLine
                || abs(current.bounds.minX - previous.bounds.minX) > max(previous.bounds.width, current.bounds.width) * 0.9
            let paragraphGap = edgeGap > max(typicalHeight * 0.55, 3)

            if paragraphGap || changedColumn {
                result += "\n\n"
            } else {
                result += joiner(after: previous.text, before: current.text)
            }
            result += current.text
        }

        return TextUtilities.clean(result)
    }

    private static func joiner(after previous: String, before current: String) -> String {
        if previous.hasSuffix("-"),
           current.first?.isLowercase == true {
            return ""
        }
        return " "
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 12 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
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
                        imageData: slide.imageData,
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
    let imageData: Data?
}

private struct PPTXParser {
    let rootDirectory: URL

    func extractSlides() throws -> [PPTXSlide] {
        let orderedSlidePaths = try orderedSlidePaths()
        return try orderedSlidePaths.enumerated().map { index, slidePath in
            let slideURL = rootDirectory
                .appendingPathComponent("ppt", isDirectory: true)
                .appendingPathComponent(slidePath)
            let relationships = try slideRelationships(for: slidePath)
            let xml = try String(contentsOf: slideURL, encoding: .utf8)
            let extractedText = slideText(from: xml)
            let imageData = extractImageData(from: relationships)
            let slideText: String

            if extractedText.isEmpty {
                slideText = imageData != nil ? "Image on this slide." : "No readable text on this slide."
            } else if imageData != nil {
                slideText = extractedText + "\n\nImage on this slide."
            } else {
                slideText = extractedText
            }

            return PPTXSlide(title: "Slide \(index + 1)", text: slideText, imageData: imageData)
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
        let pattern = #"<Relationship\b[^>]*Id="([^"]+)"[^>]*Target="([^"]+)"[^>]*/?>"#
        return Dictionary(uniqueKeysWithValues: capturePairs(in: xml, pattern: pattern))
    }

    private func slideRelationships(for slidePath: String) throws -> [String: String] {
        let slideRelationshipsURL = rootDirectory
            .appendingPathComponent("ppt", isDirectory: true)
            .appendingPathComponent("slides", isDirectory: true)
            .appendingPathComponent("_rels", isDirectory: true)
            .appendingPathComponent((slidePath as NSString).lastPathComponent + ".rels")
        guard FileManager.default.fileExists(atPath: slideRelationshipsURL.path) else {
            return [:]
        }
        let xml = try String(contentsOf: slideRelationshipsURL, encoding: .utf8)
        return relationshipTargets(from: xml)
    }

    private func extractImageData(from relationships: [String: String]) -> Data? {
        for target in relationships.values {
            let lowercased = target.lowercased()
            guard lowercased.hasSuffix(".png") || lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") || lowercased.hasSuffix(".heic") || lowercased.hasSuffix(".tiff") || lowercased.hasSuffix(".gif") else {
                continue
            }

            let imageURL = URL(fileURLWithPath: target, relativeTo: rootDirectory.appendingPathComponent("ppt/slides", isDirectory: true))
                .standardizedFileURL
            if let data = try? Data(contentsOf: imageURL), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private func slideText(from xml: String) -> String {
        SlideTextExtractor.extract(from: xml)
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
                appendNewline()
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
