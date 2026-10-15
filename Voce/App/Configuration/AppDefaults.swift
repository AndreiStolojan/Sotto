import AppKit
import Carbon.HIToolbox
import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum AutoLearnSettings {
    static let isEnabledKey = "IsAutoLearnDictionaryEnabled"
    static let providerKey = "AutoLearnDictionaryProvider"
    static let modelKey = "AutoLearnDictionaryModel"
    static let hasFailureKey = "AutoLearnDictionaryHasFailure"
    static let failureMessageKey = "AutoLearnDictionaryFailureMessage"
    static let failureAcknowledgedKey = "AutoLearnDictionaryFailureAcknowledged"
    static let reviewScheduleKey = "AutoLearnDictionaryReviewSchedule"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    static var selectedProvider: AIProvider? {
        guard let value = UserDefaults.standard.string(forKey: providerKey) else { return nil }
        return AIProvider(rawValue: value)
    }

    static var selectedModel: String? {
        let value = UserDefaults.standard.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static var reviewSchedule: AutoLearnReviewSchedule {
        guard let value = UserDefaults.standard.string(forKey: reviewScheduleKey) else {
            return .immediately
        }
        return AutoLearnReviewSchedule(rawValue: value) ?? .immediately
    }

    /// Adopts the first configured enhancement provider for Auto Learn.
    /// Once a Dictionary selection exists, provider configuration changes do not replace it.
    static func initializeSelectionIfNeeded(
        provider: AIProvider,
        model: String,
        defaults: UserDefaults = .standard
    ) {
        if let storedProvider = defaults.string(forKey: providerKey),
            AIProvider(rawValue: storedProvider) != nil
        {
            return
        }

        defaults.set(provider.rawValue, forKey: providerKey)
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedModel.isEmpty {
            defaults.removeObject(forKey: modelKey)
        } else {
            defaults.set(selectedModel, forKey: modelKey)
        }
    }

    static func recordFailure(_ error: Error) {
        let nsError = error as NSError
        var details = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason,
            !reason.isEmpty,
            !details.contains(reason)
        {
            details.append(reason)
        }
        if let suggestion = nsError.localizedRecoverySuggestion,
            !suggestion.isEmpty,
            !details.contains(suggestion)
        {
            details.append(suggestion)
        }
        let message = details
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        UserDefaults.standard.set(
            message.isEmpty ? "The selected provider or model could not review corrections." : message,
            forKey: failureMessageKey
        )
        UserDefaults.standard.set(false, forKey: failureAcknowledgedKey)
        UserDefaults.standard.set(true, forKey: hasFailureKey)
    }

    static func clearFailure() {
        UserDefaults.standard.set(false, forKey: hasFailureKey)
        UserDefaults.standard.removeObject(forKey: failureMessageKey)
        UserDefaults.standard.removeObject(forKey: failureAcknowledgedKey)
    }

    static func acknowledgeCurrentFailure(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: failureAcknowledgedKey)
    }
}

enum OnboardingSettings {
    static let completedV2Key = "hasCompletedOnboardingV2"
    static let preparedV2Key = "hasPreparedOnboardingV2"
}

/// Prepares the local dictation profile before recording and model managers load it.
/// Menu bar only and the fixed Fn shortcut are enforced on every launch, including after an
/// interrupted setup; the model, language, AutoLearn and enhancement seeds run once. Existing modes
/// move onto the Latin script filter in `ModeDataMigration`, when `ModeManager` loads them.
@MainActor
enum LocalPrototypeSettings {
    static let defaultModelName = "parakeet-tdt-0.6b-v3"
    private static let configuredKey = "VoceLocalProfileConfigured"
    private static let enhancementResetKey = "VoceEnhancementResetV1"

    static func configure() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "IsMenuBarOnly")
        ShortcutStore.setShortcut(
            .modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function]),
            for: .primaryRecording
        )
        defaults.set(
            RecordingShortcutManager.ShortcutSelection.custom.rawValue,
            forKey: "primaryRecordingShortcut"
        )
        defaults.set(RecordingShortcutManager.Mode.doubleTap.rawValue, forKey: "primaryRecordingShortcutMode")

        if !defaults.bool(forKey: configuredKey) {
            defaults.set(false, forKey: AutoLearnSettings.isEnabledKey)
            defaults.set(defaultModelName, forKey: "CurrentTranscriptionModel")
            defaults.set(LanguageDictionary.latinScriptKey, forKey: "SelectedLanguage")
            defaults.set(true, forKey: configuredKey)
        }

        // Upstream modes ship with enhancement on. With Ollama running, every stop would wait
        // for an LLM pass before inserting text. Turn it off once; the mode editor can re-enable it.
        if !defaults.bool(forKey: enhancementResetKey) {
            let modeKey = "modeConfigurationsV2"
            if let data = defaults.data(forKey: modeKey),
                var modes = try? JSONDecoder().decode([ModeConfig].self, from: data)
            {
                for index in modes.indices {
                    modes[index].isAIEnhancementEnabled = false
                }
                if let localModes = try? JSONEncoder().encode(modes) {
                    defaults.set(localModes, forKey: modeKey)
                }
            }
            defaults.set(true, forKey: enhancementResetKey)
        }
    }
}

enum AppDefaults {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Onboarding & General
            OnboardingSettings.completedV2Key: false,
            OnboardingSettings.preparedV2Key: false,

            // Clipboard
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,

            // Audio & Media
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
                .rawValue,

            // Recording & Transcription
            "IsTextFormattingEnabled": true,
            "IsVADEnabled": true,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": true,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,
            AutoLearnSettings.isEnabledKey: true,
            AutoLearnSettings.reviewScheduleKey: AutoLearnReviewSchedule.immediately.rawValue,

            // Cleanup
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,

            // UI & Behavior
            "IsMenuBarOnly": false,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
            // Enhancement
            "SkipShortEnhancement": false,
            "ShortEnhancementWordThreshold": 3,
            EnhancementRequestSettings.timeoutKey: EnhancementRequestSettings.defaultTimeoutSeconds,
            EnhancementRequestSettings.retryOnTimeoutKey: EnhancementRequestSettings.defaultRetryOnTimeout,

            // Model
            "PrewarmModelOnWake": true,

        ])

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
