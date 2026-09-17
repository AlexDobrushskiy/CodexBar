import Foundation

/// Byte-comparable stand-in for Swift's `String` ordering of a transcript path.
///
/// The cross-file tie-break in `claudeRowWins` orders on `lhs.path < rhs.path`, and the SQL view
/// that reproduces that ranking must reach the same answer. It cannot order on `path` directly:
/// SQLite's BINARY collation compares UTF-8 bytes while Swift's `String <` is canonical-equivalence
/// aware, and APFS stores filenames decomposed — the two invert on a decomposed non-ASCII path.
/// Normalizing to NFC first makes byte order reproduce Swift's order, so the key is the one
/// ordering authority and `path` is never sorted on.
enum ClaudeUsageStorePathSortKey {
    /// NFC-normalized UTF-8 bytes of `path`.
    static func make(_ path: String) -> [UInt8] {
        Array(path.precomposedStringWithCanonicalMapping.utf8)
    }
}
