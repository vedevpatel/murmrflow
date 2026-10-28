import AVFoundation

/// Captures the default mic as 16 kHz mono Int16, the format the ASR server wants.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread with each converted chunk of little-endian Int16 PCM.
    var onChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: AudioRecorder.sampleRate,
                                          channels: 1, interleaved: true)!
    /// Auto gain and loudness measurement for the current recording; kept after `stop()` for the last phrase.
    private(set) var level = VoiceLevel(mic: "default")

    /// `handsFree` keeps auto gain from lifting the room above the speech server's floor; see VoiceLevel.
    func start(handsFree: Bool) throws {
        level = VoiceLevel(mic: VoiceLevel.currentMic, handsFree: handsFree)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns everything recorded since `start()`, with auto gain applied.
    func stop() -> [Int16] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        let chunk = level.process(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        chunk.withUnsafeBufferPointer { onChunk?(Data(buffer: $0)) }
    }

    static func wav(from samples: [Int16]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); put(36 + dataSize)
        d.append("WAVEfmt ".data(using: .ascii)!); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate) * 2); put(UInt16(2)); put(UInt16(16))
        d.append("data".data(using: .ascii)!); put(dataSize)
        samples.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: samples.count * 2)) }
        return d
    }
}
