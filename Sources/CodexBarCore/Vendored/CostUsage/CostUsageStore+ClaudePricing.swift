import Foundation

#if canImport(CSQLite3)
import CSQLite3
#else
import SQLite3
#endif

// MARK: - Claude pricing catalog (schema v5)

extension CostUsageStore {
    /// Every `(model, backend)` pair the stored events actually use.
    ///
    /// The price table is seeded from this rather than from the whole catalog: a vault uses a
    /// handful of models, and models.dev carries thousands.
    func readClaudeEventModelKeys() -> [ClaudeStoreModelKey] {
        self.withDatabase(default: []) { database in
            let statement = try Self.prepare(database, """
            SELECT DISTINCT model, backend FROM claude_usage_events
            """)
            defer { sqlite3_finalize(statement) }
            var keys: [ClaudeStoreModelKey] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let model = Self.columnText(statement, at: 0),
                      let backend = Self.columnText(statement, at: 1)
                else { continue }
                keys.append(ClaudeStoreModelKey(model: model, backend: backend))
            }
            return keys
        }
    }

    /// Installs the whole price catalog in one transaction.
    ///
    /// Replace rather than merge: the rows are derived from the current pricing catalog, so a stale
    /// window left behind would keep being joined by `claude_event_costs` and silently outrank the
    /// new one for its date range.
    @discardableResult
    func replaceClaudeModelPrices(_ prices: [ClaudeStoreModelPrice]) -> Bool {
        self.withDatabase(default: false) { database in
            try Self.execute(database, "DELETE FROM claude_model_prices")
            let statement = try Self.prepare(database, """
            INSERT INTO claude_model_prices(
                model, backend, valid_from_ms, valid_to_ms,
                input_per_token, cache_read_per_token, cache_write_per_token, output_per_token,
                long_context_threshold, long_context_input_per_token,
                long_context_cache_read_per_token, long_context_cache_write_per_token,
                long_context_output_per_token)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
            defer { sqlite3_finalize(statement) }
            for price in prices {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                Self.bind(price.model, to: statement, at: 1)
                Self.bind(price.backend, to: statement, at: 2)
                Self.bind(price.validFromMs, to: statement, at: 3)
                Self.bind(price.validToMs, to: statement, at: 4)
                Self.bind(price.inputPerToken, to: statement, at: 5)
                Self.bind(price.cacheReadPerToken, to: statement, at: 6)
                Self.bind(price.cacheWritePerToken, to: statement, at: 7)
                Self.bind(price.outputPerToken, to: statement, at: 8)
                Self.bind(price.longContextThreshold, to: statement, at: 9)
                Self.bind(price.longContextInputPerToken, to: statement, at: 10)
                Self.bind(price.longContextCacheReadPerToken, to: statement, at: 11)
                Self.bind(price.longContextCacheWritePerToken, to: statement, at: 12)
                Self.bind(price.longContextOutputPerToken, to: statement, at: 13)
                try Self.stepDone(statement, database: database)
            }
            return true
        }
    }

    func readClaudeModelPrices() -> [ClaudeStoreModelPrice] {
        self.withDatabase(default: []) { database in
            let statement = try Self.prepare(database, """
            SELECT model, backend, valid_from_ms, valid_to_ms,
                   input_per_token, cache_read_per_token, cache_write_per_token, output_per_token,
                   long_context_threshold, long_context_input_per_token,
                   long_context_cache_read_per_token, long_context_cache_write_per_token,
                   long_context_output_per_token
            FROM claude_model_prices
            ORDER BY model, backend, valid_from_ms
            """)
            defer { sqlite3_finalize(statement) }
            var prices: [ClaudeStoreModelPrice] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                prices.append(ClaudeStoreModelPrice(
                    model: Self.columnText(statement, at: 0) ?? "",
                    backend: Self.columnText(statement, at: 1) ?? "",
                    validFromMs: sqlite3_column_int64(statement, 2),
                    validToMs: Self.columnInt64(statement, at: 3),
                    inputPerToken: sqlite3_column_double(statement, 4),
                    cacheReadPerToken: sqlite3_column_double(statement, 5),
                    cacheWritePerToken: sqlite3_column_double(statement, 6),
                    outputPerToken: sqlite3_column_double(statement, 7),
                    longContextThreshold: Self.columnInt64(statement, at: 8).map(Int.init),
                    longContextInputPerToken: Self.columnDouble(statement, at: 9),
                    longContextCacheReadPerToken: Self.columnDouble(statement, at: 10),
                    longContextCacheWritePerToken: Self.columnDouble(statement, at: 11),
                    longContextOutputPerToken: Self.columnDouble(statement, at: 12)))
            }
            return prices
        }
    }

    private static func columnDouble(_ statement: OpaquePointer, at index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }
}

// MARK: - Synchronous bridge for the scanner

extension CostUsageStore {
    nonisolated func syncReadClaudeEventModelKeys() -> [ClaudeStoreModelKey] {
        self.syncWithStoreIsolation { $0.readClaudeEventModelKeys() }
    }

    nonisolated func syncReplaceClaudeModelPrices(_ prices: [ClaudeStoreModelPrice]) -> Bool {
        self.syncWithStoreIsolation { $0.replaceClaudeModelPrices(prices) }
    }
}
