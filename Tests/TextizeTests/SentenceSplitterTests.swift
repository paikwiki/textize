import Foundation
import Testing
@testable import Textize

struct SentenceSplitterTests {
    private let ko = Locale(identifier: "ko-KR")
    private let en = Locale(identifier: "en-US")
    private let ja = Locale(identifier: "ja-JP")

    @Test func emptyOrWhitespaceGivesNothing() {
        #expect(SentenceSplitter.split("", locale: ko).isEmpty)
        #expect(SentenceSplitter.split("  \n\t ", locale: ko).isEmpty)
    }

    @Test func splitsKoreanSentences() {
        #expect(SentenceSplitter.split("안녕하세요. 자막 테스트입니다.", locale: ko) == ["안녕하세요.", "자막 테스트입니다."])
    }

    @Test func splitsEnglishOnTerminalPunctuation() {
        #expect(SentenceSplitter.split("Hello there. How are you? Fine!", locale: en) == ["Hello there.", "How are you?", "Fine!"])
    }

    @Test func splitsJapaneseSentences() {
        #expect(SentenceSplitter.split("こんにちは。テストです。", locale: ja) == ["こんにちは。", "テストです。"])
    }

    @Test func keepsUnterminatedSpeechAsOneSentence() {
        #expect(SentenceSplitter.split("this is still being spoken", locale: en) == ["this is still being spoken"])
    }

    @Test func trimsWhitespaceAroundSentences() {
        #expect(SentenceSplitter.split("  Hello there.   How are you?  \n", locale: en) == ["Hello there.", "How are you?"])
    }

    @Test func unknownLocaleStillSplits() {
        let zxx = Locale(identifier: "zxx")
        #expect(SentenceSplitter.split("One. Two.", locale: zxx).count == 2)
    }
}
