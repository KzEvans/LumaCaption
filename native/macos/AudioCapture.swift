import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import ScreenCaptureKit

enum CaptureFailure: LocalizedError {
    case invalidSource, permissionDenied, noDisplay, unavailableDevice, invalidFormat
    var errorDescription: String? {
        switch self {
        case .invalidSource: return "未知音频来源。请选择系统声音或麦克风。"
        case .permissionDenied: return "麦克风权限未授权，请在系统设置的隐私与安全性中允许 LumaCaption 使用麦克风。"
        case .noDisplay: return "系统声音采集需要一个可用显示器。"
        case .unavailableDevice: return "所选音频设备已不可用，请重新选择设备。"
        case .invalidFormat: return "音频设备没有提供可转换的 PCM 格式。"
        }
    }
}

/// Preserve ScreenCaptureKit's reason instead of treating every start failure as
/// a privacy denial. In particular, -3818 is an audio-start failure, not -3801.
struct CaptureErrorReport {
    let code: String
    let message: String
    let details: [String: Any]

    static func isSystemPermissionDenied(_ error: Error) -> Bool {
        let native = error as NSError
        return native.domain == SCStreamErrorDomain && native.code == SCStreamError.Code.userDeclined.rawValue
    }

    init(_ error: Error, source: String) {
        let native = error as NSError
        details = [
            "domain": native.domain, "nativeCode": native.code, "source": source,
            "appPath": Bundle.main.bundleURL.path,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? ""
        ]
        if source == "system" && Self.isSystemPermissionDenied(error) {
            code = "systemCapturePermissionDenied"
            message = "macOS 未允许当前这份 LumaCaption 采集系统声音。若已在系统设置开启，请完全退出并重新打开；仍失败时，请确认允许的是正在运行的应用副本。"
        } else if source == "microphone", let failure = error as? CaptureFailure, case .permissionDenied = failure {
            code = "microphonePermissionDenied"
            message = failure.localizedDescription
        } else if native.domain == SCStreamErrorDomain && native.code == SCStreamError.Code.failedToStartAudioCapture.rawValue {
            code = "systemAudioStartFailed"
            message = "系统声音流启动失败，请检查音频输出设备后重试。\(native.localizedDescription)"
        } else {
            code = "capture"
            message = native.localizedDescription
        }
    }
}

/// A bounded handoff between real-time callbacks, conversion, and Flutter's UI queue.
/// The capture callback never waits for conversion, Dart, or the network.
final class PCMDelivery {
    private let queue = DispatchQueue(label: "app.lumacaption.pcm", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 8)
    private let stateLock = NSLock()
    private var active = false
    private var paused = false
    private var generation = 0
    private var sequence = 0
    private var dropped = 0
    private var converter: AVAudioConverter?
    private var converterFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    var onEvent: (([String: Any]) -> Void)?

    func begin() -> Int {
        stateLock.lock()
        generation += 1
        active = true
        paused = false
        let token = generation
        stateLock.unlock()
        queue.async { [weak self] in
            self?.converter = nil
            self?.converterFormat = nil
            self?.sequence = 0
        }
        return token
    }

    func end() {
        stateLock.lock()
        active = false
        generation += 1
        stateLock.unlock()
    }

    func setPaused(_ value: Bool) {
        stateLock.lock()
        paused = value
        stateLock.unlock()
        queue.async { [weak self] in self?.converter?.reset() }
    }

    private func accepts(_ token: Int) -> Bool {
        // This is also used on the tap queue, so a busy lock means a skipped frame.
        guard stateLock.try() else { return false }
        defer { stateLock.unlock() }
        return active && !paused && generation == token
    }

    func submit(_ input: AVAudioPCMBuffer, timestampUs: Int64, token: Int) {
        guard accepts(token), slots.wait(timeout: .now()) == .success else { return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            slots.signal(); return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            if let from = source[index].mData, let to = destination[index].mData {
                memcpy(to, from, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            guard self.accepts(token) else { self.slots.signal(); return }
            if self.converterFormat != copy.format {
                self.converter = AVAudioConverter(from: copy.format, to: self.outputFormat)
                self.converterFormat = copy.format
            }
            guard let converter = self.converter else {
                self.emitError("audioFormat", message: "音频格式转换失败。", token: token)
                self.slots.signal(); return
            }
            let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * 16_000 / copy.format.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: capacity) else {
                self.slots.signal(); return
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, result in
                if supplied { result.pointee = .noDataNow; return nil }
                supplied = true
                result.pointee = .haveData
                return copy
            }
            guard status != .error, error == nil, let samples = output.floatChannelData?[0] else {
                self.emitError("audioConversion", message: error?.localizedDescription ?? "音频重采样失败。", token: token)
                self.slots.signal(); return
            }
            guard output.frameLength > 0 else { self.slots.signal(); return }
            let data = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Float>.size)
            let sequence = self.sequence
            self.sequence += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.slots.signal() }
                guard self.accepts(token) else { return }
                self.onEvent?([
                    "type": "audio", "pcm": data, "sampleRate": 16_000, "channels": 1,
                    "timestampUs": timestampUs, "sequence": sequence, "generation": token,
                    "sampleFormat": "float32le"
                ])
            }
        }
    }

    private func emitError(_ code: String, message: String, token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.accepts(token) else { return }
            self.onEvent?(["type": "error", "code": code, "message": message])
        }
    }
}

