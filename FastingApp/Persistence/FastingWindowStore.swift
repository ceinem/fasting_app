import Foundation
import SQLite3

protocol FastingWindowStoreProtocol: AnyObject {
    func fetchWindows(in interval: DateInterval) async throws -> [FastingWindow]
    func fetchActiveWindow(at date: Date) async throws -> FastingWindow?
    func save(window: FastingWindow, note: String?, source: FastingWindowSource) async throws
    func deleteWindow(id: UUID) async throws
    func fetchRegimens() async throws -> [FastingRegimen]
    func fetchActiveRegimen() async throws -> FastingRegimen?
    func save(regimen: FastingRegimen) async throws
    func deleteRegimen(id: UUID) async throws
    func setActiveRegimen(id: UUID?) async throws
    func fetchWindow(id: UUID) async throws -> FastingWindow?
    func fetchMostRecentWindow(before date: Date, type: FastingWindow.WindowType?) async throws -> FastingWindow?
    func fetchNextWindow(after date: Date, type: FastingWindow.WindowType?) async throws -> FastingWindow?
    func exportDatabaseData() async throws -> Data
    func importDatabase(from url: URL) async throws
    func resetDatabase() async throws
}

enum FastingDatabaseError: LocalizedError {
    case openDatabase(message: String)
    case execution(message: String)
    case statementPreparation(message: String)
    case binding(message: String)
    case step(message: String)

    var errorDescription: String? {
        switch self {
        case .openDatabase(let message),
             .execution(let message),
             .statementPreparation(let message),
             .binding(let message),
             .step(let message):
            return message
        }
    }
}

enum FastingWindowSource: String {
    case user
    case system
}

