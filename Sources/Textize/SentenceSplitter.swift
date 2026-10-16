import Foundation
import NaturalLanguage

enum SentenceSplitter {
    static func split(_ text: String, locale: Locale) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        if let code = locale.language.languageCode?.identifier {
            tokenizer.setLanguage(NLLanguage(rawValue: code))
        }
        tokenizer.string = trimmed
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let s = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        return sentences.isEmpty ? [trimmed] : sentences
    }
}
