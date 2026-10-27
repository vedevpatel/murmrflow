import Foundation
import SQLite3

/// One finished dictation. `text` is only present when the user has opted in to saving transcripts.
struct DictationEntry: Identifiable {
    let id: Int64
    let date: Date
    let words: Int
    let seconds: Double
    let text: String?
    /// The transcript before cleanup rewrote it; nil when cleanup did not change it.
    let rawText: String?
    let appName: String?
}

/// Everything Murmrflow remembers, in ~/Library/Application Support/Murmrflow/murmrflow.sqlite.
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var entries: [DictationEntry] = []
    @Published var saveText: Bool {
        didSet { UserDefaults.standard.set(saveText, forKey: Self.saveTextKey) }
    }
    /// Whether fixes made by hand after a paste are learned from; see EditLearner.
    @Published var learnFromEdits: Bool {
        didSet { UserDefaults.standard.set(learnFromEdits, forKey: Self.learnKey) }
    }

    private static let saveTextKey = "saveTranscriptText"
    private static let learnKey = "learnFromEdits"
    let directory: URL
    private let db: Database?

    private init() {
        saveText = UserDefaults.standard.bool(forKey: Self.saveTextKey)
        learnFromEdits = UserDefaults.standard.object(forKey: Self.learnKey) as? Bool ?? true
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmrflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try? Database(url: directory.appendingPathComponent("murmrflow.sqlite"))
        migrate()
        reload()
    }

    private func migrate() {
        guard let db else { return }
        if db.userVersion < 1 {
            try? db.run("""
                CREATE TABLE IF NOT EXISTS dictations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    started_at REAL NOT NULL,
                    seconds REAL NOT NULL,
                    words INTEGER NOT NULL,
                    text TEXT,
                    app_bundle TEXT,
                    app_name TEXT
                )
                """)
            try? db.run("CREATE INDEX IF NOT EXISTS idx_dictations_started ON dictations(started_at)")
            db.userVersion = 1
        }
        if db.userVersion < 2 {
            try? db.run("ALTER TABLE dictations ADD COLUMN raw_text TEXT")
            db.userVersion = 2
        }
        if db.userVersion < 3 {
            // The text as the user left it after fixing it by hand, next to what was pasted.
            try? db.run("ALTER TABLE dictations ADD COLUMN edited_text TEXT")
            // Small fixes learned from those edits, shown to the cleanup model as examples.
            try? db.run("""
                CREATE TABLE IF NOT EXISTS corrections (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at REAL NOT NULL,
                    app_bundle TEXT,
                    before_text TEXT NOT NULL,
                    after_text TEXT NOT NULL
                )
                """)
            db.userVersion = 3
        }
        importLegacyLog()
    }

    /// Counts logged by the first version of the dashboard (stats.jsonl) move into the database once.
    private func importLegacyLog() {
        let legacy = directory.appendingPathComponent("stats.jsonl")
        guard let db, let data = try? Data(contentsOf: legacy) else { return }
        struct Legacy: Decodable { let date: Date; let words: Int; let seconds: Double }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let e = try? decoder.decode(Legacy.self, from: line) else { continue }
            try? db.run("INSERT INTO dictations (started_at, seconds, words) VALUES (?, ?, ?)",
                        [e.date.timeIntervalSince1970, e.seconds, e.words])
        }
        try? FileManager.default.moveItem(at: legacy, to: directory.appendingPathComponent("stats.jsonl.imported"))
    }

    func reload() {
        guard let db else { return }
        entries = (try? db.query("SELECT id, started_at, seconds, words, text, app_name, raw_text FROM dictations ORDER BY started_at") { s in
            DictationEntry(id: sqlite3_column_int64(s, 0),
                           date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                           words: Int(sqlite3_column_int64(s, 3)),
                           seconds: sqlite3_column_double(s, 2),
                           text: Database.text(s, 4),
                           rawText: Database.text(s, 6),
                           appName: Database.text(s, 5))
        }) ?? []
    }

    func record(text: String, raw: String, seconds: Double, appName: String?, appBundle: String?) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0, let db else { return }
        let rawText = saveText && raw != text ? raw : nil
        try? db.run("INSERT INTO dictations (started_at, seconds, words, text, raw_text, app_bundle, app_name) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [Date().timeIntervalSince1970, seconds, words, saveText ? text : nil, rawText, appBundle, appName])
        reload()
    }

    /// Keeps the user's edited version of the latest dictation, when transcripts are being saved.
    func markLastEdited(_ text: String) {
        guard saveText else { return }
        try? db?.run("UPDATE dictations SET edited_text = ? WHERE id = (SELECT MAX(id) FROM dictations)", [text])
    }

    func addCorrection(before: String, after: String, bundle: String?) {
        guard let db else { return }
        // A fix made again moves to the front instead of being stored twice.
        try? db.run("DELETE FROM corrections WHERE before_text = ? AND after_text = ?", [before, after])
        try? db.run("INSERT INTO corrections (created_at, app_bundle, before_text, after_text) VALUES (?, ?, ?, ?)",
                    [Date().timeIntervalSince1970, bundle, before, after])
    }

    /// The latest learned fixes, those made in the same kind of app first.
    func recentCorrections(for kind: AppKind, limit: Int = 6) -> [(before: String, after: String)] {
        let rows = (try? db?.query("SELECT before_text, after_text, app_bundle FROM corrections ORDER BY created_at DESC LIMIT 50") { s in
            (before: Database.text(s, 0) ?? "", after: Database.text(s, 1) ?? "", kind: AppKind(bundle: Database.text(s, 2)))
        }) ?? []
        let sameKind = rows.filter { $0.kind == kind }, others = rows.filter { $0.kind != kind }
        return (sameKind + others).prefix(limit).map { ($0.before, $0.after) }
    }

    func deleteAll() {
        try? db?.run("DELETE FROM dictations")
        try? db?.run("DELETE FROM corrections")
        reload()
    }
}
