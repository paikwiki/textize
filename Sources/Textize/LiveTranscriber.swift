import CoreMedia
import AVFoundation
import Speech

final class LiveTranscriber {
    enum TranscriberError: LocalizedError {
        case unsupportedLocale(Locale)
        case noAudioFormat
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let l): return "On-device recognition is not available for this language: \(l.identifier)"
            case .noAudioFormat: return L("Could not determine the audio format for the recognizer.")
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let feedQueue = DispatchQueue(label: "wiki.paik.textize.feed")

    /// (텍스트, 확정 여부, 오디오 시작 시각(초)). 임의 스레드에서 호출된다.
    var onResult: ((String, Bool, Double) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func start(locale requested: Locale) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError.unsupportedLocale(requested)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        // 앱이 모델을 받아 둘 수 있는 언어는 최대 5개(maximumReservedLocales). 꽉 찬 채로 새 언어를 받으면
        // SFSpeechErrorDomain 11 "Too many allocated locales"가 나므로, 자리가 날 만큼 다른 언어의 예약을 먼저 푼다.
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }) {
            var toFree = reserved.count - AssetInventory.maximumReservedLocales + 1
            for old in reserved where toFree > 0 && old.identifier != locale.identifier {
                if await AssetInventory.release(reservedLocale: old) {
                    toFree -= 1
                    Log.info("released speech model reservation: \(old.identifier)")
                }
            }
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?(L("Downloading speech model… (\(locale.identifier))"))
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noAudioFormat
        }
        targetFormat = format

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let start = CMTimeGetSeconds(result.range.start)
                    self?.onResult?(text, result.isFinal, start)
                }
            } catch {
                if !Task.isCancelled { self?.onError?(error) }
            }
        }

        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.transcriber = transcriber
        onStatus?("")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        feedQueue.async { [self] in
            guard let targetFormat, let continuation = inputContinuation else { return }
            guard let converted = convert(buffer, to: targetFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        converterInputFormat = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }

        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
