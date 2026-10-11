// AudioRecorder — records the microphone straight into memory with AVAudioEngine.
// Audio is converted on the fly to 16 kHz mono 16-bit PCM (what speech models want,
// ~32 KB/s), so nothing touches the disk and there's no ffmpeg start-up delay.
// `level` (0…1) is reported ~40 times a second for the live waveform.
import AVFoundation
import CoreAudio

final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case cannotConvert
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone available"
            case .cannotConvert: return "The microphone's audio format isn't supported"
            }
        }
    }

    static let sampleRate = 16_000.0

    /// Called on the main queue with a smoothed 0…1 input level.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue once the first audio buffer has arrived.
    var onFirstAudio: (() -> Void)?

    private var engine: AVAudioEngine?
    private var pcm = Data()
    private let lock = NSLock()
    private var gotAudio = false
    private var smoothed: Float = 0

    var isRecording: Bool { engine?.isRunning ?? false }

    /// Seconds of audio captured so far.
    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(pcm.count) / 2 / Self.sampleRate
    }

    func start(deviceUID: String) throws {
        stopEngine()
        lock.lock(); pcm = Data(); pcm.reserveCapacity(32_000 * 30); lock.unlock()
        gotAudio = false
        smoothed = 0

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty {
            if let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
                var dev = id
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                                  0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr { Log.error("Couldn't select microphone \(deviceUID) (\(status)) — using the default") }
            } else {
                Log.info("Microphone \(deviceUID) not connected — using the default")
            }
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw RecorderError.cannotConvert }
        converter.downmix = true
        let ratio = Self.sampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.reportLevel(buffer)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
            self.lock.lock(); self.pcm.append(bytes); self.lock.unlock()
            if !self.gotAudio {
                self.gotAudio = true
                DispatchQueue.main.async { self.onFirstAudio?() }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops recording and returns the audio as a WAV file in memory.
    func stop() -> Data {
        stopEngine()
        lock.lock(); let samples = pcm; pcm = Data(); lock.unlock()
        return WAV.encode(pcm16Mono: samples, sampleRate: Int(Self.sampleRate))
    }

    /// Stops and throws the audio away (a tap, a chord, or Esc).
    func discard() {
        stopEngine()
        lock.lock(); pcm = Data(); lock.unlock()
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let samples = data[0]
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-6))
        let level = max(0, min(1, (db + 55) / 45))       // -55 dB … -10 dB → 0 … 1
        smoothed = level > smoothed ? level : smoothed * 0.75 + level * 0.25
        let value = smoothed
        DispatchQueue.main.async { [weak self] in self?.onLevel?(value) }
    }
}

enum WAV {
    static func encode(pcm16Mono pcm: Data, sampleRate: Int) -> Data {
        var d = Data(capacity: 44 + pcm.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    /// Duration in seconds of a WAV made by `encode`.
    static func duration(of wav: Data) -> Double {
        Double(max(0, wav.count - 44)) / 2 / AudioRecorder.sampleRate
    }
}

/// Lists audio input devices through CoreAudio.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: String      // the device UID (stable across reboots)
        let name: String
    }

    static func inputs() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let s = value else { return nil }
        return s.takeRetainedValue() as String
    }
}
