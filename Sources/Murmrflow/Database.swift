import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite library; enough for a handful of local tables.
final class Database {
    struct Failure: Error { let message: String }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure(message: "cannot open \(url.path)") }
        try run("PRAGMA journal_mode = WAL")
    }

    deinit { sqlite3_close(db) }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version") { Int(sqlite3_column_int64($0, 0)) }.first) ?? 0 }
        set { try? run("PRAGMA user_version = \(newValue)") }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    func run(_ sql: String, _ params: [Any?] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        // Some PRAGMAs answer with a row; that is still success for a statement run for its effect.
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
    }

    func query<T>(_ sql: String, _ params: [Any?] = [], row: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        sqlite3_column_text(stmt, col).map { String(cString: $0) }
    }
}
