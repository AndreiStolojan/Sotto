import AppKit
import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboardingV2: Bool
    @EnvironmentObject var fluidAudioModelManager: FluidAudioModelManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var aiService: AIService
    @EnvironmentObject var enhancementService: AIEnhancementService
    @StateObject private var coordinator = OnboardingCoordinator()
    let contentMaxWidth: CGFloat = 560

    var body: some View {
        let isTranscriptionSetupReady = coordinator.isTranscriptionModelDownloaded(
            using: fluidAudioModelManager
        )

        ZStack(alignment: .bottomLeading) {
            OnboardingBackground()

            Group {
                switch coordinator.stage {
                case .permissions:
                    OnboardingPermissionsScreen(
                        contentMaxWidth: contentMaxWidth,
                        isComplete: coordinator.requiredPermissionsGranted,
                        activePermission: coordinator.activePermission,
                        hasRequestedScreenRecording: coordinator.hasRequestedScreenRecording,
                        stepNumber: { coordinator.permissions.stepNumber(for: $0) },
                        status: { coordinator.permissions.status(for: $0) },
                        isLocked: { coordinator.permissions.isLocked($0) },
                        actionTitle: { coordinator.permissions.actionTitle(for: $0) },
                        onSelect: coordinator.permissions.setActivePermission,
                        onAction: coordinator.permissions.performAction,
                        onQuit: {
                            NSApplication.shared.terminate(nil)
                        },
                        onRecheck: coordinator.permissions.refreshPermissionStatuses,
                        onContinue: coordinator.flow.goToMicrophoneStep
                    )
                    .transition(.opacity)
                case .microphone:
                    OnboardingMicrophoneScreen(
                        contentMaxWidth: contentMaxWidth,
                        onBack: coordinator.flow.goToPermissionsStep,
                        onContinue: coordinator.flow.goToModelStep
                    )
                    .transition(.opacity)
                case .model:
                    OnboardingModelScreen(
                        contentMaxWidth: contentMaxWidth,
                        localModel: coordinator.requiredTranscriptionModel,
                        isLocalDownloaded: isTranscriptionSetupReady,
                        isLocalDownloading: coordinator.requiredTranscriptionModel.map {
                            fluidAudioModelManager.isFluidAudioModelDownloading($0)
                        } ?? false,
                        localDownloadStatus: coordinator.requiredTranscriptionModel.flatMap {
                            fluidAudioModelManager.downloadStatus(for: $0)
                        },
                        onDownload: {
                            coordinator.flow.downloadTranscriptionModel(
                                $0,
                                modelManager: fluidAudioModelManager
                            )
                        },
                        onCancelDownload: {
                            fluidAudioModelManager.cancelDownload($0)
                        },
                        onBack: coordinator.flow.goToMicrophoneStep,
                        onContinue: {
                            coordinator.flow.goToExperienceStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                enhancementService: enhancementService
                            )
                        }
                    )
                    .transition(.opacity)
                case .experience:
                    OnboardingExperienceScreen(
                        step: coordinator.experienceStep,
                        isInIntroPhase: coordinator.isShowingExperienceIntroPhase,
                        shortcutAction: coordinator.experienceShortcutAction,
                        hasShortcut: coordinator.hasExperienceModeShortcut,
                        text: coordinator.currentExperienceText,
                        isLastStep: coordinator.isLastExperienceStep,
                        isReady: coordinator.isCurrentExperienceReady(
                            isTranscriptionSetupReady: isTranscriptionSetupReady
                        ),
                        isComplete: coordinator.isCurrentExperienceComplete,
                        onBackFromIntro: {
                            coordinator.flow.goToPreviousExperienceStep(enhancementService: enhancementService)
                        },
                        onContinueIntro: coordinator.flow.goToExperiencePracticePhase,
                        onBackFromPractice: {
                            coordinator.flow.goBackFromExperiencePractice(enhancementService: enhancementService)
                        },
                        onAdvance: {
                            coordinator.flow.advanceExperienceStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                enhancementService: enhancementService
                            )
                        },
                        onShortcutChanged: {
                            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
                        },
                        onAppear: coordinator.flow.activateExperienceModeForDemo
                    )
                    .transition(.opacity)
                case .contextAwareness:
                    OnboardingContextAwarenessScreen(
                        contentMaxWidth: contentMaxWidth,
                        onBack: {
                            coordinator.flow.goToPreviousContextAwarenessStep(
                                enhancementService: enhancementService
                            )
                        },
                        onContinue: {
                            coordinator.flow.continueFromContextAwarenessStep(
                                enhancementService: enhancementService
                            )
                        }
                    )
                    .transition(.opacity)
                case .trust:
                    OnboardingTrustScreen(
                        contentMaxWidth: contentMaxWidth,
                        onBack: {
                            coordinator.flow.goToPreviousTrustStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                enhancementService: enhancementService
                            )
                        },
                        onContinue: {
                            coordinator.flow.completeOnboarding(
                                isTranscriptionSetupReady: isTranscriptionSetupReady
                            ) {
                                hasCompletedOnboardingV2 = true
                            }
                        }
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OnboardingProgressBadge(
                currentStep: coordinator.currentStepNumber,
                totalSteps: coordinator.totalStepCount
            )
            .padding(.leading, 28)
            .padding(.bottom, 26)
            .allowsHitTesting(false)

        }
        .frame(minWidth: 820, minHeight: 680)
        .animation(.easeInOut(duration: 0.22), value: coordinator.stage)
        .onAppear {
            coordinator.permissions.refreshPermissionStatuses()
            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
            coordinator.flow.reconcileStage(
                isTranscriptionSetupReady: coordinator.isTranscriptionModelDownloaded(using: fluidAudioModelManager),
                enhancementService: enhancementService
            )
        }
        .onDisappear {
            coordinator.permissions.cancelRefreshTask()
        }
        .onReceive(LifecycleObserver.shared.publisher(for: .applicationDidBecomeActive)) { _ in
            coordinator.permissions.refreshPermissionStatuses()
            coordinator.flow.reconcileStage(
                isTranscriptionSetupReady: coordinator.isTranscriptionModelDownloaded(using: fluidAudioModelManager),
                enhancementService: enhancementService
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            guard let action = notification.object as? ShortcutAction,
                action == coordinator.experienceShortcutAction
            else {
                return
            }

            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modeConfigurationsDidChange)) { _ in
            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
        }
        .onChange(of: coordinator.stage) { _, _ in
            coordinator.flow.activateExperienceModeForDemo()
            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
        }
    }

}

#Preview {
    OnboardingView(hasCompletedOnboardingV2: .constant(false))
}
