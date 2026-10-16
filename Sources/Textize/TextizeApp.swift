import AppKit
import SwiftUI

@main
struct TextizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppDelegate.controller

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, settings: controller.settings, menu: controller.menuState)
        } label: {
            MenuLabel(menu: controller.menuState)
        }
    }
}

private struct MenuLabel: View {
    @ObservedObject var menu: MenuState
    var body: some View {
        Image(nsImage: menu.isRunning ? MenuBarIcon.running : MenuBarIcon.idle)
    }
}

/// 메뉴바 아이콘. 앱 아이콘과 같은 "화면 틀 + 자막 띠" 모양을 템플릿 이미지로 그린다 (라이트/다크 메뉴바에 맞춰 색이 바뀐다).
/// 실행 중이면 틀을 채우고 띠를 뚫고, 정지 상태면 윤곽선에 띠를 채운다.
enum MenuBarIcon {
    static let idle = make(running: false)
    static let running = make(running: true)

    private static func make(running: Bool) -> NSImage {
        let size = NSSize(width: 17, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let frame = NSRect(x: 0.75, y: 0.75, width: 15.5, height: 14.5)
            let bar = NSRect(x: 4.5, y: 3.5, width: 8, height: 2)
            let barPath = NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1)
            NSColor.black.set()
            if running {
                let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
                path.append(barPath)
                path.windingRule = .evenOdd  // 띠 부분을 구멍으로 남긴다
                path.fill()
            } else {
                let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
                path.lineWidth = 1.5
                path.stroke()
                barPath.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 자막 모델을 직접 관찰하지 않는다 (관찰하면 자막 갱신마다 메뉴가 재구성되어 하위 메뉴가 닫힌다).
private struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: Settings
    @ObservedObject var menu: MenuState

    var body: some View {
        Button(menu.isRunning ? L("Stop Captions") : L("Start Captions")) { controller.toggle() }
        Button(menu.isOverlayHidden || menu.isAutoHidden ? L("Show Caption Window") : L("Hide Caption Window")) {
            controller.setOverlayHidden(!(menu.isOverlayHidden || menu.isAutoHidden))
        }
        Picker(L("Auto-Hide"), selection: $settings.autoHideSeconds) {
            ForEach(Settings.autoHideOptions, id: \.self) { Text(Settings.autoHideLabel($0)).tag($0) }
        }
        Divider()
        Picker(L("Speech Language"), selection: $settings.localeIdentifier) {
            ForEach(controller.availableLocales, id: \.identifier) { locale in
                Text(controller.displayName(locale)).tag(locale.identifier(.bcp47))
            }
        }
        // Picker 항목에는 .disabled가 먹지 않아 Toggle 항목으로 된 Menu를 쓴다 (체크 표시는 같게 보인다).
        Menu(L("Translate To")) {
            ForEach(controller.translationLanguages, id: \.minimalIdentifier) { lang in
                let id = lang.minimalIdentifier
                Toggle(controller.displayName(lang), isOn: Binding(
                    get: { settings.translationTarget == id },
                    set: { if $0 { settings.translationTarget = id } }
                ))
                .disabled(lang.languageCode == settings.sourceLanguage.languageCode)
            }
        }
        Picker(L("Translation Display"), selection: $settings.translationDisplay) {
            ForEach(TranslationDisplay.allCases) { Text($0.label).tag($0) }
        }
        .disabled(!settings.translationEnabled)
        Toggle(L("Select Sentence Mode"), isOn: Binding(
            get: { menu.isSelecting },
            set: { controller.model.isSelecting = $0 }
        ))
            .disabled(!settings.translationEnabled || settings.translationDisplay == .both)
        Divider()
        Picker(L("Font Size"), selection: $settings.fontSize) {
            ForEach(Settings.fontSizes, id: \.self) { Text(L("\(Int($0)) pt")).tag($0) }
        }
        Picker(L("Background Opacity"), selection: $settings.backgroundOpacity) {
            ForEach(Settings.backgroundOpacities, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
        }
        Divider()
        Picker(L("App Language"), selection: $settings.appLanguage) {
            ForEach(AppLanguage.allCases) { Text($0.menuName).tag($0) }
        }
        Button(L("Reset Caption Window")) { controller.resetCaptionWindow() }
        Divider()
        Button(L("About Textize")) { showAbout() }
        Button(L("Quit")) { NSApp.terminate(nil) }
    }

    /// 표준 정보 패널. 부제는 번들에 넣을 곳이 없어 credits로 보여 준다.
    private func showAbout() {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let credits = NSAttributedString(
            string: L("Live captions & translation for your Mac"),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Textize", .credits: credits])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let controller = Self.controller
        controller.showPanel()
        controller.toggle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await Self.controller.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}
