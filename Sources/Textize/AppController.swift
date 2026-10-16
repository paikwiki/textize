import AppKit
import Combine
import Foundation

@MainActor
final class AppController: ObservableObject {
    let model = CaptionModel()
    let settings = Settings()
    let translator = TranslationService()
    let menuState = MenuState()
    @Published var availableLocales: [Locale] = []
    @Published var translationLanguages: [Locale.Language] = []

    private var panel: OverlayPanel?
    private var capture: SystemAudioCapture?
    private var transcriber: LiveTranscriber?
    private var startTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var previousLocaleIdentifier: String

    init() {
        previousLocaleIdentifier = settings.localeIdentifier
        model.sentenceLocale = Locale(identifier: settings.localeIdentifier)
        menuState.bind(to: model)
        model.onLineTapped = { [weak self] id in self?.lineTapped(id) }
        Task { await loadLanguages() }

        settings.$localeIdentifier.dropFirst().removeDuplicates()
            .sink { [weak self] id in
                guard let self else { return }
                let previous = Locale(identifier: previousLocaleIdentifier).language
                previousLocaleIdentifier = id
                model.sentenceLocale = Locale(identifier: id)
                translator.invalidate()
                // @Published는 값이 바뀌기 직전에 알리므로 settings.sourceLanguage는 아직 옛 값이다. 새 값은 id로 넘긴다.
                swapTranslationTargetIfNeeded(new: Locale(identifier: id).language, previous: previous)
                restartIfRunning()
            }
            .store(in: &cancellables)
        // @Published는 값이 바뀌기 직전에 알리므로, 실제 값이 반영된 뒤(다음 런루프)에 패널에 적용한다.
        model.$isSelecting
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateInteraction() }
            .store(in: &cancellables)
        settings.$translationTarget.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                translator.invalidate()
                for line in model.lines { model.update(line.id) { $0.translation = nil; $0.revealed = false } }
                translateAllIfAuto()
            }
            .store(in: &cancellables)
        settings.$translationDisplay.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.translateAllIfAuto() }
            .store(in: &cancellables)
        // @Published는 값 반영 직전에 알리므로 다음 런루프에서 (L10n.apply가 끝난 뒤) 정렬한다.
        settings.$appLanguage.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resortLanguages() }
            .store(in: &cancellables)
    }

    /// 인식 언어를 번역 언어와 같은 것으로 바꾸면 번역 언어를 직전 인식 언어로 맞바꾼다 (ko→en 중 인식을 en으로 바꾸면 en→ko).
    private func swapTranslationTargetIfNeeded(new: Locale.Language, previous: Locale.Language) {
        guard new.languageCode == settings.targetLanguage.languageCode, let code = previous.languageCode else { return }
        let sameCode = translationLanguages.filter { $0.languageCode == code }
        guard let candidate = sameCode.first(where: { $0.script == previous.script }) ?? sameCode.first else { return }
        Log.info("translation target swapped to \(candidate.minimalIdentifier)")
        settings.translationTarget = candidate.minimalIdentifier
    }

    private func loadLanguages() async {
        let locales = await LiveTranscriber.supportedLocales()
        availableLocales = locales.sorted { displayName($0) < displayName($1) }
        Log.info("supported locales: \(availableLocales.map(\.identifier))")
        let langs = await translator.supportedLanguages()
        translationLanguages = langs.sorted { displayName($0) < displayName($1) }
        Log.info("translation languages: \(translationLanguages.map(\.minimalIdentifier))")
    }

    func displayName(_ locale: Locale) -> String {
        L10n.locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    func displayName(_ language: Locale.Language) -> String {
        L10n.locale.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private func resortLanguages() {
        availableLocales.sort { displayName($0) < displayName($1) }
        translationLanguages.sort { displayName($0) < displayName($1) }
    }

    func showPanel() {
        if panel == nil {
            var actions = OverlayActions()
            actions.toggleRun = { [weak self] in self?.toggle() }
            actions.hideOverlay = { [weak self] in self?.setOverlayHidden(true) }
            actions.clearCaptions = { [weak self] in self?.model.reset() }
            panel = OverlayPanel(model: model, settings: settings, actions: actions)
        }
        if !model.isOverlayHidden { panel?.orderFrontRegardless() }
    }

    func setOverlayHidden(_ hidden: Bool) {
        model.isOverlayHidden = hidden
        if hidden { model.isSelecting = false }
        panel?.setHidden(hidden)
    }

    func resetCaptionWindow() {
        settings.resetCaptionWindowAppearance()
        showPanel()
        panel?.resetFrame()
    }

    private func updateInteraction() {
        Log.info("interaction selecting=\(model.isSelecting)")
        panel?.setInteractive(selecting: model.isSelecting)
    }

    func toggle() {
        if model.isRunning || startTask != nil {
            Task { await stop() }
        } else {
            startTask = Task { await start() }
        }
    }

    private func restartIfRunning() {
        guard model.isRunning || startTask != nil else { return }
        Task {
            await stop()
            startTask = Task { await start() }
        }
    }

    func start() async {
        guard !model.isRunning else { return }
        defer { startTask = nil }
        model.beginSession()
        model.status = L("Starting…")
        // "자막 시작"은 자막을 보겠다는 뜻이므로, 숨겨 둔(또는 자동으로 감춰진) 창을 다시 보인다.
        setOverlayHidden(false)
        showPanel()

        let transcriber = LiveTranscriber()
        let capture = SystemAudioCapture()
        wire(capture: capture, transcriber: transcriber)
        do {
            Log.info("transcriber start locale=\(settings.localeIdentifier)")
            try await transcriber.start(locale: Locale(identifier: settings.localeIdentifier))
        } catch {
            Log.error("transcriber start failed: \(error)")
            model.status = L("Failed to start: \(error.localizedDescription)")
            await transcriber.stop()
            return
        }

        // 처음 실행이면 탭 생성 때 "시스템 오디오 녹음" 권한 대화상자가 뜬다. 거부/미허용 상태면 실패하므로
        // 안내를 띄우고 허용될 때까지 3초 간격으로 다시 시도한다 (정지하면 작업이 취소된다).
        var attempt = 0
        while true {
            attempt += 1
            if Task.isCancelled { await transcriber.stop(); return }
            do {
                try await capture.start()
                Log.info("capture started (attempt \(attempt))")
                break
            } catch {
                Log.error("capture start failed (attempt \(attempt)): \(error)")
                await capture.stop()
                model.status = L("Allow Textize under System Settings > Privacy & Security > Screen & System Audio Recording (System Audio Recording Only). (\(error.localizedDescription))")
                try? await Task.sleep(for: .seconds(3))
            }
        }

        self.transcriber = transcriber
        self.capture = capture
        model.isRunning = true
        model.status = ""
    }

    func stop() async {
        startTask?.cancel()
        await capture?.stop()
        await transcriber?.stop()
        capture = nil
        transcriber = nil
        model.isRunning = false
        model.volatileSentences = []
    }

    private func wire(capture: SystemAudioCapture, transcriber: LiveTranscriber) {
        transcriber.onStatus = { [weak self] s in
            Log.info("status: \(s)")
            Task { @MainActor in self?.model.status = s }
        }
        transcriber.onResult = { [weak self] text, isFinal, start in
            Log.info("result final=\(isFinal) start=\(String(format: "%.2f", start)) chars=\(text.count)")
            Task { @MainActor in
                guard let self else { return }
                let changed = self.model.append(text: text, isFinal: isFinal, start: start)
                if self.settings.translationDisplay != .originalOnly {
                    changed.forEach { self.translateLine($0) }
                    if !isFinal { self.pretranslateVolatile() }
                }
            }
        }
        transcriber.onError = { [weak self] e in
            Task { @MainActor in self?.model.status = L("Recognition error: \(e.localizedDescription)") }
        }
        capture.onBuffer = { [weak transcriber] buf in transcriber?.feed(buf) }
        capture.onStop = { [weak self] e in
            Task { @MainActor in
                self?.model.status = L("Capture stopped: \(e?.localizedDescription ?? L("unknown"))")
                self?.restartIfRunning()
            }
        }
    }

    // MARK: 번역

    private var pretranslating: Set<String> = []

    /// 말이 끊기지 않으면 확정 결과가 수십 초 동안 안 올 수 있다. 임시 결과에서 완성된 문장(마지막 문장은 종결 부호가 있을 때만)을
    /// 미리 번역해 두면, 번역이 제 위치에 바로 보이고 확정될 때 같은 문장이면 그대로 넘어간다.
    private func pretranslateVolatile() {
        guard settings.translationEnabled else { return }
        let sentences = model.volatileSentences
        guard !sentences.isEmpty else { return }
        var candidates = Array(sentences.dropLast())
        if let last = sentences.last, Self.endsSentence(last) { candidates.append(last) }
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        for text in candidates where model.volatileTranslations[text] == nil && !pretranslating.contains(text) {
            pretranslating.insert(text)
            Task {
                defer { pretranslating.remove(text) }
                do {
                    let translated = try await translator.translate(text, from: source, to: target)
                    Log.info("pretranslated \(text.count) -> \(translated.count) chars")
                    if let line = model.lines.last(where: { $0.text == text && $0.translation == nil }) {
                        model.update(line.id) { $0.translation = translated; $0.isTranslating = false }
                    } else if model.volatileSentences.contains(text) {
                        model.volatileTranslations[text] = translated
                    }
                } catch {
                    Log.error("pretranslate failed: \(error)")
                }
            }
        }
    }

    private static func endsSentence(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.unicodeScalars.last else { return false }
        let terminators = CharacterSet(charactersIn: ".!?。！？…」』”’\")")
        return terminators.contains(last)
    }

    private func translateAllIfAuto() {
        guard settings.translationDisplay != .originalOnly else { return }
        for line in model.lines where line.translation == nil && !line.isTranslating {
            translateLine(line.id)
        }
    }

    func translateLine(_ id: UUID) {
        guard settings.translationEnabled,
              let line = model.lines.first(where: { $0.id == id }),
              line.translation == nil, !line.isTranslating else { return }
        model.update(id) { $0.isTranslating = true }
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        let text = line.text
        Task {
            do {
                let translated = try await translator.translate(text, from: source, to: target)
                Log.info("translated [\(source.minimalIdentifier)>\(target.minimalIdentifier)] \(text.count) -> \(translated.count) chars")
                model.update(id) { $0.translation = translated; $0.isTranslating = false }
            } catch {
                Log.error("translate failed: \(error)")
                model.update(id) { $0.isTranslating = false }
                let message = L("Translation failed: \(error.localizedDescription)")
                model.status = message
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if model.status == message { model.status = "" }
                }
            }
        }
    }

    private func lineTapped(_ id: UUID) {
        Log.info("lineTapped selecting=\(model.isSelecting) display=\(settings.translationDisplay.rawValue) enabled=\(settings.translationEnabled)")
        guard model.isSelecting else { return }
        switch settings.translationDisplay {
        case .originalOnly:
            model.update(id) { $0.revealed.toggle() }
            if model.lines.first(where: { $0.id == id })?.revealed == true { translateLine(id) }
        case .translationOnly:
            model.update(id) { $0.revealed.toggle() }
        case .both:
            break
        }
    }

}
