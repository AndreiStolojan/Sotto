import SwiftUI

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published var storedStage: String {
        didSet {
            defaults.set(storedStage, forKey: OnboardingStorageKeys.stage)
        }
    }

    @Published var storedActivePermission: String {
        didSet {
            defaults.set(storedActivePermission, forKey: OnboardingStorageKeys.activePermission)
        }
    }

    @Published var hasRequestedScreenRecording: Bool {
        didSet {
            defaults.set(hasRequestedScreenRecording, forKey: OnboardingStorageKeys.requestedScreenRecording)
        }
    }

    @Published var experienceStepIndex: Int {
        didSet {
            defaults.set(experienceStepIndex, forKey: OnboardingStorageKeys.experienceIndex)
        }
    }

    @Published var permissionStatuses: [OnboardingPermissionKind: OnboardingPermissionStatus] = [:]
    @Published var hasExperienceModeShortcut = false
    @Published var isExperienceModeInstalled = false
    @Published var experienceTextByKind: [OnboardingExperienceKind: String] = [:]
    @Published var isExperienceInIntroPhase = true
    @Published var clearedExperienceShortcutActions: Set<ShortcutAction> = []

    let defaults: UserDefaults
    var refreshTask: Task<Void, Never>?
    lazy var flow = OnboardingFlowController(coordinator: self)
    lazy var permissions = OnboardingPermissionController(coordinator: self)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storedStage = defaults.string(forKey: OnboardingStorageKeys.stage) ?? OnboardingStage.permissions.rawValue
        self.storedActivePermission =
            defaults.string(forKey: OnboardingStorageKeys.activePermission)
            ?? OnboardingPermissionKind.microphone.rawValue
        self.hasRequestedScreenRecording = defaults.bool(forKey: OnboardingStorageKeys.requestedScreenRecording)
        self.experienceStepIndex = defaults.integer(forKey: OnboardingStorageKeys.experienceIndex)
        // The local profile supplies Fn up front; the dictation introduction must preserve it.
        clearedExperienceShortcutActions.insert(.primaryRecording)
    }

    deinit {
        refreshTask?.cancel()
    }

    var stage: OnboardingStage {
        if let stage = OnboardingStage(rawValue: storedStage) {
            return stage
        }

        // Stages removed from this fork map to their nearest neighbour.
        switch storedStage {
        case "starterMode", "shortcut":
            return .experience
        case "parakeet", "api":
            return .model
        case "license":
            return .trust
        default:
            return .permissions
        }
    }

    var activePermission: OnboardingPermissionKind {
        OnboardingPermissionKind(rawValue: storedActivePermission) ?? .microphone
    }

    var requiredPermissionsGranted: Bool {
        OnboardingPermissionKind.required.allSatisfy { permissions.status(for: $0).isGranted }
    }

    var hasSelectedOnboardingMicrophone: Bool {
        defaults.audioInputModeRawValue == AudioInputMode.custom.rawValue && defaults.selectedAudioDeviceUID != nil
    }

    var currentStepNumber: Int {
        if stage == .experience {
            return experienceStepNumber(for: normalizedExperienceStepIndex)
        }

        if stage == .contextAwareness {
            return contextAwarenessStepNumber
        }

        if stage == .trust {
            return OnboardingStage.baseStepCount + activeExperienceSteps.count + contextAwarenessStepCount + 1
        }

        return stage.stepNumber
    }

    var totalStepCount: Int {
        OnboardingStage.baseStepCount + activeExperienceSteps.count + contextAwarenessStepCount + 1
    }

    var experienceStep: OnboardingExperienceStep {
        if activeExperienceSteps.indices.contains(normalizedExperienceStepIndex) {
            return activeExperienceSteps[normalizedExperienceStepIndex]
        }

        return OnboardingExperienceCatalog.steps[0]
    }

    var experienceModeTemplate: StarterModeTemplate {
        StarterModeCatalog.templates.first { $0.kind == experienceStep.starterModeKind }
            ?? StarterModeCatalog.templates[0]
    }

    var normalizedExperienceStepIndex: Int {
        min(max(experienceStepIndex, 0), max(activeExperienceSteps.count - 1, 0))
    }

    var isLastExperienceStep: Bool {
        normalizedExperienceStepIndex == activeExperienceSteps.count - 1
    }

    var experienceShortcutAction: ShortcutAction {
        experienceStep.shortcutAction(modeTemplate: experienceModeTemplate)
    }

    var shouldSkipCurrentExperienceIntro: Bool {
        experienceStep.shouldSkipShortcutIntro(
            hasConfiguredShortcut: ShortcutStore.shortcut(for: experienceShortcutAction) != nil
        )
    }

    var shouldShowContextAwarenessAfterCurrentExperience: Bool {
        guard experienceStep.showsContextAwarenessAfterCompletion else { return false }
        let nextIndex = normalizedExperienceStepIndex + 1
        return activeExperienceSteps.indices.contains(nextIndex) || isLastExperienceStep
    }

    var shouldShowContextAwarenessBeforeCurrentExperience: Bool {
        let previousIndex = normalizedExperienceStepIndex - 1
        guard activeExperienceSteps.indices.contains(previousIndex) else {
            return false
        }

        return activeExperienceSteps[previousIndex].showsContextAwarenessAfterCompletion
    }

    var isShowingExperienceIntroPhase: Bool {
        isExperienceInIntroPhase && !shouldSkipCurrentExperienceIntro
    }

    var currentExperienceText: Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return "" }
                return experienceTextByKind[experienceStep.kind] ?? experienceStep.initialFieldText
            },
            set: { [weak self] newValue in
                guard let self else { return }
                var updatedText = experienceTextByKind
                updatedText[experienceStep.kind] = newValue
                experienceTextByKind = updatedText
            }
        )
    }

    var isCurrentExperienceComplete: Bool {
        if !experienceStep.requiresTextChangeForCompletion {
            return true
        }

        let text = experienceTextByKind[experienceStep.kind] ?? ""
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialText = experienceStep.initialFieldText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !initialText.isEmpty {
            return !trimmedText.isEmpty && trimmedText != initialText
        }

        return !trimmedText.isEmpty
    }

    /// Onboarding only demonstrates local dictation; AI experiences need a configured local provider later.
    var activeExperienceSteps: [OnboardingExperienceStep] {
        OnboardingExperienceCatalog.steps.filter { !$0.requiresVerifiedAPIProvider }
    }

    private var contextAwarenessInsertionIndices: [Int] {
        activeExperienceSteps.indices.compactMap { index in
            guard activeExperienceSteps[index].showsContextAwarenessAfterCompletion else {
                return nil
            }

            return index + 1
        }
    }

    private var contextAwarenessStepCount: Int {
        contextAwarenessInsertionIndices.count
    }

    private var contextAwarenessStepNumber: Int {
        guard let insertionIndex = contextAwarenessInsertionIndices.first else {
            return OnboardingStage.baseStepCount + activeExperienceSteps.count + 1
        }

        return OnboardingStage.baseStepCount + insertionIndex + 1
    }

    private func experienceStepNumber(for index: Int) -> Int {
        let priorContextScreens = contextAwarenessInsertionIndices.filter { $0 <= index }.count
        return OnboardingStage.baseStepCount + index + priorContextScreens + 1
    }

    var requiredTranscriptionModel: FluidAudioModel? {
        TranscriptionModelRegistry.models
            .compactMap { $0 as? FluidAudioModel }
            .first { $0.name == LocalPrototypeSettings.defaultModelName }
    }

    var selectedOnboardingTranscriptionModelName: String? {
        requiredTranscriptionModel?.selectionKey
    }

    var selectedOnboardingTranscriptionUsesRealtime: Bool {
        guard let model = requiredTranscriptionModel else { return true }
        return TranscriptionRealtimeSupport.isEnabled(for: model)
    }

    var selectedOnboardingTranscriptionLanguage: String {
        guard let model = requiredTranscriptionModel else { return "auto" }
        return TranscriptionLanguageSupport.validLanguageOrFallback(nil, for: model)
    }

    func isTranscriptionModelDownloaded(using modelManager: FluidAudioModelManager) -> Bool {
        guard let requiredTranscriptionModel else { return false }
        return modelManager.isFluidAudioModelDownloaded(requiredTranscriptionModel)
    }

    func isReadyForExperience(isTranscriptionSetupReady: Bool) -> Bool {
        requiredPermissionsGranted && hasSelectedOnboardingMicrophone && isTranscriptionSetupReady
    }

    func isCurrentExperienceReady(isTranscriptionSetupReady: Bool) -> Bool {
        isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady) && isExperienceModeInstalled
            && hasExperienceModeShortcut
    }

}

enum OnboardingStorageKeys {
    static let stage = "onboardingStage"
    static let activePermission = "onboardingActivePermission"
    static let requestedScreenRecording = "onboardingRequestedScreenRecording"
    static let experienceIndex = "onboardingExperienceIndex"

    /// Includes keys written by removed stages so old defaults are still cleared.
    static let onboardingKeys = [
        stage,
        activePermission,
        requestedScreenRecording,
        experienceIndex,
        "onboardingAIProvider",
        "onboardingTranscriptionSetupKind",
        "onboardingTranscriptionProvider",
        "onboardingSkippedAPISetup",
        "onboardingStarterModeIndex",
    ]
}
