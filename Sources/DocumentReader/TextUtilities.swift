import Foundation

enum TextUtilities {
    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func paragraphs(from text: String) -> [String] {
        clean(text)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

enum SpeechChunker {
    static func chunks(from text: String, maximumLength: Int = 700) -> [String] {
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
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph

        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let sentence = String(paragraph[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }

            if sentence.count > maximumLength {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                result.append(contentsOf: split(sentence, maximumLength: maximumLength))
                return true
            }

            if !current.isEmpty && current.count + sentence.count + 1 > maximumLength {
                result.append(current)
                current = sentence
            } else {
                current += current.isEmpty ? sentence : " \(sentence)"
            }
            return true
        }

        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [paragraph] : result
    }

    private static func split(_ text: String, maximumLength: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !current.isEmpty && current.count + word.count + 1 > maximumLength {
                result.append(current)
                current = String(word)
            } else {
                current += current.isEmpty ? String(word) : " \(word)"
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

import NaturalLanguage
