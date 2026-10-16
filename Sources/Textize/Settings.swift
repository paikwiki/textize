import AppKit
import Combine
import Foundation

enum TranslationDisplay: String, CaseIterable, Identifiable {
    case originalOnly, both, translationOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .originalOnly: return L("Original only")
        case .both: return L("Original + translation")
        case .translationOnly: return L("Translation only")
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let fontSizes: [Double] = [14, 17, 20, 26, 34, 44]
    static let autoHideOptions: [Double] = [0, 5, 10, 15, 30, 60]
    /// 자막 상자 배경의 불투명도 (1 = 불투명). 완전 투명은 글자가 묻혀서 10%가 최소.
    static let backgroundOpacities: [Double] = [0.1, 0.3, 0.5, 0.7, 0.85, 1]
    static let defaultFontSize: Double = 20
    static let defaultBackgroundOpacity: Double = 0.5
    static let defaultAutoHideSeconds: Double = 10

    static func autoHideLabel(_ seconds: Double) -> String {
        if seconds <= 0 { return L("Off") }
        if seconds >= 60 { let m = Int(seconds / 60); return m == 1 ? L("1 minute") : L("\(m) minutes") }
        return L("\(Int(seconds)) seconds")
    }

    @Published var localeIdentifier: String { didSet { defaults.set(localeIdentifier, forKey: "localeIdentifier") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    @Published var autoHideSeconds: Double { didSet { defaults.set(autoHideSeconds, forKey: "autoHideSeconds") } }
    @Published var translationTarget: String { didSet { defaults.set(translationTarget, forKey: "translationTarget") } }
    @Published var translationDisplay: TranslationDisplay { didSet { defaults.set(translationDisplay.rawValue, forKey: "translationDisplay") } }
    /// UI 언어. 바꾸면 메뉴·툴팁은 바로 바뀌고, 이미 떠 있는 상태 메시지는 다음 갱신 때 바뀐다.
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: "appLanguage")
            L10n.apply(appLanguage)
        }
    }

    private let defaults: UserDefaults
    private let frameKey = "overlayFrame"

    /// 테스트에서는 별도 suite의 UserDefaults를 넣어 실제 설정을 건드리지 않게 한다.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localeIdentifier = defaults.string(forKey: "localeIdentifier") ?? "ko-KR"
        let size = defaults.double(forKey: "fontSize")
        fontSize = size > 0 ? size : Self.defaultFontSize
        let savedOpacity = defaults.object(forKey: "backgroundOpacity") == nil ? Self.defaultBackgroundOpacity : defaults.double(forKey: "backgroundOpacity")
        backgroundOpacity = Self.backgroundOpacities.min { abs($0 - savedOpacity) < abs($1 - savedOpacity) } ?? Self.defaultBackgroundOpacity
        autoHideSeconds = defaults.object(forKey: "autoHideSeconds") == nil ? Self.defaultAutoHideSeconds : defaults.double(forKey: "autoHideSeconds")
        translationTarget = defaults.string(forKey: "translationTarget") ?? "ko"
        translationDisplay = TranslationDisplay(rawValue: defaults.string(forKey: "translationDisplay") ?? "") ?? .originalOnly
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        L10n.apply(appLanguage)
    }

    func resetCaptionWindowAppearance() {
        fontSize = Self.defaultFontSize
        backgroundOpacity = Self.defaultBackgroundOpacity
        autoHideSeconds = Self.defaultAutoHideSeconds
    }

    func stepFontSize(_ delta: Int) {
        let sizes = Self.fontSizes
        let idx = sizes.firstIndex(of: fontSize) ?? sizes.firstIndex { $0 >= fontSize } ?? sizes.count - 1
        let next = min(max(idx + delta, 0), sizes.count - 1)
        fontSize = sizes[next]
    }

    func cycleBackgroundOpacity() {
        let all = Self.backgroundOpacities
        let idx = all.firstIndex(of: backgroundOpacity) ?? 0
        backgroundOpacity = all[(idx + 1) % all.count]
    }

    func cycleTranslationDisplay() {
        let all = TranslationDisplay.allCases
        let idx = all.firstIndex(of: translationDisplay) ?? 0
        translationDisplay = all[(idx + 1) % all.count]
    }

    var sourceLanguage: Locale.Language { Locale(identifier: localeIdentifier).language }
    var targetLanguage: Locale.Language { Locale.Language(identifier: translationTarget) }
    var translationEnabled: Bool {
        sourceLanguage.languageCode?.identifier != targetLanguage.languageCode?.identifier
    }

    var savedOverlayFrame: NSRect? {
        guard let s = defaults.string(forKey: frameKey) else { return nil }
        let rect = NSRectFromString(s)
        guard rect.width >= 100, rect.height >= 40,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else { return nil }
        return rect
    }

    func saveOverlayFrame(_ rect: NSRect) {
        defaults.set(NSStringFromRect(rect), forKey: frameKey)
    }

    func clearOverlayFrame() {
        defaults.removeObject(forKey: frameKey)
    }
}
