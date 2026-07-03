@preconcurrency import AppKit
import Foundation
import ImageIO
@preconcurrency import PDFKit
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
        let parts = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
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
