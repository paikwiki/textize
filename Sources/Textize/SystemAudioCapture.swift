import AVFoundation
import CoreAudio

/// Core Audio 프로세스 탭으로 시스템 오디오(맥에서 나는 소리)를 받아 PCM 버퍼로 넘긴다.
/// 화면 녹화 권한 없이 "시스템 오디오 녹음" 권한만 쓴다.
///
/// 구성: 전역 탭(모든 프로세스의 출력을 모노로 믹스다운, 이 앱 자신은 제외) → 탭을 담은 비공개 집계 장치
/// → 집계 장치의 IO 콜백에서 입력 버퍼를 복사해 넘긴다.
final class SystemAudioCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        case noOutputDevice
        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let status): return "\(what) failed (\(status))"
            case .noOutputDevice: return L("No default output device found.")
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "wiki.paik.textize.audio")
    private var bufferCount = 0
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    /// 오디오 버퍼가 도착할 때마다 호출된다 (ioQueue에서). 버퍼는 복사본이라 보관해도 된다.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 캡처가 외부 요인(기본 출력 장치 변경 등)으로 멈췄을 때. 호출자가 다시 시작한다.
    var onStop: ((Error?) -> Void)?

    func start() async throws {
        // 1. 탭: 모든 프로세스의 출력을 모노로 섞되, 이 앱 자신은 뺀다.
        var excluded: [AudioObjectID] = []
        if let me = Self.processObject(for: getpid()) { excluded.append(me) }
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Textize"
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        // 처음 한 번은 여기서 "시스템 오디오 녹음" 권한 대화상자가 뜬다. 거부하면 실패한다.
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw CaptureError.coreAudio("Creating audio tap", err) }
        tapID = tap

        // 2. 기본 출력 장치를 클록으로 삼는 비공개 집계 장치에 탭을 넣는다.
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            cleanup()
            throw CaptureError.noOutputDevice
        }
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Textize Capture",
            kAudioAggregateDeviceUIDKey: "wiki.paik.textize.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregate)
        guard err == noErr else {
            cleanup()
            throw CaptureError.coreAudio("Creating aggregate device", err)
        }
        aggregateID = aggregate

        // 3. 탭의 스트림 포맷. 인식기 쪽에서 필요한 포맷으로 변환하므로 그대로 쓴다.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw CaptureError.coreAudio("Reading tap format", err)
        }
        self.format = format
        Log.info("tap format=\(format)")

        // 4. IO 콜백. 입력 버퍼는 콜백이 끝나면 무효가 되므로 복사해서 넘긴다.
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
            guard let self, let pcm = Self.copy(inputData, format: format) else { return }
            self.bufferCount += 1
            if self.bufferCount == 1 || self.bufferCount % 500 == 0 {
                Log.info("audio buffers=\(self.bufferCount) format=\(pcm.format) frames=\(pcm.frameLength)")
            }
            self.onBuffer?(pcm)
        }
        guard err == noErr, let procID else {
            cleanup()
            throw CaptureError.coreAudio("Creating IO proc", err)
        }
        ioProcID = procID
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            cleanup()
            throw CaptureError.coreAudio("Starting device", err)
        }
        watchDefaultOutputDevice()
    }

    func stop() async {
        cleanup()
    }

    private func cleanup() {
        unwatchDefaultOutputDevice()
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
    }

    // MARK: 기본 출력 장치 변경 감시 — 집계 장치의 클록이 사라지면 캡처가 멈추므로 다시 만든다.

    private func watchDefaultOutputDevice() {
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Log.info("default output device changed; restarting capture")
            self.cleanup()
            self.onStop?(nil)
        }
        outputDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, block)
    }

    private func unwatchDefaultOutputDevice() {
        guard let block = outputDeviceListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, block)
        outputDeviceListener = nil
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Core Audio 조회

    private static func defaultOutputDeviceUID() -> String? {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // 반환된 CFString은 호출자가 해제해야 하므로 Unmanaged로 받는다.
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        return err == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func copy(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let dst = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (i, src) in buffers.enumerated() where i < dst.count {
            guard let s = src.mData, let d = dst[i].mData else { continue }
            let bytes = min(Int(src.mDataByteSize), Int(dst[i].mDataByteSize))
            memcpy(d, s, bytes)
        }
        return pcm
    }
}
