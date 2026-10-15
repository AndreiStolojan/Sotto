import OSLog
import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case modes = "Modes"
    case models = "AI Models"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }
}

final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    @Published var selectedView: ViewType = .dashboard

    private init() {}

    func navigate(to destination: String) {
        guard let viewType = ViewType(rawValue: destination) else {
            return
        }

        navigate(to: viewType)
    }

    func navigate(to destination: ViewType) {
        selectedView = destination
    }
}

/// Main window: the sectioned sidebar beside the selected page, in Eclipse's dark style.
struct ContentView: View {
    private let logger = Logger(subsystem: "ro.andrei.Voce", category: "ContentView")
    @EnvironmentObject private var navigation: MainWindowNavigation

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(selectedView: $navigation.selectedView)

            VStack(spacing: 0) {
                if !navigation.selectedView.drawsOwnHeader {
                    AppScreenHeader(title: navigation.selectedView.title)
                }
                detailView(for: navigation.selectedView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.appPage, navigation.selectedView)
        }
        .frame(width: AppWindowLayout.main.width)
        .frame(minHeight: AppWindowLayout.main.minimumHeight)
        .background {
            // Same treatment as Eclipse: stays dark whether or not the window is key.
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(AppTheme.Window.tint)
                .ignoresSafeArea()
        }
        .tint(AppTheme.Window.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            logger.notice("ContentView appeared")
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String {
                logger.notice("navigateToDestination received: \(destination, privacy: .public)")
                navigation.navigate(to: destination)
            }
        }
    }

    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .models:
            ModelManagementView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            HistoryView()
        case .audio:
            AudioSetupView()
        case .dictionary:
            DictionarySettingsView()
        case .modes:
            ModeView()
        case .settings:
            SettingsView()
        }
    }
}
