import Foundation

enum TextUtilities {
    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: #"\r\n|\r"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func paragraphs(from text: String) -> [String] {
        clean(text)
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }
}

enum SpeechChunker {
    static func chunks(from text: String, maximumLength: Int = 300) -> [String] {
        let cleaned = TextUtilities.clean(text)
        guard !cleaned.isEmpty else { return [] }

        var result: [String] = []
        for paragraph in cleaned.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result.append(contentsOf: chunks(in: trimmed, maximumLength: maximumLength))
        }

        return result.isEmpty ? [cleaned] : result
    }

    private static func chunks(in paragraph: String, maximumLength: Int) -> [String] {
        var result: [String] = []
        var current = ""

        for sentence in sentences(in: paragraph) {
            guard !sentence.isEmpty else { continue }

            if sentence.count > maximumLength {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                result.append(contentsOf: overflowChunks(from: sentence, maximumLength: maximumLength))
                continue
            }

            if !current.isEmpty && current.count + sentence.count + 1 > maximumLength {
                result.append(current)
                current = sentence
            } else {
                current += current.isEmpty ? sentence : " \(sentence)"
            }
        }

        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [paragraph] : result
    }

    private static func overflowChunks(from text: String, maximumLength: Int) -> [String] {
        var result: [String] = []
        var current = ""

        for word in text.split(whereSeparator: \.isWhitespace) {
            let wordText = String(word)
            if !current.isEmpty && current.count + wordText.count + 1 > maximumLength {
                result.append(current)
                current = wordText
            } else {
                current += current.isEmpty ? wordText : " \(wordText)"
            }
        }

        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func sentences(in paragraph: String) -> [String] {
        let pieces = paragraph.components(separatedBy: ".")
        guard pieces.count > 1 else { return [paragraph] }

        var sentences: [String] = []
        for index in pieces.indices {
            let fragment = pieces[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if fragment.isEmpty {
                continue
            }

            if index < pieces.count - 1 {
                sentences.append(fragment + ".")
            } else if paragraph.hasSuffix(".") {
                sentences.append(fragment + ".")
            } else {
                sentences.append(fragment)
            }
        }

        return sentences.isEmpty ? [paragraph] : sentences
    }

}
