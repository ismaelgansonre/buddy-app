import Foundation
import SQLite3

final class MemoryStore {

    static let shared = MemoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.buddy.memorystore", qos: .utility)

    private init() {
        openDatabase()
        createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let dirPath = NSString("~/.buddy").expandingTildeInPath
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: dirPath) {
            try? fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }

        let dbPath = (dirPath as NSString).appendingPathComponent("memory.db")

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[MemoryStore] Failed to open database at \(dbPath)")
            db = nil
        }
    }

    private func createTables() {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                user_message TEXT NOT NULL,
                buddy_response TEXT NOT NULL,
                context TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS screen_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                active_app TEXT NOT NULL,
                window_title TEXT NOT NULL,
                ai_summary TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS patterns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                pattern_type TEXT NOT NULL,
                data TEXT NOT NULL
            )
            """
        ]

        queue.sync {
            for sql in statements {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        print("[MemoryStore] Failed to create table: \(String(cString: sqlite3_errmsg(db!)))")
                    }
                }
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Save Methods

    func saveConversation(userMessage: String, buddyResponse: String, context: String? = nil) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let sql = "INSERT INTO conversations (timestamp, user_message, buddy_response, context) VALUES (?, ?, ?, ?)"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (userMessage as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (buddyResponse as NSString).utf8String, -1, nil)

            if let context = context {
                sqlite3_bind_text(stmt, 4, (context as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[MemoryStore] Failed to save conversation: \(String(cString: sqlite3_errmsg(db)))")
            }

            sqlite3_finalize(stmt)
        }
    }

    func saveScreenCapture(activeApp: String, windowTitle: String, aiSummary: String? = nil) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let sql = "INSERT INTO screen_history (timestamp, active_app, window_title, ai_summary) VALUES (?, ?, ?, ?)"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (activeApp as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (windowTitle as NSString).utf8String, -1, nil)

            if let aiSummary = aiSummary {
                sqlite3_bind_text(stmt, 4, (aiSummary as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[MemoryStore] Failed to save screen capture: \(String(cString: sqlite3_errmsg(db)))")
            }

            sqlite3_finalize(stmt)
        }
    }

    func savePattern(type: String, data: String) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let sql = "INSERT INTO patterns (timestamp, pattern_type, data) VALUES (?, ?, ?)"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (type as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (data as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[MemoryStore] Failed to save pattern: \(String(cString: sqlite3_errmsg(db)))")
            }

            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Query Methods

    func getRecentConversations(limit: Int = 20) -> [(timestamp: Date, userMessage: String, buddyResponse: String)] {
        var results: [(timestamp: Date, userMessage: String, buddyResponse: String)] = []

        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }

            let sql = "SELECT timestamp, user_message, buddy_response FROM conversations ORDER BY timestamp DESC LIMIT ?"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                let userMessage = String(cString: sqlite3_column_text(stmt, 1))
                let buddyResponse = String(cString: sqlite3_column_text(stmt, 2))
                results.append((timestamp: timestamp, userMessage: userMessage, buddyResponse: buddyResponse))
            }

            sqlite3_finalize(stmt)
        }

        return results
    }

    func getScreenHistory(since: Date) -> [(timestamp: Date, activeApp: String, windowTitle: String, summary: String)] {
        var results: [(timestamp: Date, activeApp: String, windowTitle: String, summary: String)] = []

        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }

            let sql = "SELECT timestamp, active_app, window_title, COALESCE(ai_summary, '') FROM screen_history WHERE timestamp >= ? ORDER BY timestamp DESC"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                let activeApp = String(cString: sqlite3_column_text(stmt, 1))
                let windowTitle = String(cString: sqlite3_column_text(stmt, 2))
                let summary = String(cString: sqlite3_column_text(stmt, 3))
                results.append((timestamp: timestamp, activeApp: activeApp, windowTitle: windowTitle, summary: summary))
            }

            sqlite3_finalize(stmt)
        }

        return results
    }

    func searchHistory(query: String) -> [(timestamp: Date, summary: String)] {
        var results: [(timestamp: Date, summary: String)] = []

        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }

            let sql = "SELECT timestamp, ai_summary FROM screen_history WHERE ai_summary LIKE ? ORDER BY timestamp DESC"
            var stmt: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            let pattern = "%\(query)%"
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                let summary = String(cString: sqlite3_column_text(stmt, 1))
                results.append((timestamp: timestamp, summary: summary))
            }

            sqlite3_finalize(stmt)
        }

        return results
    }

    // MARK: - Maintenance

    func cleanupOldData(retentionDays: Int) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970

            let tables = ["conversations", "screen_history", "patterns"]
            for table in tables {
                let sql = "DELETE FROM \(table) WHERE timestamp < ?"
                var stmt: OpaquePointer?

                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }

                sqlite3_bind_double(stmt, 1, cutoff)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    print("[MemoryStore] Failed to cleanup \(table): \(String(cString: sqlite3_errmsg(db)))")
                }

                sqlite3_finalize(stmt)
            }
        }
    }

    func deleteAllData() {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            let tables = ["conversations", "screen_history", "patterns"]
            for table in tables {
                let sql = "DELETE FROM \(table)"
                var stmt: OpaquePointer?

                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }

                if sqlite3_step(stmt) != SQLITE_DONE {
                    print("[MemoryStore] Failed to delete \(table): \(String(cString: sqlite3_errmsg(db)))")
                }

                sqlite3_finalize(stmt)
            }
        }
    }
}
