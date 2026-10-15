import SwiftUI

/// Sectioned sidebar after Eclipse's app window: group titles, colored icon tiles, a soft selection fill.
struct AppSidebar: View {
    @Binding var selectedView: ViewType

    static let width: CGFloat = 196

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ViewType.sidebarGroups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                ForEach(group.pages) { page in
                    SidebarItemButton(viewType: page, isSelected: selectedView == page) {
                        selectedView = page
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1).ignoresSafeArea()
        }
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
        }
    }
}

extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .transcribeAudio:
            return "Transcribe"
        default:
            return LocalizedStringKey(rawValue)
        }
    }

    static let sidebarGroups: [(title: LocalizedStringKey?, pages: [ViewType])] = [
        (nil, [.dashboard]),
        ("Dictation", [.modes, .history, .transcribeAudio]),
        ("Words", [.dictionary]),
        ("Engine", [.models, .audio]),
        ("Sotto", [.settings]),
    ]

    static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
            let sidebarItems = sidebarGroups.flatMap(\.pages)
            assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .transcribeAudio: return "waveform.path"
        case .history: return "doc.text.fill"
        case .models: return "cpu"
        case .modes: return "sparkles.square.fill.on.square"
        case .audio: return "mic.fill"
        case .dictionary: return "text.book.closed.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: return AppTheme.Sidebar.dashboard
        case .modes: return AppTheme.Sidebar.modes
        case .models: return AppTheme.Sidebar.models
        case .dictionary: return AppTheme.Sidebar.dictionary
        case .history: return AppTheme.Sidebar.audio
        case .transcribeAudio: return AppTheme.Sidebar.transcribeAudio
        case .audio, .settings: return AppTheme.Sidebar.fallback
        }
    }

    /// Pages that draw their own `AppScreenHeader` because it carries buttons; the window adds a plain one for the rest.
    var drawsOwnHeader: Bool {
        [.modes, .dictionary, .models].contains(self)
    }
}

private struct SidebarItemButton: View {
    let viewType: ViewType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PageIconTile(page: viewType, size: 22)
                Text(viewType.title)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A page's SF Symbol on its colored rounded tile, used in the sidebar and page headers.
struct PageIconTile: View {
    let page: ViewType
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(page.tint)
            Image(systemName: page.icon)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
