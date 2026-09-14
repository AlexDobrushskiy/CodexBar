import CodexBarCore
import Foundation

/// Claude profile homes (`providers[].claudeProfileHomePaths`) as spend-dashboard sources. Each configured
/// CLAUDE_CONFIG_DIR root is scanned as its own ledger next to the provider-level Claude row.
extension SpendDashboardSource {
    /// Provider-specific by design: Claude profile homes are extra CLAUDE_CONFIG_DIR roots. Each becomes
    /// its own spend source; the ambient root stays the provider-level row.
    @MainActor
    static func claudeRequests(settings: SettingsStore, store: UsageStore) -> [ClaudeSpendScanRequest] {
        let providerName = store.metadata(for: .claude).displayName
        return ClaudeProfileHomes.resolve(paths: settings.claudeProfileHomePaths).map { home in
            ClaudeSpendScanRequest(home: home, displayName: "\(providerName) · \(home.displayLabel)")
        }
    }

    static func loadClaudeProfileSnapshot(
        _ profile: ClaudeSpendScanRequest,
        request: SpendDashboardLoadRequest,
        force: Bool) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher(
            cacheRoot: self.claudeProfileCacheRoot(for: profile),
            calendar: request.configuration.bucketCalendar)
            .loadTokenSnapshot(
                // Provider-specific by design: Claude profile homes scope the transcript scan by CLAUDE_CONFIG_DIR.
                provider: .claude,
                environment: ClaudeProfileHomes.scopedEnvironment(base: [:], configRoot: profile.home.path),
                now: request.now,
                forceRefresh: force,
                claudeConfigRoot: profile.home.path,
                historyDays: self.scanDays,
                refreshPricingInBackground: false,
                includePiSessions: false)
    }

    static func claudeProfileInput(
        _ profile: ClaudeSpendScanRequest,
        snapshot: CostUsageTokenSnapshot) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: profile.sourceID,
            // Provider-specific by design: profile rows keep Claude's provider identity and model pricing.
            provider: .claude,
            displayName: profile.displayName,
            modelProviderName: ProviderDescriptorRegistry.descriptor(for: .claude).metadata.displayName,
            snapshot: snapshot)
    }

    static func claudeProfileCacheRoot(for profile: ClaudeSpendScanRequest) -> URL {
        ClaudeProfileHomes.cacheRoot(
            for: profile.home,
            baseCacheRoot: UsageStore.costUsageCacheDirectory().deletingLastPathComponent())
    }
}
