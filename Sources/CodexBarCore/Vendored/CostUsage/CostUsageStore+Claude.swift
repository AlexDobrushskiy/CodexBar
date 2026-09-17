import Foundation

#if canImport(CSQLite3)
import CSQLite3
#else
import SQLite3
#endif

// MARK: - Claude usage store (schema v4)

extension CostUsageStore {
    /// Inserts or updates one tracked transcript and returns its row id.
    ///
    /// The sort key is derived here rather than by the caller so there is a single ordering
    /// authority for the cross-file tie-break; see `ClaudeUsageStorePathSortKey`.
    func upsertClaudeSourceFile(_ file: ClaudeStoreSourceFile) -> Int64? {
        self.withDatabase(default: nil) { database in
            let statement = try Self.prepare(database, """
            INSERT INTO claude_source_files(
                path, path_sort_key, file_identity, size, mtime_ms, parsed_offset,
                coverage_since_day, coverage_until_day, parser_revision, tz_identity, complete)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                path_sort_key = excluded.path_sort_key,
                file_identity = excluded.file_identity,
                size = excluded.size,
                mtime_ms = excluded.mtime_ms,
                parsed_offset = excluded.parsed_offset,
                coverage_since_day = excluded.coverage_since_day,
                coverage_until_day = excluded.coverage_until_day,
                parser_revision = excluded.parser_revision,
                tz_identity = excluded.tz_identity,
                complete = excluded.complete
            """)
            defer { sqlite3_finalize(statement) }
            Self.bind(file.path, to: statement, at: 1)
            Self.bind(Data(ClaudeUsageStorePathSortKey.make(file.path)), to: statement, at: 2)
            Self.bind(file.fileIdentity, to: statement, at: 3)
            Self.bind(file.size, to: statement, at: 4)
            Self.bind(file.mtimeMs, to: statement, at: 5)
            Self.bind(file.parsedOffset, to: statement, at: 6)
            Self.bind(file.coverageSinceDay, to: statement, at: 7)
            Self.bind(file.coverageUntilDay, to: statement, at: 8)
            Self.bind(Int64(file.parserRevision), to: statement, at: 9)
            Self.bind(file.tzIdentity, to: statement, at: 10)
            Self.bind(file.complete ? Int64(1) : Int64(0), to: statement, at: 11)
            try Self.stepDone(statement, database: database)
            return try Self.claudeSourceFileID(database, path: file.path)
        }
    }

    func readClaudeSourceFiles() -> [ClaudeStoreSourceFile] {
        self.withDatabase(default: []) { database in
            let statement = try Self.prepare(database, """
            SELECT path, file_identity, size, mtime_ms, parsed_offset,
                   coverage_since_day, coverage_until_day, parser_revision, tz_identity, complete
            FROM claude_source_files
            ORDER BY path_sort_key
            """)
            defer { sqlite3_finalize(statement) }
            var files: [ClaudeStoreSourceFile] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                files.append(ClaudeStoreSourceFile(
                    path: Self.columnText(statement, at: 0) ?? "",
                    fileIdentity: Self.columnText(statement, at: 1),
                    size: sqlite3_column_int64(statement, 2),
                    mtimeMs: sqlite3_column_int64(statement, 3),
                    parsedOffset: sqlite3_column_int64(statement, 4),
                    coverageSinceDay: Self.columnText(statement, at: 5),
                    coverageUntilDay: Self.columnText(statement, at: 6),
                    parserRevision: Int(sqlite3_column_int64(statement, 7)),
                    tzIdentity: Self.columnText(statement, at: 8) ?? "",
                    complete: sqlite3_column_int64(statement, 9) != 0))
            }
            return files
        }
    }

    private static func claudeSourceFileID(_ database: OpaquePointer, path: String) throws -> Int64? {
        let statement = try Self.prepare(database, "SELECT id FROM claude_source_files WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        Self.bind(path, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }
}
