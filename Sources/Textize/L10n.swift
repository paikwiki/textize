import Foundation

/// UI 언어. 목록은 Resources/Localizable.xcstrings에 번역이 있는 언어와 같아야 한다.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case en, ko, ja, es, fr, de

    var id: String { rawValue }

    /// 메뉴에 보이는 이름. 각 언어는 그 언어로 적어 사용자가 자기 언어를 바로 찾게 한다.
    var menuName: String {
        switch self {
        case .system: return L("System")
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        }
    }

    static var supportedCodes: [String] { allCases.filter { $0 != .system }.map(\.rawValue) }
}

/// 현재 UI 언어의 문자열 번들. 재시작 없이 바꿀 수 있도록 선택 언어의 .lproj에서 직접 찾는다.
/// 쓰기는 메인 스레드(Settings)에서만 일어나고, 읽기는 오류 메시지처럼 다른 스레드에서도 일어난다.
enum L10n {
    nonisolated(unsafe) private(set) static var code = "en"
    nonisolated(unsafe) private(set) static var bundle: Bundle = .main
    nonisolated(unsafe) private(set) static var locale = Locale(identifier: "en")

    static func apply(_ language: AppLanguage) {
        code = language == .system ? resolveSystemLanguage() : language.rawValue
        locale = Locale(identifier: code)
        // 반드시 그 언어의 .lproj를 번들로 쓴다. 메인 번들에는 여러 .lproj가 있어 거기서 찾으면 시스템 언어로 찾아 버린다
        // 해당 .lproj가 없으면 en.lproj, 그것도 없으면(swift run 등) 키가 곧 영어라 메인 번들.
        let path = Bundle.main.path(forResource: code, ofType: "lproj") ?? Bundle.main.path(forResource: "en", ofType: "lproj")
        bundle = path.flatMap(Bundle.init(path:)) ?? .main
        Log.info("ui language: \(code) (setting=\(language == .system ? "system" : language.rawValue), bundle=\(bundle == .main ? "main" : "lproj"))")
    }

    static func resolveSystemLanguage() -> String {
        Bundle.preferredLocalizations(from: AppLanguage.supportedCodes).first ?? "en"
    }
}

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.bundle)
}
