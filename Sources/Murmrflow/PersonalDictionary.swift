import Foundation

/// A word or name the speaker uses that speech recognition tends to get wrong.
struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// How it should be written, e.g. "Murmrflow".
    var term: String
    /// What the transcript tends to say instead, e.g. "murmur flow".
    var heardAs: [String] = []
}

/// Names and terms spelled the speaker's way in every dictation: fixed in the transcript directly,
/// listed for the cleanup model, and passed to the recognizer as hotwords where it accepts them.
/// Kept in UserDefaults; it is small and edited by hand.
final class PersonalDictionary: ObservableObject {
    static let shared = PersonalDictionary()
    private static let key = "personalDictionary"

    @Published private(set) var entries: [DictionaryEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
            rules = Self.rules(for: entries)
        }
    }
    private var rules: [(NSRegularExpression, String)]

    var terms: [String] { entries.map(\.term) }

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) }
        entries = saved ?? []
        rules = Self.rules(for: saved ?? [])
    }

    /// Adds a term, or replaces the entry already spelled that way.
    func add(term: String, heardAs: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let variants = heardAs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(term) != .orderedSame }
        var list = entries.filter { $0.term.caseInsensitiveCompare(term) != .orderedSame }
        list.append(DictionaryEntry(term: term, heardAs: variants))
        entries = list.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }

    func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    /// The text with every misheard form, and every wrongly cased copy of a term, written as the term.
    func apply(_ text: String) -> String {
        rules.reduce(text) { out, rule in
            rule.0.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: rule.1)
        }
    }

    /// One whole-word, case-insensitive pattern per spelling, longest first so "murmur flow app" wins over "murmur flow".
    /// Spaces in a spelling also match hyphens, since recognizers split and join words both ways.
    private static func rules(for entries: [DictionaryEntry]) -> [(NSRegularExpression, String)] {
        let pairs = entries.flatMap { e in ([e.term] + e.heardAs).map { ($0, e.term) } }
            .sorted { $0.0.count > $1.0.count }
        return pairs.compactMap { spelling, term in
            let words = spelling.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\w])"# + words.joined(separator: #"[\s-]+"#) + #"(?![\w])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: term))
        }
    }
}
