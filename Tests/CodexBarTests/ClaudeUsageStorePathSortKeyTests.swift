import Foundation
import Testing
@testable import CodexBarCore

/// The cross-file tie-break must have exactly one ordering authority.
///
/// Swift's `String <` is canonical-equivalence aware while SQLite's BINARY collation is byte-wise,
/// and APFS stores filenames decomposed — so ordering on `path` in SQL and on `path` in Swift can
/// disagree. Every row therefore carries a sort key whose byte order reproduces Swift's ordering.
struct ClaudeUsageStorePathSortKeyTests {
    private static func byteLess(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        for (a, b) in zip(lhs, rhs) where a != b {
            return a < b
        }
        return lhs.count < rhs.count
    }

    @Test
    func `sort key byte order matches swift string order for decomposed paths`() {
        // APFS stores this decomposed; Swift ranks it after "cafz", SQLite BINARY ranks it before.
        let pairs: [(String, String)] = [
            ("/p/cafe\u{0301}/a.jsonl", "/p/cafz/a.jsonl"),
            ("/p/caf\u{00E9}/a.jsonl", "/p/cafz/a.jsonl"),
            ("/p/\u{0439}/a.jsonl", "/p/z/a.jsonl"),
            ("/p/a/a.jsonl", "/p/b/a.jsonl"),
            ("/p/a/a.jsonl", "/p/a/a.jsonl"),
            ("/p/a/a.jsonl", "/p/a/a.jsonl.bak"),
        ]
        for (lhs, rhs) in pairs {
            let keyLess = Self.byteLess(
                ClaudeUsageStorePathSortKey.make(lhs),
                ClaudeUsageStorePathSortKey.make(rhs))
            #expect(keyLess == (lhs < rhs), "\(lhs) vs \(rhs)")
        }
    }

    /// Swift treats the two spellings as the same string, so their keys must be identical or the
    /// view would rank two spellings of one path differently from the scanner.
    @Test
    func `canonically equivalent paths produce identical sort keys`() {
        let nfc = "/p/caf\u{00E9}/a.jsonl"
        let nfd = "/p/cafe\u{0301}/a.jsonl"
        #expect(nfc == nfd, "precondition: Swift considers these equal")
        #expect(ClaudeUsageStorePathSortKey.make(nfc) == ClaudeUsageStorePathSortKey.make(nfd))
    }
}
