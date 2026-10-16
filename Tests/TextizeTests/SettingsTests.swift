import AppKit
import Foundation
import Testing
@testable import Textize

/// 실제 앱 설정 대신 테스트 전용 UserDefaults suite를 쓴다. 테스트마다 비우고 끝나면 지운다.
/// 같은 suite를 공유하고 appLanguage가 L10n의 전역 상태를 바꾸므로 suite 전체를 직렬로 돌린다.
@MainActor
@Suite(.serialized)
struct SettingsTests {
    private final class Sandbox {
        static let name = "wiki.paik.textize.tests"
        let defaults: UserDefaults
        init() {
            defaults = UserDefaults(suiteName: Self.name)!
            defaults.removePersistentDomain(forName: Self.name)
        }
        deinit {
            defaults.removePersistentDomain(forName: Self.name)
            // cfprefsd가 빈 plist를 남기므로 파일도 지운다.
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(Self.name).plist")
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func defaultsWhenNothingSaved() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        #expect(s.localeIdentifier == "ko-KR")
        #expect(s.fontSize == Settings.defaultFontSize)
        #expect(s.backgroundOpacity == Settings.defaultBackgroundOpacity)
        #expect(s.autoHideSeconds == Settings.defaultAutoHideSeconds)
        #expect(s.translationTarget == "ko")
        #expect(s.translationDisplay == .originalOnly)
        #expect(s.appLanguage == .system)
        #expect(s.savedOverlayFrame == nil)
    }

    @Test func persistsChangesAcrossInstances() {
        let box = Sandbox()
        do {
            let s = Settings(defaults: box.defaults)
            s.localeIdentifier = "en-US"
            s.fontSize = 34
            s.backgroundOpacity = 0.85
            s.autoHideSeconds = 30
            s.translationTarget = "ja"
            s.translationDisplay = .both
            s.appLanguage = .ja
        }
        let s = Settings(defaults: box.defaults)
        #expect(s.localeIdentifier == "en-US")
        #expect(s.fontSize == 34)
        #expect(s.backgroundOpacity == 0.85)
        #expect(s.autoHideSeconds == 30)
        #expect(s.translationTarget == "ja")
        #expect(s.translationDisplay == .both)
        #expect(s.appLanguage == .ja)
        s.appLanguage = .system
    }

    @Test func snapsSavedOpacityToNearestOption() {
        let box = Sandbox()
        box.defaults.set(0.33, forKey: "backgroundOpacity")
        #expect(Settings(defaults: box.defaults).backgroundOpacity == 0.3)
        box.defaults.set(0.95, forKey: "backgroundOpacity")
        #expect(Settings(defaults: box.defaults).backgroundOpacity == 1)
        box.defaults.set(0, forKey: "backgroundOpacity")
        #expect(Settings(defaults: box.defaults).backgroundOpacity == 0.1)
    }

    @Test func ignoresInvalidSavedValues() {
        let box = Sandbox()
        box.defaults.set(0, forKey: "fontSize")
        box.defaults.set("weird", forKey: "translationDisplay")
        box.defaults.set("xx", forKey: "appLanguage")
        let s = Settings(defaults: box.defaults)
        #expect(s.fontSize == Settings.defaultFontSize)
        #expect(s.translationDisplay == .originalOnly)
        #expect(s.appLanguage == .system)
    }

    @Test func stepFontSizeWalksTheListAndClamps() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        #expect(s.fontSize == 20)
        s.stepFontSize(1)
        #expect(s.fontSize == 26)
        s.stepFontSize(1)
        #expect(s.fontSize == 34)
        s.stepFontSize(-1)
        #expect(s.fontSize == 26)

        s.fontSize = Settings.fontSizes.last!
        s.stepFontSize(1)
        #expect(s.fontSize == Settings.fontSizes.last!)
        s.fontSize = Settings.fontSizes.first!
        s.stepFontSize(-1)
        #expect(s.fontSize == Settings.fontSizes.first!)
    }

    @Test func stepFontSizeFromValueOutsideListSnapsDownward() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        s.fontSize = 22   // 옛 버전에서 저장된 값처럼 목록에 없는 크기
        s.stepFontSize(-1)
        #expect(s.fontSize == 20)
    }

    @Test func cycleBackgroundOpacityWraps() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        s.backgroundOpacity = 1
        s.cycleBackgroundOpacity()
        #expect(s.backgroundOpacity == 0.1)
        s.cycleBackgroundOpacity()
        #expect(s.backgroundOpacity == 0.3)
    }

    @Test func cycleTranslationDisplayWraps() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        s.cycleTranslationDisplay()
        #expect(s.translationDisplay == .both)
        s.cycleTranslationDisplay()
        #expect(s.translationDisplay == .translationOnly)
        s.cycleTranslationDisplay()
        #expect(s.translationDisplay == .originalOnly)
    }

    @Test func resetCaptionWindowAppearanceKeepsLanguageSettings() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        s.fontSize = 44
        s.backgroundOpacity = 1
        s.autoHideSeconds = 0
        s.localeIdentifier = "en-US"
        s.resetCaptionWindowAppearance()
        #expect(s.fontSize == Settings.defaultFontSize)
        #expect(s.backgroundOpacity == Settings.defaultBackgroundOpacity)
        #expect(s.autoHideSeconds == Settings.defaultAutoHideSeconds)
        #expect(s.localeIdentifier == "en-US")
    }

    @Test func translationEnabledComparesLanguageCodesOnly() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        s.localeIdentifier = "ko-KR"; s.translationTarget = "ko"
        #expect(!s.translationEnabled)
        s.localeIdentifier = "en-GB"; s.translationTarget = "en"
        #expect(!s.translationEnabled)
        s.localeIdentifier = "en-US"; s.translationTarget = "ko"
        #expect(s.translationEnabled)
    }

    @Test func autoHideLabels() {
        #expect(Settings.autoHideLabel(0) == "Off")
        #expect(Settings.autoHideLabel(5) == "5 seconds")
        #expect(Settings.autoHideLabel(60) == "1 minute")
        #expect(Settings.autoHideLabel(120) == "2 minutes")
    }

    @Test func overlayFrameRoundTripsWhenOnScreen() throws {
        let screen = try #require(NSScreen.main)
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        let rect = screen.visibleFrame.insetBy(dx: 100, dy: 100)
        s.saveOverlayFrame(rect)
        #expect(s.savedOverlayFrame == rect)
        s.clearOverlayFrame()
        #expect(s.savedOverlayFrame == nil)
    }

    @Test func rejectsTinyOrOffscreenOverlayFrames() {
        let box = Sandbox()
        let s = Settings(defaults: box.defaults)
        s.saveOverlayFrame(NSRect(x: 0, y: 0, width: 50, height: 30))
        #expect(s.savedOverlayFrame == nil)
        s.saveOverlayFrame(NSRect(x: 1_000_000, y: 1_000_000, width: 400, height: 200))
        #expect(s.savedOverlayFrame == nil)
        box.defaults.set("not a rect", forKey: "overlayFrame")
        #expect(s.savedOverlayFrame == nil)
    }
}
