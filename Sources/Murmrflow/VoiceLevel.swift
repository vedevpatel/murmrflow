import AVFoundation

/// Loudness handling for the mic signal, built on what is learned about the speaker's voice on each mic.
///
/// - Auto gain raises quiet input (a soft voice, a distant or low-volume mic) so speech stays above the speech
///   server's fixed loudness floor (0.004 RMS), below which it is silently dropped. Loud input is never turned
///   down, and only stretches that stand out from the background count as speech, so a silent room is not
///   amplified up to speech level.
/// - Phrase levels let hands-free drop phrases far quieter than the speaker: another person, a TV. See PhraseGate.
///   To know which audio a finished phrase came from, the server's own phrase-splitting rule (fermion's
///   LiveSession) is run here on exactly the chunks sent to it, one WebSocket frame each.
final class VoiceLevel {
    static let blockSize = 800  // 50 ms at 16 kHz
    /// Where auto gain puts the speaker's peaks: loud enough for the server, with headroom for the limiter.
    private static let targetPeak: Float = 0.1
    private static let maxGain: Float = 20  // +26 dB
    /// A block counts as speech when it is this many times louder than the background (6 dB). Low enough for a soft
    /// voice over a fan; noise mistaken for speech only means a quiet room gets boosted, which the recognizer ignores.
    private static let speechOverNoise: Float = 2
    private static let minimumSpeech: Float = 0.0003

    // The server's segmentation (fermion/_speech/live.py), which these must match.
    private static let serverFloor: Float = 0.004
    private static let serverRatio: Float = 0.18
    private static let serverCloseSamples = Int(0.7 * 16_000)
    private static let serverMaxSamples = 30 * 16_000

    let mic: String
    /// Hands-free keeps the boosted background under the server's floor: above it the server never hears a pause,
    /// so phrases would not end and could not be judged one by one. Held dictation boosts fully instead.
    private let keepsPausesQuiet: Bool
    private let lock = NSLock()
    private var gain: Float
    private var targetGain: Float
    /// Raw 50 ms block levels of the last 3 s; the quietest of them is the background.
    private var history: [Float] = []
    private var recent: [Float] = []
    private var carry: [Float] = []
    private var recordingPeak: Float = 0

    private struct Segment {
        var samples = 0
        var voiced = false
        var lastVoice = 0
        var peak: Float = 0
        /// Raw levels of the voiced chunks, so gain changes don't make one phrase look louder than another.
        var levels: [Float] = []
    }
    private var segment = Segment()
    /// Levels of phrases the server has closed but whose text has not been matched yet.
    private var closed: [Float] = []
    private var recordingLevels: [Float] = []

    init(mic: String, handsFree: Bool = false) {
        self.mic = mic
        keepsPausesQuiet = handsFree
        gain = Self.learned(Self.peakKey, mic: mic).map(Self.gain(for:)) ?? 1
        targetGain = gain
    }

    /// The microphone recordings come from: the system default input.
    static var currentMic: String { AVCaptureDevice.default(for: .audio)?.uniqueID ?? "default" }

