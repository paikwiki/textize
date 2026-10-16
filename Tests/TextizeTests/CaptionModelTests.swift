import Foundation
import Testing
@testable import Textize

/// 자막 모델의 구간(segment) 교체·선번역 인계·trim 규칙. 문장 분리는 영어 구두점으로 고정해 NLTokenizer 결과를 예측 가능하게 둔다.
@MainActor
struct CaptionModelTests {
    private func makeModel() -> CaptionModel {
        let m = CaptionModel()
        m.sentenceLocale = Locale(identifier: "en-US")
        return m
    }

    @Test func volatileResultDoesNotCreateLines() {
        let m = makeModel()
        let ids = m.append(text: "First sentence. Second sentence.", isFinal: false, start: 0)
        #expect(ids.isEmpty)
        #expect(m.lines.isEmpty)
        #expect(m.volatileSentences == ["First sentence.", "Second sentence."])
    }

    @Test func finalResultAppendsOneLinePerSentence() {
        let m = makeModel()
        let ids = m.append(text: "First sentence. Second sentence.", isFinal: true, start: 0)
        #expect(m.lines.map(\.text) == ["First sentence.", "Second sentence."])
        #expect(ids == m.lines.map(\.id))
        #expect(m.volatileSentences.isEmpty)
    }

    @Test func emptyFinalClearsVolatileState() {
        let m = makeModel()
        m.append(text: "Hello there.", isFinal: false, start: 0)
        m.volatileTranslations["Hello there."] = "안녕하세요."
        let ids = m.append(text: "   ", isFinal: true, start: 0)
        #expect(ids.isEmpty)
        #expect(m.lines.isEmpty)
        #expect(m.volatileSentences.isEmpty)
        #expect(m.volatileTranslations.isEmpty)
    }

    @Test func pretranslationIsCarriedIntoFinalLine() {
        let m = makeModel()
        m.append(text: "Hello there. How are", isFinal: false, start: 0)
        m.volatileTranslations["Hello there."] = "안녕하세요."
        m.append(text: "Hello there. How are you?", isFinal: true, start: 0)
        #expect(m.lines.map(\.translation) == ["안녕하세요.", nil])
        #expect(m.volatileTranslations.isEmpty)
    }

    @Test func pretranslationIsDroppedWhenSentenceChanged() {
        let m = makeModel()
        m.volatileTranslations["Hello there."] = "안녕하세요."
        m.append(text: "Hello here.", isFinal: true, start: 0)
        #expect(m.lines.first?.translation == nil)
    }

    @Test func sameSegmentRefinalizationReplacesLinesInPlace() {
        let m = makeModel()
        m.append(text: "Before.", isFinal: true, start: 0)
        let first = m.append(text: "Hello there. How are you?", isFinal: true, start: 10.0)
        m.append(text: "After.", isFinal: true, start: 20.0)
        m.update(first[0]) { $0.translation = "안녕하세요." }

        // 같은 구간(0.05초 이내)이 다시 확정됨: 첫 문장은 그대로, 둘째 문장은 바뀜.
        let changed = m.append(text: "Hello there. How are you today?", isFinal: true, start: 10.02)

        #expect(m.lines.map(\.text) == ["Before.", "Hello there.", "How are you today?", "After."])
        #expect(m.lines[1].id == first[0])
        #expect(m.lines[1].translation == "안녕하세요.")
        #expect(changed == [m.lines[2].id])
        #expect(!m.lines.contains { $0.id == first[1] })
    }

    @Test func differentSegmentAppendsEvenIfTextRepeats() {
        let m = makeModel()
        m.append(text: "Same.", isFinal: true, start: 0)
        m.append(text: "Same.", isFinal: true, start: 1.0)
        #expect(m.lines.count == 2)
    }

    @Test func beginSessionForgetsSegmentsButKeepsLines() {
        let m = makeModel()
        m.append(text: "Old line.", isFinal: true, start: 0)
        m.append(text: "Pending", isFinal: false, start: 5)
        m.volatileTranslations["Pending"] = "대기"
        m.beginSession()
        #expect(m.volatileSentences.isEmpty)
        #expect(m.volatileTranslations.isEmpty)
        // 새 인식기의 오디오 시각은 0부터 다시 시작하지만 기존 줄을 덮어쓰면 안 된다.
        m.append(text: "New line.", isFinal: true, start: 0)
        #expect(m.lines.map(\.text) == ["Old line.", "New line."])
    }

