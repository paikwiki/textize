import Combine
import Foundation

struct CaptionLine: Identifiable, Equatable {
    let id: UUID
    var text: String
    var translation: String?
    var isTranslating = false
    /// 선택 모드에서 클릭해 펼친 상태 (원문만: 번역 표시 / 번역만: 원문 표시).
    var revealed = false
}

@MainActor
final class CaptionModel: ObservableObject {
    @Published var lines: [CaptionLine] = []
    @Published var volatileSentences: [String] = []
    /// 임시 문장의 선번역 (원문 → 번역). 말이 길게 이어져 확정이 늦어도 번역을 미리 보여 주고, 확정 시 그대로 넘긴다.
    @Published var volatileTranslations: [String: String] = [:]
    @Published var status: String = ""
    @Published var isRunning = false
    @Published var isOnResizeEdge = false
    @Published var isSelecting = false
    @Published var isOverlayHidden = false
    @Published var isAutoHidden = false
    /// 커서가 스크롤 띠(오른쪽 가장자리) 위에 있어 창이 마우스를 받는 중.
    @Published var isHovering = false
    /// 커서가 상자 위 어딘가에 있음(띠 힌트 표시용). 클릭은 통과한다.
    @Published var isCursorOverBox = false
    @Published var followLive = true {
        didSet { if followLive { pendingCount = 0; trim() } }
    }
    @Published var pendingCount = 0

    var sentenceLocale = Locale(identifier: "ko-KR")
    var onLineTapped: ((UUID) -> Void)?

    private let maxLines = 200
    /// 인식기가 준 오디오 구간(start) → 그 구간에서 나온 줄들. 같은 구간이 다시 확정되면 교체한다.
    private var segments: [(start: Double, ids: [UUID])] = []

    @discardableResult
    func append(text: String, isFinal: Bool, start: Double) -> [UUID] {
        let sentences = SentenceSplitter.split(text, locale: sentenceLocale)
        guard isFinal else {
            volatileSentences = sentences
            return []
        }
        volatileSentences = []
        let pre = volatileTranslations
        volatileTranslations = [:]
        guard !sentences.isEmpty else { return [] }
        func makeLine(_ s: String) -> CaptionLine { CaptionLine(id: UUID(), text: s, translation: pre[s]) }

        var changed: [UUID] = []
        if let seg = segments.firstIndex(where: { abs($0.start - start) < 0.05 }) {
            // 같은 구간 재확정: 기존 줄을 교체하되, 문장이 그대로면 번역도 유지한다.
            let oldIDs = segments[seg].ids
            let oldLines = oldIDs.compactMap { id in lines.first { $0.id == id } }
            var newLines: [CaptionLine] = []
            for s in sentences {
                if let same = oldLines.first(where: { $0.text == s }) {
                    newLines.append(same)
                } else {
                    let line = makeLine(s)
                    newLines.append(line)
                    changed.append(line.id)
                }
            }
            let insertAt = lines.firstIndex { oldIDs.contains($0.id) } ?? lines.count
            lines.removeAll { oldIDs.contains($0.id) }
            lines.insert(contentsOf: newLines, at: min(insertAt, lines.count))
            segments[seg].ids = newLines.map(\.id)
        } else {
            let newLines = sentences.map(makeLine)
            lines.append(contentsOf: newLines)
            segments.append((start: start, ids: newLines.map(\.id)))
            changed = newLines.map(\.id)
            if !followLive { pendingCount += newLines.count }
        }
        trim()
        return changed.filter { id in lines.contains { $0.id == id } }
    }

    /// 위로 스크롤해 보는 중에는 지우지 않는다 (보던 위치가 밀리지 않도록).
    private func trim() {
        guard followLive, lines.count > maxLines else { return }
        let removed = Set(lines.prefix(lines.count - maxLines).map(\.id))
        lines.removeFirst(lines.count - maxLines)
        for i in segments.indices { segments[i].ids.removeAll { removed.contains($0) } }
        segments.removeAll { $0.ids.isEmpty }
    }

    func update(_ id: UUID, _ change: (inout CaptionLine) -> Void) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[i])
    }

    var isEmpty: Bool { lines.isEmpty && volatileSentences.isEmpty && status.isEmpty }

    func reset() {
        lines = []
        segments = []
        volatileSentences = []
        volatileTranslations = [:]
        pendingCount = 0
    }

    /// 인식을 다시 시작할 때. 기존 줄은 남기고, 새 인식기의 오디오 시각(0부터 다시 시작)이 예전 구간과
    /// 겹쳐 기존 줄을 덮어쓰지 않도록 구간 기록과 임시 상태만 비운다.
    func beginSession() {
        segments = []
        volatileSentences = []
        volatileTranslations = [:]
    }
}