    /// The input with auto gain applied. Called on the audio thread with each converted chunk, which is then sent
    /// to the server as one frame.
    func process(_ input: UnsafeBufferPointer<Int16>) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let raw = input.map { Float($0) / 32768 }
        measure(raw)
        var target = targetGain
        if keepsPausesQuiet, let noise = history.min(), noise > 0 {
            target = min(target, max(1, Self.serverFloor * 0.5 / noise))
        }
        // Ramp to the new gain across the chunk so a change never clicks.
        let start = gain, step = (target - gain) / Float(max(raw.count, 1))
        gain = target
        let out = raw.enumerated().map { i, x in
            Int16(max(-32768, min(32767, (Self.limit(x * (start + step * Float(i))) * 32767).rounded())))
        }
        followServer(raw: Self.steadyLevel(raw), sent: Self.rms(out.map { Float($0) / 32768 }), count: raw.count)
        return out
    }

    /// A chunk's loudness with clicks left out: the median over its 10 ms slices. A key click fills a slice or two,
    /// while a voice fills them all, so typing next to the mic doesn't make a quiet voice look loud.
    private static func steadyLevel(_ x: [Float]) -> Float {
        let slice = 160
        guard x.count >= slice * 2 else { return rms(x) }
        return median(stride(from: 0, to: x.count - slice + 1, by: slice).map { rms(Array(x[$0..<$0 + slice])) })
    }

    /// The loudness of the phrase the server just finished. Its text arrives shortly after the phrase closes and
    /// before the next one can, so it belongs to the latest closed phrase; older unmatched ones produced no text.
    func takePhraseLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        if let last = closed.last { closed.removeAll(); return last }
        return Self.median(segment.levels)
    }

    /// The loudness of whatever the server finishes when the recording ends.
    func takeRemainingLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let level = max(closed.last ?? 0, Self.median(segment.levels))
        closed.removeAll()
        return level
    }

    /// The loudness of the phrase in progress, for deciding whether to show its live caption.
    var phraseLevelSoFar: Float {
        lock.lock(); defer { lock.unlock() }
        return Self.median(segment.levels)
    }

    /// Remembers how loud the speaker was on this mic, for the next recording's starting gain and hands-free's gate.
    /// Only for recordings that produced text: in an empty one, what looked like speech was the room.
    func finish() {
        lock.lock(); let peak = recordingPeak, phrase = Self.median(recordingLevels); lock.unlock()
        if peak > 0 { Self.learn(peak, Self.peakKey, mic: mic) }
        if phrase > 0 { Self.learn(phrase, Self.phraseKey, mic: mic) }
    }

    private func measure(_ samples: [Float]) {
        carry += samples
        while carry.count >= Self.blockSize {
            let rms = Self.rms(Array(carry.prefix(Self.blockSize)))
            carry.removeFirst(Self.blockSize)
            history = Array((history + [rms]).suffix(60))
            // The median of three blocks, so a single click or knock does not count.
            recent = Array((recent + [rms]).suffix(3))
            let level = recent.sorted()[recent.count / 2]
            guard level > max((history.min() ?? rms) * Self.speechOverNoise, Self.minimumSpeech) else { continue }
            if level > recordingPeak {
                recordingPeak = level
                targetGain = Self.gain(for: level)
            }
        }
    }

    /// fermion's LiveSession.feed, block for block: a phrase is voiced by any chunk louder than both the floor and
    /// 18% of the phrase's loudest chunk, and ends after 0.7 s without one (or at 30 s).
    private func followServer(raw: Float, sent: Float, count: Int) {
        segment.samples += count
        segment.peak = max(segment.peak, sent)
        if sent > max(Self.serverFloor, Self.serverRatio * segment.peak) {
            segment.voiced = true
            segment.lastVoice = segment.samples
            segment.levels.append(raw)
            recordingLevels.append(raw)
        }
        if segment.voiced && segment.samples - segment.lastVoice >= Self.serverCloseSamples {
            closed.append(Self.median(segment.levels))
            segment = Segment()
        } else if segment.samples >= Self.serverMaxSamples {
            if segment.voiced {
                closed.append(Self.median(segment.levels))
                segment = Segment()
            } else {
                // The server keeps the last second of an idle segment and starts over.
                segment = Segment(samples: 16_000)
            }
        }
    }

    private static func gain(for peak: Float) -> Float {
        min(maxGain, max(1, targetPeak / peak))
    }

    /// Leaves the signal alone up to 0.8 and bends anything louder smoothly towards full scale instead of clipping.
    private static func limit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.8 else { return x }
        return (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((a - 0.8) / 0.2))
    }

    private static func rms(_ x: [Float]) -> Float {
        x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// The typical loudness of a phrase. A median, so key clicks over a TV, being a minority of its chunks, don't count.
    private static func median(_ x: [Float]) -> Float {
        x.isEmpty ? 0 : x.sorted()[x.count / 2]
    }

    // MARK: - Per-mic memory

    private static let peakKey = "speechPeakByMic"
    private static let phraseKey = "phraseLevelByMic"

    /// The speaker's usual phrase loudness on this mic, which hands-free's gate starts from.
    static func learnedPhraseLevel(mic: String) -> Float? { learned(phraseKey, mic: mic) }

    private static func learned(_ key: String, mic: String) -> Float? {
        (UserDefaults.standard.dictionary(forKey: key)?[mic] as? Double).map(Float.init)
    }

    /// Averaged in decibels, so one unusually loud or soft recording moves the estimate only part of the way.
    private static func learn(_ level: Float, _ key: String, mic: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        let blended = learned(key, mic: mic).map { exp(0.7 * log($0) + 0.3 * log(level)) } ?? level
        all[mic] = Double(blended)
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Hands-free's filter against other voices in the room. A phrase much quieter than the speaker's recent phrases
/// (under a quarter, -12 dB) is someone or something else and is dropped. The reference follows the phrases that
/// pass, so moving away from the mic gradually still counts as the speaker.
struct PhraseGate {
    private static let ratio: Float = 0.25
    private var reference: Float?

    /// `learned` is the speaker's usual phrase loudness on this mic, if known; the reference starts 6 dB below it.
    init(learned: Float?) {
        reference = learned.map { $0 * 0.5 }
    }

    func wouldAccept(_ level: Float) -> Bool {
        guard let reference, level > 0 else { return true }
        return level >= reference * Self.ratio
    }

    /// A level of 0 means the phrase could not be measured; it is let through rather than guessed at.
    mutating func accept(_ level: Float) -> Bool {
        guard level > 0 else { return true }
        guard let current = reference else {
            reference = level
            return true
        }
        guard level >= current * Self.ratio else { return false }
        reference = exp(0.7 * log(current) + 0.3 * log(level))
        return true
    }
}
