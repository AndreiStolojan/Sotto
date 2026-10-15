import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lists the local transcription models and local enhancement services.
struct ModelManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @ObservedObject private var warmupCoordinator = WhisperModelWarmupCoordinator.shared

    @State private var isSettingsPanelOpen = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if SystemArchitecture.isIntelMac {
                        intelMacWarningBanner
                    }

                    localModelsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sidePanel(isPresented: $isSettingsPanelOpen) {
            settingsPanelContent
        }
    }

    private var headerSection: some View {
        AppScreenHeader(title: "Model Catalog") {
            settingsButton
        }
    }

    private var settingsPanelContent: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Model Settings", onClose: { isSettingsPanelOpen = false })

            ModelSettingsPanel()
        }
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Model Settings"
        ) {
            isSettingsPanelOpen.toggle()
        }
    }

    private var localModelsSection: some View {
        VStack(spacing: 12) {
            ForEach(appleSpeechModels, id: \.id) { model in
                localModelCard(model)
            }

            ForEach(downloadableLocalModels, id: \.id) { model in
                localModelCard(model)
            }

            importLocalModelButton

            LocalEnhancementServiceManagementView()
                .environmentObject(aiService)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localModelCard(_ model: any TranscriptionModel) -> some View {
        let isWarming =
            (model as? WhisperModel).map { whisperModel in
                warmupCoordinator.isWarming(modelNamed: whisperModel.name)
            } ?? false

        return ModelCardView(
            model: model,
            isDownloaded: whisperModelManager.availableModels.contains { $0.name == model.name },
            downloadProgress: whisperModelManager.downloadProgress,
            modelURL: whisperModelManager.availableModels.first { $0.name == model.name }?.url,
            isWarming: isWarming,
            deleteAction: {
                deleteLocalModel(model)
            },
            downloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.startDownload(whisperModel)
                }
            },
            cancelDownloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.cancelDownload(whisperModel)
                }
            }
        )
    }

    private var importLocalModelButton: some View {
        HStack(spacing: 8) {
            Button(action: { presentImportPanel() }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Local Model…")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(AppMaterialCardBackground(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            InfoTip("Add a custom fine-tuned whisper model to use with Sotto. Select the downloaded .bin file.")
        }
    }

    private var intelMacWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Status.warningStrong)

            Text("Local models don't work reliably on Intel Macs")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.Status.warningStrong.opacity(0.08))
        .cornerRadius(8)
    }

    private var localModels: [any TranscriptionModel] {
        transcriptionModelManager.allAvailableModels.filter {
            transcriptionModelManager.isAvailableOnCurrentOS($0)
        }
    }

    private var appleSpeechModels: [any TranscriptionModel] {
        localModels.filter { $0.provider == .nativeApple }
    }

    private var downloadableLocalModels: [any TranscriptionModel] {
        localModels.filter { $0.provider != .nativeApple }
    }

    private func deleteLocalModel(_ model: any TranscriptionModel) {
        guard let downloadedModel = whisperModelManager.availableModels.first(where: { $0.name == model.name }) else {
            return
        }

        Task {
            await whisperModelManager.deleteModel(downloadedModel)
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.title = String(localized: "Select a Whisper ggml .bin model")
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await whisperModelManager.importWhisperModel(from: url)
            }
        }
    }
}
