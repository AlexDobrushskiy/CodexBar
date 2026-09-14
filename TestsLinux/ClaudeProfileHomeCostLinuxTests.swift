import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Claude profile homes (`providers[].claudeProfileHomePaths`) are extra `CLAUDE_CONFIG_DIR` roots that the
/// local cost scan reports as separate ledgers. These tests pin the config round-trip, path validation, and
/// the scanner isolation between the ambient root and a profile root.
struct ClaudeProfileHomeCostLinuxTests {
    private struct Environment {
        let root: URL
        let cacheRoot: URL
        let ambientProjectsRoot: URL
        let profileHome: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-claude-profile-\(UUID().uuidString)", isDirectory: true)
            self.cacheRoot = self.root.appendingPathComponent("cache", isDirectory: true)
            self.ambientProjectsRoot = self.root.appendingPathComponent("ambient/projects", isDirectory: true)
            self.profileHome = self.root.appendingPathComponent("claude-work", isDirectory: true)
            for url in [self.cacheRoot, self.ambientProjectsRoot, self.profileHome.appendingPathComponent("projects")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }

        func writeTranscript(projectsRoot: URL, name: String, at date: Date, inputTokens: Int) throws {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line: [String: Any] = [
                "type": "assistant",
                "timestamp": formatter.string(from: date),
                "sessionId": "session-\(name)",
                "requestId": "request-\(name)",
                "message": [
                    "id": "message-\(name)",
                    "model": "claude-sonnet-4-20250514",
                    "usage": [
                        "input_tokens": inputTokens,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 2,
                    ],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: line)
            let directory = projectsRoot.appendingPathComponent("-Users-test-project", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let json = try #require(String(bytes: data, encoding: .utf8))
            try (json + "\n")
                .write(to: directory.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
        }
    }

    @Test
    func `claudeProfileHomePaths round-trips through provider config JSON`() throws {
        var config = ProviderConfig(id: UsageProvider.claude.instanceID, enabled: true)
        config.claudeProfileHomePaths = ["~/.claude-work", "/tmp/claude-other"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)

        #expect(decoded.claudeProfileHomePaths == ["~/.claude-work", "/tmp/claude-other"])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["claudeProfileHomePaths"] as? [String] == ["~/.claude-work", "/tmp/claude-other"])
    }

    @Test
    func `normalized profile paths accept absolute and tilde roots and drop the rest`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let paths = ClaudeProfileHomes.normalizedHomePaths([
            "~/.claude-work",
            "/tmp/claude-other/",
            "relative-home",
            "~someone/.claude",
            "  ",
            "~/.claude-work",
        ])

        #expect(paths == ["\(home)/.claude-work", "/tmp/claude-other"])
    }

    @Test
    func `resolve skips the ambient root and homes without a projects directory`() throws {
        let env = try Environment()
        defer { env.cleanup() }
        let ambientRoot = env.root.appendingPathComponent("ambient", isDirectory: true)
        let emptyHome = env.root.appendingPathComponent("claude-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)

        let resolved = ClaudeProfileHomes.resolve(
            paths: [ambientRoot.path, env.profileHome.path, emptyHome.path, "/definitely/missing"],
            environment: ["CLAUDE_CONFIG_DIR": ambientRoot.path],
            homeDirectory: env.root)

        #expect(resolved.map(\.path) == [env.profileHome.standardizedFileURL.path])
        #expect(resolved.first?.displayLabel == "~/claude-work")
        #expect(resolved.first?.projectsRoot.lastPathComponent == "projects")
        #expect(resolved.first?.cacheIdentity.count == 64)
    }

    @Test
    func `scoped environment sets CLAUDE_CONFIG_DIR only for a profile`() {
        #expect(ClaudeProfileHomes.scopedEnvironment(base: ["HOME": "/h"], configRoot: nil) == ["HOME": "/h"])
        #expect(ClaudeProfileHomes.scopedEnvironment(base: ["HOME": "/h"], configRoot: "/h/.claude-work")
            == ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/h/.claude-work"])
    }

    @Test
    func `fetcher scopes claude history to the requested profile home`() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        let now = Date()
        try env.writeTranscript(projectsRoot: env.ambientProjectsRoot, name: "ambient", at: now, inputTokens: 100)
        try env.writeTranscript(
            projectsRoot: env.profileHome.appendingPathComponent("projects", isDirectory: true),
            name: "profile",
            at: now,
            inputTokens: 10)
        let profile = ClaudeProfileHome(path: env.profileHome.standardizedFileURL.path, homeDirectory: env.root)

        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: now,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: CostUsageScanner.Options(
                claudeProjectsRoots: [env.ambientProjectsRoot],
                cacheRoot: env.cacheRoot))
        let scoped = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: now,
            claudeConfigRoot: profile.path,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: CostUsageScanner.Options(
                claudeProjectsRoots: [env.ambientProjectsRoot],
                cacheRoot: ClaudeProfileHomes.cacheRoot(for: profile, baseCacheRoot: env.cacheRoot)))

        #expect(ambient.sessionTokens == 102)
        #expect(scoped.sessionTokens == 12)
        #expect(ClaudeProfileHomes.cacheRoot(for: profile, baseCacheRoot: env.cacheRoot).path
            .hasSuffix("cost-usage/claude-profiles/\(profile.cacheIdentity)"))
    }

    @Test
    func `cost payload and text carry the profile label`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 12,
            sessionCostUSD: 0.5,
            last30DaysTokens: 12,
            last30DaysCostUSD: 0.5,
            historyDays: 30,
            daily: [],
            updatedAt: Date())

        let payload = CodexBarCLI.makeCostPayload(
            provider: .claude,
            snapshot: snapshot,
            error: nil,
            profileHome: "~/.claude-work")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(json["provider"] as? String == "claude")
        #expect(json["profileHome"] as? String == "~/.claude-work")

        let ambient = CodexBarCLI.makeCostPayload(provider: .claude, snapshot: snapshot, error: nil)
        let ambientJSON = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ambient)) as? [String: Any])
        #expect(ambientJSON["profileHome"] == nil)

        let text = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: snapshot,
            useColor: false,
            profileLabel: "~/.claude-work")
        #expect(text.hasPrefix("Claude (~/.claude-work) Cost (API-rate estimate)"))
    }
}
