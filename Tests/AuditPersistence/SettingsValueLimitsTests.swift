import Foundation

/// Checks the bounds that keep imported or hand-edited delay settings from
/// trapping when readers convert seconds to nanoseconds.
@main
enum SettingsValueLimitsTests {
    private static var failures = 0

    static func main() {
        let restore = SettingsValueLimits.clipboardRestoreDelay
        expect(SettingsValueLimits.clamped(2, to: restore) == 2, "keeps an in-range delay")
        expect(SettingsValueLimits.clamped(-10, to: restore) == 0.25, "raises a negative delay to the minimum")
        expect(SettingsValueLimits.clamped(1e300, to: restore) == 5, "caps a huge delay")
        expect(SettingsValueLimits.clamped(.infinity, to: restore) == 0.25, "replaces infinity")
        expect(SettingsValueLimits.clamped(.nan, to: restore) == 0.25, "replaces NaN")

        let resume = SettingsValueLimits.audioResumptionDelay
        expect(SettingsValueLimits.clamped(-.infinity, to: resume) == 0, "replaces negative infinity")
        expect(SettingsValueLimits.clamped(7, to: resume) == 5, "caps the resume delay")

        // Every clamped delay must convert to nanoseconds without trapping.
        for value in [Double.nan, .infinity, -.infinity, -1, 1e300, Double.greatestFiniteMagnitude] {
            let seconds = SettingsValueLimits.clamped(value, to: restore)
            _ = UInt64(seconds * 1_000_000_000)
        }

        let minutes = SettingsValueLimits.transcriptionRetentionMinutes
        expect(!minutes.contains(-1), "rejects negative retention minutes")
        expect(!minutes.contains(Int.max), "rejects retention minutes that overflow when multiplied by 60")
        expect(minutes.contains(7 * 24 * 60), "accepts the longest retention the picker offers")
        expect(minutes.upperBound.multipliedReportingOverflow(by: 60).overflow == false, "upper bound converts to seconds")

        let days = SettingsValueLimits.audioRetentionDays
        expect(!days.contains(0), "rejects a zero-day audio retention that would delete all audio")
        expect(!days.contains(-7), "rejects negative audio retention")
        expect(days.contains(30), "accepts the longest audio retention the picker offers")

        if failures > 0 {
            print("FAIL: \(failures) settings value limit check(s)")
            exit(1)
        }
        print("PASS: settings value limits")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}
