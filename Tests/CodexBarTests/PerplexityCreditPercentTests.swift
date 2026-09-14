import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PerplexityCreditPercentTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: [false, true])
    func `explicit credit pools render without a duration or fabricated pace`(showUsed: Bool) throws {
        let json = """
        {
          "balance_cents": 3000,
          "renewal_date_ts": \(self.now.addingTimeInterval(7200).timeIntervalSince1970),
          "current_period_purchased_cents": 3000,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 5000 },
            { "type": "promotional", "amount_cents": 4000 }
          ],
          "total_usage_cents": 9000
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: self.now)
            .toUsageSnapshot()
        let semantic = MenuBarLayoutSemanticWindowResolver.windows(provider: .perplexity, snapshot: snapshot)
        #expect(semantic.session == snapshot.primary)
        #expect(semantic.weekly == snapshot.secondary)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.primary?.resetsAt == self.now.addingTimeInterval(7200))
        #expect(snapshot.secondary?.resetsAt == nil)
        for window in [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self) {
            #expect(window.windowMinutes == nil)
            #expect(UsagePaceText.sessionPace(provider: .perplexity, window: window, now: self.now) == nil)
        }
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic, provider: .perplexity, snapshot: snapshot, supportsAverage: false)
        #expect(automatic?.remainingPercent == 75)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .perplexity, snapshot: snapshot, showUsed: showUsed) == (showUsed ? 25 : 75))
        let data = MenuBarLayoutRenderData(
            provider: .perplexity,
            iconKey: "perplexity",
            providerName: "Perplexity",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .perplexity, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(snapshot.primary),
            secondary: MenuBarLayoutRenderWindow(snapshot.secondary),
            tertiary: MenuBarLayoutRenderWindow(snapshot.tertiary),
            session: MenuBarLayoutRenderWindow(semantic.session),
            weekly: MenuBarLayoutRenderWindow(semantic.weekly),
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: MenuBarLayoutRenderWindow(automatic),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
        for (preference, expected): (MenuBarPercentWindowPreference, String) in [
            (.session, showUsed ? "S 100%" : "S 0%"),
            (.weekly, showUsed ? "B 25%" : "B 75%"),
            (.automatic, showUsed ? "25%" : "75%"),
        ] {
            let layout = preference.applied(to: MenuBarLayout(lines: [[.percent(window: .automatic)]]))
            let output = MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: showUsed,
                    conditionals: [],
                    appearanceName: NSAppearance.Name.aqua.rawValue,
                    isDebugApp: false,
                    now: self.now))
            if let path = ProcessInfo.processInfo.environment["CODEXBAR_PERPLEXITY_PERCENT_PROOF_DIR"] {
                let file = URL(fileURLWithPath: path)
                    .appendingPathComponent("\(preference.rawValue)-\(showUsed ? "used" : "remaining").txt")
                try output.attributedTitle.string.write(to: file, atomically: true, encoding: .utf8)
            }
            #expect(output.attributedTitle.string == expected)
        }
    }

    @Test
    func `automatic preserves credit consumption order with missing or exhausted pools`() {
        let recurring = RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: "recurring")
        let promo = RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: "bonus")
        let purchased = RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: "purchased")
        let exhausted = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "exhausted")
        for (primary, secondary, tertiary, expected): (RateWindow?, RateWindow?, RateWindow?, RateWindow?) in [
            (recurring, promo, purchased, recurring),
            (exhausted, promo, purchased, purchased),
            (nil, promo, purchased, purchased),
            (nil, promo, exhausted, promo),
            (exhausted, exhausted, exhausted, exhausted),
            (exhausted, nil, nil, exhausted),
            (nil, nil, nil, nil),
        ] {
            let snapshot = UsageSnapshot(
                primary: primary,
                secondary: secondary,
                tertiary: tertiary,
                updatedAt: self.now)
            #expect(snapshot.automaticPerplexityWindow() == expected)
        }
    }
}
