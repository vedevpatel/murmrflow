import AppKit
import NaturalLanguage

/// The text either side of the caret in the focused field, read through Accessibility,
/// so a dictation can be fitted into what is already there.
struct CursorContext {
    let before: String
    let after: String
    /// The field itself and where the selection started (UTF-16 offset), so it can be read again after pasting.
    var element: AXUIElement? = nil
    var location = 0

    /// Nil when the focused element exposes no text (or is a password field), or does not answer quickly.
    static func read() -> CursorContext? {
        let system = AXUIElementCreateSystemWide()
        // Applies to every element: a slow app must never hold up the paste.
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let element: AXUIElement = attribute(system, kAXFocusedUIElementAttribute),
              (attribute(element, kAXSubroleAttribute) as String?) != kAXSecureTextFieldSubrole,
              let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selection) else { return nil }

        let start = selection.location, end = selection.location + selection.length
        if let before = string(element, from: max(0, start - 200), to: start),
           let total: Int = attribute(element, kAXNumberOfCharactersAttribute),
           let after = string(element, from: end, to: min(total, end + 50)) {
            return CursorContext(before: before, after: after, element: element, location: start)
        }
        // Some apps only expose the whole value, not ranges of it.
        guard let value = value(of: element) else { return nil }
        let ns = value as NSString
        guard end <= ns.length else { return nil }
        let from = max(0, start - 200), to = min(ns.length, end + 50)
        return CursorContext(before: ns.substring(with: NSRange(location: from, length: start - from)),
                             after: ns.substring(with: NSRange(location: end, length: to - end)),
                             element: element, location: start)
    }

    /// The whole text of a field, or nil once it is gone or stops answering.
    static func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func string(_ element: AXUIElement, from: Int, to: Int) -> String? {
        guard to >= from else { return nil }
        if to == from { return "" }
        var range = CFRange(location: from, length: to - from)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         param, &value) == .success else { return nil }
        return value as? String
    }

    /// The dictation adjusted to its surroundings: a space before it when it follows a word, a lowercase
    /// first word when it continues a sentence, and no period of its own when it lands mid-sentence.
    func fit(_ text: String) -> String {
        var out = text
        let line = before.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        if let last = line.last, !last.isNewline {
            if last.isLetter || last.isNumber || ",;-–—)".contains(last) { out = Self.lowercasingFirstWord(out, after: before) }
            let opener = "([{\"“‘'/@#".contains(last)
            if !opener, let c = before.last, !c.isWhitespace { out = " " + out }
        }
        let next = after.first { $0 != " " && $0 != "\t" }
        if let next, next.isLowercase || next.isNumber || ",;:".contains(next) || (next == "." && after.first == ".") {
            out = Self.droppingFinalPeriod(out)
        }
        if let first = after.first, first.isLetter || first.isNumber { out += " " }
        return out
    }

    /// Lowercases "Then" in "…and Then", but leaves "I", acronyms and names alone. A word counts as a name
    /// when the tagger says so, or when the system word list only has it capitalized.
    static func lowercasingFirstWord(_ text: String, after before: String) -> String {
        guard let range = text.range(of: #"^\s*[A-Z][a-z]*"#, options: .regularExpression) else { return text }
        let word = text[range].trimmingCharacters(in: .whitespaces)
        let rest = text[range.upperBound...]
        if word == "I" || rest.first?.isLetter == true || rest.first?.isNumber == true { return text }
        if isCommonWord(word) == false { return text }
        let joined = before + text
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = joined
        let start = joined.index(joined.startIndex, offsetBy: before.count + text.distance(from: text.startIndex, to: text.range(of: word)!.lowerBound))
        let (tag, _) = tagger.tag(at: start, unit: .word, scheme: .nameType)
        if [.personalName, .placeName, .organizationName].contains(tag) { return text }
        return text.replacingCharacters(in: range, with: text[range].lowercased())
    }

    /// Whether the word is an ordinary lowercase English word rather than a name or made-up term;
    /// nil when the system word list is missing.
    static func isCommonWord(_ word: String) -> Bool? {
        wordList.map { $0.range(of: Data("\n\(word.lowercased())\n".utf8)) != nil }
    }

    /// One word per line; ordinary words are lowercase and proper nouns capitalized.
    private static let wordList = try? Data(contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"))

    /// Removes one closing period, but not an ellipsis or the end of an abbreviation like "p.m.".
    static func droppingFinalPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix(".."),
              let lastWord = text.split(whereSeparator: \.isWhitespace).last,
              lastWord.dropLast().contains(".") == false else { return text }
        return String(text.dropLast())
    }

    /// Chat messages read better without a closing period, as long as they are short.
    static func droppingChatPeriod(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        guard tokenizer.tokens(for: text.startIndex..<text.endIndex).count <= 2 else { return text }
        return droppingFinalPeriod(text)
    }
}