actor FastingWindowStore: FastingWindowStoreProtocol {
    static let shared: FastingWindowStore = {
        do {
            return try FastingWindowStore()
        } catch {
            fatalError("Failed to bootstrap fasting database: \(error)")
        }
    }()

    private var db: OpaquePointer
    private let fileURL: URL
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func openConnection(at url: URL) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let path = url.path(percentEncoded: false)
        if sqlite3_open(path, &connection) != SQLITE_OK {
            let message = errorMessage(for: connection)
            defer { if connection != nil { sqlite3_close(connection) } }
            throw FastingDatabaseError.openDatabase(message: message)
        }
        guard let connection else {
            throw FastingDatabaseError.openDatabase(message: "Unable to obtain SQLite connection.")
        }
        do {
            try configure(connection: connection)
            try migrate(connection: connection)
            try ensureDefaultRegimen(on: connection)
        } catch {
            sqlite3_close(connection)
            throw error
        }
        return connection
    }

    private static func execute(_ sql: String, on connection: OpaquePointer) throws {
        if sqlite3_exec(connection, sql, nil, nil, nil) != SQLITE_OK {
            throw FastingDatabaseError.execution(message: errorMessage(for: connection))
        }
    }

    private static func prepare(sql: String, on connection: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(connection, sql, -1, &statement, nil) != SQLITE_OK {
            throw FastingDatabaseError.statementPreparation(message: errorMessage(for: connection))
        }
        guard let statement else {
            throw FastingDatabaseError.statementPreparation(message: "Failed to prepare statement.")
        }
        return statement
    }

    private static func configure(connection: OpaquePointer) throws {
        try execute("PRAGMA foreign_keys = ON;", on: connection)
        try execute("PRAGMA journal_mode = WAL;", on: connection)
    }

    private static func migrate(connection: OpaquePointer) throws {
        let createWindowsSQL = """
        CREATE TABLE IF NOT EXISTS fasting_windows (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL CHECK (type IN ('fast','eat')),
            start_date REAL NOT NULL,
            end_date REAL NOT NULL,
            note TEXT,
            source TEXT NOT NULL DEFAULT 'user',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        try execute(createWindowsSQL, on: connection)
        try execute("CREATE INDEX IF NOT EXISTS idx_fasting_windows_start ON fasting_windows(start_date);", on: connection)

        let createRegimensSQL = """
        CREATE TABLE IF NOT EXISTS fasting_regimens (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            fast_duration REAL NOT NULL,
            feed_duration REAL NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        try execute(createRegimensSQL, on: connection)
        try execute("CREATE INDEX IF NOT EXISTS idx_fasting_regimens_created ON fasting_regimens(created_at);", on: connection)
    }

    private static func ensureDefaultRegimen(on connection: OpaquePointer) throws {
        let countStatement = try prepare(sql: "SELECT COUNT(*) FROM fasting_regimens;", on: connection)
        defer { sqlite3_finalize(countStatement) }
        var needsDefault = false
        if sqlite3_step(countStatement) == SQLITE_ROW {
            needsDefault = sqlite3_column_int64(countStatement, 0) == 0
        }

        if needsDefault {
            let now = Date().timeIntervalSince1970
            let defaultRegimen = FastingRegimen(name: "Standard 16 · 8",
                                                fastDuration: 16 * 3600,
                                                feedDuration: 8 * 3600,
                                                isActive: true,
                                                createdAt: Date(timeIntervalSince1970: now),
                                                updatedAt: Date(timeIntervalSince1970: now))
            let insertSQL = """
            INSERT OR REPLACE INTO fasting_regimens
                (id, name, fast_duration, feed_duration, is_active, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, 1, ?, ?);
            """
            let insertStatement = try prepare(sql: insertSQL, on: connection)
            defer { sqlite3_finalize(insertStatement) }
            if sqlite3_bind_text(insertStatement, 1, defaultRegimen.id.uuidString, -1, sqliteTransient) != SQLITE_OK {
                throw FastingDatabaseError.binding(message: errorMessage(for: connection))
            }
            if sqlite3_bind_text(insertStatement, 2, defaultRegimen.name, -1, sqliteTransient) != SQLITE_OK {
                throw FastingDatabaseError.binding(message: errorMessage(for: connection))
            }
            if sqlite3_bind_double(insertStatement, 3, defaultRegimen.fastDuration) != SQLITE_OK {
                throw FastingDatabaseError.binding(message: errorMessage(for: connection))
            }
            if sqlite3_bind_double(insertStatement, 4, defaultRegimen.feedDuration) != SQLITE_OK {
                throw FastingDatabaseError.binding(message: errorMessage(for: connection))
            }
            if sqlite3_bind_double(insertStatement, 5, now) != SQLITE_OK {
                throw FastingDatabaseError.binding(message: errorMessage(for: connection))
            }
            if sqlite3_bind_double(insertStatement, 6, now) != SQLITE_OK {
                throw FastingDatabaseError.binding(message: errorMessage(for: connection))
            }
            if sqlite3_step(insertStatement) != SQLITE_DONE {
                throw FastingDatabaseError.step(message: errorMessage(for: connection))
            }
        }

        let activeStatement = try prepare(sql: "SELECT COUNT(*) FROM fasting_regimens WHERE is_active = 1;", on: connection)
        defer { sqlite3_finalize(activeStatement) }
        var hasActive = false
        if sqlite3_step(activeStatement) == SQLITE_ROW {
            hasActive = sqlite3_column_int64(activeStatement, 0) > 0
        }

        if !hasActive {
            let updateSQL = """
            UPDATE fasting_regimens
            SET is_active = 1, updated_at = ?
            WHERE id = (
                SELECT id FROM fasting_regimens ORDER BY created_at ASC LIMIT 1
            );
            """
            let updateStatement = try prepare(sql: updateSQL, on: connection)
            defer { sqlite3_finalize(updateStatement) }
            if sqlite3_bind_double(updateStatement, 1, Date().timeIntervalSince1970) != SQLITE_OK {
                throw FastingDatabaseError.binding(message: errorMessage(for: connection))
            }
            if sqlite3_step(updateStatement) != SQLITE_DONE {
                throw FastingDatabaseError.step(message: errorMessage(for: connection))
            }
        }
    }

    init(fileManager: FileManager = .default) throws {
        self.fileURL = try Self.databaseURL(fileManager: fileManager)
        db = try Self.openConnection(at: fileURL)
    }

    deinit {
        sqlite3_close(db)
    }

    func fetchWindows(in interval: DateInterval) async throws -> [FastingWindow] {
        let sql = """
        SELECT id, type, start_date, end_date
        FROM fasting_windows
        WHERE start_date < ? AND end_date > ?
        ORDER BY start_date ASC;
        """
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bindDouble(interval.end.timeIntervalSince1970, to: 1, in: statement)
        try bindDouble(interval.start.timeIntervalSince1970, to: 2, in: statement)

        var windows: [FastingWindow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                windows.append(try window(from: statement))
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                throw FastingDatabaseError.step(message: currentErrorMessage())
            }
        }
        return windows
    }

    func fetchActiveWindow(at date: Date) async throws -> FastingWindow? {
        let sql = """
        SELECT id, type, start_date, end_date
        FROM fasting_windows
        WHERE start_date <= ? AND end_date > ?
        ORDER BY start_date DESC
        LIMIT 1;
        """
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        let timestamp = date.timeIntervalSince1970
        try bindDouble(timestamp, to: 1, in: statement)
        try bindDouble(timestamp, to: 2, in: statement)

        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_ROW {
            return try window(from: statement)
        } else if stepResult == SQLITE_DONE {
            return nil
        } else {
            throw FastingDatabaseError.step(message: currentErrorMessage())
        }
    }

    func save(window: FastingWindow,
              note: String? = nil,
              source: FastingWindowSource = .user) async throws {
        let sql = """
        INSERT INTO fasting_windows
            (id, type, start_date, end_date, note, source, created_at, updated_at)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            type = excluded.type,
            start_date = excluded.start_date,
            end_date = excluded.end_date,
            note = excluded.note,
            source = excluded.source,
            updated_at = excluded.updated_at;
        """
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        let now = Date().timeIntervalSince1970
        let createdAt = window.startDate.timeIntervalSince1970

        try bindText(window.id.uuidString, to: 1, in: statement)
        try bindText(window.type.rawValue, to: 2, in: statement)
        try bindDouble(window.startDate.timeIntervalSince1970, to: 3, in: statement)
        try bindDouble(window.endDate.timeIntervalSince1970, to: 4, in: statement)
        if let note {
            try bindText(note, to: 5, in: statement)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        try bindText(source.rawValue, to: 6, in: statement)
        try bindDouble(createdAt, to: 7, in: statement)
        try bindDouble(now, to: 8, in: statement)

        try step(statement)
    }

    func deleteWindow(id: UUID) async throws {
        let sql = "DELETE FROM fasting_windows WHERE id = ?;"
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bindText(id.uuidString, to: 1, in: statement)
        try step(statement)
    }

    func fetchWindow(id: UUID) async throws -> FastingWindow? {
        let sql = """
        SELECT id, type, start_date, end_date
        FROM fasting_windows
        WHERE id = ?
        LIMIT 1;
        """
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bindText(id.uuidString, to: 1, in: statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return try window(from: statement)
        } else if result == SQLITE_DONE {
            return nil
        } else {
            throw FastingDatabaseError.step(message: currentErrorMessage())
        }
    }

    func fetchMostRecentWindow(before date: Date, type: FastingWindow.WindowType? = nil) async throws -> FastingWindow? {
        var sql = """
        SELECT id, type, start_date, end_date
        FROM fasting_windows
        WHERE start_date <= ?
        """
        if type != nil {
            sql.append(" AND type = ?")
        }
        sql.append(" ORDER BY start_date DESC LIMIT 1;")

        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bindDouble(date.timeIntervalSince1970, to: 1, in: statement)
        if let type {
            try bindText(type.rawValue, to: 2, in: statement)
        }

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return try window(from: statement)
        } else if result == SQLITE_DONE {
            return nil
        } else {
            throw FastingDatabaseError.step(message: currentErrorMessage())
        }
    }

    func fetchNextWindow(after date: Date, type: FastingWindow.WindowType? = nil) async throws -> FastingWindow? {
        var sql = """
        SELECT id, type, start_date, end_date
        FROM fasting_windows
        WHERE start_date >= ?
        """
        if type != nil {
            sql.append(" AND type = ?")
        }
        sql.append(" ORDER BY start_date ASC LIMIT 1;")

        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bindDouble(date.timeIntervalSince1970, to: 1, in: statement)
        if let type {
            try bindText(type.rawValue, to: 2, in: statement)
        }

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return try window(from: statement)
        } else if result == SQLITE_DONE {
            return nil
        } else {
            throw FastingDatabaseError.step(message: currentErrorMessage())
        }
    }

    func exportDatabaseData() async throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fasting-export-\(UUID().uuidString).sqlite")
        try backupDatabase(to: tempURL)
        let data = try Data(contentsOf: tempURL)
        try deleteIfExists(at: tempURL)
        try deleteIfExists(at: auxiliaryURL(for: tempURL, suffix: "-wal"))
        try deleteIfExists(at: auxiliaryURL(for: tempURL, suffix: "-shm"))
        return data
    }

    func importDatabase(from url: URL) async throws {
        try reopenDatabase(replacingWith: url)
    }

    func resetDatabase() async throws {
        try reopenDatabase(replacingWith: nil)
    }

    func fetchRegimens() async throws -> [FastingRegimen] {
        let sql = """
        SELECT id, name, fast_duration, feed_duration, is_active, created_at, updated_at
        FROM fasting_regimens
        ORDER BY created_at ASC;
        """
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        var regimens: [FastingRegimen] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                regimens.append(try regimen(from: statement))
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                throw FastingDatabaseError.step(message: currentErrorMessage())
            }
        }

        if regimens.isEmpty {
            try ensureDefaultRegimen()
            return try await fetchRegimens()
        }

        return regimens
    }

    func fetchActiveRegimen() async throws -> FastingRegimen? {
        let sql = """
        SELECT id, name, fast_duration, feed_duration, is_active, created_at, updated_at
        FROM fasting_regimens
        WHERE is_active = 1
        ORDER BY updated_at DESC
        LIMIT 1;
        """
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return try regimen(from: statement)
        } else if result != SQLITE_DONE {
            throw FastingDatabaseError.step(message: currentErrorMessage())
        }

        let regimens = try await fetchRegimens()
        guard let first = regimens.first else {
            return nil
        }
        try await setActiveRegimen(id: first.id)
        return first
    }

    func save(regimen: FastingRegimen) async throws {
        let sql = """
        INSERT INTO fasting_regimens
            (id, name, fast_duration, feed_duration, is_active, created_at, updated_at)
        VALUES
            (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            fast_duration = excluded.fast_duration,
            feed_duration = excluded.feed_duration,
            is_active = excluded.is_active,
            updated_at = excluded.updated_at;
        """
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }

        try bindText(regimen.id.uuidString, to: 1, in: statement)
        try bindText(regimen.name, to: 2, in: statement)
        try bindDouble(regimen.fastDuration, to: 3, in: statement)
        try bindDouble(regimen.feedDuration, to: 4, in: statement)
        try bindInt(regimen.isActive ? 1 : 0, to: 5, in: statement)
        try bindDouble(regimen.createdAt.timeIntervalSince1970, to: 6, in: statement)
        try bindDouble(regimen.updatedAt.timeIntervalSince1970, to: 7, in: statement)

        try step(statement)

        if regimen.isActive {
            try await setActiveRegimen(id: regimen.id)
        }
    }

    func deleteRegimen(id: UUID) async throws {
        let active = try await fetchActiveRegimen()
        let sql = "DELETE FROM fasting_regimens WHERE id = ?;"
        let statement = try prepare(sql: sql)
        defer { sqlite3_finalize(statement) }
        try bindText(id.uuidString, to: 1, in: statement)
        try step(statement)

        var remaining = try await fetchRegimens()
        if remaining.isEmpty {
            try ensureDefaultRegimen()
            remaining = try await fetchRegimens()
        }

        if let active, active.id == id {
            let next = remaining.first(where: { $0.id != id }) ?? remaining.first
            try await setActiveRegimen(id: next?.id)
        }
    }

    func setActiveRegimen(id: UUID?) async throws {
        try execute("BEGIN TRANSACTION;")
        do {
            try execute("UPDATE fasting_regimens SET is_active = 0;")
            if let id {
                let sql = "UPDATE fasting_regimens SET is_active = 1, updated_at = ? WHERE id = ?;"
                let statement = try prepare(sql: sql)
                defer { sqlite3_finalize(statement) }
                try bindDouble(Date().timeIntervalSince1970, to: 1, in: statement)
                try bindText(id.uuidString, to: 2, in: statement)
                try step(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Private helpers
    private func execute(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw FastingDatabaseError.execution(message: currentErrorMessage())
        }
    }

    private func prepare(sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw FastingDatabaseError.statementPreparation(message: currentErrorMessage())
        }
        guard let statement else {
            throw FastingDatabaseError.statementPreparation(message: "Failed to prepare statement.")
        }
        return statement
    }

    private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        if sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) != SQLITE_OK {
            throw FastingDatabaseError.binding(message: currentErrorMessage())
        }
    }

    private func bindDouble(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        if sqlite3_bind_double(statement, index, value) != SQLITE_OK {
            throw FastingDatabaseError.binding(message: currentErrorMessage())
        }
    }

    private func bindInt(_ value: Int, to index: Int32, in statement: OpaquePointer) throws {
        if sqlite3_bind_int(statement, index, Int32(value)) != SQLITE_OK {
            throw FastingDatabaseError.binding(message: currentErrorMessage())
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw FastingDatabaseError.step(message: currentErrorMessage())
        }
    }

    private func reopenDatabase(replacingWith sourceURL: URL?) throws {
        try closeConnection()
        if let sourceURL {
            if sourceURL.standardizedFileURL == fileURL.standardizedFileURL {
                throw FastingDatabaseError.execution(message: "Source database matches destination path.")
            }
            try removeDatabaseFiles()
            try FileManager.default.copyItem(at: sourceURL, to: fileURL)
        } else {
            try removeDatabaseFiles()
        }
        db = try Self.openConnection(at: fileURL)
    }

    private func backupDatabase(to destinationURL: URL) throws {
        try deleteIfExists(at: destinationURL)
        try deleteIfExists(at: auxiliaryURL(for: destinationURL, suffix: "-wal"))
        try deleteIfExists(at: auxiliaryURL(for: destinationURL, suffix: "-shm"))

        var destination: OpaquePointer?
        let path = destinationURL.path(percentEncoded: false)
        if sqlite3_open(path, &destination) != SQLITE_OK {
            let message = Self.errorMessage(for: destination)
            defer { if destination != nil { sqlite3_close(destination) } }
            throw FastingDatabaseError.openDatabase(message: message)
        }
        guard let destination else {
            throw FastingDatabaseError.openDatabase(message: "Unable to open backup destination.")
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else {
            throw FastingDatabaseError.execution(message: Self.errorMessage(for: destination))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        if stepResult != SQLITE_DONE || finishResult != SQLITE_OK {
            throw FastingDatabaseError.execution(message: Self.errorMessage(for: destination))
        }
    }

    private func closeConnection() throws {
        let result = sqlite3_close(db)
        if result != SQLITE_OK {
            throw FastingDatabaseError.execution(message: Self.errorMessage(for: db))
        }
    }

    private func removeDatabaseFiles() throws {
        try deleteIfExists(at: fileURL)
        try deleteIfExists(at: auxiliaryURL(for: fileURL, suffix: "-wal"))
        try deleteIfExists(at: auxiliaryURL(for: fileURL, suffix: "-shm"))
    }

    private func deleteIfExists(at url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    private func auxiliaryURL(for baseURL: URL, suffix: String) -> URL {
        URL(fileURLWithPath: baseURL.path + suffix)
    }

    private func regimen(from statement: OpaquePointer) throws -> FastingRegimen {
        guard
            let idCString = sqlite3_column_text(statement, 0),
            let nameCString = sqlite3_column_text(statement, 1)
        else {
            throw FastingDatabaseError.execution(message: "Unexpected NULL while decoding fasting regimen.")
        }

        let idString = String(cString: idCString)
        guard let uuid = UUID(uuidString: idString) else {
            throw FastingDatabaseError.execution(message: "Invalid regimen UUID stored in database.")
        }

        let name = String(cString: nameCString)
        let fastDuration = sqlite3_column_double(statement, 2)
        let feedDuration = sqlite3_column_double(statement, 3)
        let isActive = sqlite3_column_int(statement, 4) == 1
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))

        return FastingRegimen(id: uuid,
                              name: name,
                              fastDuration: fastDuration,
                              feedDuration: feedDuration,
                              isActive: isActive,
                              createdAt: createdAt,
                              updatedAt: updatedAt)
    }

    private func window(from statement: OpaquePointer) throws -> FastingWindow {
        guard
            let idCString = sqlite3_column_text(statement, 0),
            let typeCString = sqlite3_column_text(statement, 1)
        else {
            throw FastingDatabaseError.execution(message: "Unexpected NULL while decoding fasting window.")
        }

        let idString = String(cString: idCString)
        guard let uuid = UUID(uuidString: idString) else {
            throw FastingDatabaseError.execution(message: "Invalid UUID stored in database.")
        }

        let typeString = String(cString: typeCString)
        guard let type = FastingWindow.WindowType(rawValue: typeString) else {
            throw FastingDatabaseError.execution(message: "Invalid window type stored in database.")
        }

        let startTimestamp = sqlite3_column_double(statement, 2)
        let endTimestamp = sqlite3_column_double(statement, 3)

        let startDate = Date(timeIntervalSince1970: startTimestamp)
        let endDate = Date(timeIntervalSince1970: endTimestamp)

        return FastingWindow(id: uuid, type: type, startDate: startDate, endDate: endDate)
    }

    private func ensureDefaultRegimen() throws {
        try Self.ensureDefaultRegimen(on: db)
    }

    private func currentErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else {
            return "Unknown SQLite error."
        }
        return String(cString: cString)
    }

    private static func errorMessage(for pointer: OpaquePointer?) -> String {
        guard let pointer, let cString = sqlite3_errmsg(pointer) else {
            return "Unknown SQLite error."
        }
        return String(cString: cString)
    }

    private static func databaseURL(fileManager: FileManager) throws -> URL {
        let baseDirectory = try fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        let directory = baseDirectory.appendingPathComponent("FastingAppData", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("fasting.sqlite", conformingTo: .data)
    }
}

extension FastingWindowStoreProtocol {
    func save(window: FastingWindow, source: FastingWindowSource = .user) async throws {
        try await save(window: window, note: nil, source: source)
    }
}