@available(macOS 13.0, *)
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let delivery = PCMDelivery()
    private let captureQueue = DispatchQueue(label: "app.lumacaption.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var token = 0
    private var lifecycle = 0
    private var isStarting = false
    private var systemPermissionDenied = false
    private(set) var running = false
    var onEvent: (([String: Any]) -> Void)? {
        didSet { delivery.onEvent = onEvent }
    }

    override init() {
        super.init()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            self.stop()
            self.onEvent?(["type": "error", "code": "systemSleep", "message": "系统进入睡眠，采集已停止。唤醒后请重新开始。"])
        }
    }

    func permissions() -> [String: String] {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "authorized"
        case .denied: microphone = "denied"
        case .restricted: microphone = "restricted"
        case .notDetermined: microphone = "notDetermined"
        @unknown default: microphone = "unknown"
        }
        let preflight = CGPreflightScreenCaptureAccess()
        let system: String
        if running && stream != nil {
            system = "authorized"
        } else if systemPermissionDenied {
            system = preflight ? "restartRequired" : "notAuthorized"
        } else {
            // A CoreGraphics screen preflight is only a hint. The user's Start
            // action calls ScreenCaptureKit itself; never block on this value.
            system = preflight ? "authorized" : "notVerified"
        }
        return ["microphone": microphone, "system": system]
    }

    static func devices() -> [[String: Any]] {
        var result: [[String: Any]] = [["id": "system", "name": "系统声音（所有应用）", "source": "system", "isDefault": true]]
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return result }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &ids) == noErr else { return result }
        var defaultDevice = AudioDeviceID(0)
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultProperty = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultProperty, 0, nil, &defaultSize, &defaultDevice)
        result.append(["id": "default", "name": "系统默认麦克风", "source": "microphone", "isDefault": true])
        for id in ids {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var name: CFString = "麦克风" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameProperty = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            withUnsafeMutablePointer(to: &name) { pointer in
                _ = AudioObjectGetPropertyData(id, &nameProperty, 0, nil, &nameSize, pointer)
            }
            result.append(["id": String(id), "name": name as String, "source": "microphone", "isDefault": id == defaultDevice])
        }
        return result
    }

    @MainActor
    func start(source: String, deviceID: String?) async throws {
        stop()
        let operation = lifecycle
        isStarting = true
        token = delivery.begin()
        let currentToken = token
        do {
            if source == "microphone" {
                var authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if !authorized { authorized = await AVCaptureDevice.requestAccess(for: .audio) }
                guard authorized else { throw CaptureFailure.permissionDenied }
                guard lifecycle == operation else { return }
                try startMicrophone(deviceID: deviceID, token: currentToken)
            } else if source == "system" {
                systemPermissionDenied = false
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard lifecycle == operation else { return }
                guard let display = content.displays.first else { throw CaptureFailure.noDisplay }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 16_000
                configuration.channelCount = 1
                // A display filter is required by SCStream; never register screen output.
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                stream = newStream
                try await newStream.startCapture()
                guard lifecycle == operation else {
                    try? await newStream.stopCapture()
                    return
                }
            } else { throw CaptureFailure.invalidSource }
            isStarting = false
            running = true
            onEvent?(["type": "status", "status": "capturing", "source": source])
        } catch {
            if lifecycle == operation {
                if source == "system" { systemPermissionDenied = CaptureErrorReport.isSystemPermissionDenied(error) }
                stop()
            }
            throw error
        }
    }

    private func startMicrophone(deviceID: String?, token: Int) throws {
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        if let deviceID, deviceID != "default", !deviceID.isEmpty {
            guard var id = UInt32(deviceID), let unit = input.audioUnit else { throw CaptureFailure.unavailableDevice }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw CaptureFailure.unavailableDevice }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureFailure.invalidFormat }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            let timestamp = Int64(AVAudioTime.seconds(forHostTime: hostTime) * 1_000_000)
            self?.delivery.submit(buffer, timestampUs: timestamp, token: token)
        }
        engine = audioEngine
        audioEngine.prepare()
        try audioEngine.start()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.stop()
            self.onEvent?(["type": "error", "code": "deviceChanged", "message": "音频设备或蓝牙格式发生变化，采集已停止。请检查设备并重新开始。"])
        }
    }

    func pause() {
        delivery.setPaused(true)
        onEvent?(["type": "status", "status": "paused"])
    }
    func resume() {
        delivery.setPaused(false)
        onEvent?(["type": "status", "status": running ? "capturing" : "stopped"])
    }
    func stop() {
        lifecycle += 1
        isStarting = false
        running = false
        delivery.end()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let stream {
            self.stream = nil
            stream.stopCapture { _ in }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let audioFormat = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat? else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // ScreenCaptureKit presentation time is on the host monotonic clock.
        let timestamp = pts.isValid && !pts.isIndefinite
            ? Int64(CMTimeGetSeconds(pts) * 1_000_000)
            : Int64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000)
        delivery.submit(pcm, timestampUs: timestamp, token: token)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stop()
            self.systemPermissionDenied = CaptureErrorReport.isSystemPermissionDenied(error)
            let report = CaptureErrorReport(error, source: "system")
            self.onEvent?(["type": "error", "code": report.code, "message": report.message, "details": report.details])
        }
    }

    deinit {
        stop()
        if let observer = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
