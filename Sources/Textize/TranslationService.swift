import AppKit
import Foundation
import SwiftUI
import Translation

/// 언어 팩이 없으면 작은 창을 띄워 시스템 다운로드 절차를 거친다.
@MainActor
final class TranslationService {
    enum TranslationError: LocalizedError {
        case unsupported
        case cancelled
        var errorDescription: String? {
            switch self {
            case .unsupported: return L("Translation is not supported for this language pair.")
            case .cancelled: return L("Language pack preparation was cancelled.")
            }
        }
    }

    private var session: TranslationSession?
    private var sessionKey = ""
    /// 세션 준비(언어 팩 확인·다운로드)는 한 번만 진행하고, 동시에 들어온 요청은 같은 작업을 기다린다.
    private var sessionTask: Task<TranslationSession, Error>?
    private var prepareWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        let session = try await ensureSession(from: await resolve(source), to: target)
        return try await session.translate(text).targetText
    }

    /// 인식 언어(예: ko-KR, en-US, zh-TW)를 번역 프레임워크가 아는 언어 식별자로 맞춘다.
    private func resolve(_ language: Locale.Language) async -> Locale.Language {
        let supported = await supportedLanguages()
        let id = language.minimalIdentifier
        if let exact = supported.first(where: { $0.minimalIdentifier == id }) { return exact }
        if let script = language.script,
           let sameScript = supported.first(where: { $0.languageCode == language.languageCode && $0.script == script }) {
            return sameScript
        }
        if let sameCode = supported.first(where: { $0.languageCode == language.languageCode }) { return sameCode }
        return language
    }

    func invalidate() {
        session = nil
        sessionTask?.cancel()
        sessionTask = nil
        sessionKey = ""
    }

    private func ensureSession(from source: Locale.Language, to target: Locale.Language) async throws -> TranslationSession {
        let key = source.minimalIdentifier + ">" + target.minimalIdentifier
        if let session, sessionKey == key { return session }
        if let sessionTask, sessionKey == key { return try await sessionTask.value }

        sessionKey = key
        let task = Task { [weak self] () throws -> TranslationSession in
            guard let self else { throw CancellationError() }
            let status = await LanguageAvailability().status(from: source, to: target)
            Log.info("translation status \(source.minimalIdentifier)>\(target.minimalIdentifier): \(status)")
            switch status {
            case .unsupported: throw TranslationError.unsupported
            case .supported: try await self.prepare(from: source, to: target)
            case .installed: break
            @unknown default: break
            }
            return TranslationSession(installedSource: source, target: target)
        }
        sessionTask = task
        do {
            let s = try await task.value
            if sessionKey == key { session = s; sessionTask = nil }
            return s
        } catch {
            if sessionKey == key { sessionTask = nil }
            throw error
        }
    }

    private func prepare(from source: Locale.Language, to target: Locale.Language) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false
            let finish: (Error?) -> Void = { [weak self] error in
                guard !finished else { return }
                finished = true
                if let obs = self?.closeObserver { NotificationCenter.default.removeObserver(obs) }
                self?.closeObserver = nil
                self?.prepareWindow?.close()
                self?.prepareWindow = nil
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }

            let config = TranslationSession.Configuration(source: source, target: target)
            let view = TranslationPrepareView(configuration: config, onFinish: finish)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = L("Preparing Translation")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            prepareWindow = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                Task { @MainActor in finish(TranslationError.cancelled) }
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// 언어 팩 다운로드를 트리거하는 뷰. translationTask는 창 안의 뷰에서만 동작한다.
private struct TranslationPrepareView: View {
    let configuration: TranslationSession.Configuration
    let onFinish: (Error?) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(L("Preparing the translation language pack.\nIf macOS asks, allow the download."))
                .multilineTextAlignment(.center)
                .font(.callout)
        }
        .padding(24)
        .frame(width: 380)
        .translationTask(configuration) { session in
            do {
                Log.info("prepareTranslation begin")
                try await session.prepareTranslation()
                Log.info("prepareTranslation done")
                onFinish(nil)
            } catch {
                Log.error("prepareTranslation failed: \(error)")
                onFinish(error)
            }
        }
    }
}
