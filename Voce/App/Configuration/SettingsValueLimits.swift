import Foundation

/// Bounds for numeric settings that come from UserDefaults or imported backups.
/// Readers clamp delays so a bad value cannot overflow a nanosecond conversion.
enum SettingsValueLimits {
    static let clipboardRestoreDelay: ClosedRange<Double> = 0.25...5
    static let audioResumptionDelay: ClosedRange<Double> = 0...5
    static let transcriptionRetentionMinutes: ClosedRange<Int> = 0...(3650 * 24 * 60)
    static let audioRetentionDays: ClosedRange<Int> = 1...3650

    /// Clamps a finite value into `range`. NaN and infinity become the lower bound.
    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
