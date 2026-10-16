import Foundation
import Testing
@testable import Textize

/// Localizable.xcstrings와 소스의 L("…") 호출이 서로 맞는지 검사한다 (CLAUDE.md의 UI 문자열 규칙).
/// .lproj 없이 돌아가는 swift test에서는 L()이 영어만 돌려주므로 카탈로그 파일을 직접 읽는다.
struct LocalizationCatalogTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourcesDir = packageRoot.appendingPathComponent("Sources/Textize")
    static let catalogURL = sourcesDir.appendingPathComponent("Resources/Localizable.xcstrings")

    struct Catalog {
        let sourceLanguage: String
        /// key → (언어 코드 → (value, state))
        let strings: [String: [String: (value: String, state: String)]]
    }

    static func loadCatalog() throws -> Catalog {
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        var out: [String: [String: (value: String, state: String)]] = [:]
        for (key, entry) in strings {
            var langs: [String: (value: String, state: String)] = [:]
            for (code, loc) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                let unit = loc["stringUnit"] as? [String: Any] ?? [:]
                langs[code] = (unit["value"] as? String ?? "", unit["state"] as? String ?? "")
            }
            out[key] = langs
        }
        return Catalog(sourceLanguage: root["sourceLanguage"] as? String ?? "", strings: out)
    }

    static func sourceFiles() throws -> [URL] {
        let files = try FileManager.default.subpathsOfDirectory(atPath: sourcesDir.path)
            .filter { $0.hasSuffix(".swift") }
            .map { sourcesDir.appendingPathComponent($0) }
        try #require(!files.isEmpty, "no Swift sources under \(sourcesDir.path)")
        return files
    }

    /// 소스에서 L("…")의 키를 뽑는다. 보간 `\(…)`는 "%"로 치환해 카탈로그의 %lld/%@와 맞춘다.
    static func localizationKeys(in source: String) -> [String] {
        var keys: [String] = []
        let chars = Array(source)
        var i = 0
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while i + 2 < chars.count {
            if chars[i] == "L", chars[i + 1] == "(", chars[i + 2] == "\"", i == 0 || !isIdent(chars[i - 1]) {
                if let (key, end) = scanStringLiteral(chars, from: i + 3, nested: &keys) {
                    keys.append(key)
                    i = end
                    continue
                }
            }
            i += 1
        }
        return keys
    }

    /// `"` 바로 뒤부터 읽어 닫는 `"`까지의 키와 그 다음 위치를 돌려준다. 보간 안에서 만난 L("…") 키는 nested에 모은다.
    private static func scanStringLiteral(_ c: [Character], from start: Int, nested: inout [String]) -> (String, Int)? {
        var key = ""
        var i = start
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count {
                let next = c[i + 1]
                if next == "(" {
                    guard let end = scanInterpolation(c, from: i + 2, nested: &nested) else { return nil }
                    key.append("%")
                    i = end
                    continue
                }
                switch next {
                case "n": key.append("\n")
                case "t": key.append("\t")
                default: key.append(next)   // \" \\ 등
                }
                i += 2
                continue
            }
            if ch == "\"" { return (key, i + 1) }
            key.append(ch)
            i += 1
        }
        return nil
    }

    /// `\(` 바로 뒤부터 짝이 맞는 `)` 다음 위치까지. 안에 든 문자열 리터럴은 건너뛰되, 중첩된 L("…")의 키는 nested에 모은다.
    private static func scanInterpolation(_ c: [Character], from start: Int, nested: inout [String]) -> Int? {
        var depth = 1
        var i = start
        while i < c.count {
            if c[i] == "L", i + 2 < c.count, c[i + 1] == "(", c[i + 2] == "\"",
               !(c[i - 1].isLetter || c[i - 1].isNumber || c[i - 1] == "_") {
                guard let (key, end) = scanStringLiteral(c, from: i + 3, nested: &nested) else { return nil }
                nested.append(key)
                depth += 1   // L( 의 여는 괄호. 닫는 괄호는 아래 switch가 센다.
                i = end
                continue
            }
            switch c[i] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return i + 1 }
            case "\"":
                guard let (_, end) = scanStringLiteral(c, from: i + 1, nested: &nested) else { return nil }
                i = end
                continue
            default: break
            }
            i += 1
        }
        return nil
    }

    /// 카탈로그 키의 포맷 지정자를 "%"로 정규화해 소스에서 뽑은 키와 비교할 수 있게 한다.
    static func normalized(_ catalogKey: String) -> String {
        catalogKey.replacingOccurrences(of: "%(lld|ld|d|@)", with: "%", options: .regularExpression)
    }

    @Test func sourceLanguageIsEnglish() throws {
        #expect(try Self.loadCatalog().sourceLanguage == "en")
    }

    @Test func catalogLanguagesMatchAppLanguageCases() throws {
        let catalog = try Self.loadCatalog()
        let inCatalog = Set(catalog.strings.values.flatMap(\.keys))
        #expect(inCatalog == Set(AppLanguage.supportedCodes))
    }

    @Test func everyKeyIsTranslatedInEverySupportedLanguage() throws {
        let catalog = try Self.loadCatalog()
        for (key, langs) in catalog.strings.sorted(by: { $0.key < $1.key }) {
            for code in AppLanguage.supportedCodes {
                let unit = langs[code]
                #expect(unit != nil && !unit!.value.isEmpty && unit!.state == "translated",
                        "\"\(key)\" is missing or not translated for \(code)")
            }
        }
    }

    @Test func everySourceStringExistsInCatalog() throws {
        let catalog = try Self.loadCatalog()
        let known = Set(catalog.strings.keys.map(Self.normalized))
        for file in try Self.sourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for key in Self.localizationKeys(in: source) {
                #expect(known.contains(key), "\"\(key)\" used in \(file.lastPathComponent) is not in Localizable.xcstrings")
            }
        }
    }

    @Test func everyCatalogKeyIsUsedInSource() throws {
        let catalog = try Self.loadCatalog()
        var used: Set<String> = []
        for file in try Self.sourceFiles() {
            used.formUnion(Self.localizationKeys(in: try String(contentsOf: file, encoding: .utf8)))
        }
        for key in catalog.strings.keys.sorted() {
            #expect(used.contains(Self.normalized(key)), "\"\(key)\" is in Localizable.xcstrings but no L() call uses it")
        }
    }

    @Test func keyExtractorHandlesInterpolationAndNesting() {
        let source = #"""
        let a = L("Plain")
        let b = L("Failed: \(error.localizedDescription)")
        let c = L("Capture stopped: \(e?.localizedDescription ?? L("unknown"))")
        let d = URL("not a key")
        let e = L("Say \"hi\" (\(Int($0)) pt)")
        """#
        #expect(Self.localizationKeys(in: source) == ["Plain", "Failed: %", "unknown", "Capture stopped: %", "Say \"hi\" (% pt)"])
    }
}
