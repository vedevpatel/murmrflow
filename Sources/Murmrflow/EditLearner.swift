import AppKit

/// Watches a field for a while after a dictation is pasted into it and learns from what the user fixes by hand:
/// misheard names and terms go into the personal dictionary, and small spelling, punctuation and wording fixes
/// are kept as examples for the cleanup model. Everything learned stays on this Mac.
final class EditLearner {
    static let shared = EditLearner()

    private struct Watch {
        let element: AXUIElement
        let pasted: String
        /// The text just before and after the paste, used to find the dictation again once things move.
        let before: String
        let after: String
        let location: Int
        let bundle: String?
        let whole: Bool
        let started = Date()
        /// The dictation as last seen in the field; kept when the field is later cleared, e.g. a sent chat message.
        var latest: String?
        /// Whether the user typed in the target app since the paste. Changes without typing came from
        /// somewhere else (a collaborator, autocorrect, the app reformatting) and are not learned from.
        var typed = false
    }

    private var watch: Watch?
    private var timer: Timer?
    private static let duration: TimeInterval = 120

    /// Starts watching the field a dictation was just pasted into, finishing any earlier watch first.
    /// `whole` marks a complete cleaned dictation, whose edited version is kept with its history entry.
    func watch(_ context: CursorContext, pasted: String, bundle: String?, whole: Bool) {
        finish()
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let element = context.element, !text.isEmpty else { return }
        watch = Watch(element: element, pasted: text, before: String(context.before.suffix(40)),
                      after: String(context.after.prefix(40)), location: context.location, bundle: bundle, whole: whole)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Learns from the last version of the dictation that was found, then stops watching.
    func finish() {
        timer?.invalidate()
        timer = nil
        guard let w = watch else { return }
        watch = nil
        guard w.typed, let edited = w.latest, edited != w.pasted else { return }
        learn(pasted: w.pasted, edited: edited, bundle: w.bundle, whole: w.whole)
    }

    /// Called for every key the user types; only the app it went to matters. Keys in the first half second
    /// are skipped too, in case our own simulated ⌘V is reported as coming from elsewhere.
    func noteKeyDown() {
        guard let w = watch, !w.typed, Date().timeIntervalSince(w.started) > 0.5,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == w.bundle else { return }
        watch?.typed = true
    }

    private func poll() {
        guard var w = watch else { return }
        if let value = CursorContext.value(of: w.element), let region = Self.region(in: value, of: w) {
            w.latest = region
            watch = w
        }
        if Date().timeIntervalSince(w.started) > Self.duration { finish() }
    }

    /// The dictation's current text in the field: whatever sits between the text that preceded and followed it,
    /// as long as it is still mostly the pasted words.
    private static func region(in value: String, of w: Watch) -> String? {
        var start = value.startIndex
        if !w.before.isEmpty {
            // Edits earlier in the field shift the text, so take the occurrence nearest the original position.
            let offset = { (i: String.Index) in abs(value.utf16.distance(from: value.startIndex, to: i) - w.location) }
            guard let best = value.ranges(of: w.before).min(by: { offset($0.upperBound) < offset($1.upperBound) }) else { return nil }
            start = best.upperBound
        }
        var end = value.endIndex
        if !w.after.isEmpty {
            guard let r = value.range(of: w.after, range: start..<value.endIndex) else { return nil }
            end = r.lowerBound
        }
        let region = value[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = words(w.pasted)
        return WordDiff(old: pasted, new: words(region)).matched * 5 >= pasted.count * 3 ? region : nil
    }

    private func learn(pasted: String, edited: String, bundle: String?, whole: Bool) {
        let old = Self.words(pasted), new = Self.words(edited)
        var hunks = WordDiff(old: old, new: new).hunks
        // Words typed straight after (or before) the dictation are new writing, not corrections.
        if let last = hunks.last, last.old.isEmpty, last.newStart + last.new.count == new.count { hunks.removeLast() }
        if let first = hunks.first, first.old.isEmpty, first.newStart == 0 { hunks.removeFirst() }
        guard !hunks.isEmpty else { return }
        if whole { StatsStore.shared.markLastEdited(edited) }

        // Rewriting a large part of it is a change of mind, not a fix.
        guard hunks.reduce(0, { $0 + $1.old.count }) * 10 <= old.count * 4 else { return }
        for h in hunks {
            if let learned = Self.misheardTerm(h) {
                NSLog("learned dictionary term \(learned.term) (heard as \(learned.heardAs))")
                PersonalDictionary.shared.learn(term: learned.term, heardAs: learned.heardAs)
            } else if Self.isFix(h) {
                StatsStore.shared.addCorrection(before: Self.snippet(old, at: h.oldStart, count: h.old.count),
                                                after: Self.snippet(new, at: h.newStart, count: h.new.count), bundle: bundle)
            }
        }
    }

    /// A short replacement that turns a misheard word into a name or term, like "Myrmraflow" -> "Murmrflow".
    /// A single ordinary word changed into a name ("flow" -> "Flo") is left to the fix examples, which keep its
    /// context; as a dictionary term it would make the model doubt every "flow".
    private static func misheardTerm(_ h: WordDiff.Hunk) -> (term: String, heardAs: String)? {
        guard (1...3).contains(h.old.count), (1...3).contains(h.new.count), !isAboutContent(h) else { return nil }
        let heard = core(h.old.joined(separator: " ")), term = core(h.new.joined(separator: " "))
        guard term.count >= 3, heard != term, term.split(separator: " ").contains(where: { isName(String($0)) }),
              h.old.count > 1 || heard.lowercased() == term.lowercased() || isName(heard) else { return nil }
        return similarity(heard, term) >= 0.5 ? (term, heard) : nil
    }

    /// A fix worth repeating: punctuation or capitalization, dropping a few words, or a close respelling.
    /// Changes to dates and numbers are changes of content, so they are never learned beyond punctuation.
    private static func isFix(_ h: WordDiff.Hunk) -> Bool {
        let old = h.old.joined(separator: " "), new = h.new.joined(separator: " ")
        if !h.old.isEmpty, !h.new.isEmpty, core(old).lowercased() == core(new).lowercased() { return true }
        if isAboutContent(h) { return false }
        if h.new.isEmpty { return h.old.count <= 3 }
        guard !h.old.isEmpty, h.old.count <= 3, h.new.count <= 3 else { return false }
        return similarity(core(old), core(new)) >= 0.5
    }

    private static let calendarWords = #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december|today|tomorrow|yesterday|morning|afternoon|evening|night)\b"#

    private static func isAboutContent(_ h: WordDiff.Hunk) -> Bool {
        let all = (h.old + h.new).joined(separator: " ")
        return all.rangeOfCharacter(from: .decimalDigits) != nil
            || all.range(of: calendarWords, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Not an ordinary word, judged by the part before any apostrophe, since the word list has no contractions.
    private static func isName(_ word: String) -> Bool {
        let base = core(word).split(separator: "'").first.map(String.init) ?? ""
        return base.count > 1 && CursorContext.isCommonWord(base) == false
    }

    /// The changed words with up to three words of context either side.
    private static func snippet(_ words: [String], at start: Int, count: Int) -> String {
        words[max(0, start - 3)..<min(words.count, start + count + 3)].joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func core(_ s: String) -> String {
        s.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// 1 for identical spellings, falling towards 0 as more letters differ. Spaces and case are ignored,
    /// since recognizers split and join words.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { !$0.isWhitespace }), y = Array(b.lowercased().filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]
            row[0] = i
            for j in 1...y.count {
                let next = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = next
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }
}

/// Word-level differences between two texts, as runs of replaced, removed or added words.
struct WordDiff {
    struct Hunk {
        var old: [String] = []
        var new: [String] = []
        let oldStart: Int
        let newStart: Int
    }

    let matched: Int
    let hunks: [Hunk]

    init(old: [String], new: [String]) {
        let n = old.count, m = new.count
        // lcs[i][j]: longest common run of old[i...] and new[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = [], current: Hunk?
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                if let c = current { hunks.append(c); current = nil }
                i += 1; j += 1
            } else if j == m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1]) {
                if current == nil { current = Hunk(oldStart: i, newStart: j) }
                current!.old.append(old[i]); i += 1
            } else {
                if current == nil { current = Hunk(oldStart: i, newStart: j) }
                current!.new.append(new[j]); j += 1
            }
        }
        if let c = current { hunks.append(c) }
        matched = lcs[0][0]
        self.hunks = hunks
    }
}