    @Test func resetClearsEverything() {
        let m = makeModel()
        m.append(text: "A line.", isFinal: true, start: 0)
        m.followLive = false
        m.append(text: "B line.", isFinal: true, start: 2)
        m.append(text: "Pending", isFinal: false, start: 3)
        m.reset()
        #expect(m.lines.isEmpty)
        #expect(m.volatileSentences.isEmpty)
        #expect(m.pendingCount == 0)
        #expect(m.isEmpty)
    }

    @Test func isEmptyConsidersStatusText() {
        let m = makeModel()
        #expect(m.isEmpty)
        m.status = "Listening"
        #expect(!m.isEmpty)
    }

    @Test func updateChangesOnlyMatchingLine() {
        let m = makeModel()
        let ids = m.append(text: "One. Two.", isFinal: true, start: 0)
        m.update(ids[1]) { $0.isTranslating = true }
        #expect(m.lines.map(\.isTranslating) == [false, true])
        m.update(UUID()) { $0.text = "should not apply" }
        #expect(m.lines.map(\.text) == ["One.", "Two."])
    }

    @Test func trimsToMaxLinesWhileFollowingLive() {
        let m = makeModel()
        for i in 0..<205 { m.append(text: "Line \(i).", isFinal: true, start: Double(i)) }
        #expect(m.lines.count == 200)
        #expect(m.lines.first?.text == "Line 5.")
        #expect(m.lines.last?.text == "Line 204.")
    }

    @Test func doesNotTrimWhileScrolledBackAndCountsPending() {
        let m = makeModel()
        for i in 0..<200 { m.append(text: "Line \(i).", isFinal: true, start: Double(i)) }
        m.followLive = false
        m.append(text: "Extra one. Extra two.", isFinal: true, start: 500)
        #expect(m.lines.count == 202)
        #expect(m.pendingCount == 2)

        m.followLive = true
        #expect(m.pendingCount == 0)
        #expect(m.lines.count == 200)
        #expect(m.lines.first?.text == "Line 2.")
    }

    @Test func returnedIDsAlwaysExistInLines() {
        let m = makeModel()
        for i in 0..<199 { m.append(text: "Line \(i).", isFinal: true, start: Double(i)) }
        let ids = m.append(text: "Tail one. Tail two.", isFinal: true, start: 999)
        #expect(ids.count == 2)
        #expect(ids.allSatisfy { id in m.lines.contains { $0.id == id } })
        #expect(m.lines.count == 200)
    }
}

/// 메뉴바 메뉴는 자막 갱신에 반응하면 안 된다 (하위 메뉴가 닫힌다). MenuState가 그 방화벽이다.
@MainActor
struct MenuStateTests {
    @Test func mirrorsModelFlags() {
        let model = CaptionModel()
        let menu = MenuState()
        menu.bind(to: model)

        model.isRunning = true
        model.isSelecting = true
        model.isOverlayHidden = true
        model.isAutoHidden = true
        #expect(menu.isRunning && menu.isSelecting && menu.isOverlayHidden && menu.isAutoHidden)

        model.isRunning = false
        #expect(menu.isRunning == false)
    }

    @Test func captionUpdatesDoNotNotifyMenu() {
        let model = CaptionModel()
        let menu = MenuState()
        menu.bind(to: model)

        var notifications = 0
        let sub = menu.objectWillChange.sink { notifications += 1 }
        defer { sub.cancel() }

        model.append(text: "Hello there.", isFinal: true, start: 0)
        model.append(text: "More", isFinal: false, start: 1)
        model.status = "Listening"
        model.isRunning = model.isRunning   // 같은 값은 removeDuplicates로 걸러진다
        #expect(notifications == 0)

        model.isRunning = true
        #expect(notifications == 1)
    }
}
