import Foundation

/// Basic mode: rule-based tidying done on this Mac, with no model and no network. It is instant and
/// predictable, so each phrase can be pasted as soon as it is spoken. It is also what AI cleanup falls back to.
enum BasicCleanup {
    static func apply(_ text: String) -> String {
        var s = text
        s = removingFillers(s)
        s = removingRepeats(s)
        s = applyingSpokenPunctuation(s)
        s = tidyingSpacing(s)
        // Only filler was spoken: nothing is left but the punctuation around it.
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return capitalizingSentences(s)
    }

    /// "I, um, think" -> "I think"; the commas the recognizer put around a filler go with it.
    private static func removingFillers(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?i),?\s*(?<![\w'])(?:um+|uh+|uhm+|erm+|hmm+|er)(?![\w'])\s*,?"#, with: " ",
                               options: .regularExpression)
    }

    /// Words that are often doubled on purpose ("had had", "very very", "bye bye").
    private static let meantTwice: Set = ["had", "that", "is", "very", "so", "no", "bye", "ha", "really"]

    /// "I I think the the plan" -> "I think the plan".
    private static func removingRepeats(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\b([A-Za-z']+)(?:[\s,]+\1\b)+"#, options: .caseInsensitive)
        var out = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: s), let first = Range(match.range(at: 1), in: s),
                  !meantTwice.contains(s[first].lowercased()) else { continue }
            out.replaceSubrange(whole, with: s[first])
        }
        return out
    }

    /// Spoken commands, and the symbol each becomes. Longer phrases come first so "new paragraph" wins over "new".
    private static let commands: [(words: String, symbol: String)] = [
        ("new paragraph", "\n\n"), ("new line", "\n"), ("next line", "\n"),
        ("question mark", "?"), ("exclamation point", "!"), ("exclamation mark", "!"),
        ("full stop", "."), ("period", "."), ("semicolon", ";"), ("colon", ":"), ("comma", ","),
    ]

    /// "see you soon period" -> "see you soon." The word after "a", "the" and the like is being talked about,
    /// not dictated ("a comma", "the period of time"), so it stays. Punctuation the recognizer already put
    /// around the command is replaced along with it.
    private static func applyingSpokenPunctuation(_ s: String) -> String {
        commands.reduce(s) { out, command in
            let words = command.words.replacingOccurrences(of: " ", with: #"\s+"#)
            let pattern = #"(?i)[,.;:!?]?[ \t]*(?<!\b(?:a|an|the|this|that|each|every|per|one)\s)\b"# + words + #"\b[,.;:!?]?"#
            return out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: command.symbol),
                                            options: .regularExpression)
        }
    }

    private static func tidyingSpacing(_ s: String) -> String {
        s.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
            // A space after a comma, colon or semicolon, but not inside numbers like 1,200 or times like 3:30.
            .replacingOccurrences(of: #"([,;:])(?=[^\s\d])"#, with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
            // Spaces only: a spoken "new line" at the end of a phrase must survive.
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /// A capital at the start and after each sentence end, and "I" on its own. Cursor fitting lowercases the
    /// first word again when the phrase continues a sentence already in the field.
    private static func capitalizingSentences(_ s: String) -> String {
        // A period ending an abbreviation like "i.e." or "e.g." does not end the sentence.
        let regex = try! NSRegularExpression(pattern: #"(^|(?<!\.[A-Za-z])[.!?]\s+|\n)([a-z])"#)
        var out = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let letter = Range(match.range(at: 2), in: s) else { continue }
            out.replaceSubrange(letter, with: s[letter].uppercased())
        }
        return out.replacingOccurrences(of: #"\bi(?=['\s,;:!?]|\.(?!\w)|$)"#, with: "I", options: .regularExpression)
    }
}
