import SwiftUI

/// Download card for the required local Parakeet model.
struct OnboardingTranscriptionSetupCard: View {
    let localModel: FluidAudioModel?
    let isLocalDownloaded: Bool
    let isLocalDownloading: Bool
    let localDownloadStatus: FluidAudioDownloadStatus?
    let onDownloadLocalModel: (FluidAudioModel) -> Void
    let onCancelLocalModelDownload: (FluidAudioModel) -> Void

    var body: some View {
        if let localModel {
            TranscriptionModelDownloadCard(
                model: localModel,
                isDownloaded: isLocalDownloaded,
                isDownloading: isLocalDownloading,
                status: localDownloadStatus,
                onDownload: {
                    onDownloadLocalModel(localModel)
                },
                onCancel: {
                    onCancelLocalModelDownload(localModel)
                }
            )
        } else {
            missingModelPanel
        }
    }

    private var missingModelPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Status.error)

            Text("Parakeet V3 is not available.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Text.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(AppMaterialCardBackground(cornerRadius: 12))
    }
}
