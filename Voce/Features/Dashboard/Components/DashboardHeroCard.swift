import Foundation
import SwiftUI

enum DashboardHeroHeadline {
    case calculatingProgress
    case startRecordingProgress
    case savedTime(String)
}

struct DashboardHeroCard: View {
    private static let headlineFont: Font = .system(size: 18, weight: .bold)
    private static let highlightedHeadlineFont: Font = .system(size: 18, weight: .bold)

    let isLocked: Bool
    let headline: DashboardHeroHeadline
    let subtext: String
    let actionTitle: LocalizedStringKey
    let actionIcon: String
    let canViewInsights: Bool
    let actionHelp: String
    let actionAccessibilityLabel: String
    let reviewCorrectionCount: Int?
    let onViewInsights: () -> Void
    let onReviewCorrections: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLocked {
                lockedInsightsPrompt
            } else {
                heroCopy
            }

            HStack(spacing: 12) {
                Button(action: onViewInsights) {
                    DashboardMomentumActionLabel(
                        title: actionTitle,
                        icon: actionIcon,
                        isPrimary: canViewInsights,
                        isLocked: !canViewInsights
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canViewInsights)
                .help(actionHelp)
                .accessibilityLabel(Text(actionAccessibilityLabel))

                if let reviewCorrectionCount {
                    Button(action: onReviewCorrections) {
                        DashboardMomentumActionLabel(
                            title: "Review Corrections",
                            icon: "text.book.closed",
                            isPrimary: false
                        )
                    }
                    .buttonStyle(.plain)
                    .help(reviewCorrectionsHelp(count: reviewCorrectionCount))
                    .accessibilityLabel("Review corrections")
                    .accessibilityValue(
                        Text(
                            String(
                                format: String(localized: "%lld pending corrections"),
                                Int64(reviewCorrectionCount)
                            )
                        )
                    )
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DashboardLayout.cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .strokeBorder(Color.white.opacity(0.06))
        )
    }

    private func reviewCorrectionsHelp(count: Int) -> String {
        String(
            format: String(localized: "Review %lld pending corrections"),
            Int64(count)
        )
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            headlineText
                .fixedSize(horizontal: false, vertical: true)

            Text(subtext)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headlineText: Text {
        Text(styledHeadline)
    }

    private var styledHeadline: AttributedString {
        let highlightedValue: String
        var text: AttributedString

        switch headline {
        case .calculatingProgress:
            highlightedValue = String(localized: "Sotto progress")
            text = AttributedString(localized: "Calculating \(highlightedValue).")
        case .startRecordingProgress:
            highlightedValue = String(localized: "Sotto progress")
            text = AttributedString(localized: "Start recording to build \(highlightedValue).")
        case .savedTime(let value):
            highlightedValue = value
            text = AttributedString(localized: "You have saved \(highlightedValue) with Sotto")
        }

        text.font = Self.headlineFont
        text.foregroundColor = DashboardMomentumBackground.headline

        if let highlightedRange = text.range(of: highlightedValue) {
            text[highlightedRange].font = Self.highlightedHeadlineFont
            text[highlightedRange].foregroundColor = DashboardMomentumBackground.accent
        }

        return text
    }

    private var lockedInsightsPrompt: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DashboardMomentumBackground.accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.1)))

            Text("Continue using Sotto to unlock stats and insights.")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DashboardMomentumBackground.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardMomentumActionLabel: View {
    private static let cornerRadius: CGFloat = 14

    let title: LocalizedStringKey
    let icon: String
    let isPrimary: Bool
    var isLocked = false

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .lineLimit(1)

            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(backgroundColor))
    }

    private var foregroundColor: Color {
        if isPrimary {
            return AppTheme.Text.onAccent
        }

        return isLocked ? AppTheme.Text.secondary : AppTheme.Text.primary
    }

    private var backgroundColor: Color {
        isPrimary ? DashboardMomentumBackground.accent : Color.white.opacity(0.1)
    }


}

private enum DashboardMomentumBackground {
    static let accent = AppTheme.Window.accent
    static let headline = AppTheme.Text.primary
}
