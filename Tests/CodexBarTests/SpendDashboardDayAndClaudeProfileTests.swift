import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Day-stepper selection and Claude profile-home rows on the shared spend dashboard controller.
@MainActor
@Suite(.serialized)
struct SpendDashboardDayAndClaudeProfileTests {
    @Test
    func `day stepping starts at today, widens the window and clears past today`() throws {
        let suite = "SpendDashboardControllerTests-day-stepper"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Calendar.current
        let now = Self.fixtureNow
        let today = calendar.startOfDay(for: now)
        let controller = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { mode in
                Self.request(force: mode.forcesLoader)
            },
            nowProvider: { now })
        controller.selectDays(7)

        #expect(controller.selectedDay == nil)
        controller.stepSelectedDay(by: -1)
        #expect(controller.selectedDay == calendar.date(byAdding: .day, value: -1, to: today))
        #expect(controller.selectedDays == 7)

        controller.stepSelectedDay(by: -9)
        #expect(controller.selectedDay == calendar.date(byAdding: .day, value: -10, to: today))
        #expect(controller.selectedDays == 30, "a day outside the 7-day window widens to 30")

        controller.selectToday()
        #expect(controller.selectedDay == today)
        controller.stepSelectedDay(by: 1)
        #expect(controller.selectedDay == nil, "stepping past today clears the filter")

        #expect(SpendDashboardController.smallestDayRange(containing: today, now: now, calendar: calendar) == 7)
        let future = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        #expect(SpendDashboardController.smallestDayRange(containing: future, now: now, calendar: calendar) == nil)
        let old = try #require(calendar.date(byAdding: .day, value: -100, to: today))
        #expect(SpendDashboardController.smallestDayRange(containing: old, now: now, calendar: calendar)
            == SpendDashboardSource.scanDays)
    }

    @Test
    func `forced refresh keeps Claude profile rows through the capture barrier`() async throws {
        let suite = "SpendDashboardControllerTests-claude-profile"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ClaudeSpendScanRequest(
            home: ClaudeProfileHome(path: "/synthetic/claude-work"),
            displayName: "Claude · ~/claude-work")
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.claude.rawValue],
            codexAccountIdentities: [])
        let ambient = Self.input(id: "claude", cost: 5)
        let profileInput = SpendDashboardModel.ProviderInput(
            id: profile.sourceID,
            provider: .claude,
            displayName: profile.displayName,
            snapshot: Self.input(id: "unused", cost: 7).snapshot)
        let controller = SpendDashboardController(
            userDefaults: defaults,
            requestBuilder: { mode in
                SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [ambient],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    claudeRequests: [profile],
                    now: Self.fixtureNow,
                    force: mode.forcesLoader)
            },
            loader: { request in
                SpendDashboardLoadResult(
                    inputs: request.capturedInputs + [profileInput],
                    failedSourceIDs: [])
            },
            nowProvider: { Self.fixtureNow })

        controller.update(configuration: configuration)
        await SpendDashboardControllerTests.waitUntil { !controller.isRefreshing }
        #expect(Set(controller.model.groups.flatMap(\.providers).map(\.id)) == ["claude", profile.sourceID])

        controller.refresh()
        await SpendDashboardControllerTests.waitUntil { !controller.isRefreshing }
        let rows = controller.model.groups.flatMap(\.providers)
        #expect(Set(rows.map(\.id)) == ["claude", profile.sourceID])
        #expect(rows.first { $0.id == profile.sourceID }?.displayName == "Claude · ~/claude-work")
        #expect(controller.publication.sources.contains {
            $0.id == profile.sourceID && $0.provider == .claude && $0.displayName == "Claude · ~/claude-work"
        })
    }

    private nonisolated static let fixtureNow = Date(timeIntervalSince1970: 1_784_179_200)

    private static func request(force: Bool) -> SpendDashboardLoadRequest {
        SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.claude.rawValue],
                codexAccountIdentities: []),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: self.fixtureNow,
            force: force)
    }

    private static func input(id: String, cost: Double) -> SpendDashboardModel.ProviderInput {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-07-15",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 10,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
        return SpendDashboardModel.ProviderInput(
            id: id,
            provider: .claude,
            displayName: "Claude",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 10,
                last30DaysCostUSD: cost,
                historyDays: 30,
                daily: [entry],
                updatedAt: Self.fixtureNow))
    }
}

extension SpendDashboardDayAndClaudeProfileTests {
    @Test
    func `selected day scopes totals, subscription rows and projects to that day only`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_784_222_400) // 2026-07-16 12:00:00 UTC
        let july15 = calendar.startOfDay(for: now.addingTimeInterval(-86400))
        func input(id: String, cost15: Double, cost16: Double) -> SpendDashboardModel.ProviderInput {
            SpendDashboardModel.ProviderInput(
                id: id,
                provider: .claude,
                displayName: id,
                snapshot: CostUsageTokenSnapshot(
                    sessionTokens: nil,
                    sessionCostUSD: nil,
                    last30DaysTokens: nil,
                    last30DaysCostUSD: nil,
                    historyDays: 7,
                    daily: [
                        Self.dailyEntry(day: "2026-07-15", cost: cost15, tokens: 100),
                        Self.dailyEntry(day: "2026-07-16", cost: cost16, tokens: 10),
                    ],
                    updatedAt: now))
        }
        let inputs = [input(id: "claude", cost15: 5, cost16: 1), input(id: "claude:profile:x", cost15: 2, cost16: 8)]

        let window = SpendDashboardModel.build(inputs: inputs, requestedDays: 7, now: now, calendar: calendar)
        let day = SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 7,
            now: now,
            calendar: calendar,
            selectedDay: july15)

        #expect(window.groups[0].totalCost == 16)
        #expect(day.groups[0].totalCost == 7)
        #expect(day.groups[0].totalTokens == 200)
        #expect(day.groups[0].providers.map { ($0.id, $0.totalCost) }.map(\.0) == ["claude", "claude:profile:x"])
        #expect(day.groups[0].providers.map(\.totalCost) == [5, 2])
        #expect(day.groups[0].coveredDayCount == 1)
        #expect(day.groups[0].selectedDay == july15)
        // The daily chart keeps the surrounding window for context.
        #expect(day.groups[0].dailyPoints.map(\.cost) == window.groups[0].dailyPoints.map(\.cost))
    }

    private static func dailyEntry(day: String, cost: Double, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }
}
