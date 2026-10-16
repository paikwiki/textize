import AppKit
import Combine
import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: Settings
    @State private var hoveredLine: UUID?

    private var primary: Color { .white }
    private var secondary: Color { .white.opacity(0.65) }
    private var translationColor: Color { Color(red: 0.6, green: 0.85, blue: 1.0) }

    @State private var resumeTask: Task<Void, Never>?
    /// 내용이 늘어나 프로그램이 바닥으로 내리는 동안에는 "바닥이 아님" 판정을 무시한다.
    @State private var ignoreGeometryUntil = Date.distantPast

    var body: some View {
        // 루트를 창 크기에 정확히 고정한다. 그래야 넘치는 글이 아래 기준으로 잘리고 둥근 클립이 창 안에 남는다.
        GeometryReader { geo in
            content(height: geo.size.height).frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func content(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(settings.backgroundOpacity))
                .allowsHitTesting(false)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: model.isHovering) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.lines) { line in
                            lineView(line)
                        }
                        ForEach(Array(model.volatileSentences.enumerated()), id: \.offset) { _, s in
                            volatileView(s)
                        }
                        if !model.status.isEmpty {
                            Text(model.status)
                                .font(.system(size: settings.fontSize * 0.55))
                                .foregroundStyle(.yellow)
                        }
                        if model.isSelecting && model.lines.isEmpty {
                            hint(settings.translationDisplay == .translationOnly
                                 ? L("Click a sentence to see its original. Esc to exit.")
                                 : L("Click a sentence to see its translation. Esc to exit."))
                        } else if model.isEmpty {
                            Text(model.isRunning ? L("Listening…") : L("Captions stopped"))
                                .font(.system(size: settings.fontSize * 0.55))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(.system(size: settings.fontSize, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, settings.fontSize * 0.75)
                    .padding(.vertical, settings.fontSize * 0.5)
                    .frame(minHeight: height, alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom)
                // 바닥에 닿으면 따라가기 복귀. 해제는 사용자가 휠을 굴릴 때(커서가 상자 위)만, 내용이 늘어나서 생긴 변화는 무시.
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 12
                } action: { _, atBottom in
                    if atBottom {
                        if !model.followLive { model.followLive = true }
                    } else if model.isHovering, Date() >= ignoreGeometryUntil, model.followLive {
                        model.followLive = false
                    }
                }
                .onChange(of: model.lines) { _, _ in followBottom(proxy) }
                .onChange(of: model.volatileSentences) { _, _ in followBottom(proxy) }
                .onChange(of: settings.fontSize) { _, _ in followBottom(proxy) }
                .onChange(of: model.isCursorOverBox) { _, over in
                    resumeTask?.cancel()
                    guard !over, !model.followLive else { return }
                    resumeTask = Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        guard !Task.isCancelled, !model.isCursorOverBox else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                // 새 자막 수 표시. 누르면 바닥(실시간)으로 간다. 본 패널은 평소 클릭을 통과시키므로
                // OverlayPanel.pollHover가 이 영역(liveIndicatorSize)에서만 마우스를 받게 한다.
                .overlay(alignment: .bottom) {
                    if !model.followLive, model.pendingCount > 0 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Text("↓ \(model.pendingCount)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(.blue.opacity(0.85), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("Jump to live"))
                        .frame(width: OverlayPanel.liveIndicatorSize.width, height: OverlayPanel.liveIndicatorSize.height, alignment: .top)
                    }
                }
                .overlay(alignment: .trailing) {
                    if model.isCursorOverBox && !model.isSelecting {
                        scrollStrip(proxy)
                    }
                }
            }

            // 테두리는 그리기만 하고 클릭은 아래 문장 뷰로 보낸다 (도형은 선만 그려도 히트 영역이 전체다).
            if model.isSelecting {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(translationColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .allowsHitTesting(false)
            } else if model.isOnResizeEdge {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func scrollStrip(_ proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(model.isHovering ? 0.14 : 0.06))
                .allowsHitTesting(false)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(model.isHovering ? 0.8 : 0.4))
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
            if !model.followLive {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.blue.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L("Jump to live"))
                .padding(.bottom, 44)
            }
        }
        .frame(width: OverlayPanel.scrollStripWidth)
    }

    /// 따라가기 중이면 바닥으로 내린다. 그 직후의 기하 변화는 사용자 스크롤로 오해하지 않도록 잠시 무시한다.
    private func followBottom(_ proxy: ScrollViewProxy) {
        guard model.followLive else { return }
        ignoreGeometryUntil = Date().addingTimeInterval(0.4)
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: settings.fontSize * 0.55))
            .foregroundStyle(.white.opacity(0.8))
    }

    @ViewBuilder
    private func lineView(_ line: CaptionLine) -> some View {
        let display = settings.translationEnabled ? settings.translationDisplay : .originalOnly
        VStack(alignment: .leading, spacing: 2) {
            switch display {
            case .originalOnly:
                Text(line.text).foregroundStyle(primary)
                if line.revealed { translationText(line, color: translationColor) }
            case .both:
                Text(line.text).foregroundStyle(primary)
                translationText(line, color: translationColor)
            case .translationOnly:
                if let t = line.translation {
                    Text(t).foregroundStyle(primary)
                } else {
                    Text(line.text).foregroundStyle(line.isTranslating ? secondary : primary)
                }
                if line.revealed, line.translation != nil {
                    Text(line.text).foregroundStyle(secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(model.isSelecting && hoveredLine == line.id ? 0.18 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            guard model.isSelecting else { return }
            hoveredLine = inside ? line.id : (hoveredLine == line.id ? nil : hoveredLine)
        }
        .onTapGesture {
            Log.info("line tapped selecting=\(model.isSelecting) id=\(line.id)")
            model.onLineTapped?(line.id)
        }
    }

    @ViewBuilder
    private func volatileView(_ s: String) -> some View {
        let display = settings.translationEnabled ? settings.translationDisplay : .originalOnly
        let pre = model.volatileTranslations[s]
        VStack(alignment: .leading, spacing: 2) {
            switch display {
            case .originalOnly:
                Text(s).foregroundStyle(secondary)
            case .both:
                Text(s).foregroundStyle(secondary)
                if let pre { Text(pre).foregroundStyle(translationColor.opacity(0.7)) }
            case .translationOnly:
                if let pre { Text(pre).foregroundStyle(secondary) } else { Text(s).foregroundStyle(secondary) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func translationText(_ line: CaptionLine, color: Color) -> some View {
        if let t = line.translation {
            Text(t).foregroundStyle(color)
        } else if line.isTranslating {
            Text(L("Translating…")).foregroundStyle(color.opacity(0.5))
        }
    }
}

struct OverlayActions {
    var toggleRun: () -> Void = {}
    var hideOverlay: () -> Void = {}
    var clearCaptions: () -> Void = {}
}

private struct CircleButton: View {
    let symbol: String
    let help: String
    var emphasized = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(emphasized ? 0.85 : 0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

final class MoveHandleNSView: NSView {
    var onDragEnd: (() -> Void)?
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let target = window?.parent else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = target.frame
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let target = window?.parent else { return }
        let now = NSEvent.mouseLocation
        var f = startFrame
        f.origin.x += now.x - startMouse.x
        f.origin.y += now.y - startMouse.y
        target.setFrame(ResizeEdgeView.clampToScreen(f, for: target), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        onDragEnd?()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

struct MoveHandle: NSViewRepresentable {
    let onDragEnd: () -> Void
    func makeNSView(context: Context) -> MoveHandleNSView {
        let v = MoveHandleNSView()
        v.onDragEnd = onDragEnd
        return v
    }
    func updateNSView(_ nsView: MoveHandleNSView, context: Context) { nsView.onDragEnd = onDragEnd }
}

struct EditButtonView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 4) {
            if model.isSelecting {
                CircleButton(symbol: "xmark", help: L("Exit select mode (Esc)"), emphasized: true) { model.isSelecting = false }
            } else {
                if settings.translationEnabled && settings.translationDisplay != .both {
                    CircleButton(symbol: "globe", help: settings.translationDisplay == .translationOnly ? L("Select a sentence to show its original") : L("Select a sentence to translate")) {
                        model.isSelecting = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

struct TopRightToolbarView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: Settings
    let actions: OverlayActions

    /// 언어 코드로 표시해 한글을 모르는 사용자도 알 수 있게 한다. 예: KO / KO→EN / EN
    private var displayLabel: String {
        let src = (settings.sourceLanguage.languageCode?.identifier ?? "?").uppercased()
        let dst = (settings.targetLanguage.languageCode?.identifier ?? "?").uppercased()
        switch settings.translationDisplay {
        case .originalOnly: return src
        case .both: return "\(src)→\(dst)"
        case .translationOnly: return dst
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            CircleButton(symbol: "minus", help: L("Smaller text"),
                         disabled: settings.fontSize <= Settings.fontSizes.first!) { settings.stepFontSize(-1) }
            CircleButton(symbol: "plus", help: L("Larger text"),
                         disabled: settings.fontSize >= Settings.fontSizes.last!) { settings.stepFontSize(1) }
            Button { settings.cycleBackgroundOpacity() } label: {
                Text("\(Int((settings.backgroundOpacity * 100).rounded()))%")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 26)
                    .frame(height: 22)
                    .padding(.horizontal, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Background opacity (click to cycle)"))
            Button { settings.cycleTranslationDisplay() } label: {
                Text(displayLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(height: 22)
                    .padding(.horizontal, 8)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Translation display: \(settings.translationDisplay.label) (click to cycle)"))
            .disabled(!settings.translationEnabled)
            .opacity(settings.translationEnabled ? 1 : 0.35)
            CircleButton(symbol: model.isRunning ? "pause.fill" : "play.fill",
                         help: model.isRunning ? L("Stop captions") : L("Start captions"), action: actions.toggleRun)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

struct TopLeftToolbarView: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var settings: Settings
    let actions: OverlayActions

    var body: some View {
        HStack(spacing: 4) {
            CircleButton(symbol: "eye.slash", help: L("Hide caption window (show again from the menu bar)"), action: actions.hideOverlay)
            CircleButton(symbol: "trash", help: L("Clear all captions"), disabled: model.lines.isEmpty && model.volatileSentences.isEmpty,
                         action: actions.clearCaptions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MoveBarView: View {
    let moveEnded: () -> Void

    var body: some View {
        ZStack {
            Capsule().fill(.black.opacity(0.5))
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
            MoveHandle(onDragEnd: moveEnded)
        }
        .help(L("Drag to move"))
    }
}

/// 키 창 역할만 하는 보이지 않는 패널 (OverlayPanel.focusPanel 참고).
final class FocusPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

final class CornerPanel: NSPanel {
    enum Corner { case topLeft, topRight, bottomRight, topCenter }
    let corner: Corner
    /// topCenter는 창의 정가운데에 두고, 양옆 툴바와 겹치지 않도록 너비를 줄인다(size.width는 최대 너비).
    let size: NSSize

    init<Content: View>(corner: Corner, size: NSSize, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior, content: Content) {
        self.corner = corner
        self.size = size
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        collectionBehavior = behavior
        let hosting = FirstMouseHostingView(rootView: content)
        hosting.sizingOptions = []
        contentView = hosting
    }

    static let topLeftWidth: CGFloat = 48, topRightWidth: CGFloat = 186
    static let topCenterMinWidth: CGFloat = 44, topCenterGap: CGFloat = 6
    static func minParentWidth(inset: CGFloat) -> CGFloat {
        2 * inset + topLeftWidth + topRightWidth + 2 * topCenterGap + topCenterMinWidth
    }

    func layout(in parent: NSRect, inset: CGFloat) {
        let origin: NSPoint
        var frameSize = size
        switch corner {
        case .topLeft: origin = NSPoint(x: parent.minX + inset, y: parent.maxY - size.height - inset)
        case .topRight: origin = NSPoint(x: parent.maxX - size.width - inset, y: parent.maxY - size.height - inset)
        case .bottomRight: origin = NSPoint(x: parent.maxX - size.width - inset, y: parent.minY + inset)
        case .topCenter:
            // 창의 정가운데가 기본. 좁아져 우측 툴바에 닿으면 닿은 만큼만 왼쪽으로 밀리고,
            // 양옆 툴바 사이 공간보다 길면 그 공간만큼 줄어든다. 전부 연속 함수라 창 크기를 바꿀 때 튀지 않는다.
            let gapMinX = parent.minX + inset + Self.topLeftWidth + Self.topCenterGap
            let gapMaxX = parent.maxX - inset - Self.topRightWidth - Self.topCenterGap
            frameSize.width = max(Self.topCenterMinWidth, min(size.width, gapMaxX - gapMinX))
            let x = min(max(parent.midX - frameSize.width / 2, gapMinX), gapMaxX - frameSize.width)
            origin = NSPoint(x: x, y: parent.maxY - size.height - inset)
        }
        setFrame(NSRect(origin: origin, size: frameSize), display: true)
    }
}

/// 자식 뷰를 항상 자기 크기에 꽉 채우는 컨테이너. 자동 리사이즈 마스크는 초기 크기가 0일 때 깨지므로 쓰지 않는다.
final class FillContainerView: NSView {
    override func layout() {
        super.layout()
        for v in subviews { v.frame = bounds }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for v in subviews { v.frame = bounds }
    }
}

/// 앱이 비활성 상태여도 첫 클릭을 뷰에 전달하고, 내용이 바뀌어도 스스로 크기를 키우지 않는 호스팅 뷰.
/// NSHostingView는 내용이 바뀌면 자기 프레임을 내용 크기로 바꾸려 하므로 항상 부모 크기로 되돌린다.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if let superview, superview.bounds.size != .zero {
            super.setFrameSize(superview.bounds.size)
        } else {
            super.setFrameSize(newSize)
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(superview == nil ? newOrigin : .zero)
    }
}

/// 상자 가장자리에서 마우스를 받아 바로 리사이즈하는 투명 뷰. 가장자리 띠 바깥(안쪽 영역)은 히트 테스트에서 빠져
/// 휠·클릭이 아래 자막 뷰로 간다. 최소 크기와 화면 밖 이탈은 여기서 막는다.
final class ResizeEdgeView: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }

    static let edgeWidth: CGFloat = 10
    private var dragEdges: Edges = []
    var isDragging: Bool { !dragEdges.isEmpty }
    private var dragStartMouse: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 커서는 AppKit 커서 영역에 맡긴다. 키 창일 때만 동작하므로 OverlayPanel이 가장자리 호버 시 키 창으로 올린다.
    /// 수동 NSCursor.set()과 섞으면 AppKit이 마우스 이동마다 화살표로 되돌려 깜빡이므로 쓰지 않는다.
    override func resetCursorRects() {
        let w = Self.edgeWidth, W = bounds.width, H = bounds.height
        guard W > 2 * w, H > 2 * w else { return }
        func add(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ e: Edges) {
            if let c = Self.cursor(for: e) { addCursorRect(NSRect(x: x, y: y, width: width, height: height), cursor: c) }
        }
        add(0, w, w, H - 2 * w, [.left])
        add(W - w, w, w, H - 2 * w, [.right])
        add(w, 0, W - 2 * w, w, [.bottom])
        add(w, H - w, W - 2 * w, w, [.top])
        add(0, 0, w, w, [.bottom, .left])
        add(W - w, 0, w, w, [.bottom, .right])
        add(0, H - w, w, w, [.top, .left])
        add(W - w, H - w, w, w, [.top, .right])
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    func edges(at p: NSPoint) -> Edges {
        let w = Self.edgeWidth
        var e: Edges = []
        if p.x <= w { e.insert(.left) }
        if p.x >= bounds.width - w { e.insert(.right) }
        if p.y <= w { e.insert(.bottom) }
        if p.y >= bounds.height - w { e.insert(.top) }
        return e
    }

    static func cursor(for e: Edges) -> NSCursor? {
        switch e {
        case [.left]: return .frameResize(position: .left, directions: .all)
        case [.right]: return .frameResize(position: .right, directions: .all)
        case [.top]: return .frameResize(position: .top, directions: .all)
        case [.bottom]: return .frameResize(position: .bottom, directions: .all)
        case [.top, .left]: return .frameResize(position: .topLeft, directions: .all)
        case [.top, .right]: return .frameResize(position: .topRight, directions: .all)
        case [.bottom, .left]: return .frameResize(position: .bottomLeft, directions: .all)
        case [.bottom, .right]: return .frameResize(position: .bottomRight, directions: .all)
        default: return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !dragEdges.isEmpty { return self }
        return edges(at: local).isEmpty ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragEdges = edges(at: convert(event.locationInWindow, from: nil))
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !dragEdges.isEmpty else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x
        let dy = now.y - dragStartMouse.y
        var f = dragStartFrame
        let minW = window.minSize.width, minH = window.minSize.height

        if dragEdges.contains(.right) { f.size.width = max(minW, dragStartFrame.width + dx) }
        if dragEdges.contains(.left) {
            let w = max(minW, dragStartFrame.width - dx)
            f.origin.x = dragStartFrame.maxX - w
            f.size.width = w
        }
        if dragEdges.contains(.top) { f.size.height = max(minH, dragStartFrame.height + dy) }
        if dragEdges.contains(.bottom) {
            let h = max(minH, dragStartFrame.height - dy)
            f.origin.y = dragStartFrame.maxY - h
            f.size.height = h
        }
        window.setFrame(Self.clampToScreen(f, for: window), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        dragEdges = []
        (window as? OverlayPanel)?.editDragEnded()
    }

    /// 오른쪽 가장자리는 스크롤 띠와 겹치므로 휠은 옆의 자막 뷰로 넘긴다.
    override func scrollWheel(with event: NSEvent) {
        if let sibling = superview?.subviews.first(where: { $0 !== self }) {
            sibling.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    static func clampToScreen(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let screen = window.screen ?? NSScreen.main else { return frame }
        let v = screen.visibleFrame
        var f = frame
        f.size.width = min(f.width, v.width)
        f.size.height = min(f.height, v.height)
        f.origin.x = min(max(f.origin.x, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.origin.y, v.minY), v.maxY - f.height)
        return f
    }
}

/// 항상 위에 떠 있는 자막 패널. 평소에는 클릭을 통과시키고, 커서가 스크롤 띠·가장자리 위에 있거나 선택 모드일 때만 마우스를 받는다.
final class OverlayPanel: NSPanel, NSWindowDelegate {
    private let settings: Settings
    private let model: CaptionModel
    private var cancellables: Set<AnyCancellable> = []
    private let interaction = ResizeEdgeView()
    /// 가장자리 호버 중에만 키 창이 되는 보이지 않는 보조 패널. 비활성 앱은 키 창이 있어야 커서를 바꿀 수 있는데,
    /// 본 패널을 키 창으로 올리면 키보드가 오버레이로 와서 영상 일시정지(스페이스) 같은 입력을 가로챈다.
    /// 보조 패널을 내리면(orderOut) 시스템이 원래 활성 앱으로 키보드 포커스를 돌려준다.
    private let focusPanel = FocusPanel()
    private var hoverTimer: Timer?
    private var isHovering = false
    /// 본 패널은 평소 클릭을 통과시키므로 버튼은 별도 자식 창에 둔다.
    private var cornerPanels: [CornerPanel] = []
    /// 가장자리 리사이즈 띠를 가리지 않도록 안쪽으로 띄운다.
    private let buttonInset: CGFloat = 16
    private let actions: OverlayActions

    init(model: CaptionModel, settings: Settings, actions: OverlayActions) {
        self.settings = settings
        self.model = model
        self.actions = actions
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = FillContainerView()
        let hosting = FirstMouseHostingView(rootView: OverlayView(model: model, settings: settings))
        // SwiftUI 내용의 최소/최대 크기를 창에 강제하지 않는다. 창 크기는 사용자가 정한다.
        hosting.sizingOptions = []
        container.addSubview(hosting)
        container.addSubview(interaction)
        contentView = container
        delegate = self
        updateMinSize()

        if let saved = settings.savedOverlayFrame {
            setFrame(ResizeEdgeView.clampToScreen(saved, for: self), display: true)
        } else {
            resetFrame()
        }

        focusPanel.level = level
        focusPanel.collectionBehavior = collectionBehavior
        makeCornerPanels()
        setInteractive(selecting: false)
        startHoverTracking()

        // 모니터를 빼거나 해상도가 바뀌면 창이 화면 밖에 남을 수 있다.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.clampFrameToScreen() }
            .store(in: &cancellables)

        settings.$fontSize.removeDuplicates()
            .sink { [weak self] _ in self?.updateMinSize() }
            .store(in: &cancellables)
        model.objectWillChange.merge(with: settings.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshButtonVisibility() }
            .store(in: &cancellables)
        model.$lines.map { _ in () }
            .merge(with: model.$volatileSentences.map { _ in () }, model.$volatileTranslations.map { _ in () }, model.$status.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.noteActivity() }
            .store(in: &cancellables)
    }

    // MARK: 자동 숨기기 — 한동안 새 자막이 없고 커서도 상자 위에 없으면 서서히 감춘다.

    private var lastActivity = Date()
    private var isFaded = false

    private func noteActivity() {
        lastActivity = Date()
        if isFaded { setFaded(false) }
    }

    private func updateIdleFade(overBox: Bool) {
        // 커서가 상자 위에 있는 동안도 활동으로 본다. 그래야 벗어난 뒤 설정한 시간만큼은 보이다가 사라진다("자막 창 보이기"와 같은 효과).
        if overBox { noteActivity() }
        let timeout = settings.autoHideSeconds
        let shouldFade = timeout > 0 && !model.isOverlayHidden && !model.isSelecting
            && Date().timeIntervalSince(lastActivity) >= timeout
        if shouldFade != isFaded { setFaded(shouldFade) }
    }

    private func setFaded(_ faded: Bool) {
        isFaded = faded
        model.isAutoHidden = faded
        for p in cornerPanels { p.ignoresMouseEvents = faded }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = faded ? 1.5 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: faded ? .easeIn : .easeOut)
            animator().alphaValue = faded ? 0 : 1
            for p in cornerPanels { p.animator().alphaValue = faded ? 0 : buttonAlpha }
        }
    }

    // MARK: 버튼 표시 — 커서가 상자 위에 있을 때만 버튼을 보이고, 벗어나면 서서히 감춘다.

    /// 커서가 상자 밖에 있을 때 버튼의 불투명도. 0이면 완전히 사라지고, 0.3 정도로 두면 희미하게 남는다.
    static let idleButtonAlpha: CGFloat = 0

    private var buttonsRevealed = false
    private var buttonAlpha: CGFloat { buttonsRevealed ? 1 : Self.idleButtonAlpha }

    /// 끌기(이동·리사이즈) 중에는 커서가 잠깐 상자를 벗어나도 버튼을 유지한다.
    private func updateButtonReveal(overBox: Bool) {
        let reveal = overBox || (buttonsRevealed && NSEvent.pressedMouseButtons != 0)
        guard reveal != buttonsRevealed else { return }
        buttonsRevealed = reveal
        guard !isFaded else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reveal ? 0.2 : 0.6
            ctx.timingFunction = CAMediaTimingFunction(name: reveal ? .easeOut : .easeIn)
            for p in cornerPanels { p.animator().alphaValue = buttonAlpha }
        }
    }

    private func makeCornerPanels() {
        let bottomRight = CornerPanel(
            corner: .bottomRight, size: NSSize(width: 22, height: 22), level: level, behavior: collectionBehavior,
            content: EditButtonView(model: model, settings: settings)
        )
        let topRight = CornerPanel(
            corner: .topRight, size: NSSize(width: CornerPanel.topRightWidth, height: 22), level: level, behavior: collectionBehavior,
            content: TopRightToolbarView(model: model, settings: settings, actions: actions)
        )
        let topLeft = CornerPanel(
            corner: .topLeft, size: NSSize(width: CornerPanel.topLeftWidth, height: 22), level: level, behavior: collectionBehavior,
            content: TopLeftToolbarView(model: model, settings: settings, actions: actions)
        )
        let topCenter = CornerPanel(
            corner: .topCenter, size: NSSize(width: 160, height: 22), level: level, behavior: collectionBehavior,
            content: MoveBarView(moveEnded: { [weak self] in self?.editDragEnded() })
        )
        cornerPanels = [bottomRight, topRight, topLeft, topCenter]
        for p in cornerPanels {
            p.alphaValue = buttonAlpha
            addChildWindow(p, ordered: .above)
        }
        layoutCornerPanels()
    }

    private func layoutCornerPanels() {
        for p in cornerPanels { p.layout(in: frame, inset: buttonInset) }
    }

    private func refreshButtonVisibility() {
        let boxHidden = model.isOverlayHidden
        var shown = false
        for p in cornerPanels {
            if boxHidden { p.orderOut(nil) } else if !p.isVisible { p.orderFront(nil); shown = true }
        }
        if shown { orderCornerPanelsAboveSelf() }
    }

    /// 부모 창을 앞으로 올리거나 키 창으로 만들면 자식 버튼 창이 부모 뒤로 밀리는 경우가 있다.
    /// 그러면 버튼이 어둡게 비쳐 보이고 클릭이 본 패널로 가므로, 항상 부모 바로 위로 다시 올린다.
    /// 자식 창을 orderOut하면 AppKit이 부모와의 연결을 끊는다(이동 막대는 window.parent로 상자를 찾으므로 끊기면 이동이 안 된다). 끊긴 것은 다시 붙인다.
    private func orderCornerPanelsAboveSelf() {
        guard isVisible else { return }
        for p in cornerPanels where p.isVisible {
            if p.parent !== self {
                addChildWindow(p, ordered: .above)
                Log.info("reattached corner panel")
            }
            p.order(.above, relativeTo: windowNumber)
        }
    }

    private func clampFrameToScreen() {
        let f = ResizeEdgeView.clampToScreen(frame, for: self)
        if f != frame { setFrame(f, display: true) }
        layoutCornerPanels()
        orderCornerPanelsAboveSelf()
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            for p in cornerPanels { p.orderOut(nil) }
            orderOut(nil)
        } else {
            orderFrontRegardless()
            refreshButtonVisibility()
            orderCornerPanelsAboveSelf()
            noteActivity()
        }
    }

    // MARK: 호버 감시 — 커서가 상자 위에 있을 때만 마우스(스크롤·클릭)를 받는다.

    private func startHoverTracking() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
    }

    private func pollHover() {
        let visible = isVisible && !model.isOverlayHidden
        let loc = NSEvent.mouseLocation
        let overBox = visible && frame.contains(loc)
        if overBox != model.isCursorOverBox { model.isCursorOverBox = overBox }
        updateIdleFade(overBox: overBox)
        updateButtonReveal(overBox: overBox)
        updateEdgeCursor(overBox: overBox, at: loc)
        // 오른쪽 스크롤 띠, 가장자리 리사이즈 띠, 새 자막 인디케이터 위에서만 마우스를 받는다. 나머지 영역의 클릭은 아래 앱으로 간다.
        let inStrip = overBox && loc.x >= frame.maxX - Self.scrollStripWidth
        let inIndicator = overBox && !model.followLive && model.pendingCount > 0 && liveIndicatorRect.contains(loc)
        let hovering = inStrip || inIndicator || model.isOnResizeEdge
        guard hovering != isHovering else { return }
        isHovering = hovering
        model.isHovering = hovering
        applyMouseAcceptance()
    }

    static let scrollStripWidth: CGFloat = 28
    /// 바닥 가운데 "↓ N" 인디케이터가 차지하는 영역(아래 여백 포함). 알약(24pt)은 이 영역의 위쪽에 붙고, 아래쪽은 리사이즈 띠와 겹치지 않게 비운다.
    static let liveIndicatorSize = NSSize(width: 80, height: 24 + ResizeEdgeView.edgeWidth + 2)
    private var liveIndicatorRect: NSRect {
        NSRect(x: frame.midX - Self.liveIndicatorSize.width / 2, y: frame.minY, width: Self.liveIndicatorSize.width, height: Self.liveIndicatorSize.height)
    }

    /// 가장자리 띠에 커서가 들어오면 패널을 키 창으로 올린다. 비활성 앱의 비키 창에서는 커서 영역이 먹지 않기 때문이다
    /// (nonactivating 패널이라 앱은 활성화되지 않는다). 커서 모양 자체는 ResizeEdgeView의 커서 영역이 정한다.
    private func updateEdgeCursor(overBox: Bool, at loc: NSPoint) {
        let w = ResizeEdgeView.edgeWidth
        let onEdge = overBox && !model.isSelecting && !frame.insetBy(dx: w, dy: w).contains(loc)
        if onEdge != model.isOnResizeEdge {
            model.isOnResizeEdge = onEdge
            if onEdge {
                ignoresMouseEvents = false
                makeKeyAndOrderFront(nil)
                invalidateCursorRects(for: interaction)
            } else if !interaction.isDragging {
                releaseKey()
            }
        }
        // 커서가 이미 영역 안에 있는 채로 커서 영역이 설치되면 진입 이벤트가 없어 화살표로 남고,
        // 활성 앱이 자기 창을 벗어났다며 화살표로 되돌리기도 한다. 가장자리에 있는 동안은 매 틱 다시 지정한다.
        // 커서 영역과 같은 기하를 쓰므로 AppKit과 서로 다른 커서를 넣는 일은 없다.
        if onEdge, interaction.isDragging == false {
            let local = NSPoint(x: loc.x - frame.minX, y: loc.y - frame.minY)
            if let c = ResizeEdgeView.cursor(for: interaction.edges(at: local)) { Self.forceCursor(c) }
        }
    }

    /// NSCursor.set()은 앱이 기억하는 현재 커서와 같으면 아무 일도 하지 않는다. 다른 앱이 화면 커서를 화살표로
    /// 되돌린 뒤에는 그 기억이 틀리므로, 실제 화면 커서가 다를 때 기억을 지우고 다시 지정한다.
    private static func forceCursor(_ c: NSCursor) {
        if let onScreen = NSCursor.currentSystem, onScreen.image.size == c.image.size, onScreen.hotSpot == c.hotSpot,
           onScreen.image.tiffRepresentation == c.image.tiffRepresentation {
            return
        }
        if NSCursor.current == c { NSCursor.arrow.set() }
        c.set()
    }

    private func applyMouseAcceptance() {
        ignoresMouseEvents = !(model.isSelecting || isHovering)
    }

    /// 선택 모드(Esc 입력)와 가장자리 호버(커서 영역) 중에만 키 창이 된다.
    override var canBecomeKey: Bool { model.isSelecting || model.isOnResizeEdge }

    func setInteractive(selecting: Bool) {
        applyMouseAcceptance()
        interaction.isHidden = selecting
        if selecting {
            makeKeyAndOrderFront(nil)
            Log.info("selecting: isKeyWindow=\(isKeyWindow) ignoresMouse=\(ignoresMouseEvents)")
        } else {
            // 키 창 해제는 AppKit에 맡긴다(resignKey 직접 호출 금지). 다른 창을 클릭하면 자연히 풀린다.
            orderFrontRegardless()
        }
        refreshButtonVisibility()
        orderCornerPanelsAboveSelf()
    }

    func editDragEnded() {
        settings.saveOverlayFrame(frame)
        if !model.isOnResizeEdge { releaseKey() }
    }

    /// 본 패널의 키 상태를 내려놓는다. resignKey()는 직접 부를 수 없고 orderOut은 깜빡이므로,
    /// 보이지 않는 보조 패널을 잠깐 키 창으로 올렸다가 내린다. 그러면 이 앱에 키 창이 없어져
    /// 키보드 포커스가 원래 활성 앱으로 돌아간다(canBecomeKey가 false라 본 패널이 다시 선택되지 않는다).
    private func releaseKey() {
        guard isKeyWindow else { return }
        focusPanel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY))
        focusPanel.makeKeyAndOrderFront(nil)
        focusPanel.orderOut(nil)
    }

    private func updateMinSize() {
        let lineHeight = settings.fontSize * 1.5
        let padding = settings.fontSize * 1.0
        // 높이는 한 줄이 들어가고, 위아래 모서리 버튼 줄(22pt)이 서로 겹치지 않을 만큼.
        let buttonsHeight = 2 * (buttonInset + 22) + 4
        minSize = NSSize(width: CornerPanel.minParentWidth(inset: buttonInset), height: max(ceil(lineHeight + padding), buttonsHeight))
        var f = frame
        if f.height < minSize.height || f.width < minSize.width {
            f.size.height = max(f.height, minSize.height)
            f.size.width = max(f.width, minSize.width)
            setFrame(f, display: true)
        }
    }

    func resetFrame() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let width = min(f.width * 0.7, 1200)
        let height: CGFloat = 150
        setFrame(NSRect(x: f.midX - width / 2, y: f.minY + 40, width: width, height: height), display: true)
        settings.clearOverlayFrame()
    }

    // MARK: 키 입력 (선택 모드)

    override func keyDown(with event: NSEvent) {
        if model.isSelecting && event.keyCode == 53 { model.isSelecting = false } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        if model.isSelecting { model.isSelecting = false }
    }

    func windowDidMove(_ notification: Notification) { layoutCornerPanels() }
    func windowDidResize(_ notification: Notification) { layoutCornerPanels() }
    func windowDidBecomeKey(_ notification: Notification) { orderCornerPanelsAboveSelf() }
    func windowDidResignKey(_ notification: Notification) { orderCornerPanelsAboveSelf() }
}
